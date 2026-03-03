#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# Create a Docker registry secret and seal it. Credentials from environment or .env.
# Copy .env.example to .env and set DOCKER_USERNAME, DOCKER_PASSWORD, DOCKER_EMAIL.
# Do not commit .env or real credentials.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

NAMESPACE="${NAMESPACE:-prod}"
SECRET_NAME="${SECRET_NAME:-dockerhub-secret}"
DOCKER_SERVER="${DOCKER_SERVER:-https://index.docker.io/v1/}"
DOCKER_USERNAME="${DOCKER_USERNAME:?Set DOCKER_USERNAME in .env or environment}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:?Set DOCKER_PASSWORD in .env or environment}"
DOCKER_EMAIL="${DOCKER_EMAIL:?Set DOCKER_EMAIL in .env or environment}"

# Output: sealed file for Argo CD (override with SEALED_OUTPUT_PATH if needed)
SEALED_DIR="$(cd "$SCRIPT_DIR/../../helmcharts/system-charts/argocd-config/sealed" 2>/dev/null && pwd)"
OUTPUT_FILE="${SEALED_OUTPUT_PATH:-${SEALED_DIR:-$SCRIPT_DIR}/dockerhub_secret.yaml}"

kubectl create secret docker-registry "$SECRET_NAME" \
  --docker-server="$DOCKER_SERVER" \
  --docker-username="$DOCKER_USERNAME" \
  --docker-password="$DOCKER_PASSWORD" \
  --docker-email="$DOCKER_EMAIL" \
  --namespace="$NAMESPACE" \
  --dry-run=client -o yaml | kubeseal --format=yaml > "$OUTPUT_FILE"

echo "Sealed secret written to $OUTPUT_FILE"
if [[ "$OUTPUT_FILE" != *"argocd-config/sealed"* ]]; then
  echo "Copy it to helmcharts/system-charts/argocd-config/sealed/dockerhub_secret.yaml so Argo CD can apply it."
fi
