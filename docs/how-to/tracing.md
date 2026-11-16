# Trace requests with OpenTelemetry and Tempo

This guide turns on distributed tracing for an application built on `helm-common`, using `hello-api` as the example, and connects traces with logs and metrics in Grafana. Traces go over OTLP to Grafana Tempo from the optional `tracing` toolchain.

## How the pieces fit

| Signal | Producer | Store | Link to the trace |
| --- | --- | --- | --- |
| Traces | OpenTelemetry SDK in the application, one server span per request (W3C `traceparent` in, OTLP/HTTP out) | Tempo, `tempo.tracing.svc` (OTLP HTTP 4318, gRPC 4317, query API 3200) | not applicable |
| Logs | JSON `slog` records with `trace_id` and `span_id` | Loki, through Alloy | Loki derived field on `trace_id` opens the trace |
| Metrics | `http_requests_total` and `http_request_duration_seconds` with an exemplar `trace_id` for sampled requests | Prometheus | Exemplar link on the Prometheus datasource opens the trace |

`hello-api` implements the application side. Any other service gets the same result with an OpenTelemetry SDK that reads the standard `OTEL_*` environment variables, which `helm-common` sets.

## Prerequisites

- The `tracing` toolchain on the cluster. It is off by default; switch it on in `clusters/<name>/cluster.yaml`:

  ```yaml
  toolchains:
    tracing:
      enabled: true
  ```

- For the Grafana links, the `monitoring` toolchain with the Tempo datasource on, and the `logging` toolchain with the Loki datasource for the logs links:

  ```yaml
  toolchains:
    monitoring:
      enabled: true
      values:
        datasources:
          tempo:
            enabled: true
          loki:
            enabled: true
  ```

## Turn tracing on for an app

Tracing is off by default in the library and in `hello-api`. Set `otel.enabled` in the chart values, or per environment under `environments.<env>` (the files under `envs/` hold only the image tag and digest):

```yaml
otel:
  enabled: true
  endpoint: http://tempo.tracing.svc:4318
```

With `otel.enabled: true`, `helm-common`:

- sets `OTEL_SERVICE_NAME` (the release full name unless `otel.serviceName` is set), `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf`), `OTEL_TRACES_EXPORTER=otlp`, `OTEL_METRICS_EXPORTER=none`, `OTEL_LOGS_EXPORTER=none`, `OTEL_TRACES_SAMPLER` with `OTEL_TRACES_SAMPLER_ARG` (parent based, ratio 1.0 by default) and `OTEL_PROPAGATORS` (`tracecontext,baggage`);
- builds `OTEL_RESOURCE_ATTRIBUTES` with `k8s.namespace.name`, `k8s.pod.name` and `k8s.node.name` from the downward API, `k8s.deployment.name`, `service.version` and `deployment.environment.name` (from `global.environment`), plus any `otel.resourceAttributes`;
- adds an egress rule to the app NetworkPolicy towards namespace `otel.networkPolicy.namespace` (`tracing`) on port `otel.networkPolicy.port` (4318), because application namespaces deny all egress except DNS.

A variable the chart already sets in `env` is never emitted a second time, so an app can override any of them. Metrics and logs exporters are off because Tempo accepts traces only; metrics are scraped by Prometheus and logs are collected from stdout.

Sampling: the default keeps every trace. On busy services lower `otel.samplerArg` (for example `"0.1"`). The parent-based sampler follows the decision of the caller, so a trace that started upstream is either complete or absent.

## Verify

Send a request with a known trace ID and look it up in Tempo:

```bash
trace_id="$(openssl rand -hex 16)"
kubectl -n dev port-forward svc/hello-api 8080:80 &
curl -s -H "traceparent: 00-${trace_id}-$(openssl rand -hex 8)-01" http://127.0.0.1:8080/
kubectl -n tracing port-forward svc/tempo 3200:3200 &
curl -s "http://127.0.0.1:3200/api/v2/traces/${trace_id}" | jq '.trace.resourceSpans[].scopeSpans[].spans[].name'
kubectl -n dev logs deploy/hello-api | jq -c "select(.trace_id == \"${trace_id}\")"
```

`tests/integration/tracing/run.sh` automates this on a throwaway kind cluster (`make integration-tracing`); its README lists what the run proves.

## Grafana correlation

The monitoring chart provisions the links when the datasources are on:

- Logs to traces: the Loki datasource has a derived field that matches `trace_id` in a log line and opens the trace in Tempo.
- Traces to logs: the Tempo datasource searches Loki around the span time, filtered by the trace ID.
- Metrics to traces: the Prometheus datasource links exemplars with the label `trace_id` to Tempo. `hello-api` serves exemplars on its two HTTP metrics in the OpenMetrics format. Prometheus keeps them only when it runs with exemplar storage (`enableFeatures: [exemplar-storage]` in `prometheusSpec`), which the monitoring chart does not set today; until it does, the exemplar link stays inert.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No trace in Tempo, no error in the app log | `otel.enabled` rendered the env vars: `kubectl -n dev get deploy hello-api -o yaml \| grep OTEL_` |
| `opentelemetry error` lines with connection refused or timeouts | The app NetworkPolicy has the egress rule to `tracing` on 4318, and the Tempo pod is ready |
| Trace IDs in logs but no trace | The request was not sampled: the caller sent `traceparent` with flags `00`, or `otel.samplerArg` is below 1 |
| Traces without Kubernetes attributes | `OTEL_RESOURCE_ATTRIBUTES` was overridden in `env`; keep the `k8s.*` keys |
