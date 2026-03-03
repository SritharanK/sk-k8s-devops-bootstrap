# Threat model

One-page view: risks this platform is designed to mitigate and how. For capability summary see [PLATFORM_CAPABILITIES.md](PLATFORM_CAPABILITIES.md).

---

## Risk → Mitigation

| Risk | Mitigation |
|------|------------|
| **Privileged or hostile container** | Kyverno policy `block-privileged-containers` (Enforce). Pods with `securityContext.privileged: true` are rejected at admission. Plus PSS namespace labels (baseline/restricted) and helm-common defaults (runAsNonRoot, no privilege escalation). |
| **Lateral movement / cross-namespace abuse** | Default-deny NetworkPolicy in prod and dev; inter-namespace traffic denied. Allow-lists: DNS egress to kube-system, ingress only from ingress-nginx namespace. Blast radius contained per namespace. |
| **Resource exhaustion** | LimitRange (default requests/limits per container) and ResourceQuota (aggregate CPU/memory/pods per namespace) in prod and dev. Runaway workloads cannot starve the cluster. |
| **Vulnerable or untrusted image** | Trivy image scan in Jenkins CI: build fails on CRITICAL/HIGH; no push if gate fails. Trivy config scan in GitHub Actions (advisory). Immutable tags in production (no `:latest`). See [SECURITY.md](SECURITY.md#trivy-vulnerability-and-config-scanning). |
| **RBAC escalation / over-broad access** | No cluster-admin for routine use. Bounded platform-admin ClusterRole; Argo CD limited to destination namespaces via AppProject; app deployer Role is namespace-scoped. |
| **Credential leak in repo** | No unsealed secrets or vault password committed; kubeconfig and RKE state gitignored. Sealed Secrets for in-cluster secrets; placeholders in repo. See [SECURITY.md](SECURITY.md). |
| **Unauthorized access to Argo CD** | Production: Ingress + TLS only (cert-manager); NodePort not used. Optional SSO/OIDC documented. |

---

## Failure scenario: policy rejection example

Policies are not decorative — they block disallowed workloads. Example:

**Scenario:** A pod is submitted with `securityContext.privileged: true`.

**What happens:** Kyverno ClusterPolicy `block-privileged-containers` (in `helmcharts/system-charts/kyverno-policies/block-privileged.yaml`) validates all Pods. The admission controller rejects the create/update.

**Example (try in a cluster where Kyverno is installed):**

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: prod
spec:
  containers:
    - name: bad
      image: busybox
      securityContext:
        privileged: true
  restartPolicy: Never
EOF
```

**Expected result:** Admission denied with a message such as (exact text may vary by Kyverno version):

```text
Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc" denied the request:

resource Pod/prod/privileged-test was blocked by ClusterPolicy block-privileged-containers.
Privileged containers are not allowed.
```

Similar behaviour applies to:

- **No resource limits** — ClusterPolicy `require-resource-requests-limits` rejects Pods in prod/dev without `resources.requests` and `resources.limits` (memory, cpu).
- **Run as root** — ClusterPolicy `require-run-as-non-root` rejects Pods in prod/dev without `runAsNonRoot: true` (and container-level runAsNonRoot).
- **No readiness probe** — ClusterPolicy `require-readiness-probe` rejects Pods in prod/dev without a `readinessProbe`.
- **Cross-namespace traffic** — Default-deny NetworkPolicy blocks traffic that is not explicitly allowed (e.g. from nginx for ingress, or to kube-system for DNS). A pod in prod cannot reach a service in dev unless an explicit allow policy is added.

These controls show that the platform enforces the intended security posture at admission and network layer.

---

## Reproducible policy failure demo

Copy-paste demos (cluster must have Kyverno installed). Expected outcome: **Denied**.

**1. Privileged container (one-liner):**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: privileged-test, namespace: prod }
spec:
  containers: [{ name: bad, image: busybox, securityContext: { privileged: true } }]
  restartPolicy: Never
EOF
```

**Expected:** `admission webhook "validate.kyverno.svc" denied the request` / `block-privileged-containers` / "Privileged containers are not allowed."

**2. No readiness probe (prod/dev):**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: no-probe-test, namespace: prod }
spec:
  containers: [{ name: app, image: nginx:alpine }]
  restartPolicy: Never
EOF
```

**Expected:** Denied by `require-readiness-probe` — "Pods must define a readinessProbe."

In both cases the pod is not created; the policy is enforced, not decorative.
