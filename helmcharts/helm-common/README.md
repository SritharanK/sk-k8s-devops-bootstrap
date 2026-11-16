# helm-common

Version 2.1.0, type library.

Library chart that renders HTTP workloads with secure defaults for the platform policies.

`helm-common` is a Helm library chart. It renders the Kubernetes objects of an HTTP workload (Deployment, Service, ServiceAccount, HTTPRoute, HPA, PDB, NetworkPolicy, ServiceMonitor, Argo Rollouts Rollout, ConfigMaps, a PVC, an Envoy Gateway BackendTrafficPolicy and a KEDA ScaledObject) with defaults that pass the platform admission policies. Application charts keep only their values and one thin template per object kind.

## Consuming the library

Declare the dependency without an alias. Helm stores the library defaults under the dependency name (`.Values "helm-common"`), and the templates look for them there; with an alias the render fails.

```yaml
# Chart.yaml of the application chart
apiVersion: v2
name: hello-api
type: application
version: 0.1.0
appVersion: "1.4.2"
dependencies:
  - name: helm-common
    version: 2.1.0
    repository: file://../helm-common
```

Run `helm dependency build` after changing the dependency. Pin an exact version, never a range.

Set the library keys at the top level of the application values, not under a `helm-common:` key:

```yaml
image:
  registry: registry.example.com/your-org
  repository: hello-api
route:
  enabled: true
metrics:
  serviceMonitor:
    enabled: true
```

Then add one thin template per kind:

```yaml
# templates/deployment.yaml
{{ include "common.deployment" . }}
```

| Template | Object | Rendered when |
|----------|--------|---------------|
| `common.deployment` | apps/v1 Deployment | always |
| `common.service` | v1 Service (plus `<fullname>-canary` with Gateway API traffic routing) | `service.enabled` |
| `common.serviceaccount` | v1 ServiceAccount | `serviceAccount.create` |
| `common.httproute` | gateway.networking.k8s.io/v1 HTTPRoute | `route.enabled` |
| `common.backendtrafficpolicy` | gateway.envoyproxy.io/v1alpha1 BackendTrafficPolicy | `trafficPolicy.enabled` (needs `route.enabled`) |
| `common.hpa` | autoscaling/v2 HorizontalPodAutoscaler | `autoscaling.enabled` |
| `common.scaledobject` | keda.sh/v1alpha1 ScaledObject | `keda.enabled` (not together with `autoscaling.enabled`) |
| `common.pdb` | policy/v1 PodDisruptionBudget | `podDisruptionBudget.enabled` and minimum replicas above 1 |
| `common.networkpolicy` | networking.k8s.io/v1 NetworkPolicy | `networkPolicy.enabled` and at least one allow rule |
| `common.servicemonitor` | monitoring.coreos.com/v1 ServiceMonitor | `metrics.serviceMonitor.enabled` |
| `common.rollout` | argoproj.io/v1alpha1 Rollout | `rollout.enabled` |
| `common.configmap` | v1 ConfigMap, one per `configMaps` entry | `configMaps` is not empty |
| `common.pvc` | v1 PersistentVolumeClaim | `persistence.enabled` and no `existingClaim` |
| `common.all` | all of the above, separated by `---` | per object, as above |

A chart can use `common.all` from a single template file instead of one file per kind. A disabled object emits nothing, not even a document separator.

Copy `values.schema.json` into the application chart so Helm validates the values before rendering. In the copy, set the top-level `additionalProperties` to `false` and add `helm-common` as an allowed property (`global` is already defined). `helmcharts/app-charts/hello-api/values.schema.json` is an example.

## Values merge

Every template builds its own values before rendering: it takes a copy of the library defaults and merges the application values over it. The Sprig `default` function is not used for booleans or numbers, so `false` and `0` are never replaced by a default.

Precedence, lowest first:

1. library defaults (`values.yaml` of this chart)
2. application values: the chart `values.yaml`, environment value files, `--set`, Argo CD `valuesObject`
3. `environments.<global.environment>`, when that entry exists

Merge rules, the same at every level:

- maps merge key by key, recursively
- lists replace the default list completely (for example `env`, `containerPorts`, `route.parentRefs`)
- scalars replace; `false` and `0` are kept
- `null` removes the key (see the limits below)
- probes: when `livenessProbe`, `readinessProbe` or `startupProbe` sets a handler (`httpGet`, `tcpSocket`, `grpc`, `exec`), the default handlers of the other types are dropped. `livenessProbe: {tcpSocket: {port: http}}` therefore replaces the default `httpGet` and keeps the default timings, while `livenessProbe: {httpGet: {path: /livez}}` keeps the default port. A probe that ends up empty is not rendered.

`null` follows Helm's own coalescing, which runs before the library sees the values:

- `null` in a value file, `--set` or Argo CD `valuesObject` reaches the library and removes the default, but only for a key that the application chart's own `values.yaml` does not define. When the application `values.yaml` defines the key, Helm deletes it first and the library default comes back.
- `null` written in the application chart's own `values.yaml` is dropped by Helm and has no effect. This includes `null` inside `environments` in that file.
- Prefer explicit values where they exist (`false`, `0`, `{}`, `[]`); use `null` only for fields that have no neutral value, such as `podSecurityContext.fsGroup`.

The `environments` key is removed from the merged values and never reaches a rendered object.

## Global values and per-environment overrides

Argo CD passes `global.environment` (dev, stage or prod), `global.domain`, `global.cluster` and `global.profile` to every application. Environment value files then only carry `image.tag` and `image.digest`.

`environments` holds partial value trees keyed by environment name. The entry that matches `global.environment` is merged last:

```yaml
replicaCount: 1
environments:
  prod:
    replicaCount: 3
    autoscaling:
      enabled: true
  dev:
    tmpVolume:
      medium: Memory
```

An environment without an entry leaves the values unchanged.

When `route.enabled` is true and `route.hostnames` is empty, the HTTPRoute gets one hostname: `<fullname>.<global.environment>.<global.domain>`, for example `hello-api.dev.localtest.me`. The render fails when either global value is missing or empty. Explicit `route.hostnames` always win.

## Secure defaults and the workload policies

The defaults meet the platform workload policies without any application values:

| Requirement | Default |
|-------------|---------|
| Non-root user | `runAsNonRoot: true` at pod and container level, UID and GID 65532, `fsGroup: 65532` |
| No privilege escalation | `allowPrivilegeEscalation: false` |
| No Linux capabilities | `capabilities.drop: [ALL]` |
| Seccomp | `RuntimeDefault` at pod and container level |
| Read-only root filesystem | `readOnlyRootFilesystem: true`, with an emptyDir at `/tmp` (64Mi) for temporary files |
| Requests and limits | CPU and memory requests and limits are set |
| Health checks | liveness (`/healthz`) and readiness (`/readyz`) probes on the `http` port |
| API token | `automountServiceAccountToken: false` on the ServiceAccount and the pod |
| Immutable image | the tag `latest` fails the render; a digest can pin the image |

Security contexts are rendered as given, so an opt-out such as `readOnlyRootFilesystem: false` or `runAsNonRoot: false` renders exactly like that. The admission policies decide whether the opt-out is allowed; the chart does not hide it.

## Image reference

- `image.repository` is required and must not contain a tag or digest. It is either an image name or a full path.
- The registry prefix is `global.imageRegistry` when the Application passes it, else `image.registry`. It is prepended only when `image.repository` does not start with a registry host (a first path segment that contains `.` or `:`, or equals `localhost`), so a full path in an environment file still works.
- The resulting path must be lowercase, as OCI repository names require; uppercase placeholders such as `YOUR_ORG` fail the render.
- With `image.digest` set, the image renders as `repository@sha256:...` and `image.tag` is ignored. The digest must match `sha256:` followed by 64 lowercase hex characters.
- Without a digest, the image renders as `repository:tag`, where the tag is `image.tag` or else the application chart `appVersion`.
- The tag `latest` (any letter case) fails the render, and so does an empty tag with an empty `appVersion`.
- The label `app.kubernetes.io/version` is the image tag, or else `appVersion`, reduced to the characters that are valid in a label value. It is omitted when both are empty.

## Argo Rollouts

`rollout.enabled` renders a Rollout that references the Deployment with `workloadRef`. The Deployment keeps the pod template; the Rollout owns the pods.

- The Deployment renders with `replicas: 0` and the Rollout with `replicas: replicaCount`.
- With autoscaling or KEDA enabled, neither object sets `replicas` and the HPA or the ScaledObject targets the Rollout (`argoproj.io/v1alpha1`, kind `Rollout`).
- `rollout.workloadRef.scaleDown` (`never`, `onsuccess`, `progressively`) tells the Rollouts controller how to scale the referenced Deployment.
- The canary runs `rollout.steps` and, when `rollout.analysis.enabled`, a background analysis with the ClusterAnalysisTemplate `rollout.analysis.templateName` (default `success-rate`) from `rollout.analysis.startingStep`.
- With `rollout.trafficRouting.gatewayAPI.enabled`, the chart also renders the Service `<fullname>-canary` (label `app.kubernetes.io/component: canary`), the HTTPRoute gets two backendRefs (stable at weight 100, canary at weight 0), and the Rollout configures the `argoproj-labs/gatewayAPI` plugin with that HTTPRoute. The HTTPRoute is the one rendered by this chart, or `rollout.trafficRouting.gatewayAPI.httpRoute` when the route lives elsewhere.

Migration: when a running workload enables the Rollout without autoscaling, Argo CD applies `replicas: 0` to the Deployment at the same sync, so the old pods stop before the Rollout pods are ready. Enable the Rollout before the application takes production traffic, or accept a short gap. With autoscaling enabled the Deployment has no `replicas` in its manifest, so the existing pods stay until the Rollouts controller scales the Deployment down according to `scaleDown`.

## ServiceMonitor

`metrics.serviceMonitor.enabled` renders a ServiceMonitor for the primary Service. Its labels include `metrics.serviceMonitor.labels`, by default `release: monitoring`, which must match the `serviceMonitorSelector` of the Prometheus instance. The selector excludes Services labelled `app.kubernetes.io/component: canary`, so the pods are not scraped twice during a canary.

## NetworkPolicy

The platform applies a default-deny policy and a DNS egress policy to every application namespace. The workload owns its allow rules, and the NetworkPolicy rendered by this chart adds to the platform policies (NetworkPolicies are additive):

- `route.enabled`: ingress from the namespace `networkPolicy.gatewayNamespace` (default `envoy-gateway-system`) to the targetPort of the first `service.ports` entry, with that entry's protocol (default TCP). Without a targetPort, the service port itself is used.
- `metrics.serviceMonitor.enabled`: ingress from the namespace `networkPolicy.monitoringNamespace` (default `monitoring`) to the targetPort of the service port named `metrics.serviceMonitor.port`. The render fails when no service port has that name.
- `networkPolicy.extraIngress`: further ingress rules, appended as given.
- `otel.enabled` with `otel.networkPolicy.namespace` (default `tracing`): egress to that namespace on TCP `otel.networkPolicy.port` (default 4318), the OTLP collector.
- `networkPolicy.egress`: egress rules as given, after the collector rule. `Egress` is added to `policyTypes` only when there is an egress rule; DNS stays covered by the platform policy.

`policyTypes` always contains `Ingress`. The policy selects the pods by the selector labels, which also covers the Rollout pods. Nothing is rendered when `networkPolicy.enabled` is false, or when there is no ingress rule and no egress rule.

## Traffic policy

`trafficPolicy.enabled` renders an Envoy Gateway BackendTrafficPolicy that targets the HTTPRoute of the chart, so it also covers the canary backend of a Rollout. The defaults set a 5s connect timeout and a 15s request timeout, retry twice only for requests that never reached the application (`connect-failure`, `refused-stream`, `reset-before-request`) or that got a 503, and cap connections and pending requests with a circuit breaker. `trafficPolicy.rateLimit.enabled` adds a local rate limit (429 above the limit). Circuit breaker and rate limit count per Envoy replica. `route.timeouts` also sets a request timeout on the route; set one of the two. The [traffic and scaling how-to](../../docs/how-to/traffic-and-scaling.md) explains the defaults and the KEDA alternative.

## KEDA

`keda.enabled` renders a KEDA ScaledObject for the Deployment, or for the Rollout when `rollout.enabled`. KEDA creates and owns the HPA, so `keda.enabled` and `autoscaling.enabled` together fail the render, and neither workload sets `replicas`. Without `keda.triggers`, one Prometheus trigger is built from `keda.prometheus`: `query` (required, rendered through `tpl`), `threshold` per replica (`metricType: AverageValue`) and the optional `activationThreshold`. `keda.idleReplicaCount: 0` scales to zero when no trigger is active and must stay below `keda.minReplicaCount`.

## OpenTelemetry

`otel.enabled` appends the OpenTelemetry SDK variables to the container env, after `env`: the pod, namespace and node names from the downward API, `OTEL_SERVICE_NAME` (the full name unless `otel.serviceName` is set), the OTLP endpoint and protocol, traces only (`OTEL_METRICS_EXPORTER` and `OTEL_LOGS_EXPORTER` are `none`), the sampler, the propagators and `OTEL_RESOURCE_ATTRIBUTES` with the Kubernetes attributes, `service.version` and `deployment.environment.name`. A variable whose name is already in `env` is not added, because Argo CD applies server-side and a duplicate env name fails the apply.

## Secrets

The chart never renders a Secret. Create Secrets with Sealed Secrets or External Secrets and reference them:

- `secretMounts` mounts an existing Secret as a read-only volume
- `envFrom` with `secretRef` loads all keys as environment variables
- `env` with `valueFrom.secretKeyRef` loads a single key

## Other rules

- PodDisruptionBudget: rendered only when the minimum replica count is above 1 (`autoscaling.minReplicas` with autoscaling; `keda.idleReplicaCount` when set, else `keda.minReplicaCount`, with KEDA; else `replicaCount`). With one replica a PDB either blocks node drains or protects nothing. Set exactly one of `maxUnavailable` and `minAvailable`.
- Persistence: `ReadWriteOnce` and `ReadWriteOncePod` fail the render when more than one pod can run (`replicaCount` above 1, autoscaling with `maxReplicas` above 1, KEDA with `maxReplicaCount` above 1, or a Rollout).
- ConfigMaps: each `configMaps` entry renders `<fullname>-<key>`. The pod template carries `checksum/config`, a hash of the data, so a data change rolls the pods.
- Selectors use only `app.kubernetes.io/name` and `app.kubernetes.io/instance`. Every object is rendered in the release namespace.

## Versioning

The chart follows semantic versioning:

- major: a breaking change to the values interface or to the rendered output (a renamed or removed key, a changed default, a changed object name or selector)
- minor: a new optional key or object that renders nothing until enabled
- patch: a fix that does not change the output for valid values

Application charts pin an exact version.

## Tests

The test chart in `tests/chart` renders every template through a thin file per kind. It has no `values.schema.json`, so the `fail` paths of the templates are reachable. The suites use helm-unittest.

```sh
helm dependency build helmcharts/helm-common/tests/chart
docker run --rm --network none \
  -v "$PWD/helmcharts:/apps/helmcharts:ro" \
  helmunittest/helm-unittest:4.3.0-1.2.1@sha256:28ea86c3e0b07f501f0c2e9c08b9f41e240f4a4b571cb5106b36cf0f0607e989 \
  helmcharts/helm-common/tests/chart
```

Run it from the repository root. `tests/chart/tests/__snapshot__/` is kept in git because helm-unittest creates that directory on every run and the mount is read-only; the suites use no snapshots.

Lint and schema checks:

```sh
helm lint helmcharts/helm-common
helm lint --strict helmcharts/helm-common/tests/chart
helm template t helmcharts/helm-common/tests/chart -n dev \
  -f helmcharts/helm-common/tests/chart/ci/everything-values.yaml \
  | kubeconform -strict -summary -kubernetes-version 1.36.0 \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

`tests/chart/ci/everything-values.yaml` enables every optional object except the KEDA ScaledObject, which excludes the HPA, and is also used by the `common.all` suite.

Regenerate this README after a change to `values.yaml` or `README.md.gotmpl`:

```sh
helm-docs --chart-search-root helmcharts/helm-common --chart-to-generate helmcharts/helm-common --template-files README.md.gotmpl
```

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Sritharan K |  |  |

## Source Code

- <https://github.com/SritharanK/sk-k8s-devops-bootstrap/tree/main/helmcharts/helm-common>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| args | list | `[]` | Container arguments. |
| autoscaling.behavior | object | `{}` | Scaling behavior (autoscaling/v2). |
| autoscaling.enabled | bool | `false` | Render a HorizontalPodAutoscaler. The replica count is then omitted. |
| autoscaling.maxReplicas | int | `5` | Maximum replicas. |
| autoscaling.metrics | list | `[]` | Full metrics list. When set, it replaces the two utilisation targets. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `75` | Target average CPU utilisation in percent. Null disables the CPU metric. |
| autoscaling.targetMemoryUtilizationPercentage | int | `nil` | Target average memory utilisation in percent. Null disables the memory metric. |
| command | list | `[]` | Container command. Empty uses the image entrypoint. |
| commonLabels | object | `{}` | Labels added to every rendered object. |
| configMaps | object | `{}` | ConfigMaps rendered by the chart, keyed by short name. Each renders as `<fullname>-<key>`. Fields: data (map, required), mountPath (mount read-only at this path), asEnv (add to envFrom). |
| containerPorts | list | `[{"containerPort":8080,"name":"http","protocol":"TCP"}]` | Container ports. The first port is the default target of the Service. |
| env | list | `[]` | Environment variables as a list of EnvVar objects. Use valueFrom.secretKeyRef for single secret keys. |
| envFrom | list | `[]` | Environment sources as a list of EnvFromSource objects, for example secretRef or configMapRef. |
| environments | object | `{}` | Per-environment overrides, keyed by environment name (for example dev, stage, prod). Each value is a partial values tree. The entry named by `global.environment` is merged over the consumer values with the same rules (maps merge, lists replace, false and 0 kept, null removes). Never rendered into an object. |
| extraVolumeMounts | list | `[]` | Extra volume mounts on the container. |
| extraVolumes | list | `[]` | Extra volumes on the pod. |
| fullnameOverride | string | `""` | Overrides the full resource name. Truncated to 63 characters. |
| image.digest | string | `""` | Image digest (sha256:...). When set, the image renders as repository@digest and the tag is not used. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.registry | string | `""` | Registry and path prefix, for example ghcr.io/your-org. global.imageRegistry takes precedence. Not applied when image.repository already starts with a registry host. |
| image.repository | string | `""` | Image name (with a registry prefix) or full lowercase path, for example ghcr.io/your-org/hello-api. Required. |
| image.tag | string | `""` | Image tag. Defaults to the chart appVersion. `latest` is rejected. |
| imagePullSecrets | list | `[]` | Image pull secrets, as a list of names. |
| keda.behavior | object | `{}` | Scaling behavior of the HPA that KEDA creates (advanced.horizontalPodAutoscalerConfig.behavior). Empty omits it. |
| keda.cooldownPeriod | int | `300` | Seconds after the last active trigger before scaling down to idleReplicaCount (or to 0 with minReplicaCount 0). |
| keda.enabled | bool | `false` | Render a ScaledObject for the Deployment, or for the Rollout when rollout.enabled. KEDA creates and owns the HPA, so autoscaling.enabled must be false. The replica count is then omitted. |
| keda.fallback | object | `{}` | Replicas to run when the scaler fails, for example `{failureThreshold: 3, replicas: 2}`. Empty omits it. |
| keda.idleReplicaCount | int | `nil` | Replicas while no trigger is active. Set 0 for scale to zero; it must be lower than minReplicaCount, so minReplicaCount must then be at least 1. Null omits it. |
| keda.initialCooldownPeriod | int | `nil` | Seconds after the ScaledObject is created before the first scale down to idle. Null omits it. |
| keda.maxReplicaCount | int | `5` | Maximum replicas. |
| keda.minReplicaCount | int | `1` | Minimum replicas while a trigger is active. |
| keda.pollingInterval | int | `30` | Seconds between two checks of the triggers. |
| keda.prometheus.activationThreshold | string | `""` | Query value above which the workload scales up from idleReplicaCount, as a string. Empty omits it. |
| keda.prometheus.authenticationRef | object | `{}` | TriggerAuthentication reference (`name`, `kind`). Empty omits it. |
| keda.prometheus.query | string | `""` | PromQL query that returns a single value. Rendered through tpl, so it may use `{{ .Release.Namespace }}` and `{{ include "common.names.fullname" . }}`. Required when keda.triggers is empty. |
| keda.prometheus.serverAddress | string | `"http://monitoring-prometheus.monitoring.svc:9090"` | Prometheus query endpoint. |
| keda.prometheus.threshold | string | `"10"` | Target value per replica (metricType AverageValue), as a string. |
| keda.triggers | list | `[]` | Full trigger list (type, metadata, metricType, authenticationRef, name). When set, it replaces the Prometheus trigger. Values in metadata are rendered as strings. |
| lifecycle | object | `{}` | Container lifecycle hooks. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/healthz","port":"http"},"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe. Setting another handler (tcpSocket, grpc or exec) replaces the default httpGet; other keys merge. |
| metrics.serviceMonitor.enabled | bool | `false` | Render a ServiceMonitor for the primary Service. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{"release":"monitoring"}` | Labels on the ServiceMonitor; must match the Prometheus serviceMonitorSelector. |
| metrics.serviceMonitor.path | string | `"/metrics"` | Metrics path. |
| metrics.serviceMonitor.port | string | `"http"` | Service port name to scrape. |
| metrics.serviceMonitor.scrapeTimeout | string | `"10s"` | Scrape timeout. |
| nameOverride | string | `""` | Overrides the chart name used in names and the app.kubernetes.io/name label. |
| networkPolicy.egress | list | `[]` | Egress rules (NetworkPolicyEgressRule list). When set, Egress is added to policyTypes. |
| networkPolicy.enabled | bool | `true` | Render a NetworkPolicy with the allow rules of the workload. Nothing is rendered when there is no rule. |
| networkPolicy.extraIngress | list | `[]` | Extra ingress rules (NetworkPolicyIngressRule list), appended after the generated rules. |
| networkPolicy.gatewayNamespace | string | `"envoy-gateway-system"` | Namespace of the Gateway. Allowed to reach the first Service targetPort when route.enabled is true. |
| networkPolicy.monitoringNamespace | string | `"monitoring"` | Namespace of Prometheus. Allowed to reach the metrics port when metrics.serviceMonitor.enabled is true. |
| nodeSelector | object | `{}` | Node selector. |
| otel.enabled | bool | `false` | Add the `OTEL_*` environment variables after env: downward API variables for the pod, namespace and node, the exporter, sampler and propagator settings, and OTEL_RESOURCE_ATTRIBUTES. A variable whose name is already in env is not added. |
| otel.endpoint | string | `"http://tempo.tracing.svc:4318"` | OTLP endpoint (OTEL_EXPORTER_OTLP_ENDPOINT). Required when otel.enabled is true. With protocol grpc, use port 4317 here and in otel.networkPolicy.port. |
| otel.networkPolicy.namespace | string | `"tracing"` | Namespace of the collector. When set and networkPolicy.enabled is true, the app NetworkPolicy allows egress to it. Empty adds no rule. |
| otel.networkPolicy.port | int | `4318` | Collector port (TCP) allowed by the egress rule. |
| otel.propagators | string | `"tracecontext,baggage"` | Context propagators (OTEL_PROPAGATORS). |
| otel.protocol | string | `"http/protobuf"` | OTLP protocol (OTEL_EXPORTER_OTLP_PROTOCOL): http/protobuf, http/json or grpc. |
| otel.resourceAttributes | object | `{}` | Extra resource attributes, appended to OTEL_RESOURCE_ATTRIBUTES sorted by key. A key here replaces the generated attribute with the same key. Keys and values must not contain "," or "=". |
| otel.sampler | string | `"parentbased_traceidratio"` | Trace sampler (OTEL_TRACES_SAMPLER). |
| otel.samplerArg | string | `"1.0"` | Sampler argument (OTEL_TRACES_SAMPLER_ARG), as a string. "1.0" keeps every new trace. |
| otel.serviceName | string | `""` | Service name (OTEL_SERVICE_NAME). Empty uses the full name. |
| persistence.accessMode | string | `"ReadWriteOnce"` | Access mode. ReadWriteOnce and ReadWriteOncePod are rejected when more than one replica can run. |
| persistence.annotations | object | `{}` | Annotations on the claim. |
| persistence.enabled | bool | `false` | Render and mount a PersistentVolumeClaim. |
| persistence.existingClaim | string | `""` | Use an existing claim instead of rendering one. |
| persistence.mountPath | string | `"/data"` | Mount path of the volume. |
| persistence.size | string | `"1Gi"` | Requested size. |
| persistence.storageClassName | string | `""` | StorageClass. Empty uses the cluster default. "-" renders an empty storageClassName. |
| podAnnotations | object | `{}` | Annotations on the pod template. |
| podDisruptionBudget.enabled | bool | `true` | Render a PodDisruptionBudget. Only rendered when the minimum replica count is above 1. |
| podDisruptionBudget.maxUnavailable | int or string | `1` | Maximum unavailable pods (number or percentage). Do not set together with minAvailable. |
| podDisruptionBudget.minAvailable | int or string | `nil` | Minimum available pods (number or percentage). Do not set together with maxUnavailable. |
| podLabels | object | `{}` | Extra labels on the pod template. Selector labels cannot be overridden. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod-level security context. Rendered as given: every field can be overridden, or removed with null from a value file. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"http"},"periodSeconds":5,"timeoutSeconds":2}` | Readiness probe. Same handler rule as the liveness probe. |
| replicaCount | int | `1` | Replica count. Not rendered when autoscaling or keda is enabled. Set to 0 on the Deployment when the Rollout is enabled. |
| resources | object | `{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Resource requests and limits. The platform policy requires both for CPU and memory. |
| revisionHistoryLimit | int | `3` | Number of old ReplicaSets to retain. |
| rollout.analysis.args | list | `[]` | Analysis arguments (name and value). |
| rollout.analysis.enabled | bool | `true` | Run background analysis during the canary. |
| rollout.analysis.startingStep | int | `1` | Step index at which the analysis starts. |
| rollout.analysis.templateName | string | `"success-rate"` | ClusterAnalysisTemplate name. |
| rollout.enabled | bool | `false` | Render a Rollout that references the Deployment. The Deployment is then rendered with 0 replicas. |
| rollout.steps | list | `[{"setWeight":20},{"pause":{"duration":"1m"}},{"setWeight":50},{"pause":{"duration":"1m"}}]` | Canary steps. |
| rollout.trafficRouting.gatewayAPI.enabled | bool | `false` | Shift traffic through the HTTPRoute with the Gateway API plugin. Renders a canary Service. |
| rollout.trafficRouting.gatewayAPI.httpRoute | string | `""` | HTTPRoute name. Defaults to the route rendered by this chart. |
| rollout.workloadRef.scaleDown | string | `"onsuccess"` | How the Rollouts controller scales the referenced Deployment: never, onsuccess or progressively. |
| route.annotations | object | `{}` | Annotations on the HTTPRoute. |
| route.enabled | bool | `false` | Render an HTTPRoute. Needs route.hostnames, or global.environment and global.domain. |
| route.hostnames | list | `[]` | Hostnames, for example hello-api.dev.localtest.me. When empty, one hostname `<fullname>.<global.environment>.<global.domain>` is rendered; the render fails if either global value is missing. Explicit hostnames always win. |
| route.matches | list | `[{"path":{"type":"PathPrefix","value":"/"}}]` | Request matches of the single rule. |
| route.parentRefs | list | `[{"name":"platform","namespace":"envoy-gateway-system","sectionName":"https"}]` | Parent Gateways. |
| route.timeouts | object | `{}` | Rule timeouts (request, backendRequest). Not rendered when empty. trafficPolicy.timeout.http.requestTimeout sets a request timeout on the same route; set one of the two, not both. |
| secretMounts | object | `{}` | Existing Secrets to mount, keyed by volume name. The chart never renders Secrets; create them with Sealed Secrets or External Secrets. Fields: secretName (required), mountPath (required), items, optional. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}` | Container-level security context. Rendered as given: every field can be overridden, or removed with null from a value file. |
| service.annotations | object | `{}` | Annotations on the Service. |
| service.enabled | bool | `true` | Render the Service. |
| service.ports | list | `[{"name":"http","port":80,"protocol":"TCP","targetPort":"http"}]` | Service ports. The first port is used by the route and the ServiceMonitor. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Annotations on the ServiceAccount, for example for workload identity. |
| serviceAccount.automount | bool | `false` | Mount the API token. Applies to the ServiceAccount and the pod spec. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the workload. |
| serviceAccount.name | string | `""` | ServiceAccount name. Defaults to the full name when create is true, else `default`. |
| startupProbe | object | `{}` | Startup probe. Not rendered when empty. |
| strategy | object | `{}` | Deployment strategy. Empty uses the Kubernetes default (RollingUpdate 25% / 25%). |
| terminationGracePeriodSeconds | int | `30` | Pod termination grace period in seconds. |
| tmpVolume.enabled | bool | `true` | Mount an emptyDir for temporary files. |
| tmpVolume.medium | string | `""` | Storage medium. Empty uses node storage; Memory uses tmpfs and counts against the memory limit. |
| tmpVolume.mountPath | string | `"/tmp"` | Mount path of the emptyDir. |
| tmpVolume.sizeLimit | string | `"64Mi"` | Size limit of the emptyDir. |
| tolerations | list | `[]` | Tolerations. |
| topologySpread.enabled | bool | `false` | Spread replicas across nodes with a constraint that uses the selector labels. |
| topologySpread.maxSkew | int | `1` | Maximum skew. |
| topologySpread.topologyKey | string | `"kubernetes.io/hostname"` | Topology key. |
| topologySpread.whenUnsatisfiable | string | `"ScheduleAnyway"` | DoNotSchedule or ScheduleAnyway. |
| trafficPolicy.annotations | object | `{}` | Annotations on the BackendTrafficPolicy. |
| trafficPolicy.circuitBreaker | object | `{"maxConnections":1024,"maxParallelRequests":1024,"maxParallelRetries":10,"maxPendingRequests":256}` | Circuit breaker thresholds, rendered as given; null in a value file omits them. They apply per Envoy replica, not per Service; requests above a threshold fail fast with 503 instead of queueing. |
| trafficPolicy.enabled | bool | `false` | Render a BackendTrafficPolicy that targets the HTTPRoute. Requires route.enabled. |
| trafficPolicy.rateLimit.enabled | bool | `false` | Add one local rate limit rule for every request to the route. Each Envoy replica counts on its own and answers 429 above the limit, so the effective limit grows with the number of Envoy replicas. |
| trafficPolicy.rateLimit.requests | int | `100` | Requests allowed per unit and per Envoy replica. |
| trafficPolicy.rateLimit.unit | string | `"Second"` | Rate limit unit: Second, Minute, Hour, Day, Week, Month or Year. |
| trafficPolicy.retry | object | `{"numRetries":2,"perRetry":{"backOff":{"baseInterval":"100ms","maxInterval":"1s"},"timeout":"5s"},"retryOn":{"httpStatusCodes":[503],"triggers":["connect-failure","refused-stream","reset-before-request","retriable-status-codes"]}}` | Retry policy (numRetries, retryOn, perRetry), rendered as given; null in a value file omits it, and numRetries 0 turns retries off. The default is deliberately conservative because Envoy cannot tell whether a request is idempotent: the three connection triggers fire only when the request never reached the application, and 503 is retried on the convention that a service answering 503 did not process the request. Add 5xx, reset or gateway-error only when every operation on the route is idempotent, or a POST may be applied twice. |
| trafficPolicy.timeout | object | `{"http":{"requestTimeout":"15s"},"tcp":{"connectTimeout":"5s"}}` | Backend timeouts: tcp.connectTimeout, http.requestTimeout, http.connectionIdleTimeout and http.maxConnectionDuration (durations such as 500ms, 15s, 1h). Rendered as given; null in a value file omits the block. route.timeouts also sets a request timeout on the same route; set one of the two, not both. |
