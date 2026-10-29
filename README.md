# GitHub Actions Runner Controller DinD on GKE Sandbox microVMs

Run self-hosted GitHub Actions runners with Docker-in-Docker (DinD) on Google Kubernetes Engine. Each runner pod boots inside its own GKE Sandbox `microvm`, a Kata Containers guest on Cloud Hypervisor, on a nested-virtualization node pool. You provision it step by step with `gcloud`, `kubectl`, and `helm`.

## 1. The problem

Your workflows need `docker build`, `docker compose`, Testcontainers, or a `container:` job. On Kubernetes that means ARC's `dind` sidecar, and the sidecar needs `privileged: true` to run `dockerd`, mount `overlayfs`, and program `iptables`.

On a standard `runc` node a privileged container holds `CAP_SYS_ADMIN` on the shared host kernel. Pod Security Admission, Gatekeeper, and Kyverno policies reject it. GKE Sandbox with gVisor (`sandbox.gke.io/runtime=gvisor`) rejects it at admission as well.

GKE Sandbox `microvm` removes the conflict. On a node pool created with `--sandbox="type=microvm" --enable-nested-virtualization` (GKE `1.37.0-gke.4713000` or later), a pod with `runtimeClassName: microvm` boots inside its own Cloud Hypervisor VM with its own guest kernel. The `docker:dind` container runs privileged against that disposable guest kernel and has no access to the node kernel.

## 2. Prerequisites

Install these CLI tools on your workstation:

* `gcloud`
* `kubectl`
* `helm`
* `gh`
* `jq` and `curl`

### Disable `constraints/compute.disableNestedVirtualization`

If your organization enforces `constraints/compute.disableNestedVirtualization`, set it to **Inactive** (`enforce: false`) on the target project before you create the node pool.

## 3. Step-by-Step Setup

### Step 1: Environment variables and preflight checks

Create `.env` from the sample, fill in your GCP project, region, zone, and GitHub repository, then source it:

```bash
cp .env.sample .env
source ./.env
```

Enable the required Google Cloud APIs. Then confirm that the nested-virtualization constraint is not enforced, that the region has at least 8 free `N2_CPUS`, and that GKE 1.37 is available in your zone:

```bash
gcloud config set project "${PROJECT_ID}"

gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  orgpolicy.googleapis.com \
  --project="${PROJECT_ID}"

# Confirm output is empty or False (not True)
gcloud org-policies describe constraints/compute.disableNestedVirtualization \
  --project="${PROJECT_ID}" --effective --format="value(booleanPolicy.enforced)"
```

Script: `scripts/00-preflight.sh`

### Step 2: Network, service account, cluster, and node pool

#### 2a. Custom VPC, subnet, and Cloud NAT

If your organization enforces `constraints/compute.vmExternalIpAccess`, GKE nodes cannot get public IPs. Create a custom VPC and subnet, then add Cloud NAT so private nodes can reach GitHub and container registries:

```bash
gcloud compute networks create "${NETWORK_NAME}" \
  --project="${PROJECT_ID}" \
  --subnet-mode=custom

gcloud compute networks subnets create "${SUBNET_NAME}" \
  --project="${PROJECT_ID}" \
  --network="${NETWORK_NAME}" \
  --region="${REGION}" \
  --range="10.40.0.0/20" \
  --secondary-range="pods=10.48.0.0/14,services=10.52.0.0/20" \
  --enable-private-ip-google-access

gcloud compute routers create "${CLUSTER_NAME}-router" \
  --project="${PROJECT_ID}" \
  --network="${NETWORK_NAME}" \
  --region="${REGION}"

gcloud compute routers nats create "${CLUSTER_NAME}-nat" \
  --project="${PROJECT_ID}" \
  --router="${CLUSTER_NAME}-router" \
  --region="${REGION}" \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips
```

#### 2b. Least-privilege node service account

```bash
export NODE_SA_EMAIL="${NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${NODE_SA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="GKE nodes for ${CLUSTER_NAME}"

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
    --quiet
done
```

#### 2c. GKE Standard cluster

The cluster uses Dataplane V2, which GKE requires to enforce `NetworkPolicy` on `microvm` pods. Its default `system` node pool (`e2-standard-4`, labeled `pool-role=system`) hosts the ARC controller and listener pods:

```bash
gcloud container clusters create "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --release-channel="${GKE_RELEASE_CHANNEL}" \
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
```

#### 2d. The `nv-microvm` node pool

Create the runner node pool on an Intel VT-x machine type (`n2-standard-8`) with `--sandbox="type=microvm"`, `--enable-nested-virtualization`, and `--threads-per-core=2`:

```bash
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
```

> [!NOTE]
> * **Machine family**: Compute Engine supports nested virtualization only on Intel processors with VT-x (`N1`, `N2`, `C2`, `C3`, `M1`, `M2`). `E2` and the AMD-based `N2D` and `T2D` families do not support it.
> * **Taint and RuntimeClass**: `--sandbox="type=microvm"` makes GKE register the `microvm` `RuntimeClass` (`handler: kata-clh`) and taint the pool's nodes with `sandbox.gke.io/runtime=microvm:NoSchedule`. GKE injects the matching toleration into any pod that sets `runtimeClassName: microvm`.

#### 2e. Fetch `kubectl` credentials and inspect nodes

```bash
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}"

kubectl get nodes -o wide -L pool-role,nested-virtualization,sandbox.gke.io/runtime
kubectl get runtimeclass
```

Script: `scripts/10-create-cluster.sh`

### Step 3: Admission policy and metadata NetworkPolicy

Create the `arc-runners` namespace and apply both policies:

```bash
kubectl create namespace "${ARC_RUNNER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/policy/privileged-only-in-microvm.yaml
kubectl apply -f deploy/policy/deny-metadata-egress.yaml
```

#### Policy details

1. **`ValidatingAdmissionPolicy`** ([`deploy/policy/privileged-only-in-microvm.yaml`](deploy/policy/privileged-only-in-microvm.yaml)) denies any pod in `arc-runners` that requests `securityContext.privileged: true` unless `spec.runtimeClassName == "microvm"`. Check it with a server-side dry run:
   ```bash
   # 1. Privileged pod WITHOUT runtimeClassName: microvm -> DENIED
   kubectl apply --dry-run=server -n arc-runners -f - <<'EOF'
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

   # 2. Privileged pod WITH runtimeClassName: microvm -> ADMITTED
   kubectl apply --dry-run=server -n arc-runners -f - <<'EOF'
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
   ```

2. **`NetworkPolicy`** ([`deploy/policy/deny-metadata-egress.yaml`](deploy/policy/deny-metadata-egress.yaml)) blocks runner pods from the Compute Engine metadata server (`169.254.169.254/32` and `169.254.169.252/32`) and allows UDP and TCP port 53 to `kube-system` pods and NodeLocal DNSCache (`169.254.20.10/32`).

> [!WARNING]
> In Cilium-backed Dataplane V2 clusters, an `ipBlock` egress rule such as `cidr: 0.0.0.0/0` with `except: [169.254.169.254/32, 169.254.169.252/32]` matches only external (`world`) traffic and blocks egress to in-cluster pods, including `kube-dns`. Keep the port 53 rule to `kube-system` and `169.254.20.10/32` from [`deploy/policy/deny-metadata-egress.yaml`](deploy/policy/deny-metadata-egress.yaml), or runner pods cannot resolve `*.actions.githubusercontent.com`.

Script: `scripts/20-apply-policy.sh`

### Step 4: GitHub credentials and ARC install

#### 4a. Create the `arc-github-app` secret

* **Option A: GitHub App**, recommended for production:
  ```bash
  kubectl create secret generic "${GITHUB_SECRET_NAME}" \
    --namespace="${ARC_RUNNER_NAMESPACE}" \
    --from-literal=github_app_id="${GITHUB_APP_ID}" \
    --from-literal=github_app_installation_id="${GITHUB_APP_INSTALLATION_ID}" \
    --from-file=github_app_private_key="${GITHUB_APP_PRIVATE_KEY_PATH}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ```
* **Option B: personal access token or `gh auth token`**:
  ```bash
  kubectl create secret generic "${GITHUB_SECRET_NAME}" \
    --namespace="${ARC_RUNNER_NAMESPACE}" \
    --from-literal=github_token="$(gh auth token)" \
    --dry-run=client -o yaml | kubectl apply -f -
  ```

Script: `scripts/30-github-app-secret.sh`

#### 4b. Install the ARC controller and the `arc-dind-microvm` scale set

```bash
# 1. Install the ARC controller onto the 'system' node pool
helm upgrade --install "${ARC_CONTROLLER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_CONTROLLER_NAMESPACE}" \
  --create-namespace \
  --values deploy/arc/controller.values.yaml \
  --wait

# 2. Install the GKE Sandbox microVM DinD runner scale set
helm upgrade --install "${ARC_RUNNER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_RUNNER_NAMESPACE}" \
  --create-namespace \
  --values deploy/arc/runner-set-dind-microvm.values.yaml \
  --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
  --wait
```

Script: `scripts/31-install-arc.sh`

#### Runner configuration in [`deploy/arc/runner-set-dind-microvm.values.yaml`](deploy/arc/runner-set-dind-microvm.values.yaml)

1. **`runtimeClassName: "microvm"`** places the whole runner pod, `runner` plus `dind` sidecar, inside one Cloud Hypervisor microVM on the `nv-microvm` node pool.
2. **An explicit `template.spec` instead of `containerMode.type: dind`.** ARC's built-in `dind` template does not let you set volumes or resources on the `dind` sidecar. Writing `template.spec` by hand lets you set CPU and memory limits on both containers, which GKE Sandbox uses to size the VM, and control `/var/lib/docker`.
3. **`emptyDir: { medium: Memory, sizeLimit: 4Gi }` for `/var/lib/docker`.** Inside a `microvm` pod, the rootfs and plain `emptyDir: {}` volumes arrive from the host over `virtiofs`, and `overlay2` cannot use `virtiofs` as its upper layer. A `medium: Memory` `emptyDir` is an in-guest `tmpfs`, so `dockerd --storage-driver=overlay2` starts without a wrapper script. Section 4 swaps this for a 30 GiB disk-backed loopback mount.
4. **`controllerServiceAccount.name: "arc-gha-rs-controller"`** matches the ServiceAccount that the `arc` Helm release creates in `arc-systems`.

#### 4c. Verify runner registration

```bash
kubectl get pods -n "${ARC_CONTROLLER_NAMESPACE}" -o wide
kubectl get autoscalingrunnersets -n "${ARC_RUNNER_NAMESPACE}" -o wide
kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" -o wide
gh api "/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners" \
  --jq '.runners[] | "\(.id)\t\(.name)\tstatus=\(.status)\tbusy=\(.busy)"'
```

#### 4d. Verify microVM isolation

Compare the node kernel with the kernel inside the privileged `dind` container:

```bash
RUNNER_POD="$(kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')"
NODE_NAME="$(kubectl get pod -n "${ARC_RUNNER_NAMESPACE}" "${RUNNER_POD}" -o jsonpath='{.spec.nodeName}')"

kubectl get node "${NODE_NAME}" -o jsonpath='Node kernel:  {.status.nodeInfo.kernelVersion}{"\n"}'
kubectl exec -n "${ARC_RUNNER_NAMESPACE}" "${RUNNER_POD}" -c dind -- sh -c \
  'echo "Guest kernel: $(uname -r)"; echo "Hypervisor:   $(cat /sys/class/dmi/id/product_name)"'
```

A `runc` pod prints the same kernel as the node. A `microvm` pod prints a different kernel and `Hypervisor: cloud-hypervisor`: `dockerd` and every `docker build` run against that guest kernel, and the node kernel is not reachable from inside the pod.

> [!NOTE]
> A different kernel proves the VM boundary. It does not block network egress, so the `deny-metadata-egress` NetworkPolicy from Step 3 is still required to keep runner jobs away from the Compute Engine metadata server at `169.254.169.254`.

Script: `scripts/40-verify-arc.sh`

### Step 5: Run the verification workflow on `arc-dind-microvm`

Push this repository to GitHub, matching `GITHUB_ORG` and `GITHUB_REPO` in `.env`, and trigger the workflow:

```bash
./scripts/41-run-demo.sh
```

[`.github/workflows/dind-microvm-smoke.yml`](.github/workflows/dind-microvm-smoke.yml) runs on `arc-dind-microvm` and:

* checks that the runner is inside a Cloud Hypervisor microVM (`DMI product_name: cloud-hypervisor`) with a guest kernel that differs from the node kernel,
* asserts that `docker info` reports the `overlay2` storage driver,
* builds and runs [`demo-app`](demo-app/Dockerfile) and calls `GET /healthz`,
* starts the `web` and `redis` stack with `docker compose` ([`demo-app/compose.yaml`](demo-app/compose.yaml)).

## 4. Optional: disk-backed `/var/lib/docker`

Step 4b put `/var/lib/docker` on a 4 GiB `tmpfs`. That is fast for small builds but counts against pod and node memory.

For image builds in the tens of GiB, move `/var/lib/docker` off guest RAM. Switching `emptyDir` from `medium: Memory` to `emptyDir: {}` does not work: inside a `microvm`, a plain `emptyDir` is a `virtiofs` share from the node's boot disk, and `overlayfs` rejects `virtiofs` as an `upperdir`. Two options keep `overlay2` on disk:

| Option | How it works inside `microvm` | Pod startup cost | Fits |
|---|---|---|---|
| **A: sparse `ext4` loopback on `emptyDir: {}`** ([`runner-set-dind-microvm-disk.values.yaml`](deploy/arc/runner-set-dind-microvm-disk.values.yaml)) | Mounts a disk-backed `emptyDir` at `/dind-backing`, creates a 30 GiB sparse file with `truncate`, formats it with `mkfs.ext4`, and loop-mounts it at `/var/lib/docker` | About 0.3 s | Ephemeral CI runners that need 10 to 80 GiB of `overlay2` storage and no PVC attach wait |
| **B: generic ephemeral volume PVC** (`ephemeral.volumeClaimTemplate`) | Attaches one GCE Persistent Disk (`pd.csi.storage.gke.io`) per runner pod, which Kata passes to Cloud Hypervisor as a `virtio-blk` block device (`/dev/vdX`) | 15 to 30 s for the GCE `attachDisk` call | Heavy builds that need 100 GiB or more with disk IOPS separate from the node boot disk |

### Apply Option A

[`deploy/arc/runner-set-dind-microvm-disk.values.yaml`](deploy/arc/runner-set-dind-microvm-disk.values.yaml) replaces `emptyDir: { medium: Memory }` with a disk-backed `emptyDir: { sizeLimit: 30Gi }` at `/dind-backing` and gives the `dind` container a startup command that loop-mounts `/dind-backing/docker.img` at `/var/lib/docker`:

```yaml
      - name: dind
        image: "docker:29.9-dind"
        command: ["sh", "-euxc"]
        args:
          - |
            if ! command -v mkfs.ext4 >/dev/null 2>&1; then
              apk add --no-cache e2fsprogs >/dev/null
            fi
            mkdir -p /var/lib/docker
            if [ "$(df -PT /var/lib/docker | awk 'NR==2 {print $2}')" != "ext4" ]; then
              rm -f /dind-backing/docker.img
              truncate -s 30G /dind-backing/docker.img
              mkfs.ext4 -F -q -m 0 /dind-backing/docker.img
              mount -o loop,noatime /dind-backing/docker.img /var/lib/docker
            fi
            df -Th /var/lib/docker
            exec dockerd-entrypoint.sh dockerd \
              --host=unix:///var/run/docker.sock \
              --group=${DOCKER_GROUP_GID} \
              --storage-driver=overlay2
```

Run `helm upgrade` (or `scripts/50-enable-disk-storage.sh`) to switch `arc-dind-microvm` to disk-backed storage:

```bash
helm upgrade --install "${ARC_RUNNER_RELEASE}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "${ARC_CHART_VERSION}" \
  --namespace "${ARC_RUNNER_NAMESPACE}" \
  --values deploy/arc/runner-set-dind-microvm-disk.values.yaml \
  --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
  --wait
```

Confirm inside the new runner pod that `/var/lib/docker` is a 30 GiB `ext4` volume (`29.4G` usable) rather than `tmpfs`:

```bash
RUNNER_POD="$(kubectl get pods -n "${ARC_RUNNER_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n "${ARC_RUNNER_NAMESPACE}" "${RUNNER_POD}" -c dind -- sh -c \
  'df -Th /var/lib/docker /dind-backing; docker info | grep -E "Storage Driver:|Backing Filesystem:"'
```

Expected output:
```text
Filesystem           Type            Size      Used Available Use% Mounted on
none                 virtiofs       29.4G    344.0K     29.3G   0% /var/lib/docker
none                 virtiofs       94.2G     12.1G     82.1G  13% /dind-backing
 Storage Driver: overlay2
  Backing Filesystem: extfs
```

## 5. Clean Up

Uninstall the ARC Helm releases and delete the GKE cluster, subnet, VPC, and node service account:

```bash
./scripts/90-destroy.sh
```
