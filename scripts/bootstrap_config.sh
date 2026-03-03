#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# First-time config bootstrap: copy example config and inventory files so you
# can fill them with your values. Does not commit anything or add real secrets.
#
# RUN: From repo root:  ./scripts/bootstrap_config.sh
#
# CREATES (if missing):
#   - config/defaults.yaml          (from config/defaults.yaml.example)
#   - ansible/inventories/dev/hosts.ini (from .../hosts.ini.example)
#   - scripts/misc/.env             (from scripts/misc/.env.example)
# Then edit those files and follow the "Next steps" printed by this script.
# See docs/GETTING_STARTED.md and docs/PRODUCTION_SETUP.md.
# -----------------------------------------------------------------------------

set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== k8s-devops-bootstrap: config bootstrap ==="

# Central config
if [[ ! -f config/defaults.yaml ]]; then
  cp config/defaults.yaml.example config/defaults.yaml
  echo "Created config/defaults.yaml from example."
else
  echo "config/defaults.yaml already exists; skipping."
fi

# Ansible inventory
HOSTS_EXAMPLE="ansible/inventories/dev/hosts.ini.example"
HOSTS_FILE="ansible/inventories/dev/hosts.ini"
if [[ ! -f "$HOSTS_FILE" ]]; then
  if [[ -f "$HOSTS_EXAMPLE" ]]; then
    cp "$HOSTS_EXAMPLE" "$HOSTS_FILE"
    echo "Created $HOSTS_FILE from example."
  else
    echo "Warning: $HOSTS_EXAMPLE not found; create $HOSTS_FILE manually."
  fi
else
  echo "$HOSTS_FILE already exists; skipping."
fi

# Optional: Docker secret script env
ENV_EXAMPLE="scripts/misc/.env.example"
ENV_FILE="scripts/misc/.env"
if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "Created $ENV_FILE from example (set DOCKER_* before running seal script)."
fi

echo ""
echo "Next steps:"
echo "  1. Edit config/defaults.yaml — set master_ip, worker_ip, ansible_user, git URLs, Argo CD URL, registry, etc."
echo "  2. Edit $HOSTS_FILE — set YOUR_MASTER_IP and YOUR_WORKER_IP."
echo "  3. Create Ansible vault password and encrypt sensitive vars (see docs/PRODUCTION_SETUP.md and GETTING_STARTED.md)."
echo "  4. For image pulls: set DOCKER_* in $ENV_FILE and run scripts/misc/create_k8s_docker_secret_seal.sh (with KUBECONFIG set)."
echo "  5. Set Argo CD admin password (bcrypt) and argocd-bootstrap/values.yaml repo URL."
echo ""
echo "Full checklist: docs/PRODUCTION_SETUP.md"
