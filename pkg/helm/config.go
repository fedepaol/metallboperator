/*


Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package helm

import (
	"context"
	"os"
	"strconv"
	"strings"

	metallbv1beta1 "github.com/metallb/metallb-operator/api/v1beta1"
	"github.com/pkg/errors"
	apiext "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type chartConfig struct {
	isOpenShift      bool
	isFrrEnabled     bool
	controllerImage  *imageInfo
	speakerImage     *imageInfo
	frrImage         *imageInfo
	mlBindPort       int
	frrMetricsPort   int
	metricsPort      int
	enablePodMonitor bool
}

type imageInfo struct {
	repo string
	tag  string
}

func patchToChartValues(c *chartConfig, crdConfig *metallbv1beta1.MetalLB, valueMap map[string]interface{}) {
	withPrometheusValues(c, valueMap)
	withControllerValues(c, crdConfig, valueMap)
	withSpeakerValues(c, crdConfig, valueMap)
}

func withPrometheusValues(c *chartConfig, valueMap map[string]interface{}) {
	valueMap["prometheus"] = map[string]interface{}{
		"metricsPort": c.metricsPort,
		"podMonitor": map[string]interface{}{
			"enabled": c.enablePodMonitor,
		},
	}
}

func withControllerValues(c *chartConfig, crdConfig *metallbv1beta1.MetalLB, valueMap map[string]interface{}) {
	logLevel := metallbv1beta1.LogLevelInfo
	if crdConfig.Spec.LogLevel != "" {
		logLevel = crdConfig.Spec.LogLevel
	}
	if c.isOpenShift {
		valueMap["controller"] = map[string]interface{}{
			"image": map[string]interface{}{
				"repository": c.controllerImage.repo,
				"tag":        c.controllerImage.tag,
			},
			"serviceAccount": map[string]interface{}{
				"create": false,
				"name":   "controller",
			},
			"logLevel": logLevel,
			"securityContext": map[string]interface{}{
				"runAsNonRoot": true,
			},
		}
		return
	}
	valueMap["controller"] = map[string]interface{}{
		"image": map[string]interface{}{
			"repository": c.controllerImage.repo,
			"tag":        c.controllerImage.tag,
		},
		"serviceAccount": map[string]interface{}{
			"create": false,
			"name":   "controller",
		},
		"logLevel": logLevel,
	}
}

func withSpeakerValues(c *chartConfig, crdConfig *metallbv1beta1.MetalLB, valueMap map[string]interface{}) {
	logLevel := metallbv1beta1.LogLevelInfo
	if crdConfig.Spec.LogLevel != "" {
		logLevel = crdConfig.Spec.LogLevel
	}
	valueMap["speaker"] = map[string]interface{}{
		"image": map[string]interface{}{
			"repository": c.speakerImage.repo,
			"tag":        c.speakerImage.tag,
		},
		"serviceAccount": map[string]interface{}{
			"create": false,
			"name":   "speaker",
		},
		"frr": map[string]interface{}{
			"enabled": c.isFrrEnabled,
			"image": map[string]interface{}{
				"repository": c.frrImage.repo,
				"tag":        c.frrImage.tag,
			},
			"metricsPort": c.frrMetricsPort,
		},
		"memberlist": map[string]interface{}{
			"enabled":    true,
			"mlBindPort": c.mlBindPort,
		},
		"logLevel": logLevel,
	}
	if crdConfig.Spec.SpeakerNodeSelector != nil {
		valueMap["speaker"].(map[string]interface{})["nodeSelector"] = crdConfig.Spec.SpeakerNodeSelector
	}
	if crdConfig.Spec.SpeakerTolerations != nil {
		valueMap["speaker"].(map[string]interface{})["tolerations"] = crdConfig.Spec.SpeakerTolerations
	}
}

func loadConfig(client client.Client, isOCP bool) (*chartConfig, error) {
	config := &chartConfig{isOpenShift: isOCP}
	var err error
	ctrlImage := os.Getenv("CONTROLLER_IMAGE")
	if ctrlImage == "" {
		return nil, errors.Errorf("CONTROLLER_IMAGE env variable must be set")
	}
	controllerRepo, controllerTag := getImageNameTag(ctrlImage)
	config.controllerImage = &imageInfo{controllerRepo, controllerTag}
	speakerImage := os.Getenv("SPEAKER_IMAGE")
	if speakerImage == "" {
		return nil, errors.Errorf("SPEAKER_IMAGE env variable must be set")
	}
	speakerRepo, speakerTag := getImageNameTag(speakerImage)
	config.speakerImage = &imageInfo{speakerRepo, speakerTag}
	config.frrImage = &imageInfo{}
	if os.Getenv("METALLB_BGP_TYPE") == bgpFrr {
		config.isFrrEnabled = true
		frrImage := os.Getenv("FRR_IMAGE")
		if frrImage == "" {
			return nil, errors.Errorf("FRR_IMAGE env variable must be set")
		}
		config.frrImage.repo, config.frrImage.tag = getImageNameTag(frrImage)
	}
	config.mlBindPort, err = valueWithDefault("MEMBER_LIST_BIND_PORT", 7946)
	if err != nil {
		return nil, err
	}
	config.frrMetricsPort, err = valueWithDefault("FRR_METRICS_PORT", 7473)
	if err != nil {
		return nil, err
	}
	config.metricsPort, err = valueWithDefault("METRICS_PORT", 7472)
	if err != nil {
		return nil, err
	}
	// We shouldn't spam the api server trying to apply PodMonitors if the resource isn't installed.
	if os.Getenv("DEPLOY_PODMONITORS") == "true" && podMonitorAvailable(client) {
		config.enablePodMonitor = true
	}
	return config, nil
}

func valueWithDefault(name string, def int) (int, error) {
	val := os.Getenv(name)
	if val != "" {
		res, err := strconv.Atoi(val)
		if err != nil {
			return 0, err
		}
		return res, nil
	}
	return def, nil
}

func getImageNameTag(envValue string) (string, string) {
	img := strings.Split(envValue, ":")
	if len(img) == 1 {
		return img[0], ""
	}
	return img[0], img[1]
}

func podMonitorAvailable(c client.Client) bool {
	crd := &apiext.CustomResourceDefinition{}
	err := c.Get(context.Background(), client.ObjectKey{Name: "podmonitors.monitoring.coreos.com"}, crd)
	return err == nil
}
