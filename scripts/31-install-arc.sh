#!/usr/bin/env bash
# Step 4b: Install or upgrade the ARC controller ('arc-systems') and
# the GKE Sandbox microVM runner scale set ('arc-dind-microvm' in 'arc-runners').
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

if ! kubectl get secret "${GITHUB_SECRET_NAME}" -n "${ARC_RUNNER_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Secret '${GITHUB_SECRET_NAME}' not found in '${ARC_RUNNER_NAMESPACE}'." >&2
  echo "Run ./scripts/30-github-app-secret.sh first." >&2
  exit 1
fi

echo "=== [1/2] Installing/upgrading ARC controller (${ARC_CHART_VERSION}) in '${ARC_CONTROLLER_NAMESPACE}' ==="
helm upgrade --install "${ARC_CONTROLLER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_CONTROLLER_NAMESPACE}" \
  --create-namespace \
  --values "${REPO_ROOT}/deploy/arc/controller.values.yaml" \
  --wait \
  --timeout 5m

kubectl get pods -n "${ARC_CONTROLLER_NAMESPACE}" -o wide

echo "=== [2/2] Installing/upgrading microVM runner scale set '${ARC_RUNNER_RELEASE}' in '${ARC_RUNNER_NAMESPACE}' ==="
helm upgrade --install "${ARC_RUNNER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_RUNNER_NAMESPACE}" \
  --create-namespace \
  --values "${REPO_ROOT}/deploy/arc/runner-set-dind-microvm.values.yaml" \
  --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
  --wait \
  --timeout 5m

helm list -A
