# monitoring

Metrics, alerting and dashboards for the platform: Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics and node-exporter from kube-prometheus-stack, plus alert rules for the core platform components. Every other toolchain ships its ServiceMonitors, PrometheusRules and dashboards against the contract below.

| Item | Value |
| --- | --- |
| Upstream chart | kube-prometheus-stack 93.3.0 and prometheus-operator-crds 33.0.2 from `oci://ghcr.io/prometheus-community/charts` |
| Upstream app version | Prometheus Operator v0.95.2, Prometheus v3.16.0, Alertmanager v0.35.0, Grafana 13.3.1 (Grafana chart 14.4.1), kube-state-metrics v2.20.0, node-exporter v1.12.1 |
| Upstream source | <https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack> |
| Namespace | `monitoring` (Pod Security: privileged, because node-exporter needs hostNetwork, hostPID and hostPath; audit stays at restricted and every other pod is restricted-compliant) |
| Enabled by default | No. Switch on with `toolchains.monitoring.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Contract for other components

| What | Contract |
| --- | --- |
| Scrape and rule objects | ServiceMonitor, PodMonitor, Probe, ScrapeConfig and PrometheusRule objects with label `release: monitoring`, in any namespace. Prometheus uses explicit `matchLabels` selectors and empty namespace selectors. Objects without the label are ignored. |
| Dashboards | ConfigMap in any namespace with label `grafana_dashboard: "1"`. Annotation `grafana_folder: <folder>` picks the Grafana folder. Dashboards in this chart's `dashboards/*.json` become ConfigMaps `monitoring-dashboard-<file name>` in folder `Platform`. |
| Datasource uids | `prometheus` (default), `alertmanager`, `loki`, `tempo` |
| Alert labels | Every alert carries `severity` (`critical`, `warning` or `info`) and the annotations `summary` and `description`. |

In-cluster addresses:

| Service | Address |
| --- | --- |
| Prometheus | `http://monitoring-prometheus.monitoring.svc:9090` |
| Alertmanager | `http://monitoring-alertmanager.monitoring.svc:9093` |
| Grafana | `http://monitoring-grafana.monitoring.svc:80` |
| Grafana (external) | `https://grafana.<cluster domain>` through HTTPRoute `monitoring-grafana` on Gateway `envoy-gateway-system/platform`, listener `https`. With ACME HTTP-01, add `grafana.<domain>` to `platform.gateway.hostnames`, or the certificate does not cover it |
| Operator | `monitoring-operator.monitoring.svc:443` (admission webhook) |

Prometheus and Alertmanager are not exposed through the Gateway. Use a port-forward:

```bash
kubectl -n monitoring port-forward svc/monitoring-prometheus 9090:9090
kubectl -n monitoring port-forward svc/monitoring-alertmanager 9093:9093
```

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Prometheus | 1 replica, retention 2d, emptyDir | 2 replicas, retention 31d (covers the 30-day SLO window) and 40GB, 50Gi PVC on the default StorageClass, hard anti-affinity per node, PDB `minAvailable: 1`, Service session affinity |
| Alertmanager | 1 replica, emptyDir | 3 replicas, 2Gi PVC, soft anti-affinity, PDB `minAvailable: 2` |
| Receivers | Placeholders without integrations; alerts are visible in the Alertmanager UI | Webhooks, URLs read from files in Secret `alertmanager-receivers` |
| Grafana | 1 replica, admin Secret created by hand | 1 replica, admin Secret from ExternalSecret, disabled `auth.generic_oauth` block with placeholders |
| Datasources | Prometheus, Alertmanager | Prometheus, Alertmanager, Loki |
| Control plane scraping | Off (kind binds the components to 127.0.0.1); matching rule groups off | kube-controller-manager, kube-scheduler, etcd and kube-proxy on RKE2 ports (see RKE2 prerequisites) |
| Requests and memory limits | Small (Prometheus 512Mi request, 1536Mi limit) | Production (Prometheus 3Gi request, 6Gi limit) |

Every container has CPU and memory requests and a memory limit. CPU limits are left out on purpose to avoid throttling Prometheus during compaction and rule evaluation.

Per-cluster values come from the Argo CD Application: `route.hostnames`, `prometheusSpec.externalLabels.cluster` and Grafana `server.root_url`.

## Alerting

Route tree (both profiles, grouped by `alertname`, `namespace`, `severity`):

| Match | Receiver | Purpose |
| --- | --- | --- |
| `alertname="Watchdog"` | `heartbeat` | Dead man's switch. Watchdog always fires and is repeated every 5 minutes. The receiving side must alert when it stops arriving. |
| `alertname="InfoInhibitor"` | `null` | Helper alert that only suppresses `info` alerts. |
| `severity="critical"` | `platform-critical` | Paging channel. |
| anything else | `platform-default` | Default channel. |

The upstream inhibit rules are kept: a `critical` alert suppresses `warning` and `info` alerts with the same `alertname` and `namespace`.

The kube-prometheus-stack default rules stay on. Watchdog is the test alert for a demo: open the Alertmanager UI through the port-forward above and it is listed under receiver `heartbeat`. In reference it reaches the heartbeat webhook every 5 minutes.

Platform rules rendered by this chart (label `release: monitoring`, one PrometheusRule per group):

| Toggle | Alert | Condition | Severity |
| --- | --- | --- | --- |
| `platformRules.argocd.enabled` | ArgoCdApplicationOutOfSync | `argocd_app_info{sync_status="OutOfSync"}` for 30m | warning |
| | ArgoCdApplicationUnhealthy | `argocd_app_info{health_status=~"Degraded\|Missing"}` for 15m | warning |
| | ArgoCdApplicationSyncFailed | `increase(argocd_app_sync_total{phase=~"Error\|Failed"}[15m]) > 0` | warning |
| `platformRules.certManager.enabled` | CertManagerCertificateExpiringSoon | 7 to 14 days left, for 1h | warning |
| | CertManagerCertificateExpiryCritical | less than 7 days left, for 1h | critical |
| | CertManagerCertificateNotReady | `certmanager_certificate_ready_status{condition="False"} == 1` for 15m | warning |
| `platformRules.kyverno.enabled` | KyvernoAdmissionLatencyHigh | p99 of `kyverno_admission_review_duration_seconds_bucket` above 1s for 10m | warning |
| `platformRules.velero.enabled` | VeleroBackupFailed | `increase(velero_backup_failure_total[1h]) > 0` | warning |
| | VeleroNoRecentBackup | `time() - velero_backup_last_successful_timestamp{schedule!=""} > 90000` (25h) | critical |

## Secrets

| Secret | Namespace | Keys | lab | reference |
| --- | --- | --- | --- | --- |
| `grafana-admin` | monitoring | `admin-user`, `admin-password` | Created by hand (below) | ExternalSecret, store `ClusterSecretStore/openbao`, remote key `platform/monitoring/grafana-admin`, properties `admin-user` and `admin-password`, sync wave -1 |
| `alertmanager-receivers` | monitoring | `default-webhook-url`, `critical-webhook-url`, `heartbeat-webhook-url` | Not used | ExternalSecret, remote key `platform/monitoring/alertmanager-receivers`, same property names, sync wave -1. Mounted at `/etc/alertmanager/secrets/alertmanager-receivers/` through `alertmanagerSpec.secrets`. |
| `grafana-oauth` | monitoring | `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` | Not used | Only when SSO is switched on; create it and uncomment `envFromSecrets` in `values-reference.yaml`. |

Lab: create the Grafana admin Secret with a generated password once the first sync has created the namespace. Grafana waits in `CreateContainerConfigError` until it exists.

```bash
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
# Read it back when you need to log in.
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Grafana is stateless: no persistent volume, dashboards and datasources come from Git. Changes made in the UI are lost when the pod restarts.

## RKE2 prerequisites (reference)

kube-controller-manager, kube-scheduler, etcd metrics and kube-proxy metrics listen on 127.0.0.1 by default. Add this to `/etc/rancher/rke2/config.yaml` on every server node and restart `rke2-server`. kube-proxy runs on every node, so agent nodes need the `kube-proxy-arg` line too (restart `rke2-agent`).

```yaml
kube-controller-manager-arg:
  - bind-address=0.0.0.0
kube-scheduler-arg:
  - bind-address=0.0.0.0
etcd-expose-metrics: true
kube-proxy-arg:
  - metrics-bind-address=0.0.0.0:10249
```

| Component | Port | Scheme | Service selector (kube-system) |
| --- | --- | --- | --- |
| kube-controller-manager | 10257 | https, `insecureSkipVerify` (self-signed serving certificate), bearer token | `component: kube-controller-manager` |
| kube-scheduler | 10259 | https, `insecureSkipVerify`, bearer token | `component: kube-scheduler` |
| etcd | 2381 | http | `component: etcd` |
| kube-proxy | 10249 | http | `component: kube-proxy` (RKE2 static pod label; the upstream default `k8s-app: kube-proxy` only matches the kubeadm DaemonSet) |

These ports are then reachable on the node addresses. Restrict them at the host firewall to the cluster and node CIDRs.

## CRD protection

The Prometheus Operator CRDs come from the `prometheus-operator-crds` dependency; kube-prometheus-stack runs with `crds.enabled: false`. Every CRD carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false` and `helm.sh/resource-policy: keep`. Deleting or pruning the `monitoring` Application therefore leaves the CRDs in place, and with them every ServiceMonitor, PodMonitor and PrometheusRule that other toolchains ship. Removing the CRDs is a separate, deliberate manual step.

The CRDs are applied with server-side apply (set on the Application); several of them are too large for a client-side apply annotation.

## Dependencies

| Needs | Why |
| --- | --- |
| cert-manager (core) | Issues the operator admission webhook certificate (self-signed CA Issuer in this namespace) and injects the CA bundle. The Application ignores `caBundle` on the webhook configurations. This replaces the upstream Helm hook Jobs. |
| Envoy Gateway, Gateway `envoy-gateway-system/platform` | HTTPRoute for Grafana. The `https` listener must allow routes from namespace `monitoring`. |
| External Secrets Operator and `ClusterSecretStore/openbao` (reference) | `grafana-admin` and `alertmanager-receivers` |
| Default StorageClass (reference) | Prometheus and Alertmanager PVCs |
| `logging` toolchain (reference) | Loki datasource. Set `datasources.loki.tenant` if Loki runs with `auth_enabled: true`. |
| `tracing` toolchain | Tempo datasource, off in both profiles until `datasources.tempo.enabled: true` |
| AppProject `platform` | Destination namespace `kube-system` (exporter Services), and the cluster-scoped kinds `CustomResourceDefinition`, `ClusterRole`, `ClusterRoleBinding`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration` |

Other toolchains depend on this one: their ServiceMonitors, PodMonitors and PrometheusRules need the CRDs and the `release: monitoring` selector.

## Upgrade

kube-prometheus-stack and prometheus-operator-crds move together. The `appVersion` of prometheus-operator-crds must equal the `appVersion` of kube-prometheus-stack (the operator version), otherwise the operator runs against CRDs that lack fields it writes or reads.

1. Read the upgrade notes: <https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md#upgrading-chart>
2. Check both app versions before changing anything:

   ```bash
   helm show chart oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version <new> | grep appVersion
   helm show chart oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds --version <new> | grep appVersion
   ```

3. Change both versions in `Chart.yaml`, run `helm dependency update helmcharts/system-charts/monitoring` and commit `Chart.lock`.
4. Render both profiles before and after and review the diff, in particular `alertmanager.config`, the Grafana values and the default rule names.

Argo CD applies the CRDs and the operator in the same sync. Because the CRDs are `Prune=false`, a CRD dropped upstream stays in the cluster until it is removed by hand.

## Known limitations

- Grafana runs one replica. Without an external database each pod has its own SQLite database and sessions, so a second replica would break logins behind the Gateway.
- The upstream Grafana ClusterRole grants read access to Secrets in every namespace. This chart binds Grafana to its own ClusterRole `monitoring-grafana-configmaps` (ConfigMaps only), so dashboards and datasources must be ConfigMaps, not Secrets.
- Lab keeps Prometheus and Alertmanager data in emptyDir volumes; it is lost when a pod is rescheduled.
- The two reference Prometheus replicas scrape independently. There is no deduplicated long-term store.
- The platform rules stay silent while the component they watch is not installed; there are no `absent()` alerts.
- `increase()` returns 0 for a counter series that first appears with a non-zero value, so the first failed sync of a brand-new Argo CD application, or the first failed backup of a new Velero schedule, can go unreported.
- The `auth.generic_oauth` block in `values-reference.yaml` is a disabled template with `https://idp.example.com` and `CHANGE_ME` placeholders.
- A plain `helm install` outside Argo CD fails on the first run, because the CRDs are templates of this chart and Helm validates the ServiceMonitors and PrometheusRules before it creates them. Apply the CRDs first: `helm template monitoring . -f values.yaml -f values-lab.yaml | yq 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side -f -`, then install with `helm upgrade --install --take-ownership monitoring .` so Helm adopts them. Argo CD needs no such step: it applies CRDs before the rest of a sync.
