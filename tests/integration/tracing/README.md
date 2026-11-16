# Tracing integration test (hello-api to Tempo)

Local check of the OpenTelemetry path: a request to `hello-api` with `otel.enabled` produces a server span that Tempo from the `tracing` chart stores and returns, in a throwaway kind cluster with the network policies of an application namespace.

```bash
make integration-tracing
```

Requirements: Docker, kind, kubectl, helm, yq (v4), jq, curl, openssl, python3, git, and network access for the chart and image downloads. About 1.5 GB of free Docker memory. The run deletes its cluster on exit (`KEEP_CLUSTER=1` keeps it) and exits non-zero when any check fails.

Last result (2026-11-16, Tempo 3.1.1 from chart 3.2.1, OpenTelemetry Go SDK 1.47.0, Envoy Gateway CRDs 1.10.0, KEDA CRDs 2.21.0, Kubernetes v1.36.4): 15 checks passed, 0 failed, about two minutes with cached images.

## What the run does

1. Builds the `hello-api` image from `sample-services/hello-api` and loads it into kind cluster `l13-tracing` (single node, `kindest/node:v1.36.4`, pinned by digest). An existing cluster of that name is deleted first.
2. Creates namespaces `tracing` and `dev` with Pod Security `restricted`, and applies to `dev` the `default-deny` and `allow-dns` policies rendered from `helmcharts/system-charts/network-policies`, as the platform does in application namespaces.
3. Installs Tempo from `helmcharts/system-charts/tracing` with `values.yaml` and `values-lab.yaml` (ServiceMonitor off, there is no Prometheus Operator).
4. Installs `hello-api` from its chart with `otel.enabled=true` and the defaults for everything else; the route and the traffic policy are off because there is no Gateway. Charts are copied to a temporary directory first, so `helm dependency build` never writes into the repository.
5. Sends `GET /` with a W3C `traceparent` that carries a random, sampled trace ID, then reads the trace from the Tempo query API.
6. Installs the CRDs of the pinned Envoy Gateway and KEDA charts and sends the rendered `HTTPRoute`, `BackendTrafficPolicy` and `ScaledObject` of `hello-api` (`ci/extras-values.yaml` plus the traffic policy and KEDA switched on) to the API server as a server-side dry run.

## What it proves

- The OTel environment that `helm-common` renders is enough for the SDK in `hello-api` to export over OTLP/HTTP to `tempo.tracing.svc:4318`, through the egress rule of the app NetworkPolicy, in a namespace that otherwise denies all egress except DNS.
- Tempo from the repository chart accepts and serves the trace: one server span `GET /`, child of the caller's span (W3C trace context propagation), with `http.route`, and resource attributes `service.name`, `k8s.namespace.name`, `k8s.pod.name` and `deployment.environment.name` from the downward API and `global.environment`.
- The access log line of the request carries the same `trace_id`, and both HTTP metrics carry an exemplar with that `trace_id` in the OpenMetrics exposition.
- The rendered `BackendTrafficPolicy` and `ScaledObject` pass the OpenAPI schemas and the CEL validation rules of the Envoy Gateway and KEDA CRDs that the platform pins.

## What it does not prove

- Grafana: the Loki derived field, the Tempo traces-to-logs link and the exemplar link are configuration only here. Exemplars also need Prometheus with exemplar storage enabled.
- Envoy behaviour of the traffic policy (timeouts, retries, circuit breaking, rate limiting) and KEDA scaling decisions: no Envoy Gateway or KEDA controller runs.
- Tempo durability, retention and the reference profile storage.

## Findings from the first runs

- Tempo's `/api/v2/traces/<id>` answers 200 with an empty trace until the spans are ingested; the test waits for a span, not for the status code.
- otelhttp 0.72 renames the server span after the matched route but does not set the `http.route` attribute. `hello-api` now sets it in its middleware.
