# sealed-secrets

Wrapper chart for the Sealed Secrets controller. The controller decrypts `SealedSecret` resources stored in Git into regular `Secret` objects, so the lab profile can keep secrets in the repository without plaintext.

## Upstream and versions

| Item | Value |
|---|---|
| Upstream chart | `sealed-secrets` 2.22.0 |
| Application | 0.41.2 (`docker.io/bitnami/sealed-secrets-controller:0.41.2`) |
| Wrapper chart | 0.1.0 |
| Source | <https://github.com/bitnami/sealed-secrets> |
| Helm repository | <https://bitnami.github.io/sealed-secrets> |

The project does not publish the chart as an OCI artifact, so the dependency uses the Helm repository named in the upstream README. 2.22.0 was the current stable release on 2026-11-16.

## Configuration

Owner values live in `values.yaml` under the `sealed-secrets` key.

- `fullnameOverride: sealed-secrets-controller`: `kubeseal` looks for a controller with this name in `kube-system` by default, so no `--controller-name` or `--controller-namespace` flags are needed.
- Key renewal stays at the controller default: a new sealing key every 30 days. Older keys stay active for decryption.
- CPU and memory requests and limits are explicit. The upstream chart derives `GOMAXPROCS` and `GOMEMLIMIT` from the limits.
- Security context meets Pod Security Standards `restricted`: non-root (UID 1001), `RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped, read-only root filesystem.
- No PodDisruptionBudget: the controller runs one replica and a `minAvailable: 1` budget would block node drains.
- Ingress, ServiceMonitor, PrometheusRule and Grafana dashboards are off. Monitoring integration follows the observability design.

## Profiles

| Profile | Delta |
|---|---|
| `lab` | None. `values.yaml` is the lab configuration. |
| `reference` | None. The reference profile uses External Secrets instead of this chart; the file exists so the chart renders for every profile. |

## Deployment

Argo CD Application `sealed-secrets`, namespace `kube-system`, sync wave 0, enabled in the `lab` profile.

The `SealedSecret` CRD (`sealedsecrets.bitnami.com`) ships in the upstream chart `crds/` directory. Argo CD renders it together with the other manifests, so CRD changes are applied on sync. Deleting the CRD deletes every `SealedSecret` in the cluster, and the `Secret` objects they own are garbage collected. The CRD is protected from cascade deletion by the `Delete=false` sync option in `spec.syncPolicy.syncOptions` of the toolchain Application, not by this chart. That option applies to every resource of the Application: deleting the Application leaves all its objects in place.

## Operations

Fetch the public certificate. Sealing with it works offline and needs no cluster access:

```sh
kubeseal --fetch-cert > sealed-secrets-cert.pem
kubeseal --cert sealed-secrets-cert.pem -o yaml < secret.yaml > sealed-secret.yaml
```

`--fetch-cert` goes through the API server service proxy. The upstream chart grants that proxy access to the group `system:authenticated` (`rbac.serviceProxier`, upstream default).

Back up the sealing keys after installation and after every key renewal (every 30 days). The file holds the private keys; store it offline and encrypted, never in Git:

```sh
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > sealed-secrets-keys.yaml
```

Restore on a rebuilt cluster: apply the backup, then restart the controller so it loads the restored keys:

```sh
kubectl apply -f sealed-secrets-keys.yaml
kubectl -n kube-system rollout restart deployment/sealed-secrets-controller
```

Without the original keys, existing `SealedSecret` resources cannot be decrypted and must be sealed again with the new certificate.

## Upgrades

1. Read the upstream release notes for every chart and controller version in between, in particular CRD and key handling changes.
2. Bump `dependencies[0].version` and `appVersion` in `Chart.yaml`.
3. Run `helm dependency update helmcharts/system-charts/sealed-secrets` and commit the new `Chart.lock`.
4. Diff the `helm template` output for both profiles against the previous version before merging.
