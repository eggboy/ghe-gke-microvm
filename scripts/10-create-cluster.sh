#!/usr/bin/env bash
# Step 2: Create the VPC, least-privilege node service account, GKE Standard cluster,
# and GKE Sandbox microVM node pool ('nv-microvm') with gcloud.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

NODE_SA_EMAIL="${NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== [1/6] Creating VPC network '${NETWORK_NAME}' and subnet '${SUBNET_NAME}' ==="
if ! gcloud compute networks describe "${NETWORK_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create "${NETWORK_NAME}" \
    --project="${PROJECT_ID}" \
    --subnet-mode=custom
else
  echo "  ✓ VPC '${NETWORK_NAME}' already exists"
fi

if ! gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SUBNET_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK_NAME}" \
    --region="${REGION}" \
    --range="10.40.0.0/20" \
    --secondary-range="pods=10.48.0.0/14,services=10.52.0.0/20" \
    --enable-private-ip-google-access
else
  echo "  ✓ Subnet '${SUBNET_NAME}' already exists"
fi

ROUTER_NAME="${CLUSTER_NAME}-router"
NAT_NAME="${CLUSTER_NAME}-nat"
if ! gcloud compute routers describe "${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers create "${ROUTER_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK_NAME}" \
    --region="${REGION}"
else
  echo "  ✓ Cloud Router '${ROUTER_NAME}' already exists"
fi

if ! gcloud compute routers nats describe "${NAT_NAME}" --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers nats create "${NAT_NAME}" \
    --project="${PROJECT_ID}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips
else
  echo "  ✓ Cloud NAT '${NAT_NAME}' already exists"
fi

echo "=== [2/6] Creating least-privilege GKE Node Service Account '${NODE_SA_EMAIL}' ==="
if ! gcloud iam service-accounts describe "${NODE_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${NODE_SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="GKE nodes for ${CLUSTER_NAME}"
else
  echo "  ✓ Service Account '${NODE_SA_EMAIL}' already exists"
fi

for role in \
  roles/logging.logWriter \
  roles/monitoring.metricWriter \
  roles/monitoring.viewer \
  roles/stackdriver.resourceMetadata.writer \
  roles/artifactregistry.reader; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${NODE_SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done
echo "  ✓ IAM roles bound to '${NODE_SA_EMAIL}'"

echo "=== [3/6] Creating GKE Standard cluster '${CLUSTER_NAME}' (GKE ${GKE_CLUSTER_VERSION}, Dataplane V2, Private Nodes) ==="
CLUSTER_STATUS="$(gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null || true)"
if [[ "${CLUSTER_STATUS}" == "ERROR" ]]; then
  echo "  Deleting failed cluster '${CLUSTER_NAME}' (status=ERROR)..."
  gcloud container clusters delete "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  CLUSTER_STATUS=""
fi

if [[ -z "${CLUSTER_STATUS}" ]]; then
  gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --release-channel="$(echo "${GKE_RELEASE_CHANNEL}" | tr '[:upper:]' '[:lower:]')" \
    --cluster-version="${GKE_CLUSTER_VERSION}" \
    --network="${NETWORK_NAME}" \
    --subnetwork="${SUBNET_NAME}" \
    --cluster-secondary-range-name="pods" \
    --services-secondary-range-name="services" \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr="172.16.0.32/28" \
    --no-enable-master-authorized-networks \
    --enable-dataplane-v2 \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --service-account="${NODE_SA_EMAIL}" \
    --machine-type="${SYSTEM_MACHINE_TYPE}" \
    --image-type="COS_CONTAINERD" \
    --disk-type="pd-balanced" \
    --disk-size="100" \
    --num-nodes="1" \
    --node-labels="pool-role=system" \
    --shielded-secure-boot \
    --shielded-integrity-monitoring
else
  echo "  ✓ Cluster '${CLUSTER_NAME}' already exists (status=${CLUSTER_STATUS})"
fi

echo "=== [4/6] Creating GKE Sandbox microVM + Nested Virtualization node pool 'nv-microvm' ==="
if ! gcloud container node-pools describe "nv-microvm" --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud container node-pools create "nv-microvm" \
    --project="${PROJECT_ID}" \
    --cluster="${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MICROVM_MACHINE_TYPE}" \
    --image-type="COS_CONTAINERD" \
    --disk-type="pd-balanced" \
    --disk-size="100" \
    --service-account="${NODE_SA_EMAIL}" \
    --sandbox="type=microvm" \
    --enable-nested-virtualization \
    --threads-per-core=2 \
    --num-nodes="1" \
    --enable-autoscaling \
    --min-nodes="1" \
    --max-nodes="3" \
    --node-labels="pool-role=arc-runner-microvm,nested-virtualization=enabled,arc-runner-pool=microvm" \
    --shielded-secure-boot \
    --shielded-integrity-monitoring
else
  echo "  ✓ Node pool 'nv-microvm' already exists"
fi

echo "=== [5/6] Configuring kubectl credentials ==="
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}"

echo "=== [6/6] Verifying nodes and RuntimeClass ==="
kubectl get nodes -o wide -L pool-role,nested-virtualization,sandbox.gke.io/runtime
kubectl get runtimeclass
