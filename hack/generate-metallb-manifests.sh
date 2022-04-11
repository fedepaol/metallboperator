#!/bin/bash
. $(dirname "$0")/common.sh

NATIVE_MANIFESTS_FILE="metallb-native.yaml"
NATIVE_MANIFESTS_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_COMMIT_ID}/config/manifests/${NATIVE_MANIFESTS_FILE}"
NATIVE_MANIFESTS_DIR="bindata/deployment/native"

NATIVE_WITH_WEBHOOKS_MANIFESTS_FILE="metallb-native-with-webhooks.yaml"
NATIVE_WITH_WEBHOOKS_MANIFESTS_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_COMMIT_ID}/config/manifests/${NATIVE_WITH_WEBHOOKS_MANIFESTS_FILE}"
NATIVE_WITH_WEBHOOKS_MANIFESTS_DIR="bindata/deployment/native-with-webhooks"

FRR_MANIFESTS_FILE="metallb-frr.yaml"
FRR_MANIFESTS_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_COMMIT_ID}/config/manifests/${FRR_MANIFESTS_FILE}"
FRR_MANIFESTS_DIR="bindata/deployment/frr"

FRR_WITH_WEBHOOKS_MANIFESTS_FILE="metallb-frr-with-webhooks.yaml"
FRR_WITH_WEBHOOKS_MANIFESTS_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_COMMIT_ID}/config/manifests/${FRR_WITH_WEBHOOKS_MANIFESTS_FILE}"
FRR_WITH_WEBHOOKS_MANIFESTS_DIR="bindata/deployment/frr-with-webhooks"

PROMETHEUS_OPERATOR_FILE="prometheus-operator.yaml"
PROMETHEUS_OPERATOR_MANIFESTS_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_COMMIT_ID}/config/prometheus/${PROMETHEUS_OPERATOR_FILE}"
PROMETHEUS_OPERATOR_MANIFESTS_DIR="bindata/deployment/prometheus-operator"

if ! command -v yq &> /dev/null
then
    echo "yq binary not found, installing... "
    go install -mod='' github.com/mikefarah/yq/v4@v4.13.3
fi

curl ${NATIVE_MANIFESTS_URL} -o _cache/${NATIVE_MANIFESTS_FILE}
generate_metallb_native_manifest _cache/${NATIVE_MANIFESTS_FILE} ${NATIVE_MANIFESTS_DIR} ${NATIVE_MANIFESTS_FILE}

curl ${NATIVE_WITH_WEBHOOKS_MANIFESTS_URL} -o _cache/${NATIVE_WITH_WEBHOOKS_MANIFESTS_FILE}
generate_metallb_native_manifest _cache/${NATIVE_WITH_WEBHOOKS_MANIFESTS_FILE} ${NATIVE_WITH_WEBHOOKS_MANIFESTS_DIR} ${NATIVE_WITH_WEBHOOKS_MANIFESTS_FILE}

curl ${FRR_MANIFESTS_URL} -o _cache/${FRR_MANIFESTS_FILE}
generate_metallb_frr_manifest _cache/${FRR_MANIFESTS_FILE} ${FRR_MANIFESTS_DIR} ${FRR_MANIFESTS_FILE}

curl ${FRR_WITH_WEBHOOKS_MANIFESTS_URL} -o _cache/${FRR_WITH_WEBHOOKS_MANIFESTS_FILE}
generate_metallb_frr_manifest _cache/${FRR_WITH_WEBHOOKS_MANIFESTS_FILE} ${FRR_WITH_WEBHOOKS_MANIFESTS_DIR} ${FRR_WITH_WEBHOOKS_MANIFESTS_FILE}

# Update MetalLB's E2E lane to clone the same commit as the manifests.
yq e --inplace ".jobs.main.steps[] |= select(.name==\"Checkout MetalLB\").with.ref=\"${METALLB_COMMIT_ID}\"" .github/workflows/metallb_e2e.yml

# TODO: run this script once FRR is merged

# Prometheus Operator manifests
curl ${PROMETHEUS_OPERATOR_MANIFESTS_URL} -o _cache/${PROMETHEUS_OPERATOR_FILE}
yq e '. | select((.kind == "Role" or .kind == "ClusterRole" or .kind == "RoleBinding" or .kind == "ClusterRoleBinding" or .kind == "ServiceAccount") | not)' _cache/${PROMETHEUS_OPERATOR_FILE} > ${PROMETHEUS_OPERATOR_MANIFESTS_DIR}/${PROMETHEUS_OPERATOR_FILE}
yq e --inplace '. | select(.kind == "PodMonitor").metadata.namespace|="{{.NameSpace}}"' ${PROMETHEUS_OPERATOR_MANIFESTS_DIR}/${PROMETHEUS_OPERATOR_FILE}
yq e --inplace '. | select(.kind == "PodMonitor").spec.namespaceSelector.matchNames|=["{{.NameSpace}}"]' ${PROMETHEUS_OPERATOR_MANIFESTS_DIR}/${PROMETHEUS_OPERATOR_FILE}
