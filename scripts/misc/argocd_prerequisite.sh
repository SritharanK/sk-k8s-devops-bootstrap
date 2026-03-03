#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# Argo CD bootstrap: create namespaces, log in, add Git repo, create root Application.
# This Application (argocd-bootstraper) points at argocd-bootstrap/ in Git; Argo CD
# then syncs all toolchains and applications defined there (App-of-Apps pattern).
#
# CONFIGURATION:
#   1. Fill in config/defaults.yaml (copied from config/defaults.yaml.example).
#      The script reads values from that file automatically.
#   2. Secrets (ARGO_PASS, KUBECONFIG) must be set via env vars or .env file —
#      never store them in config/defaults.yaml.
#
# REQUIRED (env var or .env):
#   ARGO_PASS              - Argo CD admin password
#   KUBECONFIG             - Path to kubeconfig
#
# OPTIONAL OVERRIDES (defaults come from config/defaults.yaml):
#   ARGO_URL               - Argo CD server URL  (default: argocd_url)
#   ARGO_USER              - Admin username       (default: admin)
#   ARGOCD_GIT_REPO        - Git repo SSH URL     (default: git_repo_ssh)
#   ARGOCD_GIT_BRANCH      - Branch              (default: git_branch)
#   ARGOCD_SSH_KEY_PATH    - SSH key path        (default: ~/.ssh/id_rsa)
#
# Do not commit .env or real credentials. config/defaults.yaml is gitignored.
# -----------------------------------------------------------------------------

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/config/defaults.yaml"

# Load .env if present (for secrets: ARGO_PASS, KUBECONFIG)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Read a key from config/defaults.yaml (simple grep-based parser for scalar values)
_cfg() {
  local key="$1"
  if [ -f "$CONFIG_FILE" ]; then
    grep -E "^${key}:" "$CONFIG_FILE" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'"
  fi
}

# ── Load defaults from config/defaults.yaml ────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config/defaults.yaml not found."
  echo "       Copy config/defaults.yaml.example and fill in your values."
  exit 1
fi

_GIT_REPO="$(_cfg git_repo_ssh)"
_GIT_BRANCH="$(_cfg git_branch)"
_ARGO_URL="$(_cfg argocd_url)"
_NS_PROD="$(_cfg namespace_prod)"
_NS_DEV="$(_cfg namespace_dev)"
_NS_STAGE="$(_cfg namespace_stage)"
_NS_ARGOCD="$(_cfg namespace_argocd)"
_NS_CERT="$(_cfg namespace_cert_manager)"
_NS_NGINX="$(_cfg namespace_ingress)"

# Apply env var overrides (env takes precedence over config)
ARGO_URL="${ARGO_URL:-${_ARGO_URL:?Set argocd_url in config/defaults.yaml}}"
ARGO_USER="${ARGO_USER:-admin}"
ARGO_PASS="${ARGO_PASS:?Set ARGO_PASS via env var or .env file}"
export KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG via env var or .env file}"
GIT_REPO="${ARGOCD_GIT_REPO:-${_GIT_REPO:?Set git_repo_ssh in config/defaults.yaml}}"
GIT_BRANCH="${ARGOCD_GIT_BRANCH:-${_GIT_BRANCH:-main}}"
SSH_KEY_PATH="${ARGOCD_SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
GIT_PATH="argocd-bootstrap"

echo "==> Cluster access check"
kubectl get node

echo "==> Creating platform namespaces"
for ns in "${_NS_PROD:-prod}" "${_NS_DEV:-dev}" "${_NS_STAGE:-stage}" \
           "${_NS_ARGOCD:-argocd}" "${_NS_CERT:-cert-manager}" "${_NS_NGINX:-nginx}"; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl get ns

echo "==> Logging in to Argo CD at $ARGO_URL"
argocd login "$ARGO_URL" --username "$ARGO_USER" --password "$ARGO_PASS" --insecure

echo "==> Adding Git repo: $GIT_REPO"
argocd repo add "$GIT_REPO" --ssh-private-key-path "$SSH_KEY_PATH" --insecure-skip-server-verification

echo "==> Creating root Application (App-of-Apps)"
argocd app create argocd-bootstraper \
  --project default \
  --repo "$GIT_REPO" \
  --path "$GIT_PATH" \
  --revision "$GIT_BRANCH" \
  --revision-history-limit 0 \
  --dest-namespace "${_NS_ARGOCD:-argocd}" \
  --dest-server https://kubernetes.default.svc \
  --sync-option PruneLast=true \
  --sync-policy automated

echo "==> Done. Argo CD will now sync all Applications from $GIT_REPO/$GIT_PATH."
