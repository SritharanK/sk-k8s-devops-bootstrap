# logging

Central log storage and collection for the platform. Grafana Loki stores and serves the logs, and a Grafana Alloy DaemonSet tails every container log on every node and pushes it to Loki through the Loki gateway.

| Item | Value |
| --- | --- |
| Upstream charts | loki 21.2.3 from `oci://ghcr.io/grafana-community/helm-charts`; alloy 1.16.0 from `oci://ghcr.io/grafana/helm-charts` |
| Upstream app versions | Loki 3.7.10, Alloy v1.22.0 |
| Upstream source | <https://github.com/grafana/loki>, <https://github.com/grafana/alloy> |
| Namespace | `logging` (Pod Security: privileged, because the Alloy DaemonSet reads `/var/log/pods` through a hostPath volume; every other pod is restricted-compliant) |
| Enabled by default | No. Switch on with `toolchains.logging.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

The OSS Loki chart moved to the grafana-community repository in March 2026; the `grafana/loki` chart now targets the enterprise edition. Promtail and Grafana Agent are end of life upstream; Grafana Alloy replaces them. The older standalone `loki` and `promtail` charts were removed from `helmcharts/system-charts/`.

## Addresses

| What | Address |
| --- | --- |
| Loki push and query (gateway) | `http://loki-gateway.logging.svc:80` |
| Push path used by Alloy | `http://loki-gateway.logging.svc/loki/api/v1/push` |
| Alloy self-metrics | `http://alloy.logging.svc:12345/metrics` |

Loki runs with `auth_enabled: false`. Clients send no `X-Scope-OrgID` header. A Grafana Loki datasource only needs the gateway URL.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Loki deployment mode | `Monolithic`, 1 replica | `SimpleScalable`: read, write and backend, 3 replicas each |
| Object storage | Local filesystem on an emptyDir | S3 (`https://s3.example.com`, region `CHANGE_ME`, buckets `CHANGE_ME-loki-chunks` and `CHANGE_ME-loki-ruler`) |
| Persistence | None, log data is disposable | write 20Gi PVC (WAL), backend 10Gi PVC (compactor and ruler state), default StorageClass |
| Retention | 72h | 720h (30 days) |
| Replication factor | 1 | 3 |
| Memcached caches | Off | chunks cache 1024 MB, results cache 256 MB, 1 replica each |
| Gateway (NGINX) | 1 replica | 2 replicas |
| PodDisruptionBudgets | None (single replicas) | read, write, backend and gateway, `maxUnavailable: 1` |
| Anti-affinity | Not relevant | Upstream hard pod anti-affinity on `kubernetes.io/hostname` per target |
| Alloy | DaemonSet on every node | DaemonSet on every node |

Resources (requests, memory limit):

| Container | lab | reference |
| --- | --- | --- |
| Loki single binary | 100m, 256Mi, limit 1Gi | not deployed |
| Loki write | not deployed | 500m, 1Gi, limit 2Gi |
| Loki read | not deployed | 250m, 512Mi, limit 2Gi |
| Loki backend | not deployed | 250m, 512Mi, limit 1Gi |
| Gateway NGINX | 25m, 32Mi, limit 128Mi | 50m, 64Mi, limit 256Mi |
| Gateway metrics exporter | 10m, 16Mi, limit 64Mi | 10m, 16Mi, limit 64Mi |
| Memcached | not deployed | set by the chart to 1.2 x allocated memory (1229Mi and 307Mi) |
| Alloy | 50m, 128Mi, limit 384Mi | 100m, 256Mi, limit 768Mi |
| Alloy config reloader | 10m, 32Mi, limit 64Mi | 10m, 32Mi, limit 64Mi |

No CPU limits are set. This is deliberate: CPU limits cause CFS throttling of latency-sensitive Go processes, while memory limits protect the node. The Loki chart sets `GOMEMLIMIT` to 85% of each Loki container's memory limit.

## Log pipeline

The Alloy configuration lives in `values.yaml` (`alloy.alloy.configMap.content`).

1. `discovery.kubernetes` lists only the pods on the local node (field selector `spec.nodeName` from the `K8S_NODE_NAME` environment variable).
2. `discovery.relabel` sets the stream labels and the file path `/var/log/pods/*<pod uid>/<container>/*.log`.
3. `loki.source.file` with `file_match` tails the matching files. Read offsets are kept on the node in `/var/lib/alloy-logging`, so a rollout resumes where it stopped.
4. `loki.process` parses the CRI line format with `stage.cri` (timestamp, stream, partial line joining).
5. `loki.write` pushes to the Loki gateway.

| Label | Source |
| --- | --- |
| `namespace` | Pod namespace |
| `pod` | Pod name |
| `container` | Container name (init containers included) |
| `app` | Pod label `app.kubernetes.io/name`, falling back to `app` |
| `node` | Node name |
| `stream` | `stdout` or `stderr`, set by `stage.cri` |

No log line is dropped. One label is removed: `loki.source.file` adds a `filename` label with the file path, which repeats namespace, pod and container and changes on every container restart. `stage.label_drop` removes it to avoid extra streams.

Alloy reads `/var/log` through a read-only hostPath mount and writes its positions to a second hostPath. It runs as UID 0 because container log files are owned by root with mode 0640, but with all capabilities dropped, no privilege escalation and a read-only root filesystem. Its ClusterRole (`logging-alloy`, from `templates/alloy-rbac.yaml`) only allows get, list and watch on pods. The upstream Alloy rule set, which includes read access to Secrets and ConfigMaps in every namespace, is not installed.

## Secrets

| Profile | Secret | Namespace | Keys |
| --- | --- | --- | --- |
| lab | none | | |
| reference | `loki-s3-credentials` | `logging` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

Loki reads the keys from environment variables in every read, write and backend pod and expands `${AWS_ACCESS_KEY_ID}` and `${AWS_SECRET_ACCESS_KEY}` in its configuration (`-config.expand-env=true`, set by the upstream chart). The ConfigMap holds only the variable names. The credentials need read, write, list and delete on both buckets; delete is required for retention.

Reference, through External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: loki-s3-credentials
  namespace: logging
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: loki-s3-credentials
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: CHANGE_ME/logging/loki-s3
        property: access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: CHANGE_ME/logging/loki-s3
        property: secret_access_key
```

For a quick test without External Secrets Operator, with keys issued by the object store:

```bash
kubectl -n logging create secret generic loki-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID='CHANGE_ME' \
  --from-literal=AWS_SECRET_ACCESS_KEY='CHANGE_ME'
```

## Dependencies

| Needs | Why |
| --- | --- |
| `monitoring` toolchain | Provides the `ServiceMonitor` and `PrometheusRule` CRDs. Its Prometheus selects objects labelled `release: monitoring` in every namespace: the Loki and Alloy ServiceMonitors, the Loki recording rules (`loki-loki-rules`) and alerts (`loki-loki-alerts`). Its Grafana loads the Loki dashboard ConfigMaps (label `grafana_dashboard: "1"`), which this chart creates in the `logging` namespace, so the Grafana dashboard sidecar must search all namespaces. Grafana also needs a Loki datasource pointing at `http://loki-gateway.logging.svc:80`. |
| Object storage (reference) | Buckets `CHANGE_ME-loki-chunks` and `CHANGE_ME-loki-ruler` and the Secret above. |
| Default StorageClass (reference) | PVCs for write and backend. |

The chart installs no CRDs. Cluster-scoped objects: ClusterRole and ClusterRoleBinding `logging-alloy`.

## Upgrade

1. Change the dependency versions in `Chart.yaml`.
2. Run `helm dependency update helmcharts/system-charts/logging` and commit the new `Chart.lock`.
3. Render both profiles and compare with the previous render.
4. Read the upstream notes: Loki chart README and values at <https://github.com/grafana-community/helm-charts/tree/main/charts/loki>, Loki release notes at <https://grafana.com/docs/loki/latest/release-notes/>, Alloy chart changelog at <https://github.com/grafana/alloy/blob/main/operations/helm/charts/alloy/CHANGELOG.md>, Alloy release notes at <https://grafana.com/docs/alloy/latest/release-notes/>.

Gotchas:

- Never edit an existing `schemaConfig` entry. Add a new entry with a `from` date in the future.
- The gateway image is pinned to an exact tag (`1.31.8-alpine`) because the upstream default is a floating minor tag. Review it on every chart bump.
- `SimpleScalable` is deprecated upstream and is removed in Loki 4. The migration path is `Distributed`, through the `SimpleScalable<->Distributed` transition mode.
- The deprecated name `SingleBinary` is an alias of `Monolithic`; this chart uses `Monolithic`.
- Keep `statefulSetRecreateJob` disabled. It relies on `lookup` and Helm hooks, which do not work when Argo CD renders the chart.
- `volumeClaimTemplates` are immutable. Changing the write or backend PVC size needs the StatefulSet to be deleted with `--cascade=orphan` and synced again, plus a PVC resize.
- The Alloy configuration is passed through `tpl` by the upstream chart. Do not use double curly braces in it.

## Known limitations

- Kubernetes events are not collected. `loki.source.kubernetes_events` must run in exactly one instance, so it needs a separate single-replica collector; that is out of scope for now.
- No authentication on the gateway and a single tenant. Any pod that can reach `loki-gateway.logging.svc` can push and query logs.
- Lab keeps logs on an emptyDir: a rescheduled Loki pod starts empty.
- The Loki ruler runs (backend or single binary) but has no rules: the rules sidecar is disabled and no rules are uploaded.
- The upstream dashboards include panels and dashboards for components that are not deployed (bloom filters, Thanos object storage client). They stay empty.
- Memcached runs one replica per cache in reference. Losing it costs query performance only.
- Alloy runs as UID 0 (without capabilities), which needs the privileged namespace together with the hostPath volumes.
