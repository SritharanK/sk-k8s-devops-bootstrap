# external-secrets

Wrapper chart for the External Secrets Operator (ESO). ESO reads secrets from an external store and writes them as Kubernetes `Secret` objects, driven by `ExternalSecret` resources. In the reference profile the store is OpenBao, through the `openbao` ClusterSecretStore rendered by the `openbao` chart.

## Upstream and versions

| Item | Value |
|---|---|
| Upstream chart | `external-secrets` 2.15.0 |
| Application | v2.15.0 (`ghcr.io/external-secrets/external-secrets:v2.15.0`) |
| Wrapper chart | 0.1.0 |
| Source | <https://github.com/external-secrets/external-secrets> |
| Helm repository | `oci://ghcr.io/external-secrets/charts` |

2.15.0 was the current stable release on 2026-11-16. The CRDs serve `external-secrets.io/v1`; `v1beta1` serving stays off (`crds.unsafeServeV1Beta1: false`, upstream default).

## Configuration

Owner values live in `values.yaml` under the `external-secrets` key.

- `fullnameOverride: external-secrets`: the controller ServiceAccount is `external-secrets/external-secrets`. The OpenBao Kubernetes auth role and the ClusterSecretStore reference that name.
- `installCRDs: true`: the 25 CRDs are templates of this release. `templates/guards.yaml` fails rendering if it is set to false, because the CRDs would drop out of the render, Argo CD would prune them and Kubernetes would garbage-collect every `ExternalSecret`, `SecretStore` and `PushSecret`.
- `crds.annotations`: every CRD carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
- The webhook serving certificate is issued and rotated by the bundled cert-controller (`webhook.certManager.enabled: false`). The release does not depend on cert-manager, which syncs in the same wave.
- `bitwarden-sdk-server` is disabled.
- Controller, webhook and cert-controller run with an explicit pod and container security context that meets Pod Security Standards `restricted`: non-root (UID 1000), `RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped, read-only root filesystem.
- CPU and memory requests and limits are explicit for all three components. Readiness and liveness probes are enabled for all three; upstream disables both for the controller and liveness for the other two.
- Metrics endpoints stay at upstream defaults. No ServiceMonitor.
- The chart renders no SecretStore or ClusterSecretStore. A store here would sit in wave 0 and wait for a backend that syncs later; stores belong to the chart of their backend.

## Profiles

| Profile | Delta |
|---|---|
| `lab` | Not deployed. `values-lab.yaml` renders one replica per component without PodDisruptionBudgets, for trying the chart on kind. |
| `reference` | Two replicas each for controller, webhook and cert-controller, PodDisruptionBudgets with `minAvailable: 1`, leader election on (controller and cert-controller), and a soft topology spread over nodes. |

## Deployment

Argo CD Application `external-secrets`, namespace `external-secrets`, sync wave 0.

Cluster-scoped kinds in the render: `CustomResourceDefinition`, `ClusterRole`, `ClusterRoleBinding`, `ValidatingWebhookConfiguration` (same set in both profiles).

The `clustersecretstores` and `secretstores` CRDs are about 380 KB each. That is above the 262144-byte limit of the `kubectl.kubernetes.io/last-applied-configuration` annotation, so client-side apply fails on them. The Application needs `ServerSideApply=true` in `spec.syncPolicy.syncOptions`.

The two ValidatingWebhookConfigurations (`secretstore-validate`, `externalsecret-validate`) use `failurePolicy: Fail`. While no webhook pod is ready, creating or changing a SecretStore or ExternalSecret is rejected. The cert-controller injects `caBundle` at runtime; it is not part of the rendered manifest.

## Operations

Check the components and the leases:

```sh
kubectl -n external-secrets get deploy,pods,pdb
kubectl -n external-secrets get lease
```

Check stores and sync status across the cluster:

```sh
kubectl get clustersecretstore
kubectl get externalsecret -A
kubectl -n <namespace> describe externalsecret <name>
```

A store is `Ready` only after ESO has authenticated against the backend. For the `openbao` store this needs the OpenBao runbook steps (KV mount, Kubernetes auth, role) to be done.

Force an immediate refresh of one ExternalSecret:

```sh
kubectl -n <namespace> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
```

If the webhook certificate is broken (admission errors mentioning x509), restart the cert-controller; it reissues the certificate into the `external-secrets-webhook` Secret and re-injects the CA:

```sh
kubectl -n external-secrets rollout restart deployment/external-secrets-cert-controller
```

## Upgrades

1. Read the upstream release notes for every version in between, in particular CRD changes, removed API versions and provider changes.
2. Bump `dependencies[0].version` and `appVersion` in `Chart.yaml`.
3. Run `helm dependency update helmcharts/system-charts/external-secrets` and commit the new `Chart.lock`.
4. Diff the `helm template` output for both profiles against the previous version before merging. CRD changes are applied by Argo CD on sync; `Prune=false` keeps CRDs that a new version no longer ships, and those must be removed by hand once no resources use them.
