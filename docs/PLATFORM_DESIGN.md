# Platform Design: Architect-Level Intent

This document defines how this repository is intended to be read: not as a "DevOps repo" full of features, but as **proof of 17+ years Lead Platform Engineer / Software Architect**—intentional architecture, security-first thinking, enterprise patterns, clear trade-offs, and operational maturity.

**Principle:** Maximum maturity per feature, not maximum features. If someone says "this is weak", it should only be because they don't understand platform engineering.

---

## What seniority is *not* proved by

- Adding many more tools
- Adding monitoring stack + ELK + Prometheus + many extras
- Making the repo huge

## What seniority *is* proved by

- Strong architectural decisions
- Security maturity
- Scalability patterns
- Clean configuration boundaries
- Blast-radius control

---

# 1. Security (architect-level)

## 1.1 Argo CD: Ingress + TLS + access control

- **Current:** Argo CD exposed via NodePort.
- **Intent:** NodePort is for local lab only. Production uses **Ingress + TLS (cert-manager) + access control**.
- **Options to document (or implement):**
  - Ingress with TLS termination (cert-manager).
  - IP whitelist annotation **or** OAuth/OIDC (e.g. GitHub, Azure AD).
- **Signal:** "We know the difference between lab and production exposure."

## 1.2 Pod Security Standards (PSS)

- **Intent:** PodSecurity admission labels; enforce **baseline** or **restricted** policy.
- **Examples:** `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`.
- **Where:** Enforce defaults in **helm-common** and system workloads so every app inherits safe defaults.
- **Signal:** "We default to least privilege."

## 1.3 Network policies

- **Intent:** Default-deny posture.
  - Deny all ingress.
  - Deny all egress.
  - Allow only necessary namespace-to-namespace (and egress to external dependencies) via explicit policies.
- **Signal:** "We control blast radius and lateral movement."

## 1.4 RBAC hardening

- **Intent:** Clear namespace separation and least privilege.
  - Namespaces: e.g. **platform**, **system**, **applications** (or dev/stage/prod per env).
  - No cluster-admin everywhere.
  - Argo CD limited to specific namespaces and roles.
- **Deliverable:** RBAC YAML that is visible and justified (roles, rolebindings, service accounts).

## 1.5 Secret strategy

- **Already in place:** Sealed Secrets; no unsealed secrets or vault password committed (see [SECURITY.md](SECURITY.md)).
- **To document (or optionally support):**
  - No unsealed secret ever committed; vault pass never in repo.
  - **Optional extensions:** External Secrets Operator, HashiCorp Vault integration—architecture support and doc, not necessarily full implementation.
- **Signal:** "We think in terms of secret lifecycle and enterprise secret stores."

---

# 2. Architectural features (seniority signals)

## 2.1 Environment isolation

- **Intent:** Clear **dev / stage / prod** (or equivalent).
  - Separate values files (`values-dev.yaml`, `values-stage.yaml`, `values-prod.yaml`).
  - Separate Argo CD Applications (or ApplicationSets) per environment.
  - Separate namespaces per environment.
- **Promotion model (document):**
  - CI builds image with semantic/immutable tag.
  - CD updates `values-dev` (or stage); promotion to prod requires **PR** (and optionally manual approval / sync window).
- **Signal:** "We have a promotion model and environment boundaries."

## 2.2 GitOps governance

- **Deliverable:** Short document **docs/GITOPS_GOVERNANCE.md**.
- **Content:**
  - Git is source of truth.
  - No ad-hoc `kubectl apply`; all changes via PR.
  - Argo CD auto-sync rules (what is automated, what is manual).
  - Optional: sync windows, approval policies.
- **Signal:** "We codify process, not only tooling."

## 2.3 Observability (minimal but intentional)

- **Intent:** No "everything plus ELK". Instead:
  - Reloader (already present) for config/secret reload.
  - Optional kube-prometheus-stack; document **metrics endpoint pattern** and **health check contract** (liveness/readiness).
  - Document SRE-style expectations: metrics, health, and how apps should conform.
- **Signal:** "We know what observability means in practice without overbuilding."

## 2.4 Supply chain security

- **Intent:** Show 2026-era awareness.
  - Image pull policy: document choice (e.g. `IfNotPresent` vs `Always` and when).
  - **Mention** (or optionally implement): image signing (cosign), SBOM awareness.
  - **Mention:** Dependabot / Renovate; container scanning (e.g. Trivy) in pipeline.
  - Even **one Trivy stage** in Jenkins (or equivalent) as a gate elevates the repo.
- **Signal:** "We care about supply chain and vulnerability gates."

---

# 3. CI/CD hardening

- **Intent:** Pipeline is architect-grade, not "demo pipeline".
- **Add (or document) stages:**
  - SAST (static application security testing).
  - Dependency scan.
  - Container vulnerability scan (e.g. Trivy).
- **Enforce:** No deploy if critical vulnerabilities (or document the policy).
- **Add (or document):**
  - Semantic version tagging.
  - Immutable tags only in prod (no `:latest` in production).
- **Signal:** "Enterprise pipeline with security gates and traceable artifacts."

---

# 4. Configuration maturity

- **Already planned:** Central config (`config/defaults.yaml.example`), one place for IPs and links.
- **Upgrade (document or implement):**
  - **Layered config:** global defaults → env override → local override.
  - **Validation:** fail fast if required values are missing; document validation logic.
- **Signal:** "We think in layers and fail safely."

---

# 5. What we do *not* do

We do **not**:

- Add many more databases or message queues (e.g. Kafka) "because we can".
- Add random cloud integrations or shiny tools without a clear trade-off.
- Add unnecessary complexity.

Senior engineers **remove** complexity; they don’t add it for show.

---

# 6. Target positioning (chosen)

**Positioning:** **D (All three) narrated as B + C, with A as proof.**

- Present the repo as **Cloud-native Kubernetes architect + DevSecOps maturity** (B + C).
- Prove it runs **on bare metal** via Ansible/RKE (A)—no cloud lock-in.
- Main story: **Ansible + RKE + Argo CD + Helm + Jenkins + security controls.** Optional components (GitLab, DB installers) stay clearly **optional/reference**; no promise to "test every combination" or "keep everything latest every N months" (see Adjust/Remove below).

---

# 7. Ten non-negotiable platform controls (best ROI)

These are the tight set that reviewers instantly recognize as Lead/Architect. The repo implements them as described in this document and in the referenced files (e.g. values-production.yaml, helm-common, AppProject, Kyverno policies).

| # | Control | Why it matters |
|---|--------|----------------|
| **1** | **Ingress + TLS as default path for Argo CD** | NodePort in main docs looks like home-lab. Make Ingress + TLS the documented default; keep NodePort as "lab only". |
| **2** | **OIDC SSO option for Argo CD** | Document + values stub (placeholders). Don't need to fully wire Azure AD/GitHub; include "how to enable SSO" section. Enterprise access control maturity. |
| **3** | **Pod Security Standards enforced by default** | Namespace labels + helm-common defaults (non-root, no privilege escalation, drop caps). Modern baseline expectation. |
| **4** | **Default-deny NetworkPolicy template + allow-lists** | Working example: default deny ingress/egress; allow DNS egress; allow ingress from ingress-nginx to app namespaces. Blast-radius signal. |
| **5** | **RBAC model + "no cluster-admin" rule** | One "platform admin" role; Argo CD limited roles; app namespace roles. Security-by-design. |
| **6** | **Admission / policy-as-code (one of Kyverno or OPA Gatekeeper)** | 2–3 example policies: block privileged containers; require resource requests/limits; require runAsNonRoot. Compliance/guardrails signal. |
| **7** | **Supply chain gate in CI (real)** | Trivy image scan as hard gate (fail on CRITICAL/HIGH). Optional: Syft SBOM + store as artifact. 2026 expectation. |
| **8** | **Immutable tags + provenance (documented policy)** | No `:latest` for prod; tag format e.g. `1.2.3+gitsha`; CD updates values via PR. Traceability. |
| **9** | **Backup story (minimal but real)** | etcd/RKE snapshot strategy note; Velero optional. Production thinking. |
| **10** | **"Golden path" Make targets** | Makefile as product surface; internally calls scripts/playbooks. Already in place; keep and extend as needed. |

---

# 8. Adjust: keep scope tight

- **Optional components:** GitLab + DB installers are fine; label them **"optional/reference"**. Main story = Ansible + RKE + Argo CD + Helm + Jenkins + security controls.
- **Dependency updates:** Only what a reviewer will judge (big 3: Python, Java, K8s/key charts). See [VERSIONS.md](VERSIONS.md).

---

# 9. Remove: no maintenance liability

For portfolio, **avoid** these promises:

- "We keep everything latest every N months."
- "Tested every combination."

Use instead: **"Validated on versions X/Y at publish time"** and **"Updates welcome via PR"** (see [VERSIONS.md](VERSIONS.md) and README).

---

# 10. If a CTO reviews this

If they see:

- Central config, GitOps enforced, RBAC isolation, network policies, Pod security, secret strategy, CI security scans, promotion model, clean README and architecture

they should think: **"This person designs platforms, not scripts."**

That is the goal.

---

# 11. Implementation order (no docs yet, pure engineering)

Implement in this order (the repo already contains the corresponding files):

1. Argo CD Ingress + TLS (NodePort = lab only).
2. PSS baseline + helm-common securityContext defaults.
3. Default-deny NetworkPolicy templates.
4. Trivy gate in Jenkins pipeline (fail on CRITICAL/HIGH).
5. RBAC tightening (no cluster-admin by default).
6. (Optional) Kyverno or OPA Gatekeeper with 2–3 rules.

Everything else (OIDC doc, backup story, immutable-tag policy doc) can follow.

---

# 12. Strategic choice: A vs B

How the repo should feel drives what we add in the first release:

- **A) Clean and minimal but extremely disciplined**  
  Implement the core controls (Ingress+TLS, PSS, NetworkPolicy, Trivy, RBAC) and keep the surface lean. Quotas, Kyverno, SSO stub, and governance docs can be added later or as optional. Strong signal: "every line is intentional."

- **B) Slightly heavier but visibly enterprise-complete**  
  Add ResourceQuota + LimitRange, Kyverno with 2–3 rules, SSO doc + values stub, and GOVERNANCE.md in the first release. Repo reads as "enterprise-ready out of the box."

Choose A or B so we know whether to include quotas, Kyverno, SSO, and governance in the initial implementation pass or keep it lean and precise first.

**Decision: B.** We target **slightly heavier but visibly enterprise-complete**. Core controls **plus** ResourceQuota + LimitRange, Kyverno with 2–3 rules, SSO doc + values stub, and governance docs. Repo reads as "enterprise-ready out of the box."
