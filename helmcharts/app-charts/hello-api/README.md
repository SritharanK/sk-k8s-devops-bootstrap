# hello-api

Sample HTTP service that exercises the platform workload contract.

Chart version 0.2.0, app version 0.1.0, depends on helm-common 2.1.0.

Deploys the `hello-api` sample service from `sample-services/hello-api`. All objects are rendered by the [helm-common](../../helm-common/README.md) library; the files in `templates/` only include its named templates.

## What it renders

| Object | When |
|---|---|
| Deployment, Service, ServiceAccount (token not mounted) | Always |
| HTTPRoute `hello-api.<env>.<domain>` on Gateway `platform` (`envoy-gateway-system`, listener `https`) | `route.enabled` (on) |
| NetworkPolicy allowing port `http` from `envoy-gateway-system` (route on) and from `monitoring` (ServiceMonitor on), and egress to `tracing` on 4318 (OpenTelemetry on) | `networkPolicy.enabled` (on) |
| BackendTrafficPolicy on the HTTPRoute: connect and request timeouts, retries only for requests that never reached the service (plus 503), circuit breaker; local rate limit when `trafficPolicy.rateLimit.enabled` | `trafficPolicy.enabled` (on) |
| PodDisruptionBudget (`maxUnavailable: 1`) | At least two replicas |
| HorizontalPodAutoscaler | `autoscaling.enabled` |
| KEDA ScaledObject on the request rate from Prometheus, an alternative to the HPA | `keda.enabled` (needs the `keda` toolchain and the ServiceMonitor) |
| `OTEL_*` variables for trace export to Tempo | `otel.enabled` (needs the `tracing` toolchain) |
| ServiceMonitor | `metrics.serviceMonitor.enabled` (needs the Prometheus Operator CRDs) |
| Argo Rollouts Rollout with `workloadRef`, canary Service | `rollout.enabled` (needs the Argo Rollouts controller and its Gateway API plugin) |

## Environment values

Argo CD applies `values.yaml`, then `envs/<env>/hello-api/values.yaml`, and passes `global.environment`, `global.domain`, `global.cluster` and `global.profile` through the Application.

- The environment files hold only `image.tag` and `image.digest`, which promotion changes. A digest pins the image; the tag is then informational.
- The route hostname is derived as `hello-api.<global.environment>.<global.domain>`, so the same environment file works on clusters with different domains.
- Sizing per environment lives in this chart under `environments.<env>`: dev runs one replica, stage two, prod autoscales from two to four.

`ci/` holds sample values with the same shape (image keys plus the `global` block that Argo CD injects). They are used for lint and render checks only.

## Checks

```bash
helm dependency build helmcharts/app-charts/hello-api
for f in helmcharts/app-charts/hello-api/ci/*-values.yaml; do
  helm lint --strict helmcharts/app-charts/hello-api -f "$f"
  helm template hello-api helmcharts/app-charts/hello-api -n dev -f "$f" >/dev/null
done
```

## Values

The table lists the values this chart sets. Every other helm-common key keeps its library default.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| containerPorts | list | `[{"containerPort":8080,"name":"http","protocol":"TCP"}]` | Container ports. The service listens on 8080. |
| env | list | `[{"name":"LOG_LEVEL","value":"info"},{"name":"SHUTDOWN_DELAY","value":"5s"},{"name":"SHUTDOWN_TIMEOUT","value":"20s"},{"name":"GOMEMLIMIT","valueFrom":{"resourceFieldRef":{"resource":"limits.memory"}}}]` | Service settings. SHUTDOWN_DELAY plus SHUTDOWN_TIMEOUT stays below terminationGracePeriodSeconds; GOMEMLIMIT follows the memory limit. |
| environments | object | `{"prod":{"autoscaling":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":300}},"enabled":true,"maxReplicas":4,"minReplicas":2,"targetCPUUtilizationPercentage":75},"resources":{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"48Mi"}}},"stage":{"replicaCount":2}}` | Per-environment deltas, applied when global.environment matches. They take precedence over the values above and over the environment files, which hold only image.tag and image.digest. |
| image.digest | string | `""` | Image digest. When set, the image is pulled by digest. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.registry | string | `"ghcr.io/your-org"` | Registry prefix. Replaced by global.imageRegistry when the Application passes it. |
| image.repository | string | `"hello-api"` | Image name, as built from sample-services/hello-api. |
| image.tag | string | `""` | Image tag. Empty uses the chart appVersion. Promotion sets tag and digest in the environment files. |
| keda.enabled | bool | `false` | Scale on the request rate with a KEDA ScaledObject. Requires the `keda` toolchain and the ServiceMonitor (metrics.serviceMonitor.enabled), so that Prometheus has the metric. An alternative to `autoscaling`: prod enables autoscaling under environments.prod, so enabling keda for prod also needs `environments.prod.autoscaling.enabled: false`. |
| keda.prometheus.query | string | Rate of `http_requests_total` over 2m for this release, without `/healthz`, `/readyz` and `/metrics` | Requests per second to the service, without the probe and metrics endpoints. Rendered through tpl. |
| keda.prometheus.threshold | string | `"20"` | Target requests per second per replica. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/healthz","port":"http"},"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe on the process health endpoint. |
| metrics.serviceMonitor.enabled | bool | `false` | Enable where the Prometheus Operator CRDs are installed. |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.labels | object | `{"release":"monitoring"}` | Must match the Prometheus serviceMonitorSelector. |
| metrics.serviceMonitor.path | string | `"/metrics"` |  |
| metrics.serviceMonitor.port | string | `"http"` | Service port and path that serve the metrics. |
| metrics.serviceMonitor.scrapeTimeout | string | `"10s"` |  |
| networkPolicy.enabled | bool | `true` | Render the app NetworkPolicy. It allows the Gateway data plane to reach port http because the route is enabled, and Prometheus once the ServiceMonitor is enabled. Egress stays with the platform default-deny and DNS policies. |
| networkPolicy.gatewayNamespace | string | `"envoy-gateway-system"` | Namespace of the Gateway data plane. |
| networkPolicy.monitoringNamespace | string | `"monitoring"` | Namespace of Prometheus. |
| otel.enabled | bool | `false` | Export traces over OTLP to Tempo. Requires the `tracing` toolchain. Enable it here, or per environment with `environments.<env>.otel.enabled: true`; the environment files under envs/ hold only image.tag and image.digest. Adds the `OTEL_*` variables after env and allows egress to the tracing namespace on 4318. |
| otel.endpoint | string | `"http://tempo.tracing.svc:4318"` | OTLP over HTTP to Tempo in the tracing namespace. |
| podDisruptionBudget.enabled | bool | `true` | Rendered only when at least two replicas run. |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context required by the workload policies. Matches the distroless nonroot user. |
| readinessProbe | object | `{"failureThreshold":2,"httpGet":{"path":"/readyz","port":"http"},"periodSeconds":5,"timeoutSeconds":2}` | Readiness probe; turns unready as soon as shutdown starts. |
| replicaCount | int | `1` | Replica count for dev. Stage and prod are set under `environments`. |
| resources | object | `{"limits":{"cpu":"250m","memory":"96Mi"},"requests":{"cpu":"25m","memory":"32Mi"}}` | Requests and limits; the workload policies require both for CPU and memory. |
| rollout.analysis.enabled | bool | `true` |  |
| rollout.analysis.templateName | string | `"success-rate"` |  |
| rollout.enabled | bool | `false` | Enable where the Argo Rollouts controller and the Gateway API plugin are installed. |
| rollout.trafficRouting.gatewayAPI.enabled | bool | `true` |  |
| route.enabled | bool | `true` | Expose the service through the platform Gateway. |
| route.hostnames | list | `[]` | Empty derives hello-api.<global.environment>.<global.domain>, which Argo CD passes per cluster and environment. |
| route.parentRefs[0].name | string | `"platform"` |  |
| route.parentRefs[0].namespace | string | `"envoy-gateway-system"` |  |
| route.parentRefs[0].sectionName | string | `"https"` |  |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context required by the workload policies. |
| service.ports[0].name | string | `"http"` |  |
| service.ports[0].port | int | `80` |  |
| service.ports[0].protocol | string | `"TCP"` |  |
| service.ports[0].targetPort | string | `"http"` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.automount | bool | `false` | The service does not call the Kubernetes API, so no token is mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated ServiceAccount. |
| terminationGracePeriodSeconds | int | `30` | Grace period; covers SHUTDOWN_DELAY (5s) and SHUTDOWN_TIMEOUT (20s). |
| tmpVolume | object | `{"enabled":true,"mountPath":"/tmp","sizeLimit":"16Mi"}` | Writable /tmp for the read-only root filesystem. |
| topologySpread.enabled | bool | `true` | Prefer spreading replicas across nodes. |
| topologySpread.maxSkew | int | `1` |  |
| topologySpread.topologyKey | string | `"kubernetes.io/hostname"` |  |
| topologySpread.whenUnsatisfiable | string | `"ScheduleAnyway"` |  |
| trafficPolicy.enabled | bool | `true` | Envoy Gateway BackendTrafficPolicy on the route, with the helm-common defaults: connect and request timeouts, retries only for requests that never reached the service (plus 503), and a circuit breaker. Envoy Gateway is a core component, so this adds no runtime component. |
| trafficPolicy.rateLimit.enabled | bool | `false` | Local rate limit per Envoy replica (429 above the limit). Off. |
