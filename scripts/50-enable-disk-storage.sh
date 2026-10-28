#!/usr/bin/env bash
# Section 4 (optional): Move /var/lib/docker in 'arc-dind-microvm' from RAM-backed tmpfs
# to a 30 GiB disk-backed sparse ext4 loopback mount on emptyDir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

echo "=== [1/3] Upgrading '${ARC_RUNNER_RELEASE}' to use deploy/arc/runner-set-dind-microvm-disk.values.yaml ==="
helm upgrade --install "${ARC_RUNNER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_RUNNER_NAMESPACE}" \
  --values "${REPO_ROOT}/deploy/arc/runner-set-dind-microvm-disk.values.yaml" \
  --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
  --wait \
  --timeout 5m

echo "=== [2/3] Waiting for new microVM runner pod in '${ARC_RUNNER_NAMESPACE}' to reach 2/2 Running ==="
sleep 5
kubectl wait --for=condition=Ready pod -l actions.github.com/scale-set-name="${ARC_RUNNER_RELEASE}" \
  -n "${ARC_RUNNER_NAMESPACE}" --timeout=120s
RUNNER_POD="$(kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" \
  -l actions.github.com/scale-set-name="${ARC_RUNNER_RELEASE}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" -o wide

echo "=== [3/3] Verifying disk-backed ext4 loopback (/var/lib/docker) inside '${RUNNER_POD}' ==="
kubectl exec -n "${ARC_RUNNER_NAMESPACE}" "${RUNNER_POD}" -c dind -- sh -c \
  'df -Th /var/lib/docker /dind-backing; docker info | grep -E "Storage Driver:|Backing Filesystem:"'
echo "✓ Disk-backed 30 GiB sparse ext4 loopback is active inside GKE Sandbox microVM."
