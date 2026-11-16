# helm-common values reference

This page explains the contract of the `helm-common` library chart: its named templates, its values, the workload rules it satisfies by default, and how images, observability and progressive delivery plug into it. It is for authors of app charts under `helmcharts/app-charts/`.

The authoritative per-key list, with every default, is the generated chart README `helmcharts/helm-common/README.md`, produced by helm-docs from the chart's values. This page explains what the keys mean together. Rows marked "Contract" are interfaces other parts of the platform depend on: promotion, the Gateway, and the observability and progressive delivery components. The other key names follow Helm chart conventions; check the generated README for the exact name and default before you use them.

## The library chart

- `helmcharts/helm-common` is a Helm library chart (`apiVersion: v2`, `type: library`). It renders nothing on its own; app charts include its named templates.
- An app chart declares `helm-common` as a dependency through a local `file://` reference and keeps thin templates, one include per object. The app Applications list `../../helm-common` in `manifest-generate-paths`, so a library change re-renders every app.
- Objects carry the recommended `app.kubernetes.io/*` labels. Selectors use only `app.kubernetes.io/name` and `app.kubernetes.io/instance`, so adding a label never touches an immutable selector. Names are release-scoped and truncated to 63 characters.
- Values are validated against a `values.schema.json` during `helm lint`, `helm template` and install, so a value of the wrong type fails in CI instead of rendering.
- A helm-unittest suite in `helmcharts/helm-common/tests/` covers the defaults and the opt-outs. Run it with `helm unittest helmcharts/helm-common/tests/chart`. The CI job `helm` runs it with lint, render and kubeconform for every app and environment.

A template file in an app chart is one line:

```yaml
{{- include "common.deployment" . }}
```

### Named templates

| Template | Object | Notes |
| --- | --- | --- |
| `common.deployment` | Deployment | Restricted security context, probes, resources and the `/tmp` volume. `replicas` is omitted when the HPA is on. |
| `common.service` | Service | In front of the container port. The HTTPRoute and the ServiceMonitor point at it. |
| `common.httproute` | HTTPRoute | Only when `route.enabled` is true. Attaches to the Gateway `platform`. |
| `common.networkpolicy` | NetworkPolicy | Rendered by default. Admits the service port from `envoy-gateway-system` when `route.enabled`, the metrics port from `monitoring` when `metrics.serviceMonitor.enabled`, plus the rules in `networkPolicy.extraIngress[]` and `networkPolicy.egress[]`, on top of the platform's default deny. |
| `common.serviceaccount` | ServiceAccount | A dedicated account with token automount off. |
| `common.pdb` | PodDisruptionBudget | `maxUnavailable: 1`, rendered only when the minimum replica count is above 1. |
| `common.hpa` | HorizontalPodAutoscaler | Only when autoscaling is enabled. Supports `behavior`. |

helm-common also renders a ServiceMonitor, an Argo Rollouts `Rollout` and a PersistentVolumeClaim when their values enable them; the generated README names those templates.

## Values

### Image

| Key | Default | Description |
| --- | --- | --- |
| `image.registry` | `""` | Registry and path prefix, for example `ghcr.io/your-org`. `global.imageRegistry` takes precedence when it is set. The prefix is prepended to `image.repository` only when the repository does not already start with a registry host. |
| `image.repository` | None; required | Contract. Image name, for example `hello-api`, or a full path such as `ghcr.io/your-org/hello-api`. Must not carry a tag or digest. The resulting path must be lowercase, and its registry must be in the policy allowlist. |
| `image.tag` | `""`: the `appVersion` of the app chart | Contract. Image tag. When empty, the tag is the `appVersion` in `Chart.yaml` of the app chart that includes helm-common; when that is empty too and no digest is set, the render fails. `latest`, in any case, fails the render. Without a digest, the image renders as `<path>:<tag>`. |
| `image.digest` | `""` | Contract. Content digest, `sha256:` plus 64 lowercase hex characters. When set, the image renders as `<path>@<digest>` and the tag is not part of the reference. |
| `image.pullPolicy` | See the generated README | Contract. Kubernetes `imagePullPolicy`. |

The image reference is built as follows:

1. Prefix: `global.imageRegistry`, else `image.registry`, without a trailing `/`. The app Applications set `global.imageRegistry` from `platform.imageRegistry` in the cluster file, so in the platform it replaces the `image.registry` of the app chart.
2. Path: `<prefix>/<image.repository>`, unless `image.repository` already starts with a registry host (its first path segment contains `.` or `:`, or is `localhost`), in which case the repository is used as written. A full path in an environment file therefore keeps working.
3. Reference: `<path>@<image.digest>` when the digest is set, else `<path>:<tag>`.

For `hello-api`, `global.imageRegistry: ghcr.io/your-org` and `image.repository: hello-api` give the path `ghcr.io/your-org/hello-api`. The tag and digest come from `envs/<env>/hello-api/values.yaml`: `ghcr.io/your-org/hello-api:0.1.0` while the digest is empty, `ghcr.io/your-org/hello-api@sha256:...` once the image build has set it.

### Route

| Key | Default | Description |
| --- | --- | --- |
| `route.enabled` | `false` | Contract. Renders an HTTPRoute. |
| `route.hostnames[]` | Empty: derived | Contract. Host names. When empty, the chart derives `<app>.<env>.<domain>` from `global.environment` and `global.domain`, a name covered by the `*.<env>.<domain>` entry of the platform certificate (wildcard issuers) or listed in `platform.gateway.hostnames` (ACME HTTP-01). |
| `route.parentRefs[]` | `[{name: platform, namespace: envoy-gateway-system, sectionName: https}]` | Contract. The Gateway listener the route attaches to. |

### Globals

| Key | Default | Description |
| --- | --- | --- |
| `global.environment` | Set by the Application | `dev`, `stage` or `prod`. Selects the `environments.<env>` block and forms the host name. |
| `global.domain` | Set by the Application | `cluster.domain` from the cluster file. Forms the host name. |
| `global.imageRegistry` | Set by the Application | `platform.imageRegistry` from the cluster file. Takes precedence over `image.registry`. |

The app Applications pass these values; an app chart or environment file does not set them.

### Service

| Key | Default | Description |
| --- | --- | --- |
| `service.type` | `ClusterIP` | Service type. Apps are exposed through the Gateway, not through NodePort or LoadBalancer Services. |
| `service.ports[]` | `[{name: http, port: 80, targetPort: http, protocol: TCP}]` | Service ports. The first port is used by the HTTPRoute and the ServiceMonitor. `targetPort: http` resolves to the first entry of `containerPorts` (8080 for `hello-api`). |

### Probes

| Key | Default | Description |
| --- | --- | --- |
| `readinessProbe` | Set by the app chart | Kubernetes probe. Required by the workload contract. `hello-api` uses `GET /readyz`. |
| `livenessProbe` | Set by the app chart | Kubernetes probe. Required by the workload contract. `hello-api` uses `GET /healthz`. |

### Resources

| Key | Default | Description |
| --- | --- | --- |
| `resources` | Set by the app chart | CPU and memory requests and limits, all four required by the workload contract. |

### Security context

| Key | Default | Description |
| --- | --- | --- |
| `podSecurityContext` | `runAsNonRoot: true`, `runAsUser: 65532`, `runAsGroup: 65532`, `fsGroup: 65532`, `seccompProfile.type: RuntimeDefault` | Pod-level security context. |
| `securityContext` | `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault` | Container-level security context, applied to every container. |

helm-common renders these blocks with `toYaml`, so an explicit opt-out such as `readOnlyRootFilesystem: false` reaches the manifest unchanged. In `stage` and `prod` the policies then reject it unless a `PolicyException` covers the workload. `hello-api` sets the numeric UID 65532 to match its distroless nonroot image.

### Service account

| Key | Default | Description |
| --- | --- | --- |
| `serviceAccount.create` | `true` | Creates a dedicated ServiceAccount for the app. |
| `serviceAccount.name` | The release-scoped name | Name of the ServiceAccount. |
| `serviceAccount.automount` | `false` | Mounts the API token into the pod. Set it to true only for an app that calls the Kubernetes API. |

### Network policy

| Key | Default | Description |
| --- | --- | --- |
| `networkPolicy.extraIngress[]` | Empty | Additional NetworkPolicy ingress rules for the app's pods. |
| `networkPolicy.egress[]` | Empty | NetworkPolicy egress rules for the app's pods. |

The platform keeps only `default-deny` (ingress and egress) and `allow-dns` in the app namespaces. Each app owns the rest through this NetworkPolicy: ingress on the service port from `envoy-gateway-system` when the route is enabled, and on the metrics port from the `monitoring` namespace when the ServiceMonitor is enabled, so the Gateway and the scraper reach the app without extra rules. Everything else needs a rule here, and an Audit-mode Kyverno policy reports app policies that admit all namespaces to all pods:

- in `stage` and `prod`, a call between two apps in the same namespace needs an egress rule on the caller and an ingress rule on the target;
- a call to a database or an external API needs an egress rule.

### Per-environment sizing, disruption budget and autoscaling

| Key | Default | Description |
| --- | --- | --- |
| `environments.<env>` | Set by the app chart | Sizing for `dev`, `stage` and `prod`, selected by `global.environment`: a replica count, or autoscaling bounds. `hello-api` runs 1 replica in `dev`, 2 in `stage`, and an HPA from 2 to 4 replicas in `prod`. The generated README lists the keys inside each block. |
| `autoscaling.behavior` | None | HPA scale-up and scale-down behaviour, passed through as written. |

The Deployment omits `replicas` when the HPA is on, so Argo CD and the HPA do not fight over the field. The PodDisruptionBudget uses `maxUnavailable: 1` and renders only when the minimum replica count is above 1, so a single replica never blocks a node drain. For `hello-api` that means no PDB in `dev` and one in `stage` and `prod`.

### Metrics

| Key | Default | Description |
| --- | --- | --- |
| `metrics.serviceMonitor.enabled` | `false` | Contract. Renders a ServiceMonitor for the app's `/metrics` endpoint. |
| `metrics.serviceMonitor.labels` | `{release: monitoring}` | Contract. Labels the monitoring stack selects ServiceMonitors by. |

### Rollout

| Key | Default | Description |
| --- | --- | --- |
| `rollout.enabled` | `false` | Contract. Renders an Argo Rollouts `Rollout` with `workloadRef` to the app's Deployment. |
| `rollout.steps[]` | See the generated README | Contract. Canary steps in the Argo Rollouts step format. |
| `rollout.analysis.enabled` | See the generated README | Runs the analysis during the rollout. |
| `rollout.analysis.templateName` | `success-rate` | Contract. The `ClusterAnalysisTemplate` that judges the rollout. |
| `rollout.analysis.startingStep` | See the generated README | Canary step at which the background analysis starts. |
| `rollout.analysis.args[]` | See the generated README | Arguments passed to the analysis template. |
| `rollout.trafficRouting.gatewayAPI.enabled` | See the generated README | Shifts traffic through the Gateway API plugin instead of by replica count. |
| `rollout.trafficRouting.gatewayAPI.httpRoute` | See the generated README | Contract. The HTTPRoute whose backend weights the Gateway API plugin shifts. |

### Volumes and persistence

| Key | Default | Description |
| --- | --- | --- |
| `tmpVolume.enabled` | `true` | Mounts an emptyDir at `tmpVolume.mountPath` (`/tmp`, size limit 64Mi) as writable scratch space under the read-only root filesystem. |
| `extraVolumes` | `[]` | Additional pod volumes. |
| `extraVolumeMounts` | `[]` | Additional container volume mounts. |
| `persistence.enabled` | `false` | Renders a PersistentVolumeClaim and mounts it. |
| `persistence.accessMode` | See the generated README | Access mode of the claim. Configurable because the storage classes differ per profile. |
| `persistence.size` | See the generated README | Requested size. |

### Environment and pod metadata

| Key | Default | Description |
| --- | --- | --- |
| `env[]` | Empty | Container environment variables, including `valueFrom.secretKeyRef`. |
| `envFrom[]` | Empty | Whole Secrets as environment variables through `secretRef` entries. |
| `podAnnotations` | Empty | Annotations on the pod template. |

Referenced Secrets come from Sealed Secrets in the `lab` profile and from External Secrets Operator in the `reference` profile; see [secrets handling](../security/secrets-handling.md).

## Workload contract

Every pod in `dev`, `stage` and `prod` must meet these rules. Kyverno enforces them with CEL policies from the chart `helmcharts/system-charts/kyverno-policies`: `dev` runs in Audit mode (violations are reported, not blocked), `stage` and `prod` in Enforce mode. The test cases live in `helmcharts/system-charts/kyverno-policies/tests/` and run with `make policy-test`.

| Rule | Kyverno policy class | `dev` | `stage` and `prod` | How helm-common satisfies it by default |
| --- | --- | --- | --- | --- |
| `runAsNonRoot: true` at pod and container level | `ValidatingPolicy` | Audit | Enforce | Set in `podSecurityContext` and `securityContext`. |
| `allowPrivilegeEscalation: false` | `ValidatingPolicy` | Audit | Enforce | Set in `securityContext`. |
| `capabilities.drop: [ALL]` | `ValidatingPolicy` | Audit | Enforce | Set in `securityContext`. |
| `seccompProfile.type: RuntimeDefault` | `ValidatingPolicy` | Audit | Enforce | Set in `podSecurityContext`. |
| `readOnlyRootFilesystem: true` | `ValidatingPolicy` | Audit | Enforce | Set in `securityContext`; the `/tmp` emptyDir gives the app a writable directory. |
| CPU and memory requests and limits | `ValidatingPolicy` | Audit | Enforce | Rendered from `resources`, which the app chart sets. |
| Readiness and liveness probes | `ValidatingPolicy` | Audit | Enforce | Rendered from `readinessProbe` and `livenessProbe`, which the app chart sets. |
| Explicit tag that is not `latest`, or a digest | `ValidatingPolicy` | Audit | Enforce | `image.tag: latest` fails the render; `image.digest` renders `repository@digest`, and promotion sets the digest in every environment. |
| Image registry in the allowlist from the policy values | `ValidatingPolicy` | Audit | Enforce | Nothing in the library: `image.repository` must name an allowed registry. Owned images live under `platform.imageRegistry`. |
| Image signed by the build workflow identity | `ImageValidatingPolicy` | Not enforced | Enforced in the `reference` profile, off in `lab` | Nothing to configure in the chart: images built by `build-image.yml` are signed. See [supply chain](../security/supply-chain.md). |

The rules cover init and ephemeral containers as well. Exceptions are `PolicyException` objects in the `kyverno` namespace, scoped to the workloads that need them, for example the cert-manager ACME HTTP-01 solver pods (label `acme.cert-manager.io/http01-solver: "true"`). The namespaces also carry Pod Security Standards labels at level `restricted`, which the API server applies independently of Kyverno. [Security controls](../security/controls.md) is the full enforcement matrix.

## Images and promotion

A tag is a name the registry can move to different content. A digest identifies the content itself and cannot change. Signature verification and promotion both work on digests:

- The environment file `envs/<env>/<app>/values.yaml` holds only `image.tag` and `image.digest`.
- When `image.digest` is set, the rendered reference is `repository@digest`. A tag kept next to it is for readers only.
- Promotion edits only `image.tag` and `image.digest` in `envs/<env>/<app>/values.yaml`. The build workflow opens a pull request that bumps the digest in `envs/dev/<app>/values.yaml`. The `promote.yml` workflow opens a pull request that copies it from `dev` to `stage`, or from `stage` to `prod`, after checking that the Application in the source environment is Synced and Healthy. A person merges each pull request; nothing auto-merges.

Environment differences other than the image, such as replicas and autoscaling, live in the chart under `environments.<env>` and change through a normal reviewed pull request. [Promotion](../operations/promotion.md) describes the full flow and the deployment policy.

## Observability and progressive delivery hooks

helm-common renders the objects the optional observability and progressive delivery components consume. Both components are toolchains that are off by default in the `lab` profile; enable a hook only in a cluster where the matching toolchain runs, because Argo CD cannot apply an object whose CRD is missing.

| Hook | Values | What helm-common renders | What the platform provides |
| --- | --- | --- | --- |
| Metrics | `metrics.serviceMonitor.enabled`, `metrics.serviceMonitor.labels` | A ServiceMonitor for `/metrics`, labelled `release: monitoring` by default | The `monitoring` toolchain (kube-prometheus-stack) selects ServiceMonitors by that label; the app's own NetworkPolicy admits the scrape on the metrics port. |
| Canary delivery | `rollout.enabled`, `rollout.steps[]`, `rollout.analysis.*`, `rollout.trafficRouting.gatewayAPI.*` | A `Rollout` with `workloadRef` to the app's Deployment | The `argo-rollouts` toolchain with the Gateway API plugin and the `ClusterAnalysisTemplate` named `success-rate`. |

The [observability contract](../operations/observability-contract.md) lists the probes, metrics, logs and traces every workload provides. Argo Rollouts' [migration guide](https://argo-rollouts.readthedocs.io/en/stable/migrating/) explains how a `Rollout` with `workloadRef` relates to its Deployment.

## Values layering

An app Application renders the app chart with two value files, in this order, and passes `global.environment` and `global.domain`:

1. `helmcharts/app-charts/<app>/values.yaml`: the app's defaults for every environment (probes, resources, route, network rules) and the `environments.<env>` sizing blocks.
2. `envs/<env>/<app>/values.yaml`: `image.tag` and `image.digest`, nothing else.

The later file wins. Helm merges maps key by key and replaces lists as a whole. [GitOps structure](../architecture/gitops.md) shows how the app Applications are generated from the `apps:` list, and [add an app](../operations/add-an-app.md) walks through a new chart.
