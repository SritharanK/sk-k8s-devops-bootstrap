# SPDX-License-Identifier: MIT
#
# Single entry point for local work and CI. Every CI job in
# .github/workflows/validate.yml runs one or more of these targets, so a
# developer reproduces a CI failure with the same command.
#
# Run from the repository root. `make` (or `make help`) lists the targets.
# Tool versions are pinned in mise.toml: `mise install`, then `make doctor`.
#
# Compatible with GNU Make 3.81 (macOS) and later: no .ONESHELL, no $(file),
# no `::=`, one shell per recipe line.

# Strict shell for every recipe line. GNU Make 3.81 ignores .SHELLFLAGS, so
# the flags are part of SHELL; newer versions pass the default `-c` after them.
SHELL := /usr/bin/env bash -eu -o pipefail
MAKEFLAGS += --no-builtin-rules --warn-undefined-variables
.SUFFIXES:
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Variables (override on the command line: make bootstrap-k8s PROFILE=reference)
# ---------------------------------------------------------------------------
# CLUSTER names clusters/<name>/cluster.yaml; PROFILE selects the Ansible
# inventory and the Argo CD values. Both default to lab, and PROFILE follows
# CLUSTER unless it is set explicitly.
CLUSTER ?= lab
PROFILE ?= $(CLUSTER)
CONFIRM ?=
STRICT ?=
BASE ?=
ANSIBLE_ARGS ?=
RENDER_ARGS ?=
JENKINS_LINT_ARGS ?=
OUT_DIR ?= _out
GH_TOKEN ?=
ANSIBLE_VAULT_IDENTITY_LIST ?=

ANSIBLE_DIR := ansible
# Relative to ANSIBLE_DIR, because the playbook targets run inside it.
INVENTORY ?= inventories/$(PROFILE)/hosts.yml
# Vault password per profile: prompts by default. For automation pass
# VAULT_ID=<profile>@<absolute path to a password file or client script>, or
# export ANSIBLE_VAULT_IDENTITY_LIST, which replaces this option.
VAULT_ID ?= $(PROFILE)@prompt
VAULT_ARGS := $(if $(ANSIBLE_VAULT_IDENTITY_LIST),,--vault-id $(VAULT_ID))

TRIVY ?= trivy
TRIVY_IGNORE := .github/trivy-ignore.yaml

# helm-unittest is a Helm plugin, so it is pinned here rather than in
# mise.toml. The plugin archive holds every platform binary; its SHA-256 is
# taken from helm-unittest-checksum.sha of the release.
# renovate: datasource=github-releases depName=helm-unittest/helm-unittest
HELM_UNITTEST_VERSION := 1.2.1
HELM_UNITTEST_SHA256 := bbcebd42631dff9fc595462fad839c49a1b06f9635e952e7e837d7e5fe82865f
HELM_UNITTEST_CACHE := $(OUT_DIR)/.cache/helm-unittest-$(HELM_UNITTEST_VERSION)

# Tracked files only, so local scratch files never change a lint result.
SHELL_FILES = $(shell git ls-files '*.sh' '*.bash')
DOCKERFILES = $(shell git ls-files 'Dockerfile' '**/Dockerfile' '*.Dockerfile')

# Conventional Commits header: type, optional scope, optional "!", subject;
# at most 100 characters. Merge commits are not checked.
CONVENTIONAL_RE := ^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9._/-]+\))?!?: [^ ].{0,90}$$

# $(call is_set,VAR): non-empty when VAR came from the command line or the
# environment, not from a default in this file.
is_set = $(filter command environment,$(firstword $(origin $(1))))

# Fails an Ansible target when the inventory file is missing. Without it
# ansible-playbook only warns, skips every play and exits 0, so the target
# would report success after doing nothing.
require_inventory = (cd $(ANSIBLE_DIR) && test -f '$(INVENTORY)') || { echo "inventory $(INVENTORY) not found under $(ANSIBLE_DIR)/: copy inventories/$(PROFILE)/hosts.yml.example to it and fill in the hosts, or set INVENTORY=<path relative to $(ANSIBLE_DIR)>" >&2; exit 1; }

# Fails a recipe when a script provided by another part of the repository is
# missing, naming the expected path.
require_file = test -f $(1) || { echo "missing $(1): $(2)" >&2; exit 1; }

# ---------------------------------------------------------------------------
##@ Help
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
	  /^##@ / { printf "\n%s\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_-]+:.*## / { printf "  %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nVariables: CLUSTER=%s PROFILE=%s INVENTORY=%s VAULT_ID=%s OUT_DIR=%s\n' '$(CLUSTER)' '$(PROFILE)' '$(INVENTORY)' '$(VAULT_ID)' '$(OUT_DIR)'
	@printf 'Examples:  make demo | make validate | make bootstrap-k8s PROFILE=reference | make rke2-uninstall CONFIRM=yes\n\n'

# ---------------------------------------------------------------------------
##@ Setup
# ---------------------------------------------------------------------------

.PHONY: tools
tools: ## Install the pinned toolchain from mise.toml
	mise trust --yes
	mise install

.PHONY: doctor
doctor: ## Check that every required tool is on PATH and show its version
	@missing=0; \
	for t in helm kubectl kind kubeconform kyverno chainsaw yq jq gitleaks trivy shellcheck shfmt actionlint zizmor hadolint yamllint markdownlint-cli2 lychee node npm ansible-playbook ansible-lint molecule tofu go cosign docker git; do \
	  if command -v "$$t" >/dev/null 2>&1; then printf '  ok       %s\n' "$$t"; \
	  else printf '  missing  %s\n' "$$t"; missing=1; fi; \
	done; \
	test "$$missing" = 0 || { echo "install the missing tools: make tools" >&2; exit 1; }
	@if command -v mise >/dev/null 2>&1; then mise ls --current; \
	else echo "mise not found: versions are not checked against mise.toml" >&2; fi

.PHONY: helm-plugins
helm-plugins: ## Install the pinned helm-unittest plugin (checksum verified)
	@installed="$$(helm plugin list | awk '$$1 == "unittest" { print $$2 }')"; \
	if [ "$$installed" = '$(HELM_UNITTEST_VERSION)' ]; then \
	  echo "helm-unittest $(HELM_UNITTEST_VERSION) already installed"; exit 0; fi; \
	if [ -n "$$installed" ]; then \
	  echo "helm-unittest $$installed is installed; remove it with 'helm plugin uninstall unittest', then rerun" >&2; exit 1; fi; \
	mkdir -p '$(HELM_UNITTEST_CACHE)'; \
	archive='$(HELM_UNITTEST_CACHE)/unittest-$(HELM_UNITTEST_VERSION).tgz'; \
	if [ ! -f "$$archive" ]; then \
	  curl --fail --silent --show-error --location --proto '=https' --retry 3 -o "$$archive.part" \
	    'https://github.com/helm-unittest/helm-unittest/releases/download/v$(HELM_UNITTEST_VERSION)/unittest-$(HELM_UNITTEST_VERSION).tgz'; \
	  mv "$$archive.part" "$$archive"; fi; \
	if command -v sha256sum >/dev/null 2>&1; then sum='sha256sum'; else sum='shasum -a 256'; fi; \
	echo '$(HELM_UNITTEST_SHA256)  '"$$archive" | $$sum -c -; \
	tar -xzf "$$archive" -C '$(HELM_UNITTEST_CACHE)'; \
	helm plugin install '$(abspath $(HELM_UNITTEST_CACHE))/unittest'

# ---------------------------------------------------------------------------
##@ Lint
# ---------------------------------------------------------------------------

.PHONY: lint
lint: lint-yaml lint-markdown lint-links-offline lint-shell lint-workflows lint-dockerfiles lint-catalog ## Run every offline linter (lint-catalog downloads the pinned validator once)

.PHONY: lint-yaml
lint-yaml: ## yamllint with .yamllint.yaml (Helm templates excluded)
	yamllint --strict --config-file .yamllint.yaml .

.PHONY: lint-markdown
lint-markdown: ## markdownlint-cli2 with .markdownlint-cli2.yaml
	markdownlint-cli2

.PHONY: lint-links
lint-links: ## lychee link check of Markdown files (network)
	lychee --config lychee.toml --no-progress './**/*.md'

.PHONY: lint-links-offline
lint-links-offline: ## lychee check of local links and anchors in Markdown files (no network)
	lychee --config lychee.toml --offline --no-progress './**/*.md'

.PHONY: lint-shell
lint-shell: ## shellcheck and shfmt on every tracked shell script
	shellcheck -x $(SHELL_FILES)
	shfmt -d -i 2 -ci $(SHELL_FILES)

.PHONY: lint-workflows
lint-workflows: ## actionlint and zizmor on GitHub workflows and actions
	actionlint
	zizmor $(if $(GH_TOKEN),,--offline) .github

.PHONY: lint-dockerfiles
lint-dockerfiles: ## hadolint on every tracked Dockerfile
	@$(if $(strip $(DOCKERFILES)),hadolint $(DOCKERFILES),echo "no Dockerfile found" >&2; exit 1)

.PHONY: lint-catalog
lint-catalog: ## Backstage catalog-info.yaml with the lockfile-pinned entity validator (npm ci, no install scripts)
	OUT_DIR='$(OUT_DIR)' hack/lint-catalog.sh

.PHONY: lint-commits
lint-commits: ## Conventional Commits check of the subjects in BASE..HEAD (BASE=<commit>)
	@test -n '$(BASE)' || { echo "set BASE=<commit>" >&2; exit 1; }
	@bad=0; while IFS= read -r subject; do \
	  if ! grep -Eq '$(CONVENTIONAL_RE)' <<<"$$subject"; then echo "not a Conventional Commit: $$subject" >&2; bad=1; fi; \
	done < <(git log --no-merges --format=%s '$(BASE)..HEAD'); \
	test "$$bad" = 0 && echo "commit subjects in $(BASE)..HEAD follow Conventional Commits"

.PHONY: test-lib
test-lib: ## Self-test of scripts/lib/common.sh
	scripts/lib/tests/common_test.sh

.PHONY: promotion-engine-test
promotion-engine-test: ## Test of hack/promotion-engine.sh (which engine writes the environment files) with fixture cluster files
	tests/promotion-engine/run.sh

# ---------------------------------------------------------------------------
##@ Security
# ---------------------------------------------------------------------------

.PHONY: secrets
secrets: ## gitleaks on the committed tree and working-copy changes
	hack/secrets.sh tree

.PHONY: secrets-range
secrets-range: ## gitleaks on commits BASE..HEAD (BASE=<commit>)
	@test -n '$(BASE)' || { echo "set BASE=<commit>" >&2; exit 1; }
	hack/secrets.sh range '$(BASE)'

.PHONY: secrets-history
secrets-history: ## gitleaks on the full history (credential rules)
	hack/secrets.sh history

.PHONY: secrets-test
secrets-test: ## Self-test of the gitleaks rules with generated fixtures
	hack/secrets-test.sh

.PHONY: trivy-config
trivy-config: render ## Trivy misconfiguration scan of the rendered manifests
	$(TRIVY) config --quiet --format json --output '$(OUT_DIR)/trivy-config.json' \
	  --ignorefile '$(TRIVY_IGNORE)' --exit-code 0 \
	  --skip-dirs '$(OUT_DIR)/.cache' --skip-dirs '$(OUT_DIR)/schemas' --skip-dirs '$(OUT_DIR)/e2e' \
	  --skip-dirs '$(OUT_DIR)/demo' --skip-dirs '$(OUT_DIR)/integration' \
	  --skip-files '$(OUT_DIR)/trivy-config.json' '$(OUT_DIR)'
	$(TRIVY) convert --quiet --format sarif --output '$(OUT_DIR)/trivy-config.sarif' '$(OUT_DIR)/trivy-config.json'
	$(TRIVY) convert --quiet --format table --severity HIGH,CRITICAL --exit-code 1 '$(OUT_DIR)/trivy-config.json'

# ---------------------------------------------------------------------------
##@ Validate
# ---------------------------------------------------------------------------

.PHONY: validate
validate: validate-config helm argocd-bootstrap policy-test ## Static validation of configuration, charts, GitOps and policies

.PHONY: validate-config
validate-config: ## Validate clusters/*/cluster.yaml and tenants/*.yaml, or one cluster with CLUSTER=<name> (STRICT=1 rejects placeholders)
	@$(call require_file,hack/validate-config.sh,cluster definition validator)
	hack/validate-config.sh $(if $(filter 1 yes true,$(STRICT)),--strict,) $(if $(call is_set,CLUSTER),clusters/$(CLUSTER)/cluster.yaml,)

.PHONY: helm
helm: helm-lint helm-unittest argocd-bootstrap-unittest ## Lint every chart and run the chart unit tests

.PHONY: helm-lint
helm-lint: ## helm dependency build and lint --strict of every chart
	hack/render.sh --lint-only

.PHONY: helm-unittest
helm-unittest: helm-plugins ## helm-unittest for every chart with a tests/ directory
	@charts=$$(git ls-files 'helmcharts/**/tests/*_test.yaml' | sed 's#/tests/[^/]*$$##' | sort -u); \
	test -n "$$charts" || { echo "no helm-unittest suites found (helmcharts/**/tests/*_test.yaml)" >&2; exit 1; }; \
	for c in $$charts; do \
	  echo "helm unittest $$c"; \
	  if yq -e '.dependencies | length > 0' "$$c/Chart.yaml" >/dev/null 2>&1; then helm dependency build "$$c" >/dev/null; fi; \
	  helm unittest --strict "$$c"; \
	done

.PHONY: argocd-bootstrap-unittest
argocd-bootstrap-unittest: helm-plugins ## helm-unittest render tests of argocd-bootstrap (tests/*_test.yaml: previews, image signing)
	helm unittest --strict -f 'tests/*_test.yaml' argocd-bootstrap

.PHONY: render
render: ## Render argocd-bootstrap and every chart per cluster profile into OUT_DIR
	OUT_DIR='$(OUT_DIR)' hack/render.sh $(RENDER_ARGS)

.PHONY: render-all
render-all: render ## Alias for render

# Supported Kubernetes minors other than the one the cluster files render for
# (support matrix baseline). The rendered manifests are also validated against
# their API schemas.
KUBECONFORM_EXTRA_VERSIONS ?= 1.35.0

.PHONY: kubeconform
kubeconform: render ## Validate rendered manifests against Kubernetes and CRD schemas (profile version and KUBECONFORM_EXTRA_VERSIONS)
	OUT_DIR='$(OUT_DIR)' hack/kubeconform.sh
	for v in $(KUBECONFORM_EXTRA_VERSIONS); do OUT_DIR='$(OUT_DIR)' KUBERNETES_VERSION="$$v" hack/kubeconform.sh; done

.PHONY: argocd-bootstrap
argocd-bootstrap: RENDER_ARGS = --skip-lint
argocd-bootstrap: kubeconform ## App of apps: rendered schemas, then Application and AppProject checks per cluster
	@$(call require_file,argocd-bootstrap/tests/check-projects.sh,AppProject checks)
	argocd-bootstrap/tests/check-projects.sh --deep

.PHONY: policy-test
policy-test: render ## kyverno test plus kyverno apply of the policies to rendered apps
	OUT_DIR='$(OUT_DIR)' hack/policy-test.sh

.PHONY: policy-test-attestations
policy-test-attestations: ## kyverno test of the vulnerability attestation gate against a throwaway local registry (Docker, cosign)
	helmcharts/system-charts/kyverno-policies/tests/vuln-attestation/run.sh

.PHONY: support-matrix
support-matrix: render ## Regenerate docs/reference/support-matrix.md
	OUT_DIR='$(OUT_DIR)' hack/support-matrix.sh

.PHONY: support-matrix-check
support-matrix-check: render ## Fail when docs/reference/support-matrix.md is out of date
	OUT_DIR='$(OUT_DIR)' hack/support-matrix.sh --check

# ---------------------------------------------------------------------------
##@ Containers
# ---------------------------------------------------------------------------

.PHONY: image-smoke
image-smoke: ## Build each sample service image and smoke test it (Docker)
	@$(call require_file,hack/image-smoke.sh,container smoke test)
	hack/image-smoke.sh

# ---------------------------------------------------------------------------
##@ Release
# ---------------------------------------------------------------------------

PUSH ?=
CHART ?=

.PHONY: publish-chart
publish-chart: ## Lint and package a chart for an OCI registry; dry run unless PUSH=1 (CHART=, HELM_OCI_REPO=)
	$(if $(CHART),CHART='$(CHART)' )hack/publish-chart.sh $(if $(filter 1 yes true,$(PUSH)),--push,)

# ---------------------------------------------------------------------------
##@ Ansible
# ---------------------------------------------------------------------------

.PHONY: ansible-deps
ansible-deps: ## Install the pinned Ansible collections
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r collections/requirements.yml -p collections

.PHONY: ansible-lint
ansible-lint: ansible-deps ## ansible-lint (production profile, ansible/.ansible-lint)
	cd $(ANSIBLE_DIR) && ansible-lint

.PHONY: ansible-syntax
ansible-syntax: ansible-deps ## Syntax check of every playbook and parse check of the example inventories
	cd $(ANSIBLE_DIR) && for p in playbooks/*.yml; do \
	  echo "syntax-check $$p"; ansible-playbook --syntax-check -i localhost, "$$p"; done
	cd $(ANSIBLE_DIR) && for i in inventories/*/hosts.yml.example; do \
	  echo "inventory $$i"; ANSIBLE_INVENTORY_PLUGIN_EXTS=.yml,.yaml,.json,.example \
	  ansible-inventory -i "$$i" --list >/dev/null; done

.PHONY: molecule
molecule: ansible-deps ## Molecule test of every scenario (Docker)
	@scenarios=$$(find $(ANSIBLE_DIR) -path '*/molecule/*/molecule.yml' -not -path '*/collections/*' -not -path '*/.cache/*' | sort); \
	test -n "$$scenarios" || { echo "no Molecule scenarios found under $(ANSIBLE_DIR)" >&2; exit 1; }; \
	for f in $$scenarios; do \
	  scenario=$$(basename "$$(dirname "$$f")"); base=$$(dirname "$$(dirname "$$(dirname "$$f")")"); \
	  echo "molecule test -s $$scenario in $$base"; (cd "$$base" && molecule test -s "$$scenario"); \
	done

.PHONY: preflight
preflight: ## Check the target hosts (PROFILE=lab|reference)
	@$(require_inventory)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/preflight.yml $(VAULT_ARGS) $(ANSIBLE_ARGS)

.PHONY: bootstrap-k8s
bootstrap-k8s: ## Install RKE2 on the inventory hosts (PROFILE=lab|reference)
	@$(require_inventory)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/site.yml $(VAULT_ARGS) $(ANSIBLE_ARGS)

.PHONY: rke2-uninstall
rke2-uninstall: ## Remove RKE2 and its data from the hosts (requires CONFIRM=yes)
	@test '$(CONFIRM)' = yes || { echo "rke2-uninstall destroys cluster state on every host of $(INVENTORY); rerun with CONFIRM=yes" >&2; exit 1; }
	@$(require_inventory)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/rke2_uninstall.yml -e confirm='$(CONFIRM)' $(VAULT_ARGS) $(ANSIBLE_ARGS)

.PHONY: install-jenkins
install-jenkins: ## Optional on-premises Jenkins adapter (PROFILE=lab|reference)
	@$(require_inventory)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/jenkins_setup.yml $(VAULT_ARGS) $(ANSIBLE_ARGS)

.PHONY: jenkins-lint
jenkins-lint: ## Jenkins pipeline linter in a local controller (JENKINS_LINT_ARGS=--static-only skips Docker)
	@$(call require_file,hack/jenkins-lint.sh,Jenkins pipeline linter)
	hack/jenkins-lint.sh $(JENKINS_LINT_ARGS)

# ---------------------------------------------------------------------------
##@ Infrastructure
# ---------------------------------------------------------------------------

.PHONY: tofu-validate
tofu-validate: ## OpenTofu fmt check, validate and offline tests (mocked providers) of every module under infra/
	@modules=$$(find infra -name '*.tf' -not -path '*/.terraform/*' | xargs -n1 dirname | sort -u); \
	test -n "$$modules" || { echo "no OpenTofu modules found under infra/" >&2; exit 1; }; \
	tofu fmt -check -recursive infra; \
	for m in $$modules; do \
	  echo "tofu validate $$m"; \
	  (cd "$$m" && tofu init -backend=false -input=false -lockfile=readonly >/dev/null && tofu validate -no-color); \
	  if ls "$$m"/tests/*.tftest.hcl >/dev/null 2>&1; then \
	    echo "tofu test $$m"; (cd "$$m" && tofu test -no-color); fi; \
	done

# ---------------------------------------------------------------------------
##@ GitOps
# ---------------------------------------------------------------------------

.PHONY: install-argocd
install-argocd: ## Install or upgrade Argo CD (CLUSTER=<name> and/or PROFILE=lab|reference, current KUBECONFIG)
	@$(call require_file,hack/argocd-install.sh,Argo CD install script)
	$(if $(call is_set,CLUSTER),CLUSTER='$(CLUSTER)' )$(if $(or $(call is_set,PROFILE),$(if $(call is_set,CLUSTER),,x)),PROFILE='$(PROFILE)' )hack/argocd-install.sh

.PHONY: bootstrap-gitops
bootstrap-gitops: ## Apply AppProjects and the root Application (CLUSTER=, REPO_URL=, TARGET_REVISION=, HUB_MODE=, REPO_SECRET_FILE=)
	@$(call require_file,hack/bootstrap-gitops.sh,GitOps bootstrap script)
	CLUSTER='$(CLUSTER)' hack/bootstrap-gitops.sh '$(CLUSTER)'

# ---------------------------------------------------------------------------
##@ Demo and end-to-end
# ---------------------------------------------------------------------------

.PHONY: demo
demo: ## Bring up the lab profile on a local kind cluster
	@$(call require_file,hack/demo/up.sh,demo start script)
	hack/demo/up.sh

.PHONY: demo-down
demo-down: ## Delete the demo kind cluster
	@$(call require_file,hack/demo/down.sh,demo teardown script)
	hack/demo/down.sh

.PHONY: e2e
e2e: ## End-to-end test on kind (make demo plus assertions)
	@$(call require_file,hack/e2e/run.sh,end-to-end test runner)
	hack/e2e/run.sh

.PHONY: dr-drill
dr-drill: ## Backup and restore drill against the current kube context (Velero must be installed)
	@$(call require_file,hack/dr/restore-drill.sh,backup and restore drill)
	hack/dr/restore-drill.sh

# ---------------------------------------------------------------------------
##@ CI
# ---------------------------------------------------------------------------

.PHONY: ci
ci: lint test-lib promotion-engine-test secrets secrets-test validate-config helm argocd-bootstrap policy-test trivy-config support-matrix-check ansible-lint ansible-syntax tofu-validate jenkins-lint-static ## Static CI jobs locally (no Docker; downloads charts, collections and providers)

# The static half of the jenkins-lint job; the controller checks need Docker.
.PHONY: jenkins-lint-static
jenkins-lint-static: JENKINS_LINT_ARGS = --static-only
jenkins-lint-static: jenkins-lint ## Static checks of the Jenkins adapter only (no Docker)

# ---------------------------------------------------------------------------
##@ Documentation site, previews and tracing
# ---------------------------------------------------------------------------

# Documentation site (mkdocs.yml). MkDocs and its plugins run from a virtual
# environment under OUT_DIR that uv creates from requirements-docs.txt (every
# package pinned with hashes). uv downloads the Python version below when the
# machine does not have it.
DOCS_PYTHON := 3.13
DOCS_VENV := $(OUT_DIR)/.venv-docs
DOCS_REQUIREMENTS := requirements-docs.txt
DOCS_ADDR ?= 127.0.0.1:8000

.PHONY: docs-venv
docs-venv: ## Create or update the documentation virtual environment (uv, hashes required)
	uv venv --quiet --allow-existing --python $(DOCS_PYTHON) $(DOCS_VENV)
	uv pip sync --quiet --require-hashes --python $(DOCS_VENV) $(DOCS_REQUIREMENTS)

.PHONY: docs-build
docs-build: docs-venv ## Strict build of the documentation site into OUT_DIR/site
	$(DOCS_VENV)/bin/mkdocs build --strict --clean --site-dir '$(abspath $(OUT_DIR))/site'

.PHONY: docs-serve
docs-serve: docs-venv ## Live preview of the documentation site (DOCS_ADDR=127.0.0.1:8000)
	$(DOCS_VENV)/bin/mkdocs serve --strict --dev-addr '$(DOCS_ADDR)'

.PHONY: docs-lock
docs-lock: ## Resolve requirements-docs.txt again from the direct pins in its header (network)
	@tmp="$$(mktemp)"; \
	sed -n '/^$$/q;p' $(DOCS_REQUIREMENTS) > "$$tmp"; \
	echo >> "$$tmp"; \
	sed -n 's/^#   \([A-Za-z0-9._-]*==[^ ]*\)$$/\1/p' $(DOCS_REQUIREMENTS) \
	  | uv pip compile --quiet --generate-hashes --universal --python-version $(DOCS_PYTHON) --no-header - >> "$$tmp"; \
	mv "$$tmp" $(DOCS_REQUIREMENTS); \
	echo "updated $(DOCS_REQUIREMENTS)"

.PHONY: previews-test
previews-test: helm-plugins ## Render tests of the pull request preview ApplicationSets (helm-unittest)
	helm unittest --strict -f 'tests/previews_test.yaml' argocd-bootstrap

.PHONY: integration-tracing
integration-tracing: ## hello-api trace reaches Tempo on a throwaway kind cluster (Docker)
	tests/integration/tracing/run.sh

.PHONY: integration-kargo
integration-kargo: ## Kargo promotion dev, stage and prod on a throwaway kind cluster with a local registry and Git server (Docker)
	tests/integration/kargo/run.sh
