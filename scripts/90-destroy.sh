#!/usr/bin/env bash
# Section 5: Tear down ARC Helm releases, GKE cluster, subnet, VPC, and Node Service Account via gcloud.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

NODE_SA_EMAIL="${NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== [1/4] Uninstalling ARC Helm releases ==="
helm uninstall "${ARC_RUNNER_RELEASE}" -n "${ARC_RUNNER_NAMESPACE}" --wait 2>/dev/null || true
helm uninstall "${ARC_CONTROLLER_RELEASE}" -n "${ARC_CONTROLLER_NAMESPACE}" --wait 2>/dev/null || true

echo "=== [2/4] Deleting GKE cluster '${CLUSTER_NAME}' in '${ZONE}' ==="
if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud container clusters delete "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

echo "=== [3/4] Deleting Cloud Router, subnet '${SUBNET_NAME}', and VPC '${NETWORK_NAME}' ==="
if gcloud compute routers describe "${CLUSTER_NAME}-router" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers delete "${CLUSTER_NAME}-router" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

if gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets delete "${SUBNET_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

if gcloud compute networks describe "${NETWORK_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks delete "${NETWORK_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

echo "=== [4/4] Deleting Node Service Account '${NODE_SA_EMAIL}' ==="
if gcloud iam service-accounts describe "${NODE_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${NODE_SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

echo "✓ Teardown complete."
