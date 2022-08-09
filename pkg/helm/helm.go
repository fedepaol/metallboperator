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
	"bytes"
	"io"
	"strings"

	metallbv1beta1 "github.com/metallb/metallb-operator/api/v1beta1"
	"github.com/pkg/errors"
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/cli/values"
	"helm.sh/helm/v3/pkg/getter"
	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	bgpFrr = "frr"
)

// MetalLBChart metallb chart struct containing references which helps to
// to retrieve manifests from chart after patching given custom values.
type MetalLBChart struct {
	client      *action.Install
	envSettings *cli.EnvSettings
	chart       *chart.Chart
	config      *chartConfig
	namespace   string
}

// GetObjects retrieve manifests from chart after patching custom values passed in crdConfig
// and environment variables.
func (h *MetalLBChart) GetObjects(crdConfig *metallbv1beta1.MetalLB, withPrometheus bool) ([]*unstructured.Unstructured, error) {
	chartValueOpts := &values.Options{}
	chartValues, err := chartValueOpts.MergeValues(getter.All(h.envSettings))
	if err != nil {
		return nil, err
	}

	patchToChartValues(h.config, crdConfig, withPrometheus, chartValues)
	release, err := h.client.Run(h.chart, chartValues)
	if err != nil {
		return nil, err
	}
	objs, err := parseManifest(release.Manifest)
	if err != nil {
		return nil, err
	}
	for i, obj := range objs {
		// Set namespace explicitly into non cluster-scoped resource because helm doesn't
		// patch namespace into manifests at client.Run.
		objKind := obj.GetKind()
		if objKind != "PodSecurityPolicy" {
			obj.SetNamespace(h.namespace)
		}
		// patch affinity and resources parameters explicitly into appropriate obj.
		// This is needed because helm template doesn't support loading non table
		// structure values.
		objs[i], err = overrideControllerParameters(crdConfig, objs[i])
		if err != nil {
			return nil, err
		}
		objs[i], err = overrideSpeakerParameters(crdConfig, objs[i])
		if err != nil {
			return nil, err
		}
		// we need to override the security context as helm values are added on top
		// of hardcoded ones in values.yaml, so it's not possible to reset runAsUser
		if isControllerDeployment(obj) && h.config.isOpenShift {
			controllerSecurityContext := map[string]interface{}{
				"runAsNonRoot": true,
			}
			err := unstructured.SetNestedMap(obj.Object, controllerSecurityContext, "spec", "template", "spec", "securityContext")
			if err != nil {
				return nil, err
			}
		}
		if isServiceMonitor(obj) && h.config.isOpenShift {
			err := setOcpMonitorFields(obj)
			if err != nil {
				return nil, err
			}
		}
	}
	return objs, nil
}

// InitMetalLBChart initializes metallb helm chart after loading it from given
// chart path and creating config object from environment variables.
func InitMetalLBChart(chartPath, chartName, namespace string,
	client client.Client, isOpenshift bool) (*MetalLBChart, error) {
	chart := &MetalLBChart{}
	chart.namespace = namespace
	chart.envSettings = cli.New()
	chart.client = action.NewInstall(new(action.Configuration))
	chart.client.ReleaseName = chartName
	chart.client.DryRun = true
	chart.client.ClientOnly = true
	chart.client.Namespace = namespace
	chartPath, err := chart.client.ChartPathOptions.LocateChart(chartPath, chart.envSettings)
	if err != nil {
		return nil, err
	}
	chart.chart, err = loader.Load(chartPath)
	if err != nil {
		return nil, err
	}
	chart.config, err = loadConfig(namespace, isOpenshift)
	if err != nil {
		return nil, err
	}
	return chart, nil
}

func overrideControllerParameters(crdConfig *metallbv1beta1.MetalLB, obj *unstructured.Unstructured) (*unstructured.Unstructured, error) {
	controllerConfig := crdConfig.Spec.ControllerConfig
	if controllerConfig == nil || !isControllerDeployment(obj) {
		return obj, nil
	}
	var controller *appsv1.Deployment
	err := runtime.DefaultUnstructuredConverter.FromUnstructured(obj.Object, &controller)
	if err != nil {
		return nil, err
	}
	if controllerConfig.Affinity != nil {
		controller.Spec.Template.Spec.Affinity = controllerConfig.Affinity
	}
	for j, container := range controller.Spec.Template.Spec.Containers {
		if container.Name == "controller" && controllerConfig.Resources != nil {
			controller.Spec.Template.Spec.Containers[j].Resources = *controllerConfig.Resources
		}
	}
	objMap, err := runtime.DefaultUnstructuredConverter.ToUnstructured(controller)
	if err != nil {
		return nil, err
	}
	return &unstructured.Unstructured{Object: objMap}, nil
}

func overrideSpeakerParameters(crdConfig *metallbv1beta1.MetalLB, obj *unstructured.Unstructured) (*unstructured.Unstructured, error) {
	speakerConfig := crdConfig.Spec.SpeakerConfig
	if speakerConfig == nil || !isSpeakerDaemonSet(obj) {
		return obj, nil
	}
	var speaker *appsv1.DaemonSet
	err := runtime.DefaultUnstructuredConverter.FromUnstructured(obj.Object, &speaker)
	if err != nil {
		return nil, err
	}
	if speakerConfig.Affinity != nil {
		speaker.Spec.Template.Spec.Affinity = speakerConfig.Affinity
	}
	for j, container := range speaker.Spec.Template.Spec.Containers {
		if container.Name == "speaker" && speakerConfig.Resources != nil {
			speaker.Spec.Template.Spec.Containers[j].Resources = *speakerConfig.Resources
		}
	}
	objMap, err := runtime.DefaultUnstructuredConverter.ToUnstructured(speaker)
	if err != nil {
		return nil, err
	}
	return &unstructured.Unstructured{Object: objMap}, nil
}

func parseManifest(manifest string) ([]*unstructured.Unstructured, error) {
	rendered := bytes.Buffer{}
	rendered.Write([]byte(manifest))
	out := []*unstructured.Unstructured{}
	// special case - if the entire file is whitespace, skip
	if len(strings.TrimSpace(rendered.String())) == 0 {
		return out, nil
	}

	decoder := yaml.NewYAMLOrJSONDecoder(&rendered, 4096)
	for {
		u := unstructured.Unstructured{}
		if err := decoder.Decode(&u); err != nil {
			if err == io.EOF {
				break
			}
			return nil, errors.Wrapf(err, "failed to unmarshal manifest %s", manifest)
		}
		out = append(out, &u)
	}
	return out, nil
}

func isControllerDeployment(obj *unstructured.Unstructured) bool {
	return obj.GetKind() == "Deployment" && obj.GetName() == "controller"
}

func isSpeakerDaemonSet(obj *unstructured.Unstructured) bool {
	return obj.GetKind() == "DaemonSet" && obj.GetName() == "speaker"
}

func isServiceMonitor(obj *unstructured.Unstructured) bool {
	return obj.GetKind() == "ServiceMonitor"
}

func setOcpMonitorFields(obj *unstructured.Unstructured) error {
	eps, found, err := unstructured.NestedSlice(obj.Object, "spec", "endpoints")
	if !found {
		return errors.New("failed to find endpoints in ServiceMonitor " + obj.GetName())
	}
	if err != nil {
		return err
	}
	for _, ep := range eps {
		err := unstructured.SetNestedField(ep.(map[string]interface{}), false, "tlsConfig", "insecureSkipVerify")
		if err != nil {
			return err
		}
	}
	err = unstructured.SetNestedSlice(obj.Object, eps, "spec", "endpoints")
	if err != nil {
		return err
	}
	return nil
}
