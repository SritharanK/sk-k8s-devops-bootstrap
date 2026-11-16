# velero

Namespace-level backup and restore for the platform: Velero stores the Kubernetes objects of the application namespaces and, through the node agent, the content of their volumes (Kopia file-system backup) in S3. A second schedule keeps a copy of the Sealed Secrets controller keys, so sealed manifests in Git stay decryptable after a cluster loss.

| Item | Value |
| --- | --- |
| Upstream chart | velero 12.2.5 from `https://vmware-tanzu.github.io/helm-charts` (no OCI artifact is published) |
| Upstream app version | 1.18.2 (image `docker.io/velero/velero:v1.18.2`) |
| Object store plugin | `docker.io/velero/velero-plugin-for-aws:v1.14.4` (the plugin line for Velero 1.18.x) |
| Upstream source | <https://github.com/vmware-tanzu/velero> |
| Namespace | velero (Pod Security: privileged, because the node agent mounts the kubelet pod directory `/var/lib/kubelet/pods` through hostPath and runs as root) |
| Enabled by default | No. Switch on with `toolchains.velero.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

| Workload | Purpose | Security context |
| --- | --- | --- |
| Deployment `velero` | Server: backups, restores, schedules, garbage collection | restricted-compliant: UID 1002 (`cnb`), no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem with `emptyDir` on `/tmp` and `/home/cnb` |
| DaemonSet `node-agent` | Reads and writes pod volume data on each node with Kopia | root, hostPath `/var/lib/kubelet/pods` and `/var/lib/kubelet/plugins`, not privileged; tolerates every taint so it runs on all nodes |
| Jobs (started by Velero) | Kopia repository maintenance; per-volume backup and restore pods | resources from the ConfigMaps `velero-repo-maintenance` and `velero-node-agent-config` |

No VolumeSnapshotLocation is rendered: volume data is copied by the node agent, not by storage snapshots.

## What is backed up

| Schedule (rendered name) | Cron (UTC) | Scope | Volumes | TTL lab / reference |
| --- | --- | --- | --- | --- |
| `velero-platform-daily` | `0 2 * * *` | namespaces `dev`, `stage`, `prod` with their cluster-scoped dependencies (for example PersistentVolumes) | all pod volumes, Kopia file-system backup | 168h / 720h |
| `velero-sealing-key` | `0 1 * * *` | Secrets in `kube-system` with the label `sealedsecrets.bitnami.com/sealed-secrets-key` (active and retired keys) | none | 168h / 720h |

`velero_backup_last_successful_timestamp` and `velero_backup_failure_total` carry these names in the `schedule` label. The alerts on them live in the monitoring chart; the upstream PrometheusRule is off.

Both schedules use `skipImmediately: true`: the first backup runs at the next scheduled time, not at install. That keeps the Kopia repository from being created before a custom repository password is in place. To take a first escrow copy right after install, run a backup from the schedule (Velero CLI):

```bash
velero -n velero backup create --from-schedule velero-sealing-key
```

Volumes are opted out per pod with the annotation `backup.velero.io/backup-volumes-excludes: <volume>,<volume>`. The Sealed Secrets controller namespace is set in `velero.schedules.sealing-key.template.includedNamespaces` (default `kube-system`, where this repository installs the controller).

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| BackupStorageLocation `default` | bucket `velero`, `s3Url: http://seaweedfs-s3.seaweedfs.svc:8333`, region `us-east-1`, path-style | bucket `CHANGE_ME-velero`, `s3Url: https://s3.example.com`, region `CHANGE_ME`, path-style |
| Backup TTL (server default and schedules) | 168h | 720h |
| Server requests / memory limit | 50m, 128Mi / 512Mi | 500m, 512Mi / 1Gi |
| Node agent requests / memory limit | 50m, 128Mi / 512Mi | 200m, 256Mi / 1Gi |
| Per-volume backup and restore pods | 50m, 128Mi / 1Gi | 500m, 512Mi / 2Gi |
| Repository maintenance Jobs | 50m, 128Mi / 512Mi | 500m, 512Mi / 2Gi |
| Plugin init container | 10m, 32Mi / 128Mi | 10m, 32Mi / 128Mi |
| ServiceMonitor and node agent PodMonitor (`release: monitoring`) | yes | yes |

CPU limits are not set on purpose, to avoid throttling Kopia uploads. The Velero server runs one replica by design (the upstream chart fixes `replicas: 1` with a `Recreate` strategy), so neither profile has a PodDisruptionBudget: `minAvailable: 1` on a single replica would block node drains.

## Encryption

| Data | Protection |
| --- | --- |
| Volume content (Kopia repository) | Encrypted client-side by Kopia. The repository key is protected by the repository password in Secret `velero-repo-credentials`. |
| Kubernetes objects (backup tarballs, including every Secret in the namespace) | Stored as compressed JSON, not encrypted by Velero. Protection depends on the bucket. |

Reference: enable default encryption (SSE-S3 or SSE-KMS) on the bucket at the provider, restrict the bucket to the Velero identity, and set `serverSideEncryption: AES256` in the BSL config when the provider supports per-request SSE (commented in `values-reference.yaml`).

## Secrets

| Secret | Namespace | Key | Content | Required |
| --- | --- | --- | --- | --- |
| `velero-s3-credentials` | velero | `cloud` | AWS credentials file: `[default]`, `aws_access_key_id=...`, `aws_secret_access_key=...` | yes; the server and node agent pods do not start without it |
| `velero-repo-credentials` | velero | `repository-password` | Kopia repository password | reference: yes, before the first backup with volumes. lab: optional |

The chart mounts `velero-s3-credentials` at `/credentials/cloud` and never creates it. The S3 identity needs list on the bucket and get, put, delete and multipart upload on its objects, and no access to other buckets.

Velero creates `velero-repo-credentials` with a built-in default password when it does not exist. The Velero documentation allows replacing it only before the first backup that creates the repository; after that, Velero can no longer open the existing repository with a new password (<https://velero.io/docs/v1.18/file-system-backup/>). Keep a copy of the password in escrow: without it, the volume data in the bucket cannot be read.

Lab: the key pair must match an identity in the SeaweedFS Secret `seaweedfs-s3-config`. The seaweedfs README has the commands for both Secrets; `hack/dr/restore-drill.sh --install` creates them with generated keys when they are missing. The lab keeps the default repository password.

Reference, from the platform secret store (External Secrets Operator, ClusterSecretStore `openbao`), created before the Velero Application syncs:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: velero-s3-credentials
  namespace: velero
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: velero-s3-credentials
    creationPolicy: Owner
    template:
      data:
        cloud: |
          [default]
          aws_access_key_id={{ .access_key_id }}
          aws_secret_access_key={{ .secret_access_key }}
  data:
    - secretKey: access_key_id
      remoteRef:
        key: CHANGE_ME/velero/s3
        property: access_key_id
    - secretKey: secret_access_key
      remoteRef:
        key: CHANGE_ME/velero/s3
        property: secret_access_key
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: velero-repo-credentials
  namespace: velero
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: velero-repo-credentials
    creationPolicy: Owner
  data:
    - secretKey: repository-password
      remoteRef:
        key: CHANGE_ME/velero/kopia
        property: repository-password
```

## Dependencies

| Toolchain | Why |
| --- | --- |
| seaweedfs (lab) | S3 endpoint `http://seaweedfs-s3.seaweedfs.svc:8333` and bucket `velero` |
| monitoring | ServiceMonitor and PodMonitor CRDs, Prometheus (`release: monitoring`), Velero alerts |
| sealed-secrets | The controller keys that `velero-sealing-key` escrows |
| External Secrets Operator (reference) | The two Secrets above |

Restore procedures, the restore drill and the RPO and RTO figures are in `hack/dr/README.md`; the narrative is in `docs/operations/backup-and-restore.md`.

## Upgrade

1. Pick the chart version for the target Velero release at <https://github.com/vmware-tanzu/helm-charts/releases> and set it in `Chart.yaml` (`dependencies[0].version`, `appVersion`) and `velero.image.tag`.
2. Set the plugin image to the matching line from the compatibility table at <https://github.com/vmware-tanzu/velero-plugin-for-aws> (v1.14.x for Velero 1.18.x, v1.15.x for 1.19.x).
3. Run `helm dependency update helmcharts/system-charts/velero` and commit `Chart.lock`.
4. Read the upgrade notes (for 1.18: <https://velero.io/docs/v1.18/upgrade-to-1.18/>). CRD changes need no Job: Argo CD applies the CRDs from the chart's `crds/` directory with server-side apply on every sync.
5. Run the restore drill (`make dr-drill`) on a lab cluster before promoting.

## Known limitations

- The Velero CRDs do not follow the CRD rule of the [toolchain convention](../../../docs/architecture/gitops.md#namespaces-and-crds-survive-a-disabled-toolchain). The upstream chart ships them as plain files in `crds/`, which Helm does not template, so `argocd.argoproj.io/sync-options: Prune=false,Delete=false` cannot be added through values. Deleting the Velero Application (it has the resources finalizer) therefore deletes the CRDs and with them every Backup, Restore and Schedule object. The data in the bucket stays; after a reinstall, Velero recreates the Backup objects from the bucket within the sync period (1 minute). Do not delete the Application to pause backups; set `paused: true` on the schedules instead.
- The node agent needs root and hostPath, which is why the namespace is privileged. It is not privileged in the container sense. The kyverno-policies `disallow-privileged-containers-audit` and `disallow-privileged-containers-enforce` match only the environment namespaces (`dev`, `stage`, `prod`), not `velero`. No admission policy in this repository would reject a privileged node agent; keeping it unprivileged is a property of the chart values. The Velero documentation notes that some environments need a privileged node agent; on nodes with SELinux enforcing this has to be confirmed in the reference drill.
- File-system backup copies files from a running pod, so it is crash-consistent at best. Databases need their own backup (CloudNativePG uses its barman-cloud plugin); exclude their data volumes with `backup.velero.io/backup-volumes-excludes`.
- Only `dev`, `stage` and `prod` are scheduled. Platform namespaces are rebuilt from Git by Argo CD and are not backed up.
- Schedule names carry the `velero-` prefix of the upstream chart (`velero-platform-daily`, `velero-sealing-key`).
- Some S3-compatible services reject the default CRC32 request checksum of the AWS plugin; the plugin documentation lists `checksumAlgorithm: ""` in the BSL config as the workaround. Set it only if the reference S3 rejects uploads.
- The server writes the Kopia configuration and cache below `$HOME` (`/home/cnb`), which is an `emptyDir` because of the read-only root filesystem. It is rebuilt after a pod restart.
