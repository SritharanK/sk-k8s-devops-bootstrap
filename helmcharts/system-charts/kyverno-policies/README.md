# kyverno-policies

Admission policies for the application namespaces (`dev`, `stage`, `prod`), written as Kyverno CEL policies (`policies.kyverno.io/v1`). The engine comes from [`../kyverno`](../kyverno), which pins Kyverno v1.20.0; the legacy `kyverno.io/v1` ClusterPolicy is no longer executed by that release.

| Item | Value |
|---|---|
| Kinds | `ValidatingPolicy`, `ImageValidatingPolicy` (cluster-scoped), `PolicyException` (in the Kyverno namespace) |
| Argo CD Application | `argocd-bootstrap/templates/toolchains/kyverno-policies.yaml`, sync wave 3 |
| Decisions | [ADR 0004](../../../docs/adr/0004-kyverno-cel-policies.md) (workload policy), [ADR 0008](../../../docs/adr/0008-keyless-image-signing.md) (image signing identity) |
| Tests | [`tests/`](tests), `kyverno test` format; [`tests/vuln-attestation`](tests/vuln-attestation) runs against a local registry (`make policy-test-attestations`) |

## Policies

Every policy matches Pods, Deployments, StatefulSets, DaemonSets, Jobs and CronJobs (and ephemeral container updates) in the application namespaces only. Matching the controllers rejects a non-compliant Deployment when Argo CD applies it, instead of leaving a ReplicaSet that cannot create pods.

| Policy | Rule |
|---|---|
| `require-run-as-non-root` | Effective `runAsNonRoot: true` for every container; no `runAsUser: 0` |
| `disallow-privilege-escalation` | `allowPrivilegeEscalation: false` in every container |
| `require-drop-all-capabilities` | `capabilities.drop` contains `ALL`; only `NET_BIND_SERVICE` may be added |
| `require-seccomp-profile` | Effective `seccompProfile.type` is `RuntimeDefault` or `Localhost` |
| `require-read-only-root-filesystem` | `readOnlyRootFilesystem: true` in every container |
| `require-requests-limits` | CPU and memory requests and limits on containers and init containers |
| `require-probes` | Readiness and liveness probes on containers of long-running workloads (not Jobs) |
| `require-image-tag-or-digest` | An explicit tag other than `latest`, or a sha256 digest; the tag is read after the last `/` |
| `restrict-image-registries` | Image reference starts with an entry of `allowedRegistries` |
| `disallow-privileged-containers` | No privileged container |
| `disallow-host-namespaces` | No hostNetwork, hostPID, hostIPC or hostPort |
| `disallow-host-path` | No hostPath volume |
| `restrict-service-external-ips` | No Service `externalIPs` (CVE-2020-8554) |
| `verify-image-signatures` | Images in `imageVerification.registries` carry a cosign keyless signature from the build workflow (`build-image.yml` on `main`). With `imageVerification.vulnerabilities.enabled`, also a vulnerability scan attestation from the same signer that is younger than `maxScanAge` and has no finding of a listed severity |
| `restrict-networkpolicy-broad-ingress-audit` | Reports (Audit and Warn, every environment) a NetworkPolicy that admits ingress from all namespaces or any source to every pod of the namespace |

"Effective" follows the Pod Security Standards: a container inherits the pod `securityContext` value unless it sets its own. Init and ephemeral containers are checked, except for resources and probes, which they cannot or need not declare.

Each policy is rendered once per failure action that has namespaces: `<policy>-enforce` (stage, prod: `Deny`, `failurePolicy: Fail`) and `<policy>-audit` (dev: `Audit` and `Warn`, `failurePolicy: Ignore`). Background scans are on for the validating policies, so existing objects show up in policy reports. Signature checks run at admission only.

## Exceptions

Exceptions are `PolicyException` objects in the Kyverno namespace, the only namespace the engine accepts them from. The chart ships one: cert-manager ACME HTTP-01 solver pods, matched by the `acme.cert-manager.io/http01-solver: "true"` label, a cert-manager `Challenge` owner and the solver image. A pod that only copies the label is still rejected (fixture `bad-fake-acme-solver`).

To exempt a single workload, add a PolicyException with the narrowest `matchConditions` possible and an `expiresAt` date, rather than adding to `disabledPolicies`.

## Values

| Key | Source | Default |
|---|---|---|
| `environments.<env>.namespace` | injected from `namespaces.<env>` in `clusters/<name>/cluster.yaml` | `dev`, `stage`, `prod` |
| `environments.<env>.action` | this chart | dev `Audit`, stage and prod `Enforce` |
| `allowedRegistries` | injected: `<platform.imageRegistry>/` | `ghcr.io/your-org/` |
| `imageVerification.enabled` | `values-reference.yaml` | `true` in reference, `false` in lab |
| `imageVerification.registries` | injected: `<platform.imageRegistry>/*` | `ghcr.io/your-org/*` |
| `imageVerification.issuer`, `subjectRegExp` | [ADR 0008](../../../docs/adr/0008-keyless-image-signing.md) | GitHub Actions OIDC, `build-image.yml` on `main`; the toolchain pins the owner and repository from `git.repoURL` (HTTPS or SSH github.com URL) and fails the render without one when verification is on, unless `publicKey` is set; the chart default accepts any owner |
| `imageVerification.publicKey` | cluster file | empty: keyless. A PEM public key replaces the keyless identity for the signature and the vulnerability attestation (key pair or KMS signing) |
| `imageVerification.insecureIgnoreTlog` | tests only | `false`. `true` skips the transparency log check; the render fails unless `publicKey` is set |
| `imageVerification.vulnerabilities.enabled` | `values-reference.yaml` | `true` in reference, `false` otherwise; no effect while `imageVerification.enabled` is false |
| `imageVerification.vulnerabilities.maxScanAge` | this chart | `168h`; duration in `h`, `m` and `s`, renewed by the daily rescan of `build-image.yml` |
| `imageVerification.vulnerabilities.severities` | this chart | `[CRITICAL]`; Trivy severities that block admission |
| `imageVerification.vulnerabilities.ignoreUnfixed` | this chart | `false`: findings without a fixed version block too |
| `imageVerification.vulnerabilities.ignoreVulnerabilityIDs` | cluster file | `[]`; accepted risks, reviewed per pull request with reason, owner and review date, for every checked image |
| `disabledPolicies` | this chart | `[]` |
| `networkPolicyAudit.enabled` | this chart | `true` |

## Operational notes

- Enforce policies fail closed. If the Kyverno admission controller is unavailable, pod creation in stage and prod stops; the reference profile runs three admission replicas for this reason.
- `verify-image-signatures` mutates matching image references to their digest and requires the digest. It calls the registry and the Rekor log during admission (timeout 30 s), so the Kyverno pods need egress to both.
- `kubectl debug` in stage and prod needs a custom profile that meets the policies (non-root, read-only root filesystem, dropped capabilities, seccomp).
- Admission order matters. Pod Security Admission (namespace labels from the misc chart) runs before the Kyverno webhook, so a privileged pod is rejected by PSA first. The LimitRange in each environment namespace is a mutating step, so a bare Pod without a CPU or memory limit receives the namespace default and passes `require-requests-limits`; a Deployment, StatefulSet or other controller is checked as written and is rejected.
- `verify-image-signatures` rewrites `name:tag` to `name:tag@sha256:...`, so the image that runs is the one that was verified.
- With the vulnerability gate on, a deployed digest that gets a new CRITICAL finding, or whose newest scan is older than `maxScanAge` because the rescan did not run, cannot start new pods in stage and prod, also after a node drain. Running pods are not evicted. The response is in [supply chain](../../../docs/security/supply-chain.md#operational-consequences).
