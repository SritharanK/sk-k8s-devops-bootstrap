# Tune backend traffic and scale on request rate

This guide enables and tunes the Envoy Gateway BackendTrafficPolicy that `helm-common` renders for an application route, and replaces the CPU-based HorizontalPodAutoscaler with KEDA where the request rate is the better scaling signal. It is for authors of application charts; `helmcharts/app-charts/hello-api` is the example. Every key is listed in the generated chart README and explained in the [helm-common values reference](../reference/helm-common-values.md).

## Traffic policy

### Enable the policy

The policy attaches to the HTTPRoute of the chart, so the route must be on. The render fails with `trafficPolicy.enabled` and `route.enabled: false`.

```yaml
route:
  enabled: true
trafficPolicy:
  enabled: true
```

The chart renders one `BackendTrafficPolicy` (`gateway.envoyproxy.io/v1alpha1`) named after the release, with `targetRefs` pointing at its HTTPRoute. It applies to every backend of that route, including the canary Service when an Argo Rollout shifts traffic through the Gateway API. Envoy Gateway is a core toolchain, so the policy adds no runtime component. `hello-api` enables it with the library defaults and the rate limit off.

### What the defaults mean

| Key | Default | Effect |
| --- | --- | --- |
| `timeout.tcp.connectTimeout` | `5s` | Time Envoy waits to open a connection to a pod. A pod that does not accept in time counts as a connect failure. |
| `timeout.http.requestTimeout` | `15s` | Time until the complete response is received, retries included. Envoy answers 504 after it. |
| `retry.numRetries` | `2` | At most two retries after the first attempt. |
| `retry.retryOn.triggers` | `connect-failure`, `refused-stream`, `reset-before-request`, `retriable-status-codes` | Retry only when the request never reached the application, or on a status code listed below. |
| `retry.retryOn.httpStatusCodes` | `[503]` | Status codes retried through `retriable-status-codes`. |
| `retry.perRetry.timeout` | `5s` | Timeout of a single attempt. |
| `retry.perRetry.backOff` | `100ms` to `1s` | Jittered exponential back-off between attempts. |
| `circuitBreaker.maxConnections` | `1024` | Connections to the backend, per Envoy replica. |
| `circuitBreaker.maxPendingRequests` | `256` | Requests waiting for a connection, per Envoy replica. |
| `circuitBreaker.maxParallelRequests` | `1024` | Requests in flight, per Envoy replica. |
| `circuitBreaker.maxParallelRetries` | `10` | Retries in flight, per Envoy replica. Caps retry storms during an outage. |

### Retries and idempotency

Envoy retries a request without knowing what the handler does. The default triggers fire only when the request never reached the application: the connection failed, the HTTP/2 stream was refused, or the connection was reset before the request was sent. The 503 retry relies on the convention that a service answering 503 did not process the request. Keep that true in your service, and a `POST` is not applied twice with these defaults.

Add `5xx`, `reset` or `gateway-error` only when every operation on the route is idempotent, or when the API uses idempotency keys. Maps merge key by key but lists replace, so repeat the triggers you keep:

```yaml
trafficPolicy:
  retry:
    retryOn:
      triggers: [connect-failure, refused-stream, reset-before-request, retriable-status-codes, 5xx]
```

Set `trafficPolicy.retry.numRetries: 0` to turn retries off.

### Timeouts

`route.timeouts.request` (Gateway API) also sets a request timeout on the same route. Set the request timeout in one place only, either there or in `trafficPolicy.timeout.http.requestTimeout`. Keep it above the slowest legitimate response and below the timeout of the calling client, so the client sees the 504 from the Gateway rather than its own timeout.

### Circuit breaker

Every Envoy replica of the platform Gateway keeps its own counters: the lab profile runs one replica, the reference profile two. The effective limit for the route is the threshold multiplied by the number of Envoy replicas. A request above a threshold fails fast with 503 and the response header `x-envoy-overloaded`, instead of queueing. Lower the thresholds to protect a backend with a known capacity, for example a service that holds one database connection per request.

### Local rate limit

```yaml
trafficPolicy:
  rateLimit:
    enabled: true
    requests: 100
    unit: Second
```

The chart adds one local rate limit rule for every request to the route. Each Envoy replica keeps its own bucket and answers 429 above the limit without calling the service, so two Envoy replicas admit up to twice `requests` per `unit`. The rule has no client selector: all clients share the limit. Per-client limits need the global rate limit of Envoy Gateway, which `helm-common` does not render.

### Verify the policy

```bash
kubectl -n dev get backendtrafficpolicy hello-api
kubectl -n dev get backendtrafficpolicy hello-api \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}'
for i in $(seq 1 300); do
  curl -sk -o /dev/null -w '%{http_code}\n' https://hello-api.dev.localtest.me/
done | sort | uniq -c
```

`Accepted` must be `True`. With the rate limit on, the loop shows 429 responses once the limit is reached.

## KEDA instead of the HPA

### When to use KEDA

CPU is a weak proxy for an HTTP service that waits on I/O. KEDA scales on a Prometheus query, typically the request rate, and can scale to zero. KEDA creates and owns an HPA named `keda-hpa-<fullname>` for the target, so it replaces the HPA of the chart: `keda.enabled` and `autoscaling.enabled` together fail the render. The ScaledObject targets the Rollout when `rollout.enabled`, else the Deployment, and neither workload sets `replicas`.

### Prerequisites

- The `keda` toolchain: `toolchains.keda.enabled: true` in `clusters/<name>/cluster.yaml`.
- The `monitoring` toolchain. KEDA queries `http://monitoring-prometheus.monitoring.svc:9090` by default (`keda.prometheus.serverAddress`).
- `metrics.serviceMonitor.enabled: true`, so Prometheus scrapes the series the query reads.

### Enable KEDA

`hello-api` carries the query and the threshold; enable it and switch the prod HPA off, because prod enables `autoscaling` under `environments.prod`:

```yaml
metrics:
  serviceMonitor:
    enabled: true
keda:
  enabled: true
environments:
  prod:
    autoscaling:
      enabled: false
    keda:
      minReplicaCount: 2
      maxReplicaCount: 4
```

Without the `environments.prod.autoscaling.enabled: false` line the prod render fails with `autoscaling.enabled and keda.enabled are mutually exclusive`. To enable KEDA for one environment only, set `environments.<env>.keda.enabled: true` instead.

### Query and threshold

```yaml
keda:
  prometheus:
    query: 'sum(rate(http_requests_total{namespace="{{ .Release.Namespace }}",service="{{ include "common.names.fullname" . }}",handler!~"/healthz|/readyz|/metrics"}[2m]))'
    threshold: "20"
```

- The query returns one value for the whole workload, so aggregate with `sum`. It is rendered through `tpl`, which fills in the release namespace and the full name. The probe and metrics handlers are excluded so kubelet and Prometheus traffic never holds replicas up.
- The trigger uses `metricType: AverageValue`: the HPA divides the query result by the current replica count and compares it with `threshold`. The desired count is the result divided by the threshold, rounded up, within `minReplicaCount` and `maxReplicaCount`. For `hello-api`, 100 requests per second with a threshold of 20 gives 5 replicas.
- `threshold` and `activationThreshold` are strings: the ScaledObject CRD types every trigger metadata value as a string, and the chart schema rejects numbers.
- `keda.triggers` replaces the Prometheus trigger with any KEDA trigger list, for example a cron or queue scaler.

### Scale to zero

`keda.idleReplicaCount: 0` with `keda.minReplicaCount` of at least 1 scales the workload to zero after `keda.cooldownPeriod` (300 s) without activity. Check these points first:

- A metric produced by the application cannot wake it: at zero there is no pod to count requests, so the query stays at 0. Use a trigger whose source exists without the pods, such as a queue length or a metric of the Gateway proxies.
- With no ready pod the Service has no endpoints and Envoy answers 503. The retry back-off of the traffic policy is far shorter than a pod start, so clients must tolerate errors during a cold start.
- The first pod receives traffic only after its readiness probe passes; startup time adds to the latency of the first requests.
- The chart renders no PodDisruptionBudget when the minimum can be zero.

### Verify scaling

```bash
kubectl -n dev get scaledobject hello-api
kubectl -n dev describe scaledobject hello-api
kubectl -n dev get hpa keda-hpa-hello-api
```

The ScaledObject must report `READY True`; `ACTIVE` is `True` while the query is above `activationThreshold`. The `describe` events show query errors, for example an unreachable Prometheus or a query that returns no value. `kubectl get hpa` shows the current value against the target per replica. Switching between the HPA and KEDA deletes one HPA and creates the other; the workload keeps its current replica count in between.
