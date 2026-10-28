#!/usr/bin/env bash
# Step 1: Preflight checks for GKE Sandbox microVM + ARC DinD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

echo "=== [1/7] Checking required CLI tools ==="
for bin in gcloud kubectl helm gh jq curl; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: Required binary '${bin}' not found in PATH." >&2
    exit 1
  fi
  echo "  ✓ ${bin}: $(command -v "${bin}")"
done

echo "=== [2/7] Verifying gcloud user authentication & project ==="
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n 1)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  echo "ERROR: No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi
echo "  ✓ Active gcloud account: ${ACTIVE_ACCOUNT}"
gcloud config set project "${PROJECT_ID}" >/dev/null
echo "  ✓ Target GCP project: ${PROJECT_ID}"

echo "=== [3/7] Verifying Application Default Credentials (ADC) ==="
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ERROR: Application Default Credentials (ADC) not configured or expired." >&2
  echo "Run: gcloud auth application-default login" >&2
  exit 1
fi
echo "  ✓ ADC token verified"

echo "=== [4/7] Enabling required Google Cloud APIs ==="
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  orgpolicy.googleapis.com \
  --project="${PROJECT_ID}"
echo "  ✓ Required APIs enabled"

echo "=== [5/7] Checking Org Policy constraints/compute.disableNestedVirtualization ==="
ENFORCED="$(gcloud org-policies describe constraints/compute.disableNestedVirtualization \
  --project="${PROJECT_ID}" --effective --format="value(booleanPolicy.enforced)" 2>/dev/null || true)"
if [[ "${ENFORCED}" == "True" || "${ENFORCED}" == "true" ]]; then
  echo "ERROR: Organization policy 'constraints/compute.disableNestedVirtualization' is ENFORCED on ${PROJECT_ID}." >&2
  echo "Disable it in Google Cloud Console (IAM & Admin -> Organization Policies) or run:" >&2
  echo "  gcloud org-policies reset constraints/compute.disableNestedVirtualization --project=${PROJECT_ID}" >&2
  exit 1
fi
echo "  ✓ constraints/compute.disableNestedVirtualization is NOT enforced"

echo "=== [6/7] Checking regional N2_CPUS quota in ${REGION} ==="
N2_QUOTA_JSON="$(gcloud compute regions describe "${REGION}" --project="${PROJECT_ID}" --format=json)"
N2_LIMIT="$(echo "${N2_QUOTA_JSON}" | jq -r '.quotas[] | select(.metric=="N2_CPUS") | .limit')"
N2_USAGE="$(echo "${N2_QUOTA_JSON}" | jq -r '.quotas[] | select(.metric=="N2_CPUS") | .usage')"
N2_AVAILABLE="$(awk -v l="${N2_LIMIT:-0}" -v u="${N2_USAGE:-0}" 'BEGIN { printf "%.0f", l - u }')"
echo "  ✓ N2_CPUS in ${REGION}: usage=${N2_USAGE:-0} / limit=${N2_LIMIT:-0} (available=${N2_AVAILABLE})"
if (( N2_AVAILABLE < 8 )); then
  echo "ERROR: Need at least 8 available N2_CPUS in ${REGION} for nv-microvm node pool." >&2
  exit 1
fi

echo "=== [7/7] Checking GKE 1.37+ availability in ${ZONE} & GitHub CLI auth ==="
GKE_VERSIONS="$(gcloud container get-server-config --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format="json(channels)" | jq -r '.channels[] | select(.channel=="REGULAR") | .validVersions[]' | grep '^1\.37\.' || true)"
if [[ -z "${GKE_VERSIONS}" ]]; then
  echo "ERROR: GKE 1.37+ (required for GKE Sandbox microvm GA) not found in ${ZONE} REGULAR channel." >&2
  exit 1
fi
echo "  ✓ Available GKE 1.37 versions in ${ZONE} (REGULAR):"
while IFS= read -r version; do echo "    - ${version}"; done <<< "${GKE_VERSIONS}"
gh auth status >/dev/null
echo "  ✓ GitHub CLI authenticated"

echo ""
echo "Preflight PASSED. Ready to run ./scripts/10-create-cluster.sh"
