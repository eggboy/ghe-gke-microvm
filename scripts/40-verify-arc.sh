#!/usr/bin/env bash
# Step 4c: Verify ARC controller, listener, AutoscalingRunnerSet, runner pod, and GitHub online status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

echo "=== [1/4] ARC controller and listener pods in '${ARC_CONTROLLER_NAMESPACE}' ==="
kubectl get pods -n "${ARC_CONTROLLER_NAMESPACE}" -o wide

echo "=== [2/4] AutoscalingRunnerSets & AutoscalingListeners ==="
kubectl get autoscalingrunnersets -A -o wide
kubectl get autoscalinglisteners -A -o wide

echo "=== [3/4] Runner pods in '${ARC_RUNNER_NAMESPACE}' ==="
kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" -o wide

echo "=== [4/4] Registered runners in GitHub (${GITHUB_ORG}/${GITHUB_REPO}) ==="
gh api "/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners" \
  --jq '.runners[] | "\(.id)\t\(.name)\tstatus=\(.status)\tbusy=\(.busy)"' || true
