# Project Analysis: Strengths, Weaknesses, and Roadmap

**Analysed:** March 2026  
**Scope:** Full codebase vs documentation cross-reference, architectural review, and improvement roadmap.

---

## Table of Contents

1. [Documentation vs Codebase Cross-Reference](#1-documentation-vs-codebase-cross-reference)
2. [Strengths (Pros)](#2-strengths-pros)
3. [Weaknesses (Cons)](#3-weaknesses-cons)
4. [Bugs and Inconsistencies Found](#4-bugs-and-inconsistencies-found)
5. [What Needs to Be Improved](#5-what-needs-to-be-improved)
6. [Features to Add](#6-features-to-add)
7. [Priority Roadmap](#7-priority-roadmap)

---

## 1. Documentation vs Codebase Cross-Reference

This section maps every major documented claim against what actually exists in code.

### 1.1 Correctly Documented and Implemented

| Feature | Documented In | Code Location | Status |
|---------|--------------|---------------|--------|
| Ansible provisions cluster via RKE | README, FEATURES.md, architecture.md | `ansible/playbooks/`, `ansible/roles/k8s_bootstrap/` | Correct |
| Jenkins CI/CD pipelines with Trivy gate | FEATURES.md, SECURITY.md, CONTRIBUTING.md | `scripts/jenkinsfiles/ci/*.Jenkinsfile` | Correct — Trivy runs with `--exit-code 1 --severity CRITICAL,HIGH` |
| GitHub Actions: Helm template, Trivy advisory, Gitleaks | CONTRIBUTING.md, SECURITY.md | `.github/workflows/validate.yml` | Correct — advisory mode confirmed |
| Sealed Secrets workflow | SECURITY.md, PRODUCTION_SETUP.md | `scripts/misc/seal_k8s_secrets.sh`, `scripts/misc/create_k8s_docker_secret_seal.sh` | Correct |
| App-of-Apps GitOps pattern | README, architecture.md | `argocd-bootstrap/templates/` | Correct |
| Pod Security Standards (PSS) on namespaces | PLATFORM_CAPABILITIES.md, FEATURES.md | `helmcharts/system-charts/00_misc/namespaces-pss.yaml` | Correct — `baseline` enforce, `restricted` audit/warn |
| Default-deny network policies | PLATFORM_CAPABILITIES.md, THREAT_MODEL.md | `helmcharts/system-charts/network-policies/` | Correct — deny-all + DNS allow + nginx ingress allow |
| Kyverno: block privileged containers | THREAT_MODEL.md, PLATFORM_CAPABILITIES.md | `helmcharts/system-charts/kyverno-policies/block-privileged.yaml` | Correct |
| Kyverno: require resource limits | THREAT_MODEL.md | `helmcharts/system-charts/kyverno-policies/require-resource-requests-limits.yaml` | Correct |
| Kyverno: require runAsNonRoot | PLATFORM_CAPABILITIES.md | `helmcharts/system-charts/kyverno-policies/require-run-as-non-root.yaml` | Correct |
| Kyverno: require readinessProbe | OBSERVABILITY_CONTRACT.md | `helmcharts/system-charts/kyverno-policies/require-readiness-probe.yaml` | Correct |
| LimitRange and ResourceQuota per namespace | FEATURES.md, PLATFORM_CAPABILITIES.md | `helmcharts/system-charts/00_misc/limitrange-resourcequota.yaml` | Correct |
| Platform admin RBAC (no cluster-admin) | SECURITY.md, PLATFORM_DESIGN.md | `helmcharts/system-charts/00_misc/platform-admin-rbac.yaml` | Correct |
| Central config via `config/defaults.yaml` | README, FEATURES.md | `config/defaults.yaml.example` | Correct |
| No secrets committed to repo | SECURITY.md | `.gitignore` | Correct — vault pass, kubeconfig, rkestate all ignored |
| Jenkins Job DSL (pipeline-as-code) | FEATURES.md | `scripts/jenkins-dsl/`, `ansible/roles/install_jenkins/` | Correct |
| Jenkins JCasC (Configuration-as-Code) | GETTING_STARTED.md | `ansible/roles/install_jenkins/templates/jenkins.yaml` | Correct |
| RKE1 EOL acknowledged | OPERATIONS.md, VERSIONS.md | `ansible/roles/k8s_bootstrap/defaults/main.yml` | Correct — documented as EOL July 2025 |
| Argo CD SSO (OIDC) documentation | ARGOCD_SSO.md | `helmcharts/system-charts/argo-cd/` | Correct — documented, optional |
| Deployment policy (no `:latest`) | DEPLOYMENT_POLICY.md | CD Jenkinsfiles use `${ENVIRONMENT}-${DEPLOY_ARTIFACT}` tags | Correct |
| Makefile as product surface | PLATFORM_DESIGN.md, README | `Makefile` | Correct |

### 1.2 Documented but Partially or Incorrectly Implemented

| Feature | Documented Claim | Actual Code | Gap |
|---------|-----------------|-------------|-----|
| readinessProbe "required" | OBSERVABILITY_CONTRACT.md: "Every app pod must define a readinessProbe" | All `values-prod.yaml` files have `readinessProbe: {}` (empty) | An empty map is not a configured probe. Apps pass Kyverno's pattern check (`{}` = "exists") but have no actual probe logic (no httpGet, no exec, no initialDelaySeconds). Probes are functionally absent. |
| livenessProbe "recommended" | OBSERVABILITY_CONTRACT.md: "Every app pod should define a livenessProbe" | All `values-prod.yaml` files have `livenessProbe: {}` (empty) | Same as above — empty, not configured. |
| Container-level `runAsNonRoot` | Kyverno policy `require-run-as-non-root` checks both pod AND container level | `helm-common/values.yaml` sets pod-level `runAsNonRoot: true` but does NOT set container-level `runAsNonRoot: true` | Kyverno policy enforces container-level `runAsNonRoot: true` in its pattern — apps that rely only on pod-level setting may fail admission. |
| Argo CD AppProject restricts cluster-scope resources | FEATURES.md, SECURITY.md: "Argo CD does not manage cluster-wide resources except platform CRDs" | `argocd-project/prod.yml` has `clusterResourceWhitelist: - group: "*" kind: "*"` | Contradicts documented intent — all cluster-scoped resources are permitted. Should be scoped to only needed CRD groups. |
| Argo CD AppProject restricts namespace resources | PLATFORM_CAPABILITIES.md: "RBAC — Argo CD limited to destination namespaces via AppProject" | `namespaceResourceWhitelist: - group: "*" kind: "*"` | Fully open — no resource-type restriction. Permissive for a "production" project. |
| Java installation cross-distro support | `install_dependencies.yml` supports both Debian and RHEL | `install_java.yml` uses only `yum` module | Java installation fails on Debian/Ubuntu hosts. Other distro-aware tasks use `package` or `apt`/`yum` conditionals — Java does not. |
| Observability stack (kube-prometheus-stack, Loki) | Mentioned in README and PLATFORM_DESIGN.md as "optional" | Charts exist in `helmcharts/system-charts/` but have NO corresponding Argo CD Application in `argocd-bootstrap/templates/toolchains/` | Elasticsearch, Loki, promtail, rancher, reloader charts are present but not wired into GitOps. A user cannot enable them through the documented App-of-Apps pattern without adding toolchain entries manually. |
| `foggypay` sample service | Listed in FEATURES.md and has a helm chart and Argo CD Application | No `sample-services/foggypay/` directory exists | `sample-services/` has `java-springboot`, `laravel-docker-example`, `python-django`, `surge-wp-plugin` — no foggypay source. |

### 1.3 Not Documented but Present in Code

| Item | Location | Notes |
|------|----------|-------|
| `scripts/misc/firewall_config.sh` | `scripts/misc/` | UFW rules for K8s ports — not mentioned anywhere in docs. Useful for hardening but undocumented. |
| `scripts/misc/nginx_troubleshoot.sh` | `scripts/misc/` | SELinux fix for nginx upstreams — no doc mention. |
| `scripts/misc/rke_cleanup.sh` | `scripts/misc/` | Full RKE node cleanup — not mentioned in README, OPERATIONS.md, or GETTING_STARTED.md. |
| `scripts/misc/publish_helm_common.sh` | `scripts/misc/` | Publishes helm-common to GitLab chart registry — not documented. |
| `scripts/misc/vault_encrypt.sh` | `scripts/misc/` | Wrapper around `ansible-vault encrypt_string` — not documented. |
| Elasticsearch chart | `helmcharts/system-charts/elasticsearch/` | Present but no Application, no docs. |
| kube-prometheus-stack chart | `helmcharts/system-charts/kube-prometheus-stack/` | Present but no Application, no docs on how to enable. |
| Loki + promtail charts | `helmcharts/system-charts/loki/`, `promtail/` | Present but no Applications, no docs. |
| Rancher chart | `helmcharts/system-charts/rancher/` | Present but no Application, no docs. |
| Reloader chart | `helmcharts/system-charts/reloader/` | Present but no Application, no docs. Referenced in app values via `configmap.reloader.stakater.com/reload` annotation but Reloader itself is not deployed via GitOps. |

### 1.4 Documented but Not Yet Implemented

| Feature | Documented In | Status |
|---------|--------------|--------|
| Staging environment | PLATFORM_DESIGN.md mentions dev/stage/prod isolation | Only `dev` and `prod` namespaces/values exist — no `stage` |
| Image signing (cosign) | PLATFORM_DESIGN.md "mention image signing (cosign), SBOM awareness" | No implementation — CI pipelines do not sign images |
| Dependabot / Renovate | PLATFORM_DESIGN.md mentions as supply chain control | No `.github/dependabot.yml` or `renovate.json` |
| Sync windows / approval policies | PLATFORM_DESIGN.md "optional: sync windows, approval policies" | Not configured in any Argo CD Application |
| External Secrets Operator / Vault | SECURITY.md "Optional extensions: External Secrets Operator, HashiCorp Vault" | Not implemented |
| Velero backup | OPERATIONS.md recommends Velero | No chart, no Application, no automation |
| etcd snapshot schedule | OPERATIONS.md recommends snapshot schedule | Not configured in RKE cluster template |

---

## 2. Strengths (Pros)

### 2.1 Architectural Design

**Strong GitOps discipline.** The App-of-Apps pattern is correctly implemented: a root Argo CD Application points at `argocd-bootstrap/`, which generates all system and application Applications. Changes flow through Git PR → Argo CD sync — no ad-hoc `kubectl apply` is needed.

**Single configuration surface.** `config/defaults.yaml.example` centralises all environment-specific values (IPs, URLs, registry, Argo CD) in one file. This dramatically reduces the "where do I change X?" problem for new users.

**Layered Helm chart design.** The `helm-common` library chart pattern is excellent — all five app charts depend on it, ensuring consistent deployment structure, securityContext, probes, and service configurations. App charts are thin wrappers that just override values, which is the right approach.

**Sync ordering with `argocd.argoproj.io/sync-wave`.** Toolchain Applications use sync waves (sealed-secrets at wave 2, cert-manager at 3, network-policies at 5, kyverno at 6) ensuring correct deployment ordering without manual sequencing.

### 2.2 Security Controls

**Defence-in-depth model.** Multiple security layers are implemented and documented:
- PSS baseline enforcement at namespace level (prevents most container escapes without Kyverno)
- Kyverno admission policies (block privileged, require non-root, require limits, require readiness probe)
- Default-deny NetworkPolicies with targeted allow-lists (DNS egress, ingress-nginx ingress)
- Sealed Secrets for all registry/helm credentials
- Bounded platform-admin RBAC ClusterRole (no cluster-admin)
- Trivy as a hard CI gate (CRITICAL/HIGH blocks image push)

**Correct Trivy enforcement split.** Jenkins blocks on image scan; GitHub Actions runs config scan in advisory mode. The documented rationale ("Jenkins is the deployment gate; GitHub Actions provides visibility") is architecturally sound.

**Vault-encrypted Ansible variables.** All sensitive playbook variables use `!vault` encrypted strings. No plaintext credentials in committed playbooks.

**`.gitignore` completeness.** Vault password, kubeconfig, RKE state, and real `config/defaults.yaml` are all properly excluded.

### 2.3 Operational Maturity

**Makefile as the product surface.** `make install-common`, `make bootstrap-k8s`, `make install-argocd`, `make seal-secrets` gives a clear, discoverable operational interface. The typical-order comment is especially useful.

**Jenkins Configuration-as-Code (JCasC).** Jenkins is fully configured via YAML template — security realm, authorization, credentials, executor count. No clicking through the UI.

**Job DSL for pipeline-as-code.** All CI/CD jobs are defined in Groovy DSL files that Jenkins seeds automatically via a bootstrap job. Adding a new service requires adding a DSL file, not configuring Jenkins manually.

**Cross-distro Ansible support.** Most tasks handle Debian/Ubuntu and RHEL/CentOS/Fedora correctly (conditional package managers, distro-specific repos). The `ansible.cfg` disables host-key checking and enables pipelining for speed.

**Version-pinned components.** All tool versions are defined in Ansible defaults (`rke_version`, `kubectl_version`, `yq_version`) or Helm Chart.yaml, not hardcoded in scripts. `docs/VERSIONS.md` provides a single reference table.

**Placeholder-only committed files.** `config/defaults.yaml.example`, `hosts.ini.example`, `.env.example`, `unseal/dockerhub_secret.yaml` all use `YOUR_*` placeholders and include instructions. No real IPs or credentials in the repo.

### 2.4 Documentation Quality

**Architecture diagram in Mermaid.** The flowchart in README and `architecture.md` renders directly in GitHub and clearly shows the Ansible → K8s → Argo CD → CI/CD relationships.

**PLATFORM_DESIGN.md.** This document is unusually transparent about architectural intent, trade-offs, and what "seniority signals" look like. It explicitly says "maximum maturity per feature, not maximum features" — a strong guiding principle.

**THREAT_MODEL.md with reproducible examples.** Risk/mitigation table plus working `kubectl apply` examples for Kyverno policy rejection. Rare and valuable in open-source bootstrap repos.

**Layered documentation structure.** README for quick start → GETTING_STARTED.md for detailed steps → PRODUCTION_SETUP.md checklist → specialist docs (SECURITY, OPERATIONS, DEPLOYMENT_POLICY). Good progressive disclosure.

---

## 3. Weaknesses (Cons)

### 3.1 Security Weaknesses

**Hardcoded insecure Jenkins defaults.** `jenkins.yaml` CasC template has `users: admin/admin` and `testuser/123456` hardcoded in the `localUsers` list. Even as "example" defaults, these represent an immediately exploitable Jenkins instance if the user forgets to change them. The Jenkins setup playbook also has `jenkins_admin_password: admin` not vault-encrypted.

**DB passwords as plaintext env vars in Helm values.** `values-prod.yaml` for `foggypay`, `surge-plugin`, `java-springboot`, and `python-django` all contain:
```yaml
env:
  - name: WORDPRESS_DB_PASSWORD
    value: "CHANGE_ME"
```
These are committed to the Git repo. While the comment says "change me," the documented best practice (SealedSecret → secretKeyRef) is not shown by example in any app chart.

**AppProject clusterResourceWhitelist is fully open.** `argocd-project/prod.yml` permits `group: "*" kind: "*"` for cluster-scoped resources — exactly what the documentation says it should not allow. This means Argo CD could deploy ClusterRoles, ClusterRoleBindings, CRDs, or any cluster-wide resource via the prod project.

**ArgoCD `--insecure` flag in bootstrap script.** `scripts/misc/argocd_prerequisite.sh` uses `argocd login ... --insecure` and `argocd repo add ... --insecure-skip-server-verification`. This is acceptable for initial bootstrap but not documented as temporary.

**NFS exports use open permissions.** `install_nfs.yml` creates an export with `*(rw,sync,no_subtree_check)` — world-readable NFS share from any host. In a multi-tenant environment this is too permissive.

### 3.2 Code Quality Issues

**Empty probes in all production app charts.** Every `values-prod.yaml` has:
```yaml
livenessProbe: {}
readinessProbe: {}
```
In Helm, this renders as an empty YAML block passed to `toYaml`, which produces no probe configuration. The `OBSERVABILITY_CONTRACT.md` says "readinessProbe is the enforced control" and Kyverno requires it — but no app actually has a working probe defined.

**Java installation is Debian/Ubuntu blind.** `ansible/roles/common/tasks/install_java.yml` uses only the `yum` module. Ubuntu/Debian hosts (which are more common for Kubernetes) will fail silently or error here. All other tasks use distro-conditional logic.

**`database.yml` group_vars misconfigured.** Database nodes have `enable_install_rke: true`, `enable_install_nfs: true`, and `enable_install_kubectl: true`. A database server does not need RKE, NFS server, or kubectl. This is almost certainly a copy-paste from masters.yml.

**`foogypay.yaml` typo in argocd-bootstrap.** The file `argocd-bootstrap/templates/applications/foogypay.yaml` has a double-o typo in the filename (though the `metadata.name` is correctly `foggypay`). Minor but visible in the file tree.

**`argocd_install.sh` duplicates the Makefile target.** `scripts/misc/argocd_install.sh` runs the same `helm upgrade --install argocd` command as `make install-argocd`. It adds no functionality and creates maintenance confusion.

**Surge plugin CD Jenkinsfile typo.** `scripts/jenkinsfiles/cd/surge_plugin.Jenkinsfile` references `${params.Environment}` (lowercase 'e') instead of the defined `${params.ENVIRONMENT}` parameter, causing a null/empty value at runtime.

**`argocd_prerequisite.sh` uses `--insecure` flag on all operations.** While understandable for a local bootstrap, this means TLS is never verified during the bootstrap that configures the entire platform.

**Reloader annotation present but Reloader not deployed.** App charts have `configmap.reloader.stakater.com/reload: ""` annotation but the Reloader Helm chart in `helmcharts/system-charts/reloader/` has no Argo CD Application. Annotations have no effect without the controller.

### 3.3 Architecture Gaps

**Only two environments (dev, prod).** The docs reference a stage/test promotion model but only dev and prod exist. CD Jenkinsfiles offer a `choice: [dev, test, prod]` parameter, but `test` has no corresponding namespace or values file.

**Observability charts disconnected from GitOps.** Elasticsearch, kube-prometheus-stack, Loki, promtail, Rancher, and Reloader charts exist in `helmcharts/system-charts/` but none have Argo CD Application definitions in `argocd-bootstrap/templates/toolchains/`. They cannot be enabled via the documented GitOps flow without manually adding toolchain files.

**No `foggypay` sample service source.** `argocd-bootstrap/templates/applications/foogypay.yaml` and `helmcharts/app-charts/foggypay/` exist, but there is no `sample-services/foggypay/` directory with a Dockerfile or source code. The CI pipeline would have nothing to build.

**No `values-test.yaml` for any app.** CD pipelines support a `test` environment parameter, but no `values-test.yaml` exists in any app chart. Deploying to `test` would fall back to chart defaults (no image, no probes, no resources).

**NFS as the only storage class.** The PVC template hardcodes `storageClassName: nfs-storage`. There is no option for local-path, hostPath, or cloud storage classes. Multi-cloud adoption would require template changes.

**No multi-master HA documented or tested.** The Ansible RKE template supports multiple master nodes via `master_nodes` list, but the docs only show single-node examples. No mention of etcd quorum requirements or minimum node counts.

### 3.4 Documentation Gaps

**Undocumented scripts.** Five utility scripts (`firewall_config.sh`, `nginx_troubleshoot.sh`, `rke_cleanup.sh`, `publish_helm_common.sh`, `vault_encrypt.sh`) are not mentioned in any documentation file. Users who need cluster cleanup or Helm chart publishing have no guidance.

**Reloader not documented.** The reloader system chart and the annotation convention in app values are never explained. Users don't know how to enable live config reloading.

**No upgrade guide.** There is no documentation on how to upgrade Kubernetes (RKE), Argo CD, cert-manager, or other system components. OPERATIONS.md covers RKE EOL but not the upgrade procedure.

**helm-common not published.** The README references `helm_chart_repo_url: "https://raw.githubusercontent.com/YOUR_ORG/helm-common/main"` but `helm-common` is not a published chart on any registry. App charts have mixed dependency sources: some use `file://../../helm-common` (local) and some use the GitHub raw URL (not a valid Helm repository). This inconsistency would break `helm dependency update` for apps using the GitHub URL.

---

## 4. Bugs and Inconsistencies Found

| # | Severity | Location | Description |
|---|----------|----------|-------------|
| 1 | **High** | `ansible/roles/common/tasks/install_java.yml` | Uses `yum` only — fails on Debian/Ubuntu (most K8s environments). Fix: use `package` module or add `apt` conditional. |
| 2 | **High** | `helmcharts/app-charts/*/values-prod.yaml` | All 5 apps have `readinessProbe: {}` and `livenessProbe: {}` — empty maps. No actual probe paths/ports are set. Apps would fail health checks or Kyverno enforcement in practice. |
| 3 | **High** | `ansible/roles/install_jenkins/templates/jenkins.yaml` | Hardcoded `admin`/`admin` and `testuser`/`123456` local users. Should be template variables with vault-encrypted defaults or removed entirely. |
| 4 | **High** | `helmcharts/system-charts/argocd-project/prod.yml` | `clusterResourceWhitelist: group: "*" kind: "*"` allows all cluster-scoped resources. Contradicts documented security model. Should be scoped to specific groups (e.g., argoproj.io, networking.k8s.io, cert-manager.io). |
| 5 | **Medium** | `scripts/jenkinsfiles/cd/surge_plugin.Jenkinsfile` | Uses `${params.Environment}` (wrong case) — parameter is defined as `ENVIRONMENT`. Runtime value is always null for surge-plugin CD. |
| 6 | **Medium** | `ansible/inventories/dev/group_vars/database.yml` | `enable_install_rke: true`, `enable_install_nfs: true` on database nodes. Installs unnecessary and potentially conflicting software (RKE/Kubernetes on a DB server). |
| 7 | **Medium** | `helmcharts/app-charts/*/Chart.yaml` (foggypay, python-django, surge-plugin) | `repository: https://raw.githubusercontent.com/YOUR_ORG/helm-common/main` — this is a placeholder URL and not a valid Helm chart repository. `helm dependency update` will fail. `java-springboot` and `laravel-example` correctly use `file://../../helm-common`. |
| 8 | **Medium** | `helmcharts/system-charts/kyverno-policies/require-run-as-non-root.yaml` | Enforces container-level `securityContext.runAsNonRoot: true`, but `helm-common/values.yaml` only sets pod-level runAsNonRoot. Container-level field is absent. Apps will fail Kyverno admission unless override values are added. |
| 9 | **Medium** | `argocd-bootstrap/templates/applications/foogypay.yaml` | File named `foogypay.yaml` (double-o typo) — should be `foggypay.yaml`. Minor but creates confusion when listing files. |
| 10 | **Medium** | `helmcharts/system-charts/reloader/` | Reloader chart exists and app values reference its reload annotation, but no Argo CD Application exists — annotations have no effect. |
| 11 | **Low** | `ansible/playbooks/jenkins_setup.yml` | `jenkins_admin_password: admin` is not vault-encrypted despite being in the same playbook where other secrets are vaulted. |
| 12 | **Low** | `scripts/misc/install_argocd.yml` (Ansible task) | Downloads ArgoCD CLI from `releases/latest` with no version pinning. Inconsistent with the project's version-pin discipline elsewhere. |
| 13 | **Low** | `ansible/inventories/dev/group_vars/masters.yml` | Enables `enable_install_nfs: true` — master nodes act as both NFS server and Kubernetes masters. Acceptable for single-node but should be noted in docs as a single-node shortcut, not a production pattern. |
| 14 | **Low** | `scripts/misc/argocd_prerequisite.sh` | `argocd login --insecure` and `argocd repo add --insecure-skip-server-verification` — documented as bootstrap-only but not noted as temporary. |
| 15 | **Low** | `helmcharts/system-charts/argocd-project/prod.yml` | `sourceRepos: - "*"` allows any Git repository as a source. Should be restricted to the known GitOps repo URL for hardened environments. |

---

## 5. What Needs to Be Improved

### 5.1 Critical Fixes (Blocking Correctness)

**Fix readiness and liveness probes in all app charts.**  
Replace `readinessProbe: {}` and `livenessProbe: {}` with actual probe definitions. At minimum:
```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 20
  periodSeconds: 10
```

**Fix Java installation for Debian/Ubuntu.**  
`install_java.yml` must support both package managers:
```yaml
- name: Install Java (Debian/Ubuntu)
  apt:
    name: "openjdk-{{ java_version }}-jdk"
    state: present
  when: ansible_distribution in ['Debian', 'Ubuntu']

- name: Install Java (RHEL/CentOS)
  yum:
    name: "java-{{ java_version }}-openjdk"
    state: present
  when: ansible_distribution in ['RedHat', 'CentOS', 'Fedora']
```

**Fix AppProject to restrict cluster-scoped resources.**  
Scope `clusterResourceWhitelist` to only the resource types the platform actually needs:
```yaml
clusterResourceWhitelist:
  - group: "argoproj.io"
    kind: "*"
  - group: "cert-manager.io"
    kind: "*"
  - group: "networking.k8s.io"
    kind: "NetworkPolicy"
  - group: ""
    kind: "Namespace"
```

**Fix helm-common dependency URLs.**  
All app charts should use `file://../../helm-common` for the dependency repository (consistent with `java-springboot` and `laravel-example`), or helm-common should be published to a real Helm repository and all Chart.yaml files updated with the real URL.

**Add container-level runAsNonRoot to helm-common.**  
Add `runAsNonRoot: true` to the container-level securityContext in `helm-common/templates/deployment.yaml` to satisfy the Kyverno policy and PSS restricted mode:
```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true    # ← add this
  capabilities:
    drop: [ALL]
```

### 5.2 Security Hardening

**Remove hardcoded Jenkins credentials.**  
Replace `admin`/`admin` and `testuser`/`123456` in `jenkins.yaml` with vault-encrypted template variables or remove the default users entirely, requiring operators to set them explicitly.

**Move DB passwords to Kubernetes Secrets.**  
Replace plaintext env var values in `values-prod.yaml` with `secretKeyRef` references. Provide a SealedSecret example for at least one app as a template:
```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-db-secret
        key: password
```

**Fix NFS exports security.**  
Change `*(rw,sync,no_subtree_check)` to a network-scoped export:
```
/srv/nfs  YOUR_CLUSTER_CIDR(rw,sync,no_subtree_check,no_root_squash)
```

**Restrict AppProject sourceRepos.**  
Change `sourceRepos: - "*"` to list only the actual GitOps repository URL from `config/defaults.yaml`.

### 5.3 Operational Improvements

**Add `values-test.yaml` for all app charts.**  
Create a test/staging environment values file with minimal replicas but proper probes and resource requests, enabling the CD pipeline's `test` environment option.

**Wire observability charts into GitOps.**  
Add Argo CD Application templates for at minimum kube-prometheus-stack and Reloader. Mark them clearly as optional with a comment/flag to enable, e.g.:
```yaml
# To enable: set observability.enabled=true in argocd-bootstrap/values.yaml
```

**Add Reloader Application and document the annotation.**  
The `configmap.reloader.stakater.com/reload` annotation in all app values is non-functional without the controller. Either deploy it via GitOps or remove the annotation from all values files.

**Publish or pin helm-common properly.**  
Either: (a) publish `helm-common` as a proper Helm OCI artifact or classic HTTP chart, and update all Chart.yaml dependencies with the real URL; or (b) standardise all app charts to use `file://../../helm-common` for local development consistency.

**Fix database.yml group_vars.**  
Database nodes should have minimal tooling — remove `enable_install_rke`, `enable_install_nfs`, `enable_install_kubectl` unless explicitly needed.

**Document all utility scripts.**  
Add a `scripts/README.md` or extend `docs/OPERATIONS.md` to cover `firewall_config.sh`, `rke_cleanup.sh`, `publish_helm_common.sh`, `vault_encrypt.sh`, `nginx_troubleshoot.sh`.

---

## 6. Features to Add

### 6.1 High Value / Low Effort

**Dependabot or Renovate configuration.**  
Add `.github/dependabot.yml` to automatically open PRs for Ansible Galaxy roles, Helm chart updates, and Dockerfile base image upgrades. This directly addresses the supply chain security goal documented in `PLATFORM_DESIGN.md`.

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/sample-services"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

**`etcd` snapshot configuration in RKE cluster template.**  
`OPERATIONS.md` recommends etcd snapshots but the `rke_cluster.yml.j2` template does not configure them. Add the `services.etcd.snapshot` block:
```yaml
services:
  etcd:
    snapshot: true
    creation: "6h"
    retention: "24h"
```

**`values-test.yaml` for all app charts.**  
Enable the CD pipeline's `test` environment by creating minimal staging values files for all five apps.

**`foggypay` sample service source.**  
Add a `sample-services/foggypay/` directory (or rename the WordPress-based surge-plugin sample, since both share identical WordPress DB env vars).

**`scripts/README.md` documenting all utility scripts.**  
One-page reference for all scripts in `scripts/misc/`, with purpose, prerequisites, and usage examples.

### 6.2 Medium Value / Medium Effort

**Staging namespace and promotion model.**  
Add a `stage` namespace to `namespaces-pss.yaml`, `limitrange-resourcequota.yaml`, network policies, and `argocd-project/prod.yml` destinations. Add `values-stage.yaml` for all apps. Document the `dev → stage → prod` promotion flow.

**Reloader integration.**  
Add an Argo CD Application for the Reloader chart. Document the `configmap.reloader.stakater.com/reload` annotation with an example of how to use it for zero-downtime config updates.

**Minimal observability stack (opt-in).**  
Add an Argo CD Application for kube-prometheus-stack with a minimal values file (lightweight, single-replica). Document enabling it as an opt-in step in `GETTING_STARTED.md`. This fulfils the "optional metrics endpoint" promise in `OBSERVABILITY_CONTRACT.md`.

**Image tag enforcement via Kyverno.**  
Add a Kyverno policy to block `:latest` tags in production, implementing the `DEPLOYMENT_POLICY.md` at the admission-control level:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [prod]
      validate:
        message: "Image tag ':latest' is not allowed in production."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

**SBOM generation in CI.**  
Add a `syft` or `trivy sbom` step to CI Jenkinsfiles after image push. Store the SBOM as a build artifact or push to the registry as an OCI attestation. This addresses the "SBOM awareness" mentioned in `PLATFORM_DESIGN.md`.

**ApplicationSet for multi-environment or multi-service deployment.**  
Replace (or supplement) the static Application YAML files in `argocd-bootstrap/templates/applications/` with an ApplicationSet using a List or Git generator. This scales better than maintaining one YAML per service.

**Secret rotation documentation.**  
Add a `docs/SECRET_ROTATION.md` covering how to rotate: Docker registry credentials (reseal), ArgoCD admin password, Ansible vault key, and Jenkins credentials.

### 6.3 Lower Priority / Higher Effort

**RKE2 / K3s migration path.**  
`OPERATIONS.md` notes RKE1 is EOL. Add Ansible roles for RKE2 or K3s provisioning (can be alongside RKE1, selected by variable). Provide a migration guide in docs.

**Multi-cluster support.**  
The current App-of-Apps targets `https://kubernetes.default.svc` (in-cluster). Add support for external cluster registration in `argocd-bootstrap/values.yaml` and document how to add a second cluster to Argo CD.

**Velero backup automation.**  
Add an Argo CD Application for Velero with a `Schedule` resource for daily etcd and PV backups. Document the restore process in `OPERATIONS.md`.

**OPA Gatekeeper as Kyverno alternative.**  
PLATFORM_DESIGN.md mentions "Kyverno or OPA Gatekeeper." Add an optional branch for Gatekeeper to give teams a choice, or document why Kyverno was chosen over Gatekeeper.

**OIDC/SSO for Jenkins (not just ArgoCD).**  
`ARGOCD_SSO.md` documents SSO for Argo CD but Jenkins also needs it. The Jenkins CasC template supports LDAP and SSO plugins. Add documentation and a values template for Jenkins OIDC integration.

**Helm chart versioning and release workflow.**  
Add a GitHub Actions workflow that bumps `version` in `helm-common/Chart.yaml` and all app `Chart.yaml` files on merge to main, and publishes helm-common to a real chart repository (OCI registry or GitHub Pages Helm repo).

---

## 7. Priority Roadmap

### Sprint 1 — Fix What's Broken (Week 1–2)

| Task | Effort | Impact |
|------|--------|--------|
| Fix `install_java.yml` for Debian/Ubuntu | XS | High — breaks provisioning on Ubuntu |
| Fix empty readiness/liveness probes in all app values-prod.yaml | S | High — apps have no health check |
| Fix `database.yml` group_vars (remove rke/nfs/kubectl) | XS | Medium |
| Fix `foogypay.yaml` filename typo | XS | Low |
| Fix surge_plugin CD Jenkinsfile `${params.Environment}` typo | XS | Medium — CD pipeline broken |
| Add `runAsNonRoot: true` to container securityContext in helm-common | XS | High — Kyverno policy would fail |
| Vault-encrypt `jenkins_admin_password` in playbook | XS | Medium |

### Sprint 2 — Security Hardening (Week 2–3)

| Task | Effort | Impact |
|------|--------|--------|
| Restrict AppProject clusterResourceWhitelist | S | High — closes documented security gap |
| Replace hardcoded Jenkins users with vault variables | S | High |
| Add secretKeyRef example for DB passwords in at least one app chart | M | High |
| Restrict AppProject sourceRepos from `*` to actual repo | XS | Medium |
| Fix NFS export to use CIDR scope | XS | Medium |
| Fix helm-common dependency URLs in foggypay/python-django/surge-plugin Chart.yaml | XS | High — helm dependency update fails |

### Sprint 3 — Complete the GitOps Picture (Week 3–5)

| Task | Effort | Impact |
|------|--------|--------|
| Add Reloader Argo CD Application + document annotation | S | Medium |
| Add values-test.yaml for all app charts | S | Medium |
| Wire kube-prometheus-stack as optional toolchain Application | M | High |
| Add foggypay sample service source | M | Medium |
| Add etcd snapshot config to RKE cluster template | XS | High — production safety |
| Add `.github/dependabot.yml` | XS | Medium |
| Document all utility scripts in scripts/README.md | S | Medium |

### Sprint 4 — New Features (Week 5–8)

| Task | Effort | Impact |
|------|--------|--------|
| Add stage namespace + values-stage.yaml for all apps | M | High |
| Add Kyverno policy: disallow `:latest` in prod | S | Medium |
| Add SBOM generation step in CI Jenkinsfiles | S | Medium |
| Add ApplicationSet for multi-service/environment GitOps | L | High |
| Add Velero Application + backup schedule | M | High |

### Sprint 5 — Long-term (Quarter 2+)

| Task | Effort | Impact |
|------|--------|--------|
| RKE2/K3s Ansible roles | XL | High — EOL mitigation |
| OIDC/SSO for Jenkins | L | Medium |
| Publish helm-common to OCI registry | M | High |
| Multi-cluster Argo CD support | XL | High |
| Image signing with cosign | L | Medium |

---

*This analysis was generated by full review of all 100+ files in the repository — playbooks, roles, Helm templates, values files, scripts, Jenkinsfiles, CI workflows, and all documentation. Findings reflect the state of the codebase as of March 2026.*
