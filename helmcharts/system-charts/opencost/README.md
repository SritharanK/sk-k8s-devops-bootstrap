# opencost

Cost allocation per namespace, workload and label: OpenCost combines resource usage from the platform Prometheus with an on-premises price list, so teams can see what their workloads cost on this cluster.

| Item | Value |
| --- | --- |
| Upstream chart | opencost 2.5.34 from `oci://ghcr.io/opencost/charts` |
| Upstream app version | 1.121.4 (exporter and UI images pinned by tag and digest in the upstream chart) |
| Upstream source | <https://github.com/opencost/opencost> |
| Namespace | opencost (Pod Security: restricted, no host access or privileges needed) |
| Enabled by default | No. Switch on with `toolchains.opencost.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

One Deployment `opencost` with two containers:

| Container | Port | Purpose |
| --- | --- | --- |
| `opencost` (exporter) | 9003 (`http`) | Cost model API, `/metrics` with price metrics, reads Prometheus |
| `opencost-ui` | 9090 (`http-ui`) | Web UI (nginx), proxies API calls to the exporter |

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Replicas | 1 | 1 |
| PodDisruptionBudget | none | none |
| Exporter requests / memory limit | 20m, 128Mi / 512Mi | 100m, 512Mi / 2Gi |
| UI requests / memory limit | 10m, 32Mi / 128Mi | 10m, 64Mi / 256Mi |
| ServiceMonitor (`release: monitoring`) | yes | yes |
| UI exposed | no (port-forward) | no (port-forward) |

One replica in both profiles. OpenCost keeps no state of its own (the data lives in Prometheus), a restart only delays the API and UI, and a second replica would export every price metric twice. Without a PodDisruptionBudget a node drain is never blocked. CPU limits are not set on purpose, to avoid throttling.

Security: non-root (both images run as UID 1001), `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp. The exporter has a read-only root filesystem: everything it writes goes to `CONFIG_PATH` (`/tmp/custom-config`), an emptyDir that the chart mounts while custom pricing is on. The UI root filesystem stays writable because its entrypoint rewrites the JavaScript under `/var/www` at start and nginx writes its pid and temp files to `/tmp`.

The MCP endpoint (port 8081) is switched off; the platform does not use it.

## Access

The UI and API have no authentication, so neither is published through the Gateway.

```bash
kubectl -n opencost port-forward svc/opencost 9090:9090   # UI at http://localhost:9090
kubectl -n opencost port-forward svc/opencost 9003:9003   # API, for example:
curl -s 'http://localhost:9003/allocation/compute?window=1d&aggregate=namespace'
```

## Custom pricing

The cluster runs on-premises, so there is no cloud billing API. Prices come from the ConfigMap `custom-pricing-model`, rendered from `opencost.opencost.customPricing.costModel` in `values.yaml`. OpenCost watches the ConfigMap and picks up changes without a restart.

The rates in `values.yaml` are illustrative placeholders, not real costs. Every cost figure OpenCost shows is meaningless until they are replaced with your own numbers.

| Key | Unit | Placeholder |
| --- | --- | --- |
| `CPU`, `spotCPU` | price per vCPU-hour | 0.01 |
| `RAM`, `spotRAM` | price per GiB-hour | 0.001 |
| `GPU` | price per GPU-hour | 0 |
| `storage` | price per GiB-hour of persistent volume | 0.0001 |
| `zoneNetworkEgress`, `regionNetworkEgress`, `internetNetworkEgress` | price per GiB | 0 |

The units follow the upstream default price list (`configs/default.json` in the OpenCost repository), which holds hourly list prices, for example `CPU: 0.031611` per vCPU-hour. To derive your own rates, divide the monthly cost of a node class (hardware depreciation, power, rack space, licences, support) over its vCPUs and memory and over 730 hours.

OpenCost selects this custom provider because the nodes carry no public cloud provider ID (kind and RKE2 on own hardware).

## Secrets

None. Prometheus is read inside the cluster without credentials, and cloud billing integration is not used.

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | Required. OpenCost queries the platform Prometheus at `monitoring-prometheus.monitoring.svc:9090` (rendered as the FQDN `monitoring-prometheus.monitoring.svc.cluster.local:9090`) and needs the metrics that kube-prometheus-stack collects: cAdvisor and kubelet, kube-state-metrics and node-exporter. The ServiceMonitor (`release: monitoring`) is mandatory, not optional: OpenCost reads its own price metrics back from Prometheus. |

Without the monitoring toolchain the exporter starts but returns no allocation data.

## Upgrade

1. Read the release notes at <https://github.com/opencost/opencost/releases> and the chart changes at <https://github.com/opencost/opencost-helm-chart/releases>.
2. Change `dependencies[0].version` (and `appVersion`) in `Chart.yaml`, then run `helm dependency update helmcharts/system-charts/opencost` and commit the new `Chart.lock`.
3. Render both profiles and compare. Check that the upstream chart still pins the images by digest, that `CONFIG_PATH` is still an emptyDir (required by the read-only root filesystem), and that the custom pricing keys did not change.

## Known limitations

- The cluster ID in the cost data is the upstream default `default-cluster` (`opencost.opencost.exporter.defaultClusterId`). Set a unique value if several clusters share one Prometheus or Grafana.
- Network costs are not collected: the optional network-costs DaemonSet is not part of this chart, and the egress prices are 0.
- The Prometheus address is built from `opencost.clusterName` (`cluster.local`). Change it if the cluster DNS domain differs.
- The UI container cannot run with a read-only root filesystem (see Profiles).
