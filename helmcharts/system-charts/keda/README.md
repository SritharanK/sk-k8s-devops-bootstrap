# keda

Event-driven autoscaling for platform applications: KEDA scales Deployments and Jobs on external signals such as Prometheus queries or queue length, including scale to zero, by managing a HorizontalPodAutoscaler per ScaledObject and serving the `external.metrics.k8s.io` API.

| Item | Value |
| --- | --- |
| Upstream chart | keda 2.21.0 from `https://kedacore.github.io/charts` (no OCI artifact is published) |
| Upstream app version | 2.21.0 |
| Upstream source | <https://github.com/kedacore/keda> |
| Namespace | keda (Pod Security: restricted, no component needs host access or privileges) |
| Enabled by default | No. Switch on with `toolchains.keda.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

Components:

| Deployment | Purpose |
| --- | --- |
| `keda-operator` | Reconciles ScaledObjects and ScaledJobs, creates the HPAs, polls the scalers |
| `keda-operator-metrics-apiserver` | Serves `external.metrics.k8s.io` (APIService `v1beta1.external.metrics.k8s.io`) to the HPA controller |
| `keda-admission-webhooks` | Validates ScaledObjects, for example rejects a second autoscaler for the same workload |

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Operator replicas | 1 | 2 (leader election: one active, one standby) |
| Metrics API server replicas | 1 | 2 |
| Admission webhook replicas | 1 | 1 (`failurePolicy: Ignore`, an outage never blocks API requests) |
| PodDisruptionBudget | none | `minAvailable: 1` for operator and metrics API server |
| Spread over nodes | no | `topologySpreadConstraints` on `kubernetes.io/hostname`, `ScheduleAnyway` |
| Operator requests / memory limit | 25m, 96Mi / 384Mi | 100m, 256Mi / 1Gi |
| Metrics API server requests / memory limit | 25m, 64Mi / 256Mi | 100m, 128Mi / 512Mi |
| Webhook requests / memory limit | 10m, 48Mi / 128Mi | 50m, 64Mi / 256Mi |
| ServiceMonitors (`release: monitoring`) | operator and metrics API server | operator and metrics API server |

CPU limits are not set on purpose, to avoid throttling. The upstream defaults of one core per container are removed with `limits.cpu: null`.

Both profiles render restricted-compliant pods: non-root, `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp at pod and container level, read-only root filesystem.

## Secrets

None to provide. The operator generates its own TLS certificates at runtime into the Secret `kedaorg-certs` (namespace `keda`) and injects the CA into the APIService and the ValidatingWebhookConfiguration. The Argo CD Application ignores those `caBundle` fields. cert-manager is not used.

Scalers that need credentials reference them through a `TriggerAuthentication` in the application namespace. The Prometheus trigger below needs none.

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that scrapes KEDA (`release: monitoring`); also the query endpoint for Prometheus triggers, `http://monitoring-prometheus.monitoring.svc:9090` |

## Usage

Example `ScaledObject` for the `hello-api` Deployment in `dev`. It is documentation only: this chart does not deploy it. It belongs in the application chart, next to the Deployment it scales.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: hello-api
  namespace: dev
spec:
  scaleTargetRef:
    name: hello-api            # Deployment in the same namespace
  minReplicaCount: 2
  maxReplicaCount: 10
  pollingInterval: 30          # seconds between Prometheus queries
  cooldownPeriod: 300          # only used when scaling to zero
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://monitoring-prometheus.monitoring.svc:9090
        # Requests per second over all pods, without probe and metrics traffic.
        query: sum(rate(http_requests_total{namespace="dev", service="hello-api", handler!~"/healthz|/readyz|/metrics"}[2m]))
        threshold: "20"        # target requests per second per replica
```

KEDA turns the query into an external metric with an `AverageValue` target: desired replicas = ceil(query result / threshold), bounded by `minReplicaCount` and `maxReplicaCount`.

HPA interplay:

| Rule | Reason |
| --- | --- |
| Do not define a HorizontalPodAutoscaler for a workload that a ScaledObject targets | KEDA creates and owns the HPA `keda-hpa-<scaledobject name>`. Two HPAs on one workload fight over `replicas`. The admission webhook rejects a ScaledObject whose target already has an HPA, and the reverse case is not caught. |
| Remove `replicas` from the Deployment manifest, or let Argo CD ignore it | Otherwise every Argo CD sync resets the replica count that the HPA set. |
| CPU or memory scaling goes into the same ScaledObject | Add a `cpu` or `memory` trigger next to the Prometheus trigger instead of a separate HPA. KEDA uses the highest replica count of all triggers. |
| HPA tuning goes into `spec.advanced.horizontalPodAutoscalerConfig` | Scale-down stabilisation and policies are passed through to the generated HPA. |

## Upgrade

1. Read the release notes at <https://github.com/kedacore/keda/releases> and the chart changes at <https://github.com/kedacore/charts/releases> for every version in between.
2. Change `dependencies[0].version` (and `appVersion`) in `Chart.yaml`, then run `helm dependency update helmcharts/system-charts/keda` and commit the new `Chart.lock`.
3. Render both profiles and compare with the previous render. CRD changes are applied by Argo CD with server-side apply; the CRDs are never pruned (`Prune=false,Delete=false`).

KEDA 2.21 is tested on Kubernetes 1.34 to 1.36. Each KEDA minor release covers three Kubernetes minor versions, so check the compatibility table at <https://keda.sh/docs/latest/operate/cluster/#kubernetes-compatibility> before a cluster upgrade.

## Known limitations

- A cluster has one provider of `external.metrics.k8s.io`. KEDA cannot run next to another external metrics adapter, for example prometheus-adapter with external metrics enabled.
- Upstream documents the metrics API server as a single active instance and recommends the kube-apiserver flag `--enable-aggregator-routing=true` when it runs with more than one replica. Without the flag the kube-apiserver proxies to the Service IP and its long-lived connection tends to stay on one pod; the second replica then mainly shortens failover. The flag is a kube-apiserver setting (RKE2 `kube-apiserver-arg`), outside this chart.
- The chart creates the RoleBinding `keda-operator-auth-reader` in `kube-system` (read access to `extension-apiserver-authentication`). The Argo CD AppProject must allow that destination namespace for RoleBindings.
- If KEDA is removed, the CRDs stay (`Prune=false,Delete=false`). The HPAs that KEDA created are garbage-collected with their ScaledObjects only while the CRDs exist; delete ScaledObjects before removing the CRDs by hand.
