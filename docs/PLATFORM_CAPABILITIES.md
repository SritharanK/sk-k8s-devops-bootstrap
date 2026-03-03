# Platform capabilities

One-page executive summary: what this platform provides and what risks it mitigates.

---

## Controls implemented (or planned)

- **GitOps** — Git is source of truth; Argo CD syncs applications; no ad-hoc `kubectl apply`.
- **Central configuration** — One place (`config/defaults.yaml`) for IPs, URLs, registry; no hardcoded values in code.
- **Argo CD access** — Production: Ingress + TLS only; NodePort for lab only. Optional OIDC/SSO (documented).
- **Pod Security Standards** — Namespace labels (baseline/restricted); helm-common defaults (non-root, no privilege escalation, drop caps, read-only root filesystem with opt-out).
- **Network policies** — Default-deny ingress/egress; inter-namespace traffic denied by default; allow-lists for DNS and ingress-nginx.
- **RBAC** — No cluster-admin by default; platform admin role; Argo CD limited to destination namespaces via AppProject; Argo CD does not manage cluster-wide resources except platform CRDs.
- **Secrets** — Sealed Secrets; no unsealed secrets or vault password committed; optional Vault/ESO documented.
- **Supply chain** — Trivy image scan as CI gate (CRITICAL/HIGH); optional SBOM; immutable tags in production (no `:latest`).
- **Admission policy** — Optional Kyverno: block privileged containers; require resource requests/limits; require runAsNonRoot (and optionally readiness probe).
- **Resource bounds** — Optional LimitRange and ResourceQuota per namespace.
- **Health contract** — readinessProbe required, livenessProbe recommended (helm-common); optional Kyverno enforcement.
- **Audit awareness** — Kubernetes audit logging at API server documented as production recommendation (out of scope of repo).

---

## Enforcement matrix

| Control | Enforced by | Where | Mode |
|---------|-------------|--------|------|
| Container vulnerability scan | Jenkins | CI (image build) | Blocking |
| IaC / config scan | GitHub Actions | PR | Advisory |
| PSS (Pod Security Standards) | Namespace labels | Cluster (prod, dev) | Blocking |
| Pod hardening (privileged, non-root, limits, readiness) | Kyverno | Cluster (admission) | Blocking |
| Egress / ingress control | NetworkPolicy | Namespace | Blocking |

This documents the governance model: PRs show advisory findings; deployment is gated by Jenkins and cluster admission.

---

## Threat model (overview)

| Threat | Mitigation |
|--------|------------|
| Credential leak in repo | No unsealed secrets committed; vault pass and kubeconfig gitignored; redact any secrets before making the repo public. |
| Unauthorized access to Argo CD | Ingress + TLS; optional OIDC/SSO; NodePort not used in production. |
| Privileged or hostile workloads | PSS; Kyverno block privileged; runAsNonRoot; network policies limit blast radius. |
| Runaway resource consumption | LimitRange + ResourceQuota per namespace. |
| Vulnerable or untrusted images | Trivy gate in CI; no deploy on CRITICAL/HIGH; immutable tags. |
| Lateral movement / inter-namespace abuse | Default-deny network policies; each namespace allows only what it needs. |
| Over-broad cluster access | RBAC; Argo CD scoped to namespaces; no cluster-admin for routine use. |

---

## Risks mitigated

- **Configuration drift** — GitOps and single config reduce drift; changes via PR.
- **Secret sprawl** — Sealed Secrets + doc; no plaintext in repo.
- **Weak defaults** — helm-common and PSS enforce secure defaults; apps opt out explicitly if needed.
- **Untraced deployments** — Immutable tags and CD-via-PR give traceability (tag → commit).
- **Production lab mix-up** — Clear split: values-production.yaml (Ingress+TLS) vs values-lab.yaml (NodePort).

---

## What this repo is not

- Not a managed service: you operate the cluster and tools.
- Not full DR/backup implementation: RKE/etcd and Velero are documented as options.
- **Not API-server-level audit implementation:** Kubernetes audit logging should be enabled at the API server level for production (outside scope of this repo). Documented here for awareness.

---

For design intent and implementation details, see [PLATFORM_DESIGN.md](PLATFORM_DESIGN.md). For a dedicated risk → mitigation table and **policy rejection example** (e.g. Kyverno blocking a privileged pod), see [THREAT_MODEL.md](THREAT_MODEL.md). For health and metrics contract, see [OBSERVABILITY_CONTRACT.md](OBSERVABILITY_CONTRACT.md).
