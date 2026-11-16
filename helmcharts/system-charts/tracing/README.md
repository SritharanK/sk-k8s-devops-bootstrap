# tracing

Optional trace backend for the platform. Grafana Tempo in single binary mode receives OpenTelemetry (OTLP) traces from services and serves them to Grafana.

| Item | Value |
| --- | --- |
| Upstream chart | tempo 3.2.1 from `oci://ghcr.io/grafana-community/helm-charts` (single binary; the `grafana/tempo` chart is deprecated) |
| Upstream app version | Tempo 3.1.1 |
| Upstream source | <https://github.com/grafana/tempo> |
| Namespace | `tracing` (Pod Security: restricted, Tempo needs no host access) |
| Enabled by default | No, in both profiles. Switch on with `toolchains.tracing.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Addresses

| What | Address |
| --- | --- |
| OTLP HTTP | `http://tempo.tracing.svc:4318` |
| OTLP gRPC | `tempo.tracing.svc:4317` |
| Query API (Grafana datasource) | `http://tempo.tracing.svc:3200` |

## Sending traces

Charts built on `helm-common` (2.1.0 or later) set everything below with `otel.enabled: true`, including the egress rule to this namespace and Kubernetes resource attributes; see `docs/how-to/tracing.md`. `hello-api` is the reference client: one server span per request, `trace_id` in every log line and as an exemplar on its HTTP metrics. `tests/integration/tracing/run.sh` proves the path on kind.

Other workloads: OpenTelemetry SDKs and auto-instrumentation agents read the standard exporter environment variables. Set them on the workload:

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: CHANGE_ME
  - name: OTEL_TRACES_EXPORTER
    value: otlp
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: http/protobuf
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://tempo.tracing.svc:4318
```

With `http/protobuf` the SDK appends `/v1/traces` to the endpoint. For gRPC use `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` and `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.tracing.svc:4317`. A namespace with a default-deny NetworkPolicy needs egress to the `tracing` namespace on TCP 4317 or 4318.

Grafana: the monitoring chart provides a Tempo datasource with uid `tempo`, pointing at `http://tempo.tracing.svc:3200`, when `datasources.tempo.enabled` is set in its values.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Replicas | 1 | 1 |
| Trace storage | `local` backend under `/var/tempo` on an emptyDir | S3: bucket `CHANGE_ME-tempo`, endpoint `s3.example.com`, region `CHANGE_ME`, path-style |
| WAL and live-store data | emptyDir at `/var/tempo` | 10Gi PVC at `/var/tempo`, default StorageClass |
| Retention | 24h | 168h (7 days) |
| Resources (requests, memory limit) | 50m, 128Mi, limit 512Mi | 500m, 2Gi, limit 4Gi |
| PodDisruptionBudget | None | None (single replica, a PDB would block node drains) |

Both profiles: OTLP gRPC and HTTP receivers on, anonymous usage reporting off, ServiceMonitor with label `release: monitoring`, restricted security context (non-root UID 10001, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`), no service account token mounted.

No CPU limit is set. This is deliberate: a CPU limit causes CFS throttling during compaction and query bursts, while the memory limit protects the node.

## Secrets

| Profile | Secret | Namespace | Keys |
| --- | --- | --- | --- |
| lab | none | | |
| reference | `tempo-s3-credentials` | `tracing` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

Tempo reads the keys from environment variables and expands `${AWS_ACCESS_KEY_ID}` and `${AWS_SECRET_ACCESS_KEY}` in its configuration (`-config.expand-env=true`). The ConfigMap holds only the variable names. The credentials need read, write, list and delete on the bucket; delete is required for retention and compaction.

Reference, through External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tempo-s3-credentials
  namespace: tracing
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: tempo-s3-credentials
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: CHANGE_ME/tracing/tempo-s3
        property: access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: CHANGE_ME/tracing/tempo-s3
        property: secret_access_key
```

For a quick test without External Secrets Operator, with keys issued by the object store:

```bash
kubectl -n tracing create secret generic tempo-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID='CHANGE_ME' \
  --from-literal=AWS_SECRET_ACCESS_KEY='CHANGE_ME'
```

## Dependencies

| Needs | Why |
| --- | --- |
| `monitoring` toolchain | Provides the `ServiceMonitor` CRD; its Prometheus selects ServiceMonitors labelled `release: monitoring` in every namespace. Its Grafana carries the Tempo datasource (`datasources.tempo.enabled`). |
| Object storage (reference) | Bucket `CHANGE_ME-tempo` and the Secret above. |
| Default StorageClass (reference) | PVC for the WAL. |

The chart installs no CRDs and no cluster-scoped objects.

## Upgrade

1. Change the dependency version in `Chart.yaml` (and `appVersion` to match the upstream Tempo version).
2. Run `helm dependency update helmcharts/system-charts/tracing` and commit the new `Chart.lock`.
3. Render both profiles and compare with the previous render.
4. Read the upgrade section of the chart README at <https://github.com/grafana-community/helm-charts/tree/main/charts/tempo> and the Tempo release notes at <https://grafana.com/docs/tempo/latest/release-notes/>.

Gotchas:

- `tempo.tempo.retention` is a Go duration. Use hours (`168h`), not days.
- From chart 3.2.0 on, `tempo.retention` is enforced by the backend worker. Earlier 3.x charts only passed it to the scheduler.
- Tempo 3.0 removed the ingester and compactor in favour of the live-store and backend scheduler and worker. Read the Tempo 3 migration guide before a major upgrade.
- `volumeClaimTemplates` are immutable. Changing the PVC size needs the StatefulSet to be deleted with `--cascade=orphan` and synced again, plus a PVC resize.

## Known limitations

- Single binary with one replica: no high availability. A restart interrupts ingestion until the pod is ready again. In reference, flushed blocks are in S3 and the WAL survives on the PVC. Horizontal scaling needs the distributed Tempo chart, which is out of scope.
- The upstream Jaeger receivers stay enabled. The chart's Service template reads `tempo.receivers.jaeger` and fails to render without it. The Service also lists Zipkin and legacy OTLP ports that have no receiver configured.
- No authentication or multi-tenancy. Any pod that can reach `tempo.tracing.svc` can write and read traces.
- The metrics generator (service graphs, span metrics) is off.
- Lab keeps traces on an emptyDir: they are lost when the pod is deleted or rescheduled.
