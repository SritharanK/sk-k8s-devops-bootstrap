# argo-rollouts

Progressive delivery for platform applications: Argo Rollouts runs canary releases, shifts traffic through the Gateway API (Envoy Gateway) with the `argoproj-labs/gatewayAPI` traffic router plugin, and judges each step with the shared `success-rate` ClusterAnalysisTemplate against Prometheus.

| Item | Value |
| --- | --- |
| Upstream chart | argo-rollouts 2.43.12 from `oci://ghcr.io/argoproj/argo-helm` |
| Upstream app version | v1.10.2 |
| Upstream source | <https://github.com/argoproj/argo-rollouts> |
| Traffic router plugin | argoproj-labs/gatewayAPI v0.17.0, <https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi> |
| Namespace | argo-rollouts (Pod Security: restricted, the controller and its init container need no host access or privileges) |
| Enabled by default | No. Switch on with `toolchains.argo-rollouts.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

What this chart adds on top of the upstream chart:

| Resource | Source | Purpose |
| --- | --- | --- |
| Init container `fetch-gatewayapi-plugin` | `values.yaml` | Downloads and verifies the plugin binary for the node architecture |
| ClusterRole rules for Gateway API routes | `providerRBAC.additionalRules` | Lets the plugin change route weights |
| ClusterAnalysisTemplate `success-rate` | `templates/cluster-analysis-template.yaml` | Shared canary analysis |

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Controller replicas | 1 | 2, leader election (`--leader-elect` is added by the chart when replicas > 1) |
| PodDisruptionBudget | none | `minAvailable: 1` |
| Spread over nodes | no | `topologySpreadConstraints` on `kubernetes.io/hostname`, `ScheduleAnyway` |
| Controller requests / memory limit | 50m, 128Mi / 512Mi | 100m, 256Mi / 1Gi |
| ServiceMonitor (`release: monitoring`) | yes | yes |
| Dashboard | off | off |

The plugin runs as a child process inside the controller container, so the controller memory limit covers both. CPU limits are not set on purpose, to avoid throttling of the reconcile loop. The init container requests 10m and 32Mi with a 64Mi memory limit in both profiles.

The dashboard is off because it has no authentication of its own. Use `kubectl argo rollouts` or the Argo CD UI, which shows Rollout status and has Rollout actions such as resume, promote-full and abort.

## Secrets

None. The success-rate analysis queries Prometheus inside the cluster without credentials, and the plugin download needs no token.

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that scrapes the controller (`release: monitoring`) and answers the analysis queries at `http://monitoring-prometheus.monitoring.svc:9090` (`analysis.prometheusAddress`) |
| Gateway API CRDs and Envoy Gateway | HTTPRoutes that the plugin rewrites; parentRef `{name: platform, namespace: envoy-gateway-system, sectionName: https}` |

Applications that use the analysis must expose `http_requests_total` with the labels `handler` and `code`, and be scraped through a ServiceMonitor so that Prometheus adds the `namespace` and `service` labels.

## Gateway API plugin

Argo Rollouts accepts one `location` and one `sha256` per plugin, which cannot serve both amd64 (CI, servers) and arm64 (kind on Apple Silicon). This chart therefore installs the plugin in two steps:

1. The init container `fetch-gatewayapi-plugin` (image `curlimages/curl:8.23.0`, pinned by the digest of its multi-arch index) maps `uname -m` to `amd64` or `arm64`, downloads `gatewayapi-plugin-linux-<arch>` of the pinned release, and compares its sha256 with the pinned value for that architecture. On a mismatch, an unknown architecture or a failed download it exits non-zero and the controller does not start (fail closed). A verified file is made executable and moved to `/plugins/gatewayapi` on an emptyDir (256Mi size limit).
2. The controller mounts the emptyDir read-only at `/plugins`. `argo-rollouts-config` points the plugin at `file:///plugins/gatewayapi`. At start the controller copies that file to `plugin-bin/argoproj-labs/gatewayAPI`, sets mode 0700 and runs it from there. Argo Rollouts checks a `sha256` only for `http(s)://` locations, which is why the check happens in the init container.

Network: every controller pod start downloads the plugin, so the controller pods need HTTPS egress to `github.com` and to `release-assets.githubusercontent.com` (the release download redirect target). If that egress is blocked, the init container fails after its retries and the pod stays in `Init:Error` or `Init:CrashLoopBackOff`. A running controller is not affected by a later outage.

Air-gapped clusters: mirror both release assets to an internal HTTPS server under `<base>/<version>/gatewayapi-plugin-linux-<arch>` and set `PLUGIN_BASE_URL` in the init container env to `<base>`. The checksums stay the same. Mirror the curl image as well (same digest). The plugin project also publishes a multi-arch image `ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:<version>`; copying the binary out of a mirrored copy of that image is an alternative that needs no file server.

### Plugin bump procedure

Version and both checksums sit together in the init container `env` in `values.yaml`.

1. Pick the release at <https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases> and read its notes for the minimum Argo Rollouts version and behaviour changes.
2. Download both assets and compute the checksums. Compare them with the digests GitHub shows on the release page.

   ```bash
   v=v0.17.0
   base=https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download
   for arch in amd64 arm64; do curl -fsSLO "${base}/${v}/gatewayapi-plugin-linux-${arch}"; done
   sha256sum gatewayapi-plugin-linux-amd64 gatewayapi-plugin-linux-arm64
   ```

3. Set `PLUGIN_VERSION`, `PLUGIN_SHA256_AMD64` and `PLUGIN_SHA256_ARM64`. The pod template changes, so Argo CD rolls the controller.
4. Check the init container log in the lab cluster: `kubectl -n argo-rollouts logs deploy/argo-rollouts -c fetch-gatewayapi-plugin` must end with `verified gatewayAPI plugin <version> linux-<arch> sha256 <sum>`. Then run one canary before the reference cluster.

## Rollout contract

The shared app chart keeps its Deployment and adds a Rollout that references it. The Rollout owns the ReplicaSets; the Deployment only supplies the pod template.

| Field | Value |
| --- | --- |
| `spec.workloadRef` | `{apiVersion: apps/v1, kind: Deployment, name: <app>}`. Keep the Deployment at `replicas: 0` in Git so only the Rollout runs pods. The optional `scaleDown` (`never`, `onsuccess`, `progressively`) is meant for migrating a running Deployment; it writes the Deployment `spec.replicas`, which Argo CD then reports as drift. |
| `spec.selector` | Same `matchLabels` as the Deployment pod template |
| `spec.strategy.canary.stableService` / `canaryService` | Two Services with the same selector as the pods. Argo Rollouts adds `rollouts-pod-template-hash` to both selectors at runtime. |
| `spec.strategy.canary.trafficRouting.plugins."argoproj-labs/gatewayAPI".httpRoute` | Name of the HTTPRoute. One rule of that route lists both Services as `backendRefs`; the plugin sets their weights. |
| `spec.strategy.canary.trafficRouting.plugins."argoproj-labs/gatewayAPI".namespace` | Namespace of the HTTPRoute (defaults to the Rollout namespace) |
| Analysis template | `templates: [{templateName: success-rate, clusterScope: true}]` |
| Analysis args | `service-name` (required), `namespace` (required), `threshold` (optional, default `"0.99"`) |

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: hello-api
  namespace: hello
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: hello-api
  workloadRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello-api
  strategy:
    canary:
      stableService: hello-api-stable
      canaryService: hello-api-canary
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: hello-api
            namespace: hello
      steps:
        - setWeight: 10
        - analysis:
            templates:
              - templateName: success-rate
                clusterScope: true
            args:
              - name: service-name
                # Service scraped by the ServiceMonitor; not managed by the Rollout
                value: hello-api
              - name: namespace
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
              - name: threshold
                value: "0.99"
        - setWeight: 50
        - pause: {duration: 5m}
```

`service-name` matches the `service` label, which the Prometheus Operator sets to the name of the Service a target was scraped through. During a canary Argo Rollouts narrows the selectors of `stableService` and `canaryService` to the stable and the canary pods. Consequence for the argument: the stable Service name measures only the old version, the canary Service name measures only the new version, and a Service that the Rollout does not manage (as `hello-api` above, selecting all pods) measures the traffic of both. The app chart decides which of these it passes; the template accepts any of them.

Argo CD manages the HTTPRoute and would revert the weights that the plugin writes. The Argo CD Application of each app (or `resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute` in `argocd-cm`) needs:

```yaml
ignoreDifferences:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    jqPathExpressions:
      - .spec.rules[].backendRefs[].weight
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

`ignoreDifferences` alone only hides the diff; `RespectIgnoreDifferences=true` keeps a sync from resetting the weights. While a canary runs, the plugin also sets the label `rollouts.argoproj.io/gatewayapi-canary=in-progress` on the route.

## success-rate analysis

| Setting | Value |
| --- | --- |
| Provider | Prometheus at `analysis.prometheusAddress` |
| Query | non-5xx rate divided by total rate of `http_requests_total` for the Service over 2m, excluding `/healthz`, `/readyz` and `/metrics` |
| Measurements | every 30s, 6 in total (the first at the start of the step, the last 2.5 minutes later) |
| `failureLimit` | 1: the analysis fails at the second failed measurement |
| `consecutiveErrorLimit` | 3: the analysis ends in Error at the fourth consecutive query error (for example Prometheus unreachable) |
| `successCondition` | `len(result) > 0 && !isNaN(result[0]) && result[0] >= threshold` |
| `failureCondition` | `len(result) > 0 && !isNaN(result[0]) && result[0] < threshold` |

Inconclusive behaviour: when the Service received no requests in the window, the query returns an empty vector (no series) or NaN (0/0). Neither condition matches, so the measurement is Inconclusive. `inconclusiveLimit` is not set and defaults to 0, so the first Inconclusive measurement makes the AnalysisRun Inconclusive and the Rollout pauses at that step. A person then decides with `kubectl argo rollouts promote <rollout>` or `kubectl argo rollouts abort <rollout>`, or with the resume or abort action in the Argo CD UI. The analysis never passes a canary that served no traffic. `isNaN` is one of the functions Argo Rollouts registers for condition expressions (`utils/evaluate/evaluate.go`), and `&&` short-circuits, so `result[0]` is not read when the vector is empty.

## Upgrade

1. Change the dependency version in `Chart.yaml` and run `helm dependency update` in this directory, which refreshes `Chart.lock`.
2. Read the chart changes on <https://artifacthub.io/packages/helm/argo/argo-rollouts> and the release notes at <https://github.com/argoproj/argo-rollouts/releases>. Diff the upstream `values.yaml` against the previous version, in particular `controller.initContainers`, `controller.trafficRouterPlugins`, `providerRBAC` and `crdAnnotations`.
3. Check the plugin release notes for the minimum Argo Rollouts version before you bump either side.
4. Render both profiles and compare with the previous render, then sync the lab cluster first.

CRDs are part of the chart templates (`installCRDs: true`). Argo CD applies them with server-side apply like any other resource, so CRD updates come with the chart version. `crdAnnotations` adds `argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so disabling the toolchain or removing a CRD from the chart never deletes the CRDs and the Rollouts that depend on them. `keepCRDs: true` adds `helm.sh/resource-policy: keep`, which matters only for a plain Helm install.

## Known limitations

- Each controller start downloads the plugin (about 78 MB for amd64) from GitHub. See the air-gapped alternative above.
- Plugin RBAC is cluster-wide (ClusterRole of the controller), as the plugin installation docs show. The upstream built-in `gatewayAPI` rule is switched off because it lacks `patch` and grants ConfigMap create and update that plugin v0.17.0 no longer uses; the replacement rule is in `providerRBAC.additionalRules`. All other provider rules (Istio, SMI, Ambassador, AWS, Traefik, APISIX, Contour, Gloo) are off as well.
- The analysis assumes the metric name `http_requests_total` with `handler` and `code` labels. Applications with other metric names need their own AnalysisTemplate.
- Notifications are not configured (`argo-rollouts-notification-configmap` is empty).
- A plain `helm install` outside Argo CD fails on the first run, because the CRDs are templates and Helm validates the `success-rate` ClusterAnalysisTemplate before it creates them. Apply the CRDs first: `helm template argo-rollouts . -f values.yaml -f values-lab.yaml | yq 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side -f -`, then install with `helm upgrade --install --take-ownership argo-rollouts .` so Helm adopts them. Argo CD applies CRDs before the rest of a sync.
