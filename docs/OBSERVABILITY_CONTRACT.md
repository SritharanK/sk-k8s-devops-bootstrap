# Observability contract

Minimal contract for workloads on this platform: what every service is expected to expose for health and optional metrics. No full Prometheus stack required; this defines the **contract** so operators and future tooling know what to expect.

---

## Required

| Contract | Description | Where enforced |
|----------|-------------|----------------|
| **Readiness probe** | Every app pod must define a `readinessProbe`. Used by Kubernetes to remove the pod from Service endpoints until it is ready. | helm-common chart supports `readinessProbe` in values; Kyverno policy `require-readiness-probe` enforces it in prod/dev. |
| **Liveness probe** | Every app pod should define a `livenessProbe` so the kubelet can restart unhealthy containers. | helm-common chart supports `livenessProbe` in values; recommended for all apps. |

Apps using helm-common set these in their values, for example:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 10
```

---

## Recommended: health endpoint

- **Path:** `/health` (or `/ready`, `/healthz` — document in app README).
- **Behaviour:** HTTP 200 when the app is ready to accept traffic; non-2xx or timeout when not.
- **Use:** Point readinessProbe (and livenessProbe) at this endpoint.

**`/health` is a convention; `readinessProbe` is the enforced control.** No platform-level enforcement of the path. Apps that cannot expose HTTP may use `exec` or `tcpSocket` probes.

---

## Optional: metrics endpoint

- **Path:** `/metrics` (Prometheus exposition format) or app-specific path.
- **Use:** When a metrics stack (e.g. Prometheus, kube-prometheus-stack) is installed, scrapers can target this endpoint. Not required for the minimal platform.

---

## Summary

| Item | Required | Enforced / documented |
|------|----------|------------------------|
| readinessProbe | Yes | Kyverno (prod/dev) + helm-common |
| livenessProbe | Recommended | helm-common, documented here |
| /health (or equivalent) | Recommended | Convention; use for probes |
| /metrics | Optional | For future observability stack |

This keeps the platform contract clear without mandating a full observability stack from day one.
