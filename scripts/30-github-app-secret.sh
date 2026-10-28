#!/usr/bin/env bash
# Step 4a: Create or update the 'arc-github-app' Secret in namespace 'arc-runners'.
# Supports either:
#   Option A: GitHub App credentials (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PATH)
#   Option B: GitHub PAT / gh CLI token (GITHUB_TOKEN or `gh auth token`)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../.env.sample
source "${REPO_ROOT}/.env"

kubectl create namespace "${ARC_RUNNER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_INSTALLATION_ID:-}" && -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]]; then
  echo "Creating Secret '${GITHUB_SECRET_NAME}' in '${ARC_RUNNER_NAMESPACE}' using GitHub App (${GITHUB_APP_ID})..."
  kubectl create secret generic "${GITHUB_SECRET_NAME}" \
    --namespace="${ARC_RUNNER_NAMESPACE}" \
    --from-literal=github_app_id="${GITHUB_APP_ID}" \
    --from-literal=github_app_installation_id="${GITHUB_APP_INSTALLATION_ID}" \
    --from-file=github_app_private_key="${GITHUB_APP_PRIVATE_KEY_PATH}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
  echo "Creating Secret '${GITHUB_SECRET_NAME}' in '${ARC_RUNNER_NAMESPACE}' using GitHub token..."
  kubectl create secret generic "${GITHUB_SECRET_NAME}" \
    --namespace="${ARC_RUNNER_NAMESPACE}" \
    --from-literal=github_token="${TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "✓ Secret '${GITHUB_SECRET_NAME}' ready in '${ARC_RUNNER_NAMESPACE}'."
