#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# Publish helm-common chart to a Helm registry. All values from environment or .env.
# Copy .env.example to .env and set HELM_CHART_PATH, GITLAB_PROJECT_URL (or equivalent), GITLAB_PAT.
# Do not commit .env or real credentials.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

HELM_CHART_PATH="${HELM_CHART_PATH:?Set HELM_CHART_PATH (path to helm-common chart)}"
GITLAB_PROJECT_URL="${GITLAB_PROJECT_URL:?Set GITLAB_PROJECT_URL (e.g. https://git.example.com/api/v4/projects/1)}"
GITLAB_PAT="${GITLAB_PAT:?Set GITLAB_PAT}"
GITLAB_USERNAME="${GITLAB_USERNAME:-git}"
CHART_REPO_NAME="${CHART_REPO_NAME:-helm-common}"

helm plugin list | grep push || helm plugin install https://github.com/chartmuseum/helm-push

cd "$HELM_CHART_PATH" || exit
helm package .
PACKAGED_CHART=$(ls -t *.tgz 2>/dev/null | head -n1)
[ -n "$PACKAGED_CHART" ] || { echo "No .tgz produced"; exit 1; }

helm repo add "$CHART_REPO_NAME" "$GITLAB_PROJECT_URL/packages/helm/stable" \
  --username "$GITLAB_USERNAME" \
  --password "$GITLAB_PAT"

helm cm-push "$PACKAGED_CHART" "$CHART_REPO_NAME"
rm -f "$PACKAGED_CHART"
echo "Helm chart published successfully."
