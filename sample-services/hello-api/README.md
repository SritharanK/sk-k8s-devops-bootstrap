# hello-api

Sample HTTP service that exercises the platform contract: liveness and readiness probes, Prometheus metrics, structured JSON logs, optional OpenTelemetry tracing, graceful shutdown and a non-root distroless image that runs on a read-only root filesystem. It has no business logic and no dependencies on other services.

## Endpoints

All endpoints listen on port 8080 by default.

| Method and path | Response | Purpose |
|---|---|---|
| `GET /` | `200`, JSON `{"service":"hello-api","version":"<version>","message":"Hello from hello-api"}` | Sample payload. `?name=<name>` personalises the message; names longer than 64 characters, with control characters or invalid UTF-8 return `400` with `{"error":"..."}`. |
| `GET /healthz` | `200 ok` while the process runs | Liveness probe. |
| `GET /readyz` | `200 ok`, or `503 shutting down` once shutdown has started | Readiness probe. |
| `GET /metrics` | Prometheus text exposition, or OpenMetrics when the scraper asks for it | Scrape target. |
| anything else | `404` (unknown path) or `405` (known path, wrong method) | |

`GET` routes also answer `HEAD`.

## Configuration

Values are read from the environment and validated at start. Any invalid value stops the process with exit code 1 and a log line that lists every problem.

| Variable | Default | Description |
|---|---|---|
| `HTTP_ADDR` | `:8080` | Listen address, `host:port`. The port must be 1 to 65535. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. |
| `SHUTDOWN_DELAY` | `5s` | Go duration. Time between failing readiness and closing the listener. |
| `SHUTDOWN_TIMEOUT` | `20s` | Go duration. Maximum time to drain in-flight requests. `SHUTDOWN_DELAY + SHUTDOWN_TIMEOUT` must be less than 30s, the pod termination grace period. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Base URL of an OTLP/HTTP collector, for example `http://otel-collector.example.com:4318`. Setting this or the next variable enables tracing. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Full OTLP/HTTP traces URL, for example `http://otel-collector.example.com:4318/v1/traces`. |
| `OTEL_SERVICE_NAME` | `hello-api` | `service.name` resource attribute. |
| `OTEL_RESOURCE_ATTRIBUTES` | unset | Extra resource attributes, `key=value,...`. |
| `OTEL_SDK_DISABLED` | unset | `true` disables tracing even when an endpoint is set. |

The exporter, sampler and batch processor also honour the other standard variables, such as `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_TIMEOUT`, `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` and `OTEL_BSP_*`. Tracing has no service-specific variables. `OTEL_PROPAGATORS` is not read: the propagators are fixed to W3C Trace Context and W3C Baggage. Only the `http/protobuf` protocol is supported; another value in `OTEL_EXPORTER_OTLP_PROTOCOL` logs a warning and is ignored. Without an endpoint no exporter is created and the service makes no outbound connections.

## Observability

Metrics come from a dedicated Prometheus registry:

| Metric | Type | Labels |
|---|---|---|
| `http_requests_total` | counter | `method`, `handler`, `code` |
| `http_request_duration_seconds` | histogram | `method`, `handler` |
| `hello_api_build_info` | gauge, always 1 | `version`, `goversion` |
| `go_*`, `process_*` | Go runtime and process collectors | |

`handler` is the matched route pattern (`/`, `/healthz`, `/readyz`, `/metrics`), never the raw request path. Requests that match no route use `handler="unmatched"`, and methods outside the standard HTTP set use `method="OTHER"`, so client input cannot create new series. The platform SLO rules, rollout analysis, dashboards and autoscaling examples select on `handler` and leave probes and scrapes out of traffic with `handler!~"/healthz|/readyz|/metrics"`.

When a request belongs to a sampled trace, its `http_requests_total` increment and its `http_request_duration_seconds` observation carry an exemplar `{trace_id="<32 hex>"}`, which Grafana shows as a link from the metric to the trace. Exemplars exist only in the OpenMetrics format: `/metrics` returns OpenMetrics when the `Accept` header asks for `application/openmetrics-text` (Prometheus does by default) and the classic text format, without exemplars, otherwise. Prometheus keeps exemplars only when it runs with exemplar storage enabled (`--enable-feature=exemplar-storage`).

Logs are JSON lines on stdout. Each request produces one `request` line with `method`, `route` (the same value as the `handler` label), `path`, `status`, `duration_ms` and `bytes`. Requests to `/healthz`, `/readyz` and `/metrics` are logged at `debug` level and are not traced.

Every log record written with a request context carries `trace_id` and `span_id` (lowercase hex, at the top level of the JSON object) when that context has a valid span context. The log handler adds them, so application code logs with `InfoContext` or `LogAttrs` and does not add them itself. Grafana derives a link to the trace from `trace_id` in Loki.

Incoming trace context is read from the W3C Trace Context (`traceparent`, `tracestate`) and W3C Baggage (`baggage`) headers. When tracing is enabled, every request except probes and scrapes gets a server span named `<method> <route>`, a child of the caller's span when a `traceparent` header is present. When tracing is disabled, an incoming `traceparent` is still extracted: log records then carry the caller's trace id and span id, and the request's metrics carry an exemplar with the caller's trace id when the caller sampled the trace.

## Shutdown sequence

On SIGTERM or SIGINT:

1. `/readyz` starts returning 503 and the service logs `shutdown started`.
2. The listener stays open for `SHUTDOWN_DELAY`, so the readiness probe fails and the pod is removed from Service endpoints and Gateway backends while it still serves traffic.
3. The listener closes and in-flight requests get up to `SHUTDOWN_TIMEOUT` to complete.
4. Buffered spans are flushed (at most 2s) and the process exits 0. If the drain times out, it exits 1.

A second signal during this sequence terminates the process immediately.

## Build and run locally

Requires Go 1.27.

```sh
go test ./...
go run .
curl -s localhost:8080/
curl -s 'localhost:8080/?name=Alice'
curl -s localhost:8080/metrics | grep http_requests_total
```

Set a version at build time with `-ldflags "-X main.version=0.1.0"`; it is logged at start, returned by `GET /` and exposed in `hello_api_build_info`.

The `name` query parameter is the only untrusted input of `GET /`. `FuzzHelloName` in `internal/server/fuzz_test.go` sends arbitrary values through the full handler: the response must be JSON, the name must be accepted exactly when `validateName` accepts it, and it must come back unchanged. `go test ./...` runs its seed inputs; to explore further:

```sh
go test -run '^$' -fuzz '^FuzzHelloName$' -fuzztime 60s ./internal/server
```

A failing input is saved under `internal/server/testdata/fuzz/` and then runs with every `go test` until it is fixed.

Container image:

```sh
docker build --target test .
docker build --build-arg VERSION=0.1.0 -t hello-api:0.1.0 .
docker run --rm --read-only --tmpfs /tmp -p 8080:8080 hello-api:0.1.0
```

The `test` stage runs the unit tests inside the build image. It is not part of the default target, so the second command builds only the runtime image.

The build also accepts `REVISION` (the commit SHA) for the `org.opencontainers.image.revision` label, and builds for the target platform of `docker buildx build --platform`. CI builds the image from this directory as build context.

## Image properties

- Runtime base `gcr.io/distroless/static-debian13:nonroot`, pinned by digest. It contains no shell, package manager or HTTP client.
- Static binary built with `CGO_ENABLED=0`, `-trimpath` and stripped symbols.
- Runs as UID and GID 65532 (`USER 65532:65532`, numeric so `runAsNonRoot` can verify it).
- Needs no writable path and no Linux capabilities; it runs with a read-only root filesystem, all capabilities dropped and `no-new-privileges`. A writable `/tmp` is mounted by convention.
- `HEALTHCHECK` runs `/hello-api -healthcheck`, which calls `GET /healthz` on 127.0.0.1 at the `HTTP_ADDR` port with a 2s timeout. Kubernetes ignores this instruction and uses the chart probes.
- OCI labels: `title`, `description`, `source`, `licenses`, `version`, `revision` and `base.name`.

## Deployment

The chart in `helmcharts/app-charts/hello-api` deploys the image on port 8080 with:

- liveness probe `GET /healthz` and readiness probe `GET /readyz`;
- a restricted security context: UID 65532, read-only root filesystem with an `emptyDir` at `/tmp`, all capabilities dropped, `RuntimeDefault` seccomp;
- `LOG_LEVEL`, `SHUTDOWN_DELAY` and `SHUTDOWN_TIMEOUT` as environment variables, with `terminationGracePeriodSeconds: 30`;
- an optional ServiceMonitor that scrapes `/metrics` on port 8080.

See the chart README for its values. To enable tracing, add `OTEL_EXPORTER_OTLP_ENDPOINT` to the chart `env` list.

## Layout

| Path | Content |
|---|---|
| `main.go` | Flags, signal handling, wiring, `-healthcheck` mode. |
| `internal/config` | Environment parsing and validation. |
| `internal/server` | Handlers, readiness state, metrics, access log middleware, graceful shutdown, health check client. |
| `internal/telemetry` | OpenTelemetry tracer provider and propagator setup, log handler that adds `trace_id` and `span_id`. |
