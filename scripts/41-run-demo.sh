#!/usr/bin/env bash
# Step 5: Trigger and watch the end-to-end GitHub Actions workflow on 'arc-dind-microvm'.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

FULL_REPO="${GITHUB_ORG}/${GITHUB_REPO}"

run_and_verify_workflow() {
  local wf_file="$1"
  local label="$2"
  echo "=================================================================="
  echo " Triggering ${label} (${wf_file}) on ${FULL_REPO}"
  echo "=================================================================="
  local start_ts
  start_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  gh workflow run "${wf_file}" --repo "${FULL_REPO}"

  local run_id=""
  for _ in $(seq 1 30); do
    sleep 3
    run_id="$(gh run list --repo "${FULL_REPO}" --workflow "${wf_file}" --limit 5 \
      --json databaseId,createdAt \
      --jq ".[] | select(.createdAt >= \"${start_ts}\") | .databaseId" | head -n 1)"
    if [[ -n "${run_id}" ]]; then
      break
    fi
  done

  if [[ -z "${run_id}" ]]; then
    echo "ERROR: Could not locate newly triggered workflow run for ${wf_file}." >&2
    exit 1
  fi

  echo "Watching workflow run ID ${run_id}..."
  gh run watch "${run_id}" --repo "${FULL_REPO}" --exit-status
  echo "✓ Workflow ${wf_file} (run ${run_id}) SUCCEEDED."
  echo "--- Key log lines from run ${run_id} ---"
  gh run view "${run_id}" --repo "${FULL_REPO}" --log | \
    grep -E "Guest kernel:|DMI product_name:|Docker Storage Driver|Backing Filesystem:|demo-app" | tail -n 25 || true
}

run_and_verify_workflow "dind-microvm-smoke.yml" "ARC DinD inside GKE Sandbox microVM Smoke"
