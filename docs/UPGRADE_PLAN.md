# Enterprise-Grade Upgrade Plan — Final

**Status:** Final. Incorporates full hardcode audit + all review cycles.  
**Format:** Phased, PR-by-PR. Each PR is atomic — one concern, one review, one merge.

---

## Executive Decisions (Locked)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| `foggypay` rename | → `payments-example` | Brand name in a public repo creates confusion and maintenance risk |
| `helm-common` publishing | OCI via GitHub Packages | Local `file://` blocks external reuse; OCI is the Helm 3.8+ standard |
| Kubernetes provisioner default | RKE2 (default), RKE1 (legacy flag) | RKE1 is legacy; new clusters use RKE2. RKE1 has `legacy_compatibility: true` comment in config |
| Observability | Optional opt-in, lab/demo values only, no persistence | Bootstrap platform — not a monitoring product |
| Secret templates directory | `argocd-config/templates/` (renamed from `unseal/`) | "unseal" implies a runtime verb; "templates" correctly signals documentation-as-code |
| Phase 5 docs | Merge into `OPERATIONS.md` + `SECURITY.md` | Avoid doc sprawl |
| AppProject whitelist | Minimal default + commented expansion block | Tight by default, explained for when to loosen |
| ApplicationSet vs Static Apps | Both present — Static = simple mode, ApplicationSet = scale mode | Documented explicitly in README to prevent "duplication" confusion |
| SBOM enforcement split | Jenkins = enforcement (blocks on failure), GH Actions = advisory | Mirrors the existing Trivy split. Consistent narrative, no tooling duplication |

---

## Core Principle: Configuration Flow Architecture

**Every configurable value must flow from a single source through a defined chain. Hardcoded values anywhere in the chain break reusability.**

```
config/defaults.yaml.example
         │
         ▼  (operator copies and fills)
config/defaults.yaml  ──────────────────────────────────────────────┐
         │                                                           │
         ▼  (vars_files in every playbook)                          │
Ansible playbooks / group_vars                                       │
         │                                                           │
         ├──▶ Jenkins JCasC (jenkins.yaml template)                 │
         │         │                                                 │
         │         ▼  (global env vars in JCasC)                    │
         │    Jenkinsfiles (read only from env vars / params)        │
         │                                                           │
         └──▶ Ansible roles / templates (rke_cluster.yml.j2, etc.)  │
                                                                     │
                                                          argocd-bootstrap/values.yaml
                                                                     │
                                                                     ▼
                                                         Helm chart values
                                                                     │
                                                                     ▼
                                                         Running workloads
```

**Rule:** If a value is not in `config/defaults.yaml.example`, it must not be hardcoded anywhere else.  
**Rule:** Ansible playbooks always load `config/defaults.yaml` via `vars_files`.  
**Rule:** Jenkinsfiles read all environment-specific values from Jenkins global env vars (set via JCasC from Ansible vars) — no fallback placeholders like `YOUR_*`.  
**Rule:** Raw YAML manifests (`00_misc`, `network-policies`, `kyverno-policies`) are wrapped in Helm charts so namespace names and other values come from `argocd-bootstrap/values.yaml`.

---

## Hardcode Audit Summary

The full audit found the following categories of hardcoded values:

| Severity | Count | Key Examples |
|----------|-------|-------------|
| **Critical — plaintext secrets in defaults/playbooks** | 4 | `jenkins_admin_password: admin`, `postgres_password: "postgres"`, `gitlab_root_password: "root"`, repeated in both defaults AND playbooks |
| **High — runtime breakage** | 8 | `YOUR_PLATFORM_ADMIN_GROUP` in RBAC YAML, `CHANGE_ME` DB passwords in prod values, `repoURL: CHANGE_ME` in ArgoCD bootstrap, foggypay CI/CD both point to `java-springboot.git` |
| **High — credential IDs hardcoded in Jenkinsfiles** | 5 | `"git-ssh-key"`, `"dockerhub"`, `"jenkins_git_user"`, `"argocd-creds"`, `"jenkins@example.com"` in all 10 Jenkinsfiles |
| **Medium — structural values not in config** | 20+ | Namespace names `prod`/`dev` in 8+ files, ingress-nginx namespace `nginx`, `jenkins_port`, `rke_cluster_name`, `registry_pull_secret_name` |
| **Low — tunable defaults** | 15+ | PostgreSQL `max_connections`, MariaDB paths, RKE CNI options, resource quota values |

**Root cause:** `config/defaults.yaml.example` is missing ~20 keys that are hardcoded elsewhere. Ansible playbooks do not load this file as `vars_files`. Raw YAML manifests have no templating layer.

---

## Phase 0 — Configuration Architecture Foundation

> **Must complete before all other phases.** This phase establishes the configuration plumbing that everything else depends on. Without Phase 0, every other fix is still partially hardcoded.

### PR-000 · Expand `config/defaults.yaml.example` with all missing keys

**File:** `config/defaults.yaml.example`

Add every value that is currently hardcoded elsewhere but missing from the central config:

```yaml
# ---- Cluster identity ----
cluster_name: "YOUR_CLUSTER_NAME"
kubernetes_provisioner: "rke2"         # rke2 (recommended) or rke1 (legacy)
rke_network_plugin: "flannel"          # flannel or calico
cluster_cidr: "10.42.0.0/16"          # Pod CIDR — Flannel default
service_cidr: "10.43.0.0/16"          # Service CIDR — Flannel default

# ---- Platform namespaces ----
namespace_prod: "prod"
namespace_dev: "dev"
namespace_stage: "stage"
namespace_argocd: "argocd"
namespace_cert_manager: "cert-manager"
namespace_ingress: "nginx"

# ---- Ingress ----
ingress_class_name: "nginx"

# ---- Jenkins ----
jenkins_port: "8081"
jenkins_admin_username: "admin"
jenkins_num_executors: "5"
jenkins_git_creds_id: "git-ssh-key"
jenkins_docker_creds_id: "dockerhub"
jenkins_git_user_creds_id: "jenkins_git_user"
jenkins_argocd_creds_id: "argocd-creds"
jenkins_agent_label: "default"
jenkins_git_commit_user: "jenkins"
jenkins_git_commit_email: "jenkins@YOUR_DOMAIN"
jenkins_dsl_script_pattern: "scripts/**/*.groovy"

# ---- Registry ----
registry_pull_secret_name: "dockerhub-secret"

# ---- ArgoCD ----
argocd_namespace: "argocd"
argocd_project_name: "prod"

# ---- RBAC ----
platform_admin_group: "YOUR_PLATFORM_ADMIN_GROUP"
platform_deployers_group: "deployers"

# ---- Database (optional) ----
postgresql_version: "15"
postgresql_port: "5432"
postgresql_allowed_cidr: "0.0.0.0/0"  # Restrict to cluster CIDR in production
mysql_port: "3306"

# ---- Resource quotas (prod / dev / stage) ----
quota_prod_requests_cpu: "10"
quota_prod_limits_cpu: "20"
quota_prod_requests_memory: "20Gi"
quota_prod_limits_memory: "40Gi"
quota_prod_pods: "50"
quota_dev_requests_cpu: "5"
quota_dev_limits_cpu: "10"
quota_dev_requests_memory: "10Gi"
quota_dev_limits_memory: "20Gi"
quota_dev_pods: "30"
quota_stage_requests_cpu: "8"
quota_stage_limits_cpu: "16"
quota_stage_requests_memory: "16Gi"
quota_stage_limits_memory: "32Gi"
quota_stage_pods: "40"
```

---

### PR-001 · Make all Ansible playbooks load `config/defaults.yaml`

**Files:** All 5 playbooks in `ansible/playbooks/`

**Problem:** Playbooks define values independently and repeat/override what should come from the central config.

**Fix:** Add `vars_files` at the top of every playbook:

```yaml
# ansible/playbooks/jenkins_setup.yml (and all other playbooks)
- name: Install and Configure Jenkins
  hosts: jenkins
  become: yes
  gather_facts: true

  vars_files:
    - ../../config/defaults.yaml       # Single source of truth

  vars:
    # Vault-encrypted secrets only — no plain values here
    ansible_user: !vault |
      ...
    jenkins_admin_password: !vault |
      ...
```

**Remove from playbooks** all values that now come from `config/defaults.yaml`:
- `jenkins_port`, `jenkins_dsl_git_branch`, `dsl_script_pattern`, `git_creds_id`, `num_executor`, `argocd_username`
- From `install_database.yml`: `postgresql_version`, `postgresql_port`, `mysql_port`

**Fix Ansible role defaults** — remove plaintext password defaults entirely. These are now intentionally blank (must be provided via vault):
- `ansible/roles/install_jenkins/defaults/main.yml`: remove `jenkins_admin_password: admin`
- `ansible/roles/install_postgresql/defaults/main.yml`: remove `postgres_password: "postgres"`
- `ansible/roles/install_gitlab_server/defaults/main.yml`: remove `gitlab_root_password: "root"`

Replace with a required-variable assertion:
```yaml
# In role tasks/main.yml — fail fast if not provided
- name: Assert required secrets are provided
  assert:
    that:
      - jenkins_admin_password is defined
      - jenkins_admin_password | length > 0
    fail_msg: "jenkins_admin_password must be set via vault. See docs/SECURITY.md."
```

---

### PR-002 · Convert `00_misc` raw YAMLs to a Helm chart

**Problem:** `helmcharts/system-charts/00_misc/` contains raw YAML files with hardcoded namespace names, email addresses, RBAC group names, and resource quota values. There is no templating layer — values cannot be configured without editing source files.

**Fix:** Add `Chart.yaml` and `values.yaml` to `00_misc/`, and wrap each manifest in a Helm templates folder.

**New structure:**
```
helmcharts/system-charts/00_misc/
  Chart.yaml
  values.yaml
  templates/
    namespaces-pss.yaml
    limitrange-resourcequota.yaml
    cert_manager_issuer.yaml
    platform-admin-rbac.yaml
    app-namespace-role-deployer.yaml
```

**`values.yaml`** (all values come from `argocd-bootstrap/values.yaml` → passed via Helm):
```yaml
namespaces:
  prod: "prod"
  dev: "dev"
  stage: "stage"

certManager:
  email: "CHANGE_ME"             # cert_manager_email from config/defaults.yaml — never use example.com
  ingressClass: "nginx"

rbac:
  platformAdminGroup: "YOUR_PLATFORM_ADMIN_GROUP"
  deployersGroup: "deployers"

quotas:
  prod:
    requestsCpu: "10"
    limitsCpu: "20"
    requestsMemory: "20Gi"
    limitsMemory: "40Gi"
    pods: "50"
  dev:
    requestsCpu: "5"
    limitsCpu: "10"
    requestsMemory: "10Gi"
    limitsMemory: "20Gi"
    pods: "30"
  stage:
    requestsCpu: "8"
    limitsCpu: "16"
    requestsMemory: "16Gi"
    limitsMemory: "32Gi"
    pods: "40"
```

**Example `templates/cert_manager_issuer.yaml`:**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: {{ .Values.certManager.email }}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: {{ .Values.certManager.ingressClass }}
```

**Update `argocd-bootstrap/templates/toolchains/misc.yaml`** to pass values:
```yaml
helm:
  valueFiles:
    - values.yaml
  parameters:
    - name: certManager.email
      value: {{ .Values.platform.certManagerEmail }}
    - name: rbac.platformAdminGroup
      value: {{ .Values.platform.adminGroup }}
```

**Update `argocd-bootstrap/values.yaml`** to include these platform-level values.

---

### PR-003 · Convert `network-policies` to a Helm chart

**Problem:** Network policy YAMLs hardcode namespace names (`prod`, `dev`) and the ingress-nginx namespace (`nginx`). Adding a new namespace (e.g. `stage`) requires editing source YAML files directly.

**Fix:** Same pattern as PR-002. Add `Chart.yaml`, `values.yaml`, `templates/`.

**`values.yaml`:**
```yaml
appNamespaces:
  - prod
  - dev
  - stage
ingressNginxNamespace: "nginx"
```

**`templates/default-deny.yaml`:**
```yaml
{{- range .Values.appNamespaces }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: {{ . }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
{{- end }}
```

Same `range` pattern for `allow-dns-egress.yaml` and `allow-ingress-from-nginx.yaml`.

**Result:** Adding the `stage` namespace to network policies is now a one-line change in `argocd-bootstrap/values.yaml`.

---

### PR-004 · Convert `kyverno-policies` to a Helm chart

**Problem:** Three of four Kyverno policies hardcode namespace names (`prod`, `dev`). Any new enforced namespace requires direct file editing.

**Fix:** Same Helm chart pattern.

**`values.yaml`:**
```yaml
enforcedNamespaces:
  - prod
  - dev
  - stage
```

**`templates/require-readiness-probe.yaml`:**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-readiness-probe
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-readiness-probe
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                {{- range .Values.enforcedNamespaces }}
                - {{ . }}
                {{- end }}
      validate:
        message: "Pods must define a readinessProbe."
        pattern:
          spec:
            containers:
              - readinessProbe: {}
```

**Guardrail from review:** Kyverno policies already target only `prod`/`dev` — toolchain namespaces (`kube-system`, `argocd`, `cert-manager`, `nginx`) are NOT in the enforced list. The Helm chart makes this explicit and configurable. Verify the `enforcedNamespaces` list never includes system namespaces.

---

### PR-005 · Fix Jenkins JCasC — all values from config, global env vars for Jenkinsfiles

**File:** `ansible/roles/install_jenkins/templates/jenkins.yaml`

**Problem:** Jenkins CasC has hardcoded `http://jenkins:8081/`, `'jenkins'` username, and no global environment variables. Jenkinsfiles hardcode credential IDs and git commit identity.

**Fix — Part A:** Template all values in `jenkins.yaml`:
```yaml
jenkins:
  systemMessage: "{{ cluster_name }} Jenkins — managed by Ansible JCasC"
  numExecutors: {{ jenkins_num_executors }}

  globalNodeProperties:
    - envVars:
        env:
          # All values Jenkinsfiles need — read from these env vars, never hardcoded
          - key: "DOCKER_REGISTRY"
            value: "{{ docker_registry }}"
          - key: "OPS_GIT_REPO"
            value: "{{ git_repo_ssh }}"
          - key: "ARGOCD_SERVER"
            value: "{{ argocd_url }}"
          - key: "GIT_CREDS_ID"
            value: "{{ jenkins_git_creds_id }}"
          - key: "DOCKER_CREDS_ID"
            value: "{{ jenkins_docker_creds_id }}"
          - key: "JENKINS_GIT_USER_CREDS_ID"
            value: "{{ jenkins_git_user_creds_id }}"
          - key: "ARGOCD_CREDS_ID"
            value: "{{ jenkins_argocd_creds_id }}"
          - key: "JENKINS_AGENT_LABEL"
            value: "{{ jenkins_agent_label }}"
          - key: "GIT_COMMIT_USER"
            value: "{{ jenkins_git_commit_user }}"
          - key: "GIT_COMMIT_EMAIL"
            value: "{{ jenkins_git_commit_email }}"

  location:
    url: "http://{{ ansible_host }}:{{ jenkins_port }}/"
    adminAddress: "{{ jenkins_git_commit_email }}"

securityRealm:
  local:
    allowsSignup: false
    users:
      - id: "{{ jenkins_admin_username }}"
        name: "Jenkins Administrator"
        password: "{{ jenkins_admin_password }}"
```

**Fix — Part B:** Update ALL Jenkinsfiles (CI and CD, all 5) to read from env vars instead of hardcoded IDs:
```groovy
// Before (hardcoded):
def gitCredsId = "git-ssh-key"
sshagent(credentials: ['git-ssh-key'])

// After (from Jenkins global env var set by JCasC):
def gitCredsId = env.GIT_CREDS_ID ?: error("GIT_CREDS_ID not set in Jenkins global env")
sshagent(credentials: [gitCredsId])
```

Apply same pattern to: `DOCKER_CREDS_ID`, `ARGOCD_CREDS_ID`, `JENKINS_GIT_USER_CREDS_ID`, `JENKINS_AGENT_LABEL`, `GIT_COMMIT_USER`, `GIT_COMMIT_EMAIL`.

**Note:** Using `?: error(...)` instead of `?: "fallback"` means Jenkins fails fast with a clear message when a variable is not configured, rather than silently using a wrong/placeholder value.

---

### PR-006 · Fix all Jenkinsfiles — remove hardcoded values and copy-paste bugs

**Files:** All 10 Jenkinsfiles (5 CI, 5 CD)

**Issues beyond credential IDs:**

1. **foggypay CI and CD both use `java-springboot.git` as the service repo** — copy-paste bug. Fix: use `payments-example.git` (after rename in Phase 2).

2. **`surge_plugin` CD uses `${params.Environment}` (lowercase e)** — fix to `${params.ENVIRONMENT}`.

3. **Git commit identity hardcoded in CD Jenkinsfiles:**
```groovy
// Before:
sh "git config user.name 'jenkins'"
sh "git config user.email 'jenkins@example.com'"

// After:
sh "git config user.name '${env.GIT_COMMIT_USER}'"
sh "git config user.email '${env.GIT_COMMIT_EMAIL}'"
```

4. **Agent label:**
```groovy
// Before:
agent { label 'default' }

// After:
agent { label env.JENKINS_AGENT_LABEL ?: 'default' }
```

5. **`helm chart path` variable** — `def helmChartPath = "helmcharts/app-charts/${serviceName}"` is derived from service name, which is correct. No change needed.

---

### PR-007 · Fix `argocd-bootstrap/values.yaml` — source values from config

**File:** `argocd-bootstrap/values.yaml`

**Problem:** `repoURL: CHANGE_ME` and `targetRevision: main` hardcoded. Operators who don't read the README will miss these.

**Fix:** Add inline comments pointing to `config/defaults.yaml`:
```yaml
# argocd-bootstrap/values.yaml
# ─────────────────────────────────────────────────────────────────────────────
# All CHANGE_ME values below must match what you set in config/defaults.yaml.
# Run: ./scripts/misc/argocd_prerequisite.sh  — it reads .env which sources defaults.
# ─────────────────────────────────────────────────────────────────────────────
spec:
  project: "prod"                    # argocd_project_name from config/defaults.yaml
  destination:
    server: "https://kubernetes.default.svc"
    app_ns: "prod"                   # namespace_prod from config/defaults.yaml
    argo_ns: "argocd"                # namespace_argocd from config/defaults.yaml
  source:
    repoURL: "CHANGE_ME"             # git_repo_url from config/defaults.yaml
    targetRevision: "main"           # git_branch from config/defaults.yaml
    helm:
      valueFiles:
        - values-prod.yaml

# ---- Platform values (used by toolchain Helm charts via Argo CD parameters) ----
platform:
  certManagerEmail: "CHANGE_ME"           # cert_manager_email from config/defaults.yaml — never example.com
  adminGroup: "YOUR_PLATFORM_ADMIN_GROUP" # platform_admin_group from config/defaults.yaml
  deployersGroup: "deployers"             # platform_deployers_group from config/defaults.yaml
  clusterCidr: "10.42.0.0/16"            # cluster_cidr from config/defaults.yaml

namespaces:
  prod: "prod"
  dev: "dev"
  stage: "stage"
  argocd: "argocd"
  nginx: "nginx"
  certManager: "cert-manager"

reloader:
  enabled: true

observability:
  prometheus:
    enabled: false

applicationset:
  enabled: false
```

**Update `scripts/misc/argocd_prerequisite.sh`** to load `config/defaults.yaml` and auto-populate `argocd-bootstrap/values.yaml`:
```bash
# Read from config/defaults.yaml and set Argo CD bootstrap values
source config/defaults.yaml 2>/dev/null || true
GIT_REPO="${ARGOCD_GIT_REPO:-${git_repo_ssh:?'Set git_repo_ssh in config/defaults.yaml'}}"
GIT_BRANCH="${ARGOCD_GIT_BRANCH:-${git_branch:-main}}"
```

---

## Phase 1 — Fix Remaining Broken Code

> All correctness bugs not addressed in Phase 0.

### PR-008 · Fix Ansible Java installation (Debian/Ubuntu)

**File:** `ansible/roles/common/tasks/install_java.yml`

```yaml
---
- name: Install Java (Debian/Ubuntu)
  apt:
    name: "openjdk-{{ java_version }}-jdk"
    state: present
    update_cache: yes
  when: ansible_distribution in ['Debian', 'Ubuntu']

- name: Install Java (RHEL/CentOS/Fedora)
  yum:
    name:
      - "java-{{ java_version }}-openjdk"
      - "java-{{ java_version }}-openjdk-devel"
    state: present
  when: ansible_distribution in ['RedHat', 'CentOS', 'Fedora']

- name: Verify Java installation
  command: java -version
  register: java_version_output
  changed_when: false

- name: Display Java version
  debug:
    msg: "Java installed: {{ java_version_output.stderr }}"
```

---

### PR-009 · Fix Helm dependency URLs (temporary fix; PR-023 is the permanent fix)

**Files:** `helmcharts/app-charts/foggypay/Chart.yaml`, `python-django/Chart.yaml`, `surge-plugin/Chart.yaml`

Change `repository: https://raw.githubusercontent.com/YOUR_ORG/helm-common/main` to `repository: "file://../../helm-common"`.

**Note in commit message:** "Temporary: use local file dep until helm-common is published via OCI in PR-023. Remove any guidance about raw GitHub URLs as Helm repos from all doc comments."

---

### PR-010 · Fix database group_vars

**File:** `ansible/inventories/dev/group_vars/database.yml`

```yaml
enable_create_linux_user: false
enable_install_rke: false
enable_install_docker: true
enable_install_nfs: false
enable_install_kubectl: false
enable_install_python: true
enable_install_java: false
enable_install_yq: false
enable_install_ansible: false
enable_install_argocd: false
enable_install_php_tools: false
```

---

### PR-011 · Fix ArgoCD bootstrap file typo + rename

Rename `argocd-bootstrap/templates/applications/foogypay.yaml` → `foggypay.yaml` (will be renamed again to `payments-example.yaml` in PR-015).

---

## Phase 2 — Fix What Contradicts the Documentation

> Credibility. Every documented security claim must match the code.

### PR-012 · Fix AppProject: Scope cluster-wide access, restrict sourceRepos

**File:** `helmcharts/system-charts/argocd-project/prod.yml`

```yaml
spec:
  sourceRepos:
    # Only your GitOps repo. No wildcard — prevents arbitrary repo injection.
    - "CHANGE_ME"     # git_repo_url from config/defaults.yaml

  destinations:
    # Destinations are now templated via Helm (this file becomes a Helm chart in PR-002)
    # Until then, list all needed namespaces explicitly — no wildcard namespace.
    - namespace: prod
      server: https://kubernetes.default.svc
    - namespace: dev
      server: https://kubernetes.default.svc
    - namespace: stage
      server: https://kubernetes.default.svc
    - namespace: cert-manager
      server: https://kubernetes.default.svc
    - namespace: nginx
      server: https://kubernetes.default.svc
    - namespace: kube-system
      server: https://kubernetes.default.svc
    - namespace: monitoring
      server: https://kubernetes.default.svc

  # Minimal cluster-scoped whitelist.
  # Argo CD can only create cluster-scoped resources of these types.
  clusterResourceWhitelist:
    - group: ""
      kind: "Namespace"
    - group: "apiextensions.k8s.io"
      kind: "CustomResourceDefinition"
    # argoproj.io CRDs are cluster-scoped (AppProject, ClusterWorkflowTemplate, etc.)
    # Required for Argo CD to manage its own resources.
    - group: "argoproj.io"
      kind: "*"

  # --- Expand ONLY when deploying cluster-scoped controllers via Argo CD ---
  # (cert-manager, Kyverno, ingress-nginx, sealed-secrets install ClusterRoles)
  # Uncomment when needed:
  #  - group: "rbac.authorization.k8s.io"
  #    kind: "ClusterRole"
  #  - group: "rbac.authorization.k8s.io"
  #    kind: "ClusterRoleBinding"
  #  - group: "cert-manager.io"
  #    kind: "*"
  #  - group: "kyverno.io"
  #    kind: "*"
  #  - group: "bitnami.com"
  #    kind: "SealedSecret"
```

---

### PR-013 · Fix helm-common: Add container-level runAsNonRoot

**Files:** `helmcharts/helm-common/values.yaml`, `helmcharts/helm-common/templates/deployment.yaml`

Add `runAsNonRoot: true` to the container-level securityContext in both the values and the template.

---

### PR-014 · Fix readiness/liveness probes in all app charts + add `/health` to sample services

**Files:** `helmcharts/app-charts/*/values-prod.yaml` (all 5)

HTTP apps (python-django, java-springboot, laravel-example):
```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080     # (80 for laravel)
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 3
  successThreshold: 1
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 20
  failureThreshold: 3
```

WordPress apps (payments-example, surge-plugin):
```yaml
readinessProbe:
  tcpSocket:
    port: 80
  initialDelaySeconds: 20
  periodSeconds: 10
  failureThreshold: 3
livenessProbe:
  tcpSocket:
    port: 80
  initialDelaySeconds: 40
  periodSeconds: 20
  failureThreshold: 3
```

**Also add to sample services:**
- `sample-services/python-django/` — add a `/health` view
- `sample-services/java-springboot/` — add a `/health` actuator endpoint or custom endpoint
- `sample-services/laravel-docker-example/` — add a `Route::get('/health', ...)` route

---

### PR-015 · Rename `foggypay` → `payments-example` across all files

**Files affected:**
- `helmcharts/app-charts/foggypay/` directory → `payments-example/`
- All values files: `name: foggypay` → `name: payments-example`
- `argocd-bootstrap/templates/applications/foggypay.yaml` → `payments-example.yaml`
- `scripts/jenkinsfiles/ci/foggypay.Jenkinsfile` → `payments_example.Jenkinsfile`
- `scripts/jenkinsfiles/cd/foggypay.Jenkinsfile` → `payments_example.Jenkinsfile`
- `scripts/jenkins-dsl/ci/foggypay.groovy` → `payments_example.groovy`
- `scripts/jenkins-dsl/cd/foggypay.groovy` → `payments_example.groovy`
- All `serviceName = "foggypay"` → `serviceName = "payments-example"`
- Fix copy-paste bug: CI and CD service git repo was pointing to `java-springboot.git` → change to `payments-example.git`

**Add:** `sample-services/payments-example/` with Dockerfile (WordPress), `docker-compose.yml`, `README.md`.

---

### PR-016 · Replace plaintext passwords with secretKeyRef + centralized secret templates

**Files:** `helmcharts/app-charts/*/values-prod.yaml` (java-springboot, python-django, payments-example, surge-plugin)

```yaml
env:
  - name: DB_HOST
    value: "mysql"
  - name: DB_PORT
    value: "3306"
  - name: DB_USER
    value: root
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-db-secret
        key: db-password
  - name: DB_NAME
    value: "YOUR_DB_NAME"
```

**New file:** `helmcharts/system-charts/argocd-config/templates/app-db-secret.yaml`

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# TEMPLATE — COMMENT ONLY. DO NOT APPLY DIRECTLY.
# This file must be sealed before use. Applying this file as-is will create
# a plaintext Secret — never do this in production.
#
# How to seal:
#   kubectl create secret generic app-db-secret \
#     --from-literal=db-password=YOUR_DB_PASSWORD \
#     --namespace=prod --dry-run=client -o yaml \
#   | kubeseal --format=yaml \
#   > helmcharts/system-charts/argocd-config/sealed/app-db-secret.yaml
#
# All apps reference this secret by name via secretKeyRef.
# One shared platform-level secret per namespace.
# ─────────────────────────────────────────────────────────────────────────────
#
# apiVersion: v1
# kind: Secret
# metadata:
#   name: app-db-secret
#   namespace: prod
# type: Opaque
# stringData:
#   db-password: "YOUR_DB_PASSWORD"
```

**Directory rename:** `argocd-config/unseal/` → `argocd-config/templates/`  
"unseal" implies a runtime operation. "templates" correctly signals these are documentation-as-code reference files, not runnable manifests.

**Note:** The template is fully comment-only (`#`-prefixed YAML). It cannot be applied by Argo CD or accidentally `kubectl apply`-ed. It is documentation in the correct platform-level location.

---

### PR-017 · Improve `values-dev.yaml` — real dev vs prod differences

**Files:** `helmcharts/app-charts/*/values-dev.yaml` (all 5)

Expand from `replicas: 1` to full dev-specific overrides: `pullPolicy: Always`, lower resources, more tolerant probes, no TLS, no HPA.

---

## Phase 3 — Complete the Platform

### PR-018 · Fix surge_plugin CD Jenkinsfile `${params.Environment}` typo

**File:** `scripts/jenkinsfiles/cd/surge_plugin.Jenkinsfile`

Replace all `${params.Environment}` → `${params.ENVIRONMENT}`.

*(Note: this was in Phase 1 but depends on the Jenkinsfile structure stabilised in Phase 0 PR-006)*

---

### PR-019 · Add Reloader to GitOps + document annotation

New `argocd-bootstrap/templates/toolchains/reloader.yaml` guarded by `{{ if .Values.reloader.enabled }}`. Sync-wave 3. Document in `OPERATIONS.md`.

---

### PR-020 · Add stage environment (namespace + values + network policies + quotas)

Stage namespace in `namespaces-pss.yaml` (now Helm-templated from PR-002). Stage entries in `limitrange-resourcequota.yaml`, network policies, argocd-project destinations. `values-stage.yaml` for all 5 apps. CD Jenkinsfile environment choice renamed from `test` → `stage`.

---

### PR-021 · Add Kyverno policy: disallow `:latest` tag (correct implementation)

**Sequence dependency:** This PR adds `disallow-latest-tag` to the Kyverno policies Helm chart. The `enforcedNamespaces` list at this point contains `prod` and `dev` only. `stage` is added to the list in PR-020 (after the stage namespace is created). Do not add `stage` to `enforcedNamespaces` before PR-020 — the namespace would not exist and Kyverno would produce admission errors.

New `helmcharts/system-charts/kyverno-policies/disallow-latest-tag.yaml` (now Helm-templated from PR-004):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
  annotations:
    policies.kyverno.io/description: >
      Blocks ':latest' image tags or missing tags in enforced namespaces.
      All production images must use explicit, immutable tags (e.g. prod-abc1234).
      Note: Images with registry ports (e.g. registry:5000/app:tag) are handled correctly
      because the tag colon is always the last colon. The no-tag check ('^[^:]+$') is
      a pragmatic rule — registries with port and no tag are exceedingly rare.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: disallow-latest-tag
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces:
                {{- range .Values.enforcedNamespaces }}
                - {{ . }}
                {{- end }}
      validate:
        message: >
          Image ':latest' or untagged image not allowed. Use an explicit tag.
          See docs/DEPLOYMENT_POLICY.md.
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ regex_match('^.*:latest$', element.image) }}"
                    operator: Equals
                    value: "true"
                  - key: "{{ regex_match('^[^:]+$', element.image) }}"
                    operator: Equals
                    value: "true"
    - name: disallow-latest-tag-init
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces:
                {{- range .Values.enforcedNamespaces }}
                - {{ . }}
                {{- end }}
      validate:
        message: "Init container image ':latest' or untagged not allowed."
        foreach:
          - list: "request.object.spec.initContainers"
            deny:
              conditions:
                any:
                  - key: "{{ regex_match('^.*:latest$', element.image) }}"
                    operator: Equals
                    value: "true"
                  - key: "{{ regex_match('^[^:]+$', element.image) }}"
                    operator: Equals
                    value: "true"
```

---

### PR-022 · Add etcd snapshot configuration to RKE cluster template

**File:** `ansible/roles/k8s_bootstrap/templates/rke_cluster.yml.j2`

```yaml
services:
  etcd:
    snapshot: true
    creation: "6h"
    retention: "24h"
```

---

### PR-023 · Wire kube-prometheus-stack as optional toolchain

New `argocd-bootstrap/templates/toolchains/kube-prometheus-stack.yaml` guarded by `{{ if .Values.observability.prometheus.enabled }}`. New `values-minimal.yaml` for the chart — no persistence, lab-only, with explicit comment. Sync-wave 8.

---

### PR-024 · Fix NFS export security

**File:** `ansible/roles/common/tasks/install_nfs.yml`

```yaml
- name: Configure NFS exports
  lineinfile:
    path: /etc/exports
    line: "/srv/nfs  {{ cluster_cidr }}(rw,sync,no_subtree_check,no_root_squash)"
    create: yes
```

`cluster_cidr` now comes from `config/defaults.yaml` via `vars_files` (set in PR-001).

---

## Phase 4 — Modern DevSecOps Signals

### PR-025 · Add Dependabot

New `.github/dependabot.yml` covering Docker and GitHub Actions ecosystems.

---

### PR-026 · Add SBOM generation to all CI pipelines

**Enforcement split (mirrors Trivy policy):**
- **Jenkins CI (enforcement):** SBOM is generated and archived as a build artifact after the image is pushed. This is part of the production build record.
- **GitHub Actions (advisory):** No SBOM step added to GH Actions. Avoid duplicating tooling. GH Actions remains the advisory/config scan layer; Jenkins is the enforcement layer.

This is documented explicitly in `SECURITY.md` alongside the Trivy enforcement split, so the narrative is consistent across all supply chain controls.

Add `trivy image --format cyclonedx` stage after Trivy scan in all 5 CI Jenkinsfiles. Archive SBOM as build artifact.

---

### PR-027 · Publish helm-common as OCI chart (GitHub Packages)

New `.github/workflows/publish-helm-common.yml`. After merge, update all 5 app `Chart.yaml` to use `oci://ghcr.io/YOUR_ORG/helm-charts`. Update `config/defaults.yaml.example` with `helm_chart_repo_url`.

---

### PR-028 · Add Helm lint to GitHub Actions CI

Add `helm-lint-apps` job to `.github/workflows/validate.yml`.

**From review:** Remove `|| true` from `helm dependency build` after PR-027 (OCI deps in place). Until then, keep `|| true` with a comment: `# TODO: remove || true after PR-027 (OCI helm-common) is merged`.

---

### PR-029 · Add ApplicationSet for scalable GitOps

New `argocd-bootstrap/templates/applications/application-set.yaml` guarded by `{{ if .Values.applicationset.enabled }}`. Coexists with static Applications (disabled by default).

**README must include this explanation** to prevent reviewers thinking it is duplication:

```markdown
## Deployment modes

**Simple mode (default):** One static `Application` manifest per service in
`argocd-bootstrap/templates/applications/`. Easy to read, easy to modify
individually. Suitable for ≤10 services.

**Scale mode (opt-in):** Set `applicationset.enabled: true` in
`argocd-bootstrap/values.yaml` to use a single `ApplicationSet` that generates
all Application resources from a list generator. Eliminates per-service YAML
for large platforms. The static files remain as reference.
```

This one paragraph prevents every reviewer from opening a GitHub issue titled "why do you have two ways to deploy apps?"

---

### PR-030 · Add RKE2 provisioner role (default), keep RKE1 as legacy

New `ansible/roles/k8s_bootstrap_rke2/`. `kubernetes_provisioner` variable in `config/defaults.yaml` selects which role runs. Default is `rke2`.

RKE1 is clearly weighted as secondary in both config and documentation:
```yaml
# config/defaults.yaml.example
kubernetes_provisioner: "rke2"    # rke2: recommended default
                                   # rke1: legacy_compatibility — existing clusters only
```

The comment `legacy_compatibility` makes the intent explicit without relying on a date ("EOL July 2025" becomes stale; "legacy_compatibility" is timeless). RKE2 and RKE1 are not presented with equal weight anywhere — RKE2 is the first, default, documented path.

---

## Phase 5 — Documentation

### PR-031 · Add `scripts/README.md`

One-page reference for all scripts in `scripts/misc/` — purpose, prerequisites, usage.

---

### PR-032 · Expand `OPERATIONS.md` with upgrade + secret rotation

Merge component upgrade procedure and secret rotation instructions into `OPERATIONS.md`. No new files.

---

### PR-033 · Update FEATURES.md and README after all merges

Update feature table to reflect stage environment, Reloader, prometheus opt-in, ApplicationSet, SBOM, disallow-latest-tag, RKE2 default.

---

## PR Execution Order

```
Phase 0 — Foundation (sequential, strict order):
  PR-000 → PR-001 → PR-002 → PR-003 → PR-004 → PR-005 → PR-006 → PR-007

Phase 1 — Broken Code (parallel within phase):
  PR-008  PR-009  PR-010  PR-011

Phase 2 — Credibility (PR-012 first, rest parallel):
  PR-012 → PR-013  PR-014  PR-015  PR-016  PR-017

Phase 3 — Complete Platform (parallel within phase):
  PR-018  PR-019  PR-020  PR-021  PR-022  PR-023  PR-024

Phase 4 — Modern DevSecOps (PR-027 before PR-028):
  PR-025  PR-026  PR-027 → PR-028  PR-029  PR-030

Phase 5 — Documentation (after all others):
  PR-031  PR-032  PR-033
```

---

## Total Change Summary

| Phase | PRs | New Files | Modified Files |
|-------|-----|-----------|----------------|
| 0 — Configuration Foundation | 8 | 3 | 22 |
| 1 — Fix Broken | 4 | 0 | 8 |
| 2 — Fix Credibility | 6 | 3 | 16 |
| 3 — Complete Platform | 7 | 6 | 9 |
| 4 — Modern DevSecOps | 6 | 5 | 8 |
| 5 — Documentation | 3 | 1 | 4 |
| **Total** | **34 PRs** | **18** | **67** |

---

## Approval Checklist

- [ ] Phase 0 approved — configuration architecture (most important)
- [ ] Phase 1 approved — correctness fixes
- [ ] Phase 2 approved — credibility fixes
- [ ] Phase 3 approved — platform completeness
- [ ] Phase 4 approved — modern DevSecOps signals
- [ ] Phase 5 approved — documentation

---

---

## Strategic Note: README Must Communicate Scope Clearly

After all phases are implemented, the project has grown from "secure GitOps bootstrap" into something closer to a "reusable internal platform foundation." That is more powerful — but it increases cognitive load for a reviewer browsing GitHub for the first time.

The README must answer three questions within the first scroll:

**1. What is the core? (Always installed)**
- Ansible provisioning (RKE2 + common packages)
- Argo CD App-of-Apps (GitOps)
- Helm charts (helm-common + app charts)
- Security controls (PSS, NetworkPolicy, Kyverno, Sealed Secrets)
- Jenkins CI/CD with Trivy gate

**2. What is optional? (Off by default, one flag to enable)**
- Reloader (`reloader.enabled: true`)
- kube-prometheus-stack (`observability.prometheus.enabled: true`)
- ApplicationSet (`applicationset.enabled: true`)
- Stage environment (namespace + values files — enable by adding to `namespaces` list)
- GitLab CE, PostgreSQL, MariaDB (Ansible roles, disabled by default)

**3. What is demo-only? (Sample code, not production patterns)**
- `sample-services/` — Dockerfiles and source for reference builds
- `helmcharts/app-charts/` — reference app charts for the 5 sample services

**README restructuring (part of PR-033):**

Replace the current README "Optional components" section with a three-tier table:

```markdown
## What is included

| Tier | Component | Default | How to enable |
|------|-----------|---------|---------------|
| **Core** | Ansible + RKE2 provisioning | Always | — |
| **Core** | Argo CD App-of-Apps (GitOps) | Always | — |
| **Core** | Security controls (PSS, NetworkPolicy, Kyverno, Sealed Secrets) | Always | — |
| **Core** | Jenkins CI/CD + Trivy gate | Always | — |
| **Optional** | Reloader (live config reload) | Off | `reloader.enabled: true` |
| **Optional** | kube-prometheus-stack (metrics) | Off | `observability.prometheus.enabled: true` |
| **Optional** | ApplicationSet (scale mode) | Off | `applicationset.enabled: true` |
| **Optional** | GitLab CE | Off | Ansible role in `playbooks/gitlab_setup.yml` |
| **Optional** | PostgreSQL / MariaDB | Off | Ansible role in `playbooks/install_database.yml` |
| **Demo only** | Sample services (5 apps) | — | Source in `sample-services/` |
```

This table answers the cognitive load problem in 10 seconds. A reviewer immediately knows what they are looking at, what is stable, and what is decorative.

---

*Full hardcode audit: available on request. Analysis of current state: `docs/ANALYSIS.md`.*
