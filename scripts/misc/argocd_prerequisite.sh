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
# REQUIRED ENV (or set in scripts/misc/.env):
#   ARGO_URL       - Argo CD server URL (e.g. 192.168.1.10:31980 or argocd.example.com)
#   ARGO_PASS      - Admin password
#   KUBECONFIG     - Path to kubeconfig (or ARGOCD_KUBECONFIG_PATH)
#   ARGOCD_GIT_REPO - Git repo URL (e.g. git@github.com:YOUR_ORG/your-repo.git)
#
# OPTIONAL ENV:
#   ARGO_USER (default: admin)
#   ARGOCD_GIT_PATH (default: argocd-bootstrap)
#   ARGOCD_GIT_BRANCH (default: main)
#   ARGOCD_SSH_KEY_PATH (default: $HOME/.ssh/id_rsa)
#
# Do not commit .env or real credentials. See docs/GETTING_STARTED.md.
# -----------------------------------------------------------------------------

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

ARGO_URL="${ARGO_URL:?Set ARGO_URL (e.g. argocd.example.com or IP:port)}"
ARGO_USER="${ARGO_USER:-admin}"
ARGO_PASS="${ARGO_PASS:?Set ARGO_PASS}"
export KUBECONFIG="${KUBECONFIG:-${ARGOCD_KUBECONFIG_PATH:?Set KUBECONFIG or ARGOCD_KUBECONFIG_PATH}}"
GIT_REPO="${ARGOCD_GIT_REPO:?Set ARGOCD_GIT_REPO (e.g. git@github.com:YOUR_ORG/your-repo.git)}"
GIT_PATH="${ARGOCD_GIT_PATH:-argocd-bootstrap}"
GIT_BRANCH="${ARGOCD_GIT_BRANCH:-main}"
SSH_KEY_PATH="${ARGOCD_SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

# Verify cluster access and create namespaces needed by Argo CD applications
kubectl get node
kubectl create ns prod || true
kubectl create ns cert-manager || true
kubectl create ns nginx || true
kubectl get ns

# Log in to Argo CD and add the Git repo (so Argo CD can clone and sync)
argocd login "$ARGO_URL" --username "$ARGO_USER" --password "$ARGO_PASS" --insecure
argocd repo add "$GIT_REPO" --ssh-private-key-path "$SSH_KEY_PATH" --insecure-skip-server-verification

# Create the root Application that syncs argocd-bootstrap/ from Git (App-of-Apps).
# Once this is synced, Argo CD will create all Applications defined in that path.
argocd app create argocd-bootstraper \
  --project default \
  --repo "$GIT_REPO" \
  --path "$GIT_PATH" \
  --revision "$GIT_BRANCH" \
  --revision-history-limit 0 \
  --dest-namespace argocd \
  --dest-server https://kubernetes.default.svc \
  --sync-option PruneLast=true \
  --sync-policy automated
