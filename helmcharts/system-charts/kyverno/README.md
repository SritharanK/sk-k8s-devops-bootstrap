# kyverno

Wrapper chart for the Kyverno policy engine. It installs the admission, background, cleanup and reports controllers and the Kyverno CRDs. Policies are not part of this chart: they live in [`../kyverno-policies`](../kyverno-policies) and sync in wave 3, two waves after this chart (wave 1).

| Item | Value |
|---|---|
| Upstream chart | `oci://ghcr.io/kyverno/charts/kyverno` |
| Pinned chart version | 3.10.0 (see `Chart.yaml` and `Chart.lock`) |
| Kyverno version | v1.20.0 (the image tags rendered by chart 3.10.0) |
| Minimum Kubernetes | 1.35 (`kubeVersion` in `Chart.yaml`) |
| Namespace | `kyverno` (`namespaces.kyverno` in the cluster definition) |
| Argo CD Application | `argocd-bootstrap/templates/toolchains/kyverno.yaml`, sync wave 1 |

## Profiles

| Setting | `values-lab.yaml` | `values-reference.yaml` |
|---|---|---|
| Admission controller replicas | 1 | 3, spread across nodes |
| Background, cleanup, reports replicas | 1 | 2 each |
| PodDisruptionBudgets | none | `maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow` on every controller |
| Admission priority class | none | `system-cluster-critical` |
| Memory limits (admission, reports) | 512Mi, 512Mi | 1Gi, 1Gi |

CPU limits are not set: throttling on the admission path shows up as API latency and webhook timeouts. Memory requests and limits are set on every controller. The reference sizes are starting points.

## Decisions in `values.yaml`

- `config.webhooks` uses the map shape (`namespaceSelector.matchExpressions`). The list shape is a per-webhook override keyed by webhook name; in chart 3.3.x it broke the render.
- Webhooks exclude `kube-system`, `kube-public`, `kube-node-lease`, the Argo CD namespace and, through `excludeKyvernoNamespace`, the Kyverno namespace. Argo CD is excluded so that the controller reconciling Kyverno is never blocked by a Kyverno webhook that fails closed. The toolchain Application replaces the list with the namespace names from `clusters/<name>/cluster.yaml`.
- `features.policyExceptions` is enabled and restricted to the Kyverno namespace, so only identities that can write there can create exceptions.
- `config.preserve: false`, ServerSideApply and ServerSideDiff follow the Kyverno platform notes for Argo CD.
- The reports controller gets read access to `pods/ephemeralcontainers` (`reportsController.rbac.clusterRole.extraResources`). The workload policies match that subresource, and without the permission Kyverno reports them as not ready (condition `RBACPermissionsGranted`).

## Upgrade notes

1. Read the upstream release notes and the chart changelog (`helm show chart oci://ghcr.io/kyverno/charts/kyverno --version <new>`).
2. Change the dependency version in `Chart.yaml`, then run `helm dependency update` and commit `Chart.lock`. Never commit `charts/`.
3. Render both profiles and diff against the previous render: `helm template kyverno . -n kyverno -f values-reference.yaml`.
4. Run the policy tests with a `kyverno` CLI of the same version: `kyverno test ../kyverno-policies/tests`.
5. Since Kyverno 1.20 the legacy `kyverno.io` policy types (`ClusterPolicy`, `Policy`, `kyverno.io/v2 PolicyException`) are no longer executed, and the chart blocks install or upgrade while such objects exist on the cluster. This repository ships only `policies.kyverno.io/v1` policies. Do not set `upgrade.acknowledgeLegacyPoliciesNotEnforced`; delete legacy objects instead.
