# Observability contract

This page states what every workload on the platform must expose for health, metrics, logs and traces, and what the optional observability profile provides. It is for developers who build services and for operators who run the monitoring stack. `hello-api` is the reference implementation of the contract.

## Required for every workload

| Requirement | Convention | Enforced or provided by |
| --- | --- | --- |
| Readiness probe | HTTP `GET /readyz` | Kyverno policy: Audit in `dev`, Enforce in `stage` and `prod`. helm-common default |
| Liveness probe | HTTP `GET /healthz` | Kyverno policy, as above. helm-common default |
| Metrics | `GET /metrics` in the Prometheus text format, on the service port | Contract; scraped through a ServiceMonitor |
| ServiceMonitor | `metrics.serviceMonitor.enabled: true` with the label `release: monitoring` | helm-common renders it where the `monitoring` toolchain runs |
| Logs | JSON, one object per line, to stdout or stderr, with trace IDs | Contract |
| Traces | OpenTelemetry SDK configured through the standard `OTEL_*` environment variables, W3C trace context | Contract |
| Shutdown | Graceful on SIGTERM, within `terminationGracePeriodSeconds` | Contract; helm-common sets the grace period |

The probes are part of the workload contract that Kyverno enforces (see [helm-common values](../reference/helm-common-values.md) and [controls](../security/controls.md)). The other rows are conventions: the platform and its dashboards rely on them, but no admission policy checks them.

## Health endpoints

- `/healthz` answers whether the process is alive and able to serve. It does not check dependencies: a database outage must not make the kubelet restart every replica.
- `/readyz` answers whether the pod should receive traffic. It fails during startup until the service is ready, and from the moment shutdown starts. It may check dependencies the service cannot work without.
- Both return HTTP 200 when the answer is yes and a non-2xx status (503 by convention) when it is no. The kubelet reads only the status code.

The helm-common defaults point the probes at these paths on the named port `http`:

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: http
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /readyz
    port: http
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3
```

Add a `startupProbe` for a service that needs long to start, instead of a long `initialDelaySeconds`. A service without HTTP can use `tcpSocket` or `grpc` probes; `exec` probes need a binary in the image, which distroless images do not provide.

## Metrics

- Serve `/metrics` in the Prometheus text exposition format on the same named port as the API (`http`, container port 8080 for `hello-api`).
- HTTP services use the metric names `hello-api` uses, so that the dashboards and SLOs apply without changes: `http_requests_total` with the labels `code`, `method` and `handler`, and the histogram `http_request_duration_seconds`.
- Keep label cardinality bounded: label by route template (`handler`), never by raw path, user or request ID.

Every app Application sets `metrics.serviceMonitor.enabled: true` while the `monitoring` toolchain is enabled in the cluster file, and leaves it to the chart otherwise, because the `ServiceMonitor` kind does not exist without that toolchain. The setting overrides `envs/<env>/<app>/values.yaml`, so an app on a monitored cluster serves `/metrics` and its Service. The chart values that this enables:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    labels:
      release: monitoring
    port: http
    path: /metrics
    interval: 30s
```

Prometheus selects ServiceMonitors, PodMonitors and PrometheusRules by the label `release: monitoring`. Prometheus reaches the pods through the app's own NetworkPolicy, which helm-common extends with ingress from the `monitoring` namespace on the metrics port when `metrics.serviceMonitor.enabled` is true (see [add an app](add-an-app.md#5-allow-the-traffic-the-service-needs)).

## Logs

- Write JSON to stdout or stderr, one object per line. Do not write log files: the root filesystem is read-only.
- Include a timestamp, a level and a message in every record. `hello-api` uses the Go `log/slog` JSON handler, which writes them as `time`, `level` and `msg`.
- Add `trace_id` and `span_id` when a span is active, so that a log line leads to its trace.
- Never log secrets, tokens or personal data.

With the `logging` toolchain, Grafana Alloy collects the container logs on every node and sends them to Loki; no change in the app is needed.

## Traces

Configure the OpenTelemetry SDK only through the standard environment variables, so that the platform can point every service at the same collector:

| Variable | Use |
| --- | --- |
| `OTEL_SERVICE_NAME` | Service name in every span |
| `OTEL_RESOURCE_ATTRIBUTES` | Extra resource attributes, for example `deployment.environment.name=prod` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint; `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` for traces only |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` or `grpc` |
| `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` | Sampling, for example `parentbased_traceidratio` with `0.1` |
| `OTEL_SDK_DISABLED` | `true` turns the SDK off |

Propagate W3C trace context (`traceparent`) on incoming and outgoing requests.

`hello-api` exports traces only when an OTLP endpoint variable is set and `OTEL_SDK_DISABLED` is not `true`; without them it opens no connection. It supports OTLP over HTTP (`http/protobuf`) and names itself `hello-api` unless `OTEL_SERVICE_NAME` or `OTEL_RESOURCE_ATTRIBUTES` says otherwise.

With the `tracing` toolchain, Tempo accepts OTLP at `tempo.tracing.svc:4317` (gRPC) and `tempo.tracing.svc:4318` (HTTP). A chart built on helm-common sets `otel.enabled: true`: the library adds the `OTEL_*` variables and the egress rule to the `tracing` namespace ([helm-common values](../reference/helm-common-values.md#tracing), [tracing](../how-to/tracing.md)). Only a workload that does not use helm-common sets the variables in its `env` list and allows the egress itself (TCP 4318 to the `tracing` namespace for OTLP over HTTP):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://tempo.tracing.svc:4318
  - name: OTEL_TRACES_SAMPLER
    value: parentbased_traceidratio
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"
```

helm-common merges maps key by key but replaces lists, so an `env` list in a per-environment override replaces the whole base list. Repeat every entry you need there.

## Graceful shutdown

On SIGTERM, a service:

1. fails `/readyz` at once;
2. keeps serving for a short delay, so that the endpoint controllers and the Gateway remove the pod;
3. stops accepting connections and drains in-flight requests within a timeout;
4. flushes telemetry and exits with status 0.

The delay and the timeout together stay below `terminationGracePeriodSeconds` (30 seconds by default), otherwise the kubelet kills the process. `hello-api` reads them from `SHUTDOWN_DELAY` (default 5s) and `SHUTDOWN_TIMEOUT` (default 20s). Implement the delay in the process: distroless images have no shell, so a `preStop` hook that runs `sleep` through a shell does not work.

## Observability profile

The observability components are optional wrapper charts, each a toolchain Application in sync wave 4. They are off by default in the `lab` profile; enable them per cluster in `clusters/<name>/cluster.yaml` (see [configuration](../reference/configuration.md)):

```yaml
toolchains:
  monitoring: {enabled: true}
  logging: {enabled: true}
  tracing: {enabled: true}
  slo: {enabled: true}
```

| Toolchain | Provides |
| --- | --- |
| `monitoring` | kube-prometheus-stack: Prometheus, Alertmanager and Grafana. Grafana answers at `grafana.<domain>` through the Gateway. Prometheus selects ServiceMonitors, PodMonitors and PrometheusRules labelled `release: monitoring`. Dashboards live in Git as ConfigMaps labelled `grafana_dashboard: "1"` |
| `logging` | Grafana Alloy collects container logs; Loki stores them. Push endpoint `http://loki-gateway.logging.svc/loki/api/v1/push` |
| `tracing` | Tempo, receiving OTLP on ports 4317 and 4318. Optional within the profile |
| `slo` | SLOs as code: Sloth specs in `helmcharts/system-charts/slo/slos/`, turned into Prometheus recording and alerting rules with the Sloth CLI at development time; the generated rules are committed |

The SLOs defined as code:

| SLO | Indicator | Objective |
| --- | --- | --- |
| App availability | Share of requests without a 5xx status, from `http_requests_total` with `namespace="prod"` | 99.5% |
| App latency | Share of requests faster than 250 ms, from `http_request_duration_seconds` with `namespace="prod"` | 99% |
| Argo CD sync success | Share of successful sync operations | 99% |
| Admission latency | Share of Kyverno admission reviews faster than 1 s | 99% |

The specs are in `helmcharts/system-charts/slo/slos/`. Certificate expiry is not an SLO: the `monitoring` chart raises the alert `CertManagerCertificateExpiringSoon`.

Progressive delivery uses the same metrics. With the optional `argo-rollouts` toolchain, the `ClusterAnalysisTemplate` `success-rate` queries Prometheus with the arguments `service-name`, `namespace` and the optional `threshold` (default 0.99). Without traffic, the analysis is Inconclusive and the rollout pauses. See [promotion](promotion.md#optional-and-planned). Kargo verifies each promotion with the same template when its verification is enabled ([promote with Kargo](../how-to/promote-with-kargo.md)).

## References

- Kubernetes probes: <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
- Prometheus exposition format: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus Operator ServiceMonitor: <https://prometheus-operator.dev/docs/developer/getting-started/>
- OpenTelemetry SDK environment variables: <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- W3C Trace Context: <https://www.w3.org/TR/trace-context/>
- Kubernetes pod termination: <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination>
- Grafana Alloy: <https://grafana.com/docs/alloy/latest/>
- Sloth: <https://sloth.dev/>
- Argo Rollouts analysis: <https://argo-rollouts.readthedocs.io/en/stable/features/analysis/>
