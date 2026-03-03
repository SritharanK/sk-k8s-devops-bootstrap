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

INVENTORY            ?= ansible/inventories/dev/hosts.ini
VAULT_PASSWORD_FILE  ?= ansible/.ansible_vault_pass

# ── Helper: list all app chart directories ────────────────────────────────────
APP_CHARTS := $(wildcard helmcharts/app-charts/*/)
SYSTEM_CHARTS := helmcharts/system-charts/00_misc \
                 helmcharts/system-charts/network-policies \
                 helmcharts/system-charts/kyverno-policies \
                 helmcharts/system-charts/argocd-project

.PHONY: install-common bootstrap-k8s install-jenkins install-argocd seal-secrets \
        helm-deps helm-lint helm-render check

# ── Provisioning ──────────────────────────────────────────────────────────────

# Install common packages (Docker, RKE, kubectl, Java, Python, etc.) on inventory hosts.
install-common:
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/install_common.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Bootstrap Kubernetes cluster with RKE. Requires install-common first.
bootstrap-k8s: install-common
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/k8s_bootstrap.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Install and configure Jenkins (JCasC, Job DSL, plugins). Optional.
install-jenkins:
	cd ansible && ansible-playbook -i $(INVENTORY) playbooks/jenkins_setup.yml --vault-password-file $(VAULT_PASSWORD_FILE)

# Install Argo CD via Helm. Set KUBECONFIG before running.
# Uses values-lab.yaml (NodePort); for production use -f argo-cd/values-production.yaml.
install-argocd:
	cd helmcharts/system-charts && helm upgrade --install argocd argo-cd -f argo-cd/values-lab.yaml -n argocd --create-namespace

# Seal unsealed secret manifests with kubeseal.
seal-secrets:
	./scripts/misc/seal_k8s_secrets.sh

# ── Helm developer targets ────────────────────────────────────────────────────

# Resolve helm-common dependency for all app charts (run this once after clone).
helm-deps:
	@for chart in $(APP_CHARTS); do \
	  echo "── Building deps: $$chart"; \
	  helm dependency build $$chart; \
	done

# Lint all app charts and managed system charts. Run after any values or template change.
helm-lint: helm-deps
	@echo "── Linting app charts ──────────────────────────────────────────────"
	@for chart in $(APP_CHARTS); do \
	  echo "   $$chart"; \
	  helm lint $$chart --strict; \
	done
	@echo "── Linting system charts ───────────────────────────────────────────"
	@for chart in $(SYSTEM_CHARTS); do \
	  if [ -f "$$chart/Chart.yaml" ]; then \
	    echo "   $$chart"; \
	    helm lint $$chart --strict; \
	  fi \
	done
	@echo "── Linting argocd-bootstrap ────────────────────────────────────────"
	@helm lint argocd-bootstrap \
	  --set spec.source.repoURL=https://github.com/example/repo.git \
	  --set spec.destination.server=https://kubernetes.default.svc \
	  --set spec.destination.app_ns=prod \
	  --set spec.destination.argo_ns=argocd \
	  --set spec.source.targetRevision=main \
	  --strict

# Render all app charts to stdout (useful for quick visual inspection).
helm-render: helm-deps
	@for chart in $(APP_CHARTS); do \
	  name=$$(basename $$chart); \
	  echo ""; \
	  echo "════════════════════════════════════════════════════════════════════"; \
	  echo "  $$name (prod)"; \
	  echo "════════════════════════════════════════════════════════════════════"; \
	  helm template $$name $$chart -f $${chart}values-prod.yaml 2>/dev/null || true; \
	done

# Run all local validation checks (lint + yamllint if available).
check: helm-lint
	@if command -v yamllint >/dev/null 2>&1; then \
	  echo "── yamllint ────────────────────────────────────────────────────────"; \
	  yamllint -d relaxed config/defaults.yaml.example 2>/dev/null || true; \
	  yamllint -d relaxed argocd-bootstrap/values.yaml 2>/dev/null || true; \
	else \
	  echo "── yamllint not installed — skipping (pip install yamllint)"; \
	fi
	@echo "── check complete ───────────────────────────────────────────────────"
