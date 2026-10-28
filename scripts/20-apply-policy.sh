#!/usr/bin/env bash
# Step 3: Apply ValidatingAdmissionPolicy ('privileged-only-in-microvm') and
# Metadata Egress NetworkPolicy ('deny-metadata-egress') to namespace 'arc-runners'.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

echo "=== [1/4] Ensuring runner namespace '${ARC_RUNNER_NAMESPACE}' exists ==="
kubectl create namespace "${ARC_RUNNER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== [2/4] Applying ValidatingAdmissionPolicy and Metadata Egress NetworkPolicy ==="
kubectl apply -f "${REPO_ROOT}/deploy/policy/privileged-only-in-microvm.yaml"
kubectl apply -f "${REPO_ROOT}/deploy/policy/deny-metadata-egress.yaml"
sleep 3

echo "=== [3/4] Dry-run test 1: Privileged pod WITHOUT runtimeClassName=microvm in '${ARC_RUNNER_NAMESPACE}' must be denied ==="
set +e
DENY_OUTPUT="$(kubectl apply --dry-run=server -n "${ARC_RUNNER_NAMESPACE}" -f - 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-unisolated-privileged
spec:
  containers:
    - name: dind
      image: docker:29.9-dind
      securityContext:
        privileged: true
EOF
)"
DENY_RC=$?
set -e
echo "${DENY_OUTPUT}"
if [[ ${DENY_RC} -eq 0 ]]; then
  echo "ERROR: Expected ValidatingAdmissionPolicy to deny privileged pod without runtimeClassName=microvm." >&2
  exit 1
fi
echo "✓ Admission denied the unisolated privileged pod."

echo "=== [4/4] Dry-run test 2: Privileged pod WITH runtimeClassName=microvm in '${ARC_RUNNER_NAMESPACE}' must be admitted ==="
kubectl apply --dry-run=server -n "${ARC_RUNNER_NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-microvm-privileged
spec:
  runtimeClassName: microvm
  containers:
    - name: dind
      image: docker:29.9-dind
      securityContext:
        privileged: true
EOF
echo "✓ Admission allowed the microVM-isolated privileged pod."
