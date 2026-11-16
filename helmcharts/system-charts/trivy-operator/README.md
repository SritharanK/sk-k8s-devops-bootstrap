# trivy-operator

Continuous security scanning inside the cluster: Trivy Operator scans running workload images for vulnerabilities and exposed secrets, audits Kubernetes configuration and RBAC, assesses nodes against CIS checks, and stores the results as Kubernetes reports next to the workloads.

| Item | Value |
| --- | --- |
| Upstream chart | trivy-operator 0.38.1 from `https://aquasecurity.github.io/helm-charts` (no OCI artifact is published) |
| Upstream app version | 0.36.1 (Trivy 0.76.1, node-collector 0.3.1) |
| Upstream source | <https://github.com/aquasecurity/trivy-operator> |
| Namespace | trivy-system (Pod Security: privileged, the node-collector Job reads node files through hostPath volumes) |
| Enabled by default | No. Switch on with `toolchains.trivy-operator.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

Workloads:

| Workload | Purpose |
| --- | --- |
| Deployment `trivy-operator` | Watches workloads, creates scan Jobs, writes the reports, exposes metrics |
| StatefulSet `trivy-server` | Built-in Trivy server: holds the vulnerability database for all scans |
| Scan Jobs (created at runtime, in `trivy-system`) | One per workload image set, Trivy in client mode against `trivy-service:4954` |
| node-collector Jobs (created at runtime) | One per node, read node configuration files for the CIS and infra assessment |

Report kinds (CRDs in `aquasecurity.github.io`): VulnerabilityReport, ExposedSecretReport, ConfigAuditReport, RbacAssessmentReport, InfraAssessmentReport, SbomReport, their cluster-scoped variants, and ClusterComplianceReport.

## Design

| Setting | Value | Reason |
| --- | --- | --- |
| Scan mode | ClientServer with the built-in server (`operator.builtInTrivyServer: true`) | In Standalone mode the init container of every scan job pod downloads the full vulnerability database. The server downloads it once, keeps it current and serves every scan. |
| `trivy.ignoreUnfixed` | `true` | Reports list only vulnerabilities with a fixed version, so every finding is actionable |
| Scan job concurrency | lab 1, reference 3 (`operator.scanJobsConcurrentLimit`, upstream 10) | Bounds the load on nodes and on the registries |
| Config audit checks | Embedded in the operator (`trivy.useEmbeddedRegoPolicies: "true"`, upstream default) | Check versions follow the operator version; no checks bundle download |
| Image registry | `mirror.gcr.io` (upstream default) | Avoids Docker Hub pull limits |

All images are pinned by the upstream chart. Two inputs float on purpose, because they are data feeds and not software: the vulnerability database `mirror.gcr.io/aquasec/trivy-db` and the Java database `mirror.gcr.io/aquasec/trivy-java-db` (schema version tags, rebuilt several times a day). Pinning them would freeze the vulnerability knowledge.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Scanned namespaces | `dev`, `stage`, `prod` (`targetNamespaces`) | all except `kube-system` (`excludeNamespaces`) |
| Concurrent scan jobs | 1 | 3 |
| Operator replicas | 1 | 1 |
| Trivy server replicas | 1 | 1 |
| Trivy server cache | emptyDir (database downloaded again after a restart) | PVC 5Gi, default StorageClass |
| Operator requests / memory limit | 50m, 128Mi / 512Mi | 100m, 256Mi / 1Gi |
| Scan job requests / memory limit | 50m, 128Mi / 512Mi | 100m, 256Mi / 1Gi |
| Trivy server requests / memory limit | 50m, 512Mi / 1Gi | 200m, 512Mi / 2Gi |
| ServiceMonitor (`release: monitoring`) | yes | yes |

Operator and server stay at one replica in both profiles: scanning is background work, an outage only delays reports, and without PodDisruptionBudgets node drains are never blocked. CPU limits are not set on purpose, to avoid throttling; the upstream CPU limits on scan jobs and server are removed with `cpu: null`.

Namespace selection applies to workload scans and config audits. RBAC assessment, the node infra assessment and the compliance reports are cluster-wide in both profiles.

Security: the operator runs as UID 10000 and the server as UID 65534, both non-root with a read-only root filesystem, no privilege escalation, all capabilities dropped and `RuntimeDefault` seccomp. Scan job containers get the same container settings. The namespace is still `privileged` because the node-collector Jobs mount host paths (`/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd` and others) and use the host PID namespace.

## Reading results

```bash
kubectl get vulnerabilityreports -n dev -o wide
kubectl get configauditreports -A -o wide
kubectl get clustercompliancereports
```

The metrics (`trivy_image_vulnerabilities`, `trivy_resource_configaudits` and others) are scraped by the platform Prometheus. No Trivy dashboard or alert rule exists in this repository; build them on these metrics if you need them.

## Secrets

None to provide. The chart renders two Secrets (`trivy-operator` and `trivy-operator-trivy-config`) with empty values; they only exist so optional credentials can be added. Private registry images are scanned with the workload's own `imagePullSecrets` and service account (`operator.accessGlobalSecretsAndServiceAccount: true`, upstream default).

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that scrapes the operator metrics (`release: monitoring`) |

Network: the Trivy server needs HTTPS egress to `mirror.gcr.io` for the databases. Scan jobs need egress to every registry that hosts a scanned image. In an air-gapped cluster set `trivy.dbRegistry`, `trivy.javaDbRegistry` and the image registries to an internal mirror.

## Upgrade

1. Read the release notes at <https://github.com/aquasecurity/trivy-operator/releases>. The chart version and the operator version differ (chart 0.38.1 ships operator 0.36.1).
2. Change `dependencies[0].version` (and `appVersion`) in `Chart.yaml`, then run `helm dependency update helmcharts/system-charts/trivy-operator` and commit the new `Chart.lock`.
3. Render both profiles and compare, in particular the CRDs and the Trivy and node-collector image tags in the ConfigMaps.

## Known limitations

- The CRDs come from the upstream `crds/` directory, which Helm renders as is. The chart offers no value to annotate them, so they do not carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false`. If the Application is deleted with its finalizer, Argo CD deletes the CRDs and all reports with them. Reports are rebuilt by the next scans, so no lasting data is lost.
- The default compliance specs are `k8s-cis-1.23`, `k8s-nsa-1.0` and the two Pod Security specs. On RKE2 the node-collector looks for kubeadm file locations; RKE2 keeps its configuration under `/etc/rancher/rke2` and `/var/lib/rancher/rke2`, so several CIS node checks report as failed or unknown. The chart also ships an `rke2-cis-1.24` spec (`compliance.specs`), which needs node-collector volume mounts for the RKE2 paths; not configured here.
- node-collector Jobs have no tolerations, so nodes with NoSchedule or NoExecute taints get no infra assessment unless `nodeCollector.tolerations` is set.
- The reports are stored in etcd. With many workloads in the reference profile, watch the object count and size; upstream offers `alternateReportStorage` (files on a PVC) as an alternative.
