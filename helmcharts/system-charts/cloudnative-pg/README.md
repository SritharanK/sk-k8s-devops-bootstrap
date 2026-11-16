# cloudnative-pg

CloudNativePG operator with the Barman Cloud backup plugin. Applications get PostgreSQL as a `Cluster` resource inside Kubernetes, with streaming replication, failover, WAL archiving and scheduled base backups to S3.

| Item | Value |
| --- | --- |
| Upstream chart | cloudnative-pg 0.29.1 and plugin-barman-cloud 0.9.0 from `oci://ghcr.io/cloudnative-pg/charts` |
| Upstream app version | CloudNativePG 1.30.1, plugin-barman-cloud v0.16.0 |
| Upstream source | <https://github.com/cloudnative-pg/cloudnative-pg>, <https://github.com/cloudnative-pg/plugin-barman-cloud> |
| Namespace | cnpg-system (Pod Security: restricted, operator and plugin run as non-root with a read-only root filesystem) |
| Enabled by default | No. Switch on with `toolchains.cloudnative-pg.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Decision

PostgreSQL for platform and application workloads runs in the cluster through CloudNativePG. It replaces the retired VM database roles (Ansible `install_postgresql` and `install_mariadb`): databases are declared in Git next to the workloads that use them, and high availability, backups and point-in-time recovery come from the operator instead of separately managed database VMs.

Backups use the Barman Cloud plugin. The in-tree `barmanObjectStore` backup method of the `Cluster` resource is deprecated since CloudNativePG 1.26 in favour of the plugin, so this chart installs the plugin and the example uses `method: plugin` only.

## What the chart installs

| Component | Detail |
| --- | --- |
| Operator | Deployment `cloudnative-pg`, cluster-wide, with its own admission webhooks. The operator generates the webhook certificate itself and writes the `caBundle` at run time (ignored by the Argo CD Application). |
| Barman Cloud plugin | Deployment `plugin-barman-cloud` and Service `barman-cloud` in the same namespace as the operator, as the plugin requires. Its sidecar `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.16.0` is injected into PostgreSQL pods that use the plugin. |
| Plugin certificates | cert-manager issues them. The chart creates a namespaced self-signed `Issuer` `plugin-barman-cloud-selfsigned-issuer` and two `Certificate` resources: `barman-cloud-server` (Secret `barman-cloud-server-tls`, DNS name `barman-cloud`) and `barman-cloud-client` (Secret `barman-cloud-client-tls`). Lifetime 90 days, renewed 15 days before expiry, new private key on every renewal. |
| CRDs | 11 `postgresql.cnpg.io` CRDs and `objectstores.barmancloud.cnpg.io`, rendered from the chart templates. |
| Metrics | PodMonitor `cloudnative-pg` for the operator with label `release: monitoring`. |
| Dashboard | ConfigMap `cnpg-grafana-dashboard` with label `grafana_dashboard: "1"`, from the upstream grafana-dashboards chart. The Grafana sidecar loads it from any namespace. |

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Operator replicas | 1 | 2, spread over nodes, PodDisruptionBudget minAvailable 1 |
| Operator requests / memory limit | 50m, 128Mi / 256Mi | 100m, 256Mi / 512Mi |
| Plugin replicas | 1 | 1 (upstream Deployment uses the Recreate strategy) |
| Plugin requests / memory limit | 10m, 64Mi / 128Mi | 50m, 128Mi / 256Mi |
| Example cluster instances | 1 | 3 |
| Example storage per instance | 5Gi | 20Gi |
| Example PostgreSQL requests / memory limit | 100m, 256Mi / 512Mi | 500m, 1Gi / 2Gi |
| Example Barman sidecar requests / memory limit | 20m, 64Mi / 256Mi | 100m, 256Mi / 1Gi |
| Example object store | `s3://cnpg/` at `http://seaweedfs-s3.seaweedfs.svc:8333` | `s3://CHANGE_ME-cnpg/` at `https://s3.example.com` |

CPU limits are left out on purpose to avoid throttling; memory limits are set. The upstream security contexts are restricted-compliant and kept as they are.

## Example database

`exampleCluster.enabled: false` by default. When enabled, the chart renders into namespace `cnpg-example` (`exampleCluster.namespace`):

| Kind | Name | Detail |
| --- | --- | --- |
| Namespace | `cnpg-example` | Pod Security `restricted` (enforce, audit, warn) |
| ImageCatalog | `postgresql` | major 18 pinned to `ghcr.io/cloudnative-pg/postgresql:18.7-202611122305-standard-trixie`, the fully qualified tag (minor, build timestamp, type, OS) |
| ObjectStore | `payments-db-s3` | `barmancloud.cnpg.io/v1`, credentials from Secret `cnpg-s3-credentials`, retention `30d`, WAL compression `gzip`, path-style addressing |
| Cluster | `payments-db` | database `payments` owned by role `payments` (`bootstrap.initdb`), image from the catalog, Barman Cloud plugin as WAL archiver |
| ScheduledBackup | `payments-db-daily` | daily at 02:00 (`0 0 2 * * *`, six fields with seconds first), `method: plugin`, first backup right after creation |
| PodMonitor | `payments-db` | selects `cnpg.io/cluster: payments-db`, label `release: monitoring` |

The custom resources carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, because their CRDs arrive in the same sync, and `argocd.argoproj.io/sync-wave: "1"`, so Argo CD applies them after the operator and plugin are healthy and their webhooks answer.

The operator creates Secret `payments-db-app` with the application credentials and the Services `payments-db-rw`, `payments-db-ro` and `payments-db-r` for clients.

To enable it:

1. Create the bucket (`cnpg` on the lab SeaweedFS, `CHANGE_ME-cnpg` in reference).
2. Create the namespace and the S3 Secret (see Secrets). Argo CD adopts a namespace that already exists.
3. Set `exampleCluster.enabled: true` in the profile values file and let Argo CD sync.
4. Check with `kubectl -n cnpg-example get cluster,backup,scheduledbackup,objectstore`.

Disabling the example prunes the namespace with the Cluster, its PersistentVolumeClaims and the Secrets; the backups in the bucket stay.

## Secrets

| Secret | Namespace | Keys | Used by |
| --- | --- | --- | --- |
| `cnpg-s3-credentials` | `cnpg-example` (the namespace of the Cluster) | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | ObjectStore `payments-db-s3` |
| `payments-db-app` | `cnpg-example` | created by the operator (`username`, `password`, `uri` and more) | applications |

Lab, with the access key that the lab SeaweedFS accepts:

```bash
kubectl create namespace cnpg-example
kubectl -n cnpg-example create secret generic cnpg-s3-credentials \
  --from-literal=ACCESS_KEY_ID=CHANGE_ME \
  --from-literal=ACCESS_SECRET_KEY=CHANGE_ME
```

Reference, through External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cnpg-s3-credentials
  namespace: cnpg-example
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: cnpg-s3-credentials
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: CHANGE_ME/cnpg-s3
        property: access_key_id
    - secretKey: ACCESS_SECRET_KEY
      remoteRef:
        key: CHANGE_ME/cnpg-s3
        property: secret_access_key
```

## Dependencies

| Component | Why |
| --- | --- |
| cert-manager | Issues the plugin server and client certificates (`cert-manager.io/v1` Issuer and Certificate). Must be running before this Application syncs. |
| monitoring | PodMonitor CRD, the Prometheus that selects `release: monitoring`, and the Grafana sidecar that loads the dashboard. |
| seaweedfs (lab) | Bucket `cnpg` behind `http://seaweedfs-s3.seaweedfs.svc:8333` for the example. |
| S3 object storage (reference) | Bucket `CHANGE_ME-cnpg` behind `https://s3.example.com`, plus the credentials in `cnpg-s3-credentials`. |
| Default StorageClass | Volumes of the example cluster. On the reference cluster, a Longhorn class with three replicas stores every PostgreSQL instance three times on top of PostgreSQL's own replication; a dedicated class with one Longhorn replica, set through `exampleCluster.storage.storageClass`, is the usual choice. |

## Upgrade

1. Read the release notes: <https://cloudnative-pg.io/documentation/current/release_notes/> and <https://github.com/cloudnative-pg/plugin-barman-cloud/releases>.
2. Bump both dependencies together in `Chart.yaml`, keeping the plugin within the operator versions it supports (v0.16.0 needs CloudNativePG 1.30 or newer). Run `helm dependency update`, then lint and render both profiles, also with `--set exampleCluster.enabled=true`.
3. An operator upgrade starts a rolling update of every PostgreSQL cluster to the new instance manager. With `primaryUpdateStrategy: unsupervised` (the default) it ends with an automatic switchover; a single-instance cluster is restarted. Applications must reconnect, so plan it as a maintenance window for production clusters.
4. PostgreSQL minor updates: change the image in the ImageCatalog. Use a fully qualified tag from <https://github.com/cloudnative-pg/postgres-containers/pkgs/container/postgresql>. A major version needs a new catalog entry and a planned major upgrade.

## Known limitations

- CRDs: the charts render their CRDs from templates with fixed annotations (`controller-gen` version and `helm.sh/resource-policy: keep`) and offer no value to add more. Argo CD treats `helm.sh/resource-policy: keep` as `Delete=false`, so deleting the Application keeps the CRDs. `Prune=false` cannot be set, so a CRD that disappears from a future chart version would be pruned by the automated sync.
- The dashboard ConfigMap is about 280 KB when serialized. It relies on server-side apply (set on the Application); with client-side apply the `last-applied-configuration` annotation would exceed the 256 KiB annotation limit.
- The plugin chart has no PodMonitor or ServiceMonitor, and the plugin runs as a single replica with the Recreate strategy. The operator calls it while reconciling clusters that use it (for example to add the sidecar to new instance pods), so an outage delays those changes. WAL archiving and backups run in the sidecar inside each instance pod.
- PostgreSQL instance pods and their Barman sidecar are created by the operator at run time, so this chart cannot render or statically check them. CloudNativePG sets a restricted-compliant security context on them by default.
