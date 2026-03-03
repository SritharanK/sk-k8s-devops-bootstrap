# -----------------------------------------------------------------------------
# Kubernetes DevOps Bootstrap - Makefile
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
# Run all targets from the repository root. These targets drive Ansible and
# Helm to provision the cluster and install Argo CD.
#
# PREREQUISITES:
#   - Ansible installed; inventory and config filled (see config/defaults.yaml.example).
#   - For playbooks: create ansible/.ansible_vault_pass and encrypt sensitive
#     vars (ansible_user, etc.) with ansible-vault encrypt_string.
#   - For install-argocd and seal-secrets: set KUBECONFIG to your kubeconfig.
#
# TYPICAL ORDER: install-common → bootstrap-k8s → [install-jenkins] → install-argocd
#                → run scripts/misc/argocd_prerequisite.sh → seal-secrets (optional).
# -----------------------------------------------------------------------------

INVENTORY ?= ansible/inventories/dev/hosts.ini
VAULT_PASSWORD_FILE ?= ansible/.ansible_vault_pass

.PHONY: bootstrap-k8s install-jenkins install-argocd seal-secrets install-common

# Install common packages (Docker, RKE, kubectl, Java, Python, etc.) on inventory hosts.
# Uses ansible/playbooks/install_common.yml and roles/common.
install-common:
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/install_common.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Bootstrap Kubernetes cluster with RKE. Requires install-common first.
# Uses ansible/playbooks/k8s_bootstrap.yml; writes kubeconfig to ansible/data/.
bootstrap-k8s: install-common
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/k8s_bootstrap.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Install and configure Jenkins (JCasC, Job DSL, plugins). Optional.
install-jenkins:
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/jenkins_setup.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Install Argo CD via Helm. Set KUBECONFIG before running.
# Uses values-lab.yaml (NodePort); for production use -f argo-cd/values-production.yaml.
# After this, run scripts/misc/argocd_prerequisite.sh to create the app-of-apps.
install-argocd:
	cd helmcharts/system-charts && helm upgrade --install argocd argo-cd -f argo-cd/values-lab.yaml -n argocd --create-namespace

# Seal unsealed secret manifests with kubeseal. Requires: KUBECONFIG set, kubeseal
# installed, and sealed-secrets controller running in the cluster. Reads from
# helmcharts/system-charts/argocd-config/unseal/ and writes to .../sealed/.
seal-secrets:
	./scripts/misc/seal_k8s_secrets.sh
