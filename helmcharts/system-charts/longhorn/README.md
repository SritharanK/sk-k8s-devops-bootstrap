# longhorn

Longhorn distributed block storage. It is the default StorageClass of the reference cluster: every volume is replicated to three nodes, and an S3 bucket is configured as the backup target.

| Item | Value |
| --- | --- |
| Upstream chart | longhorn 1.12.2 from <https://charts.longhorn.io> |
| Upstream app version | v1.12.2 |
| Upstream source | <https://github.com/longhorn/longhorn> |
| Namespace | longhorn-system (Pod Security: privileged, the manager, CSI plugin and instance managers need host access) |
| Enabled by default | No. Switch on with `toolchains.longhorn.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Version choice

The release table in the upstream README (checked 2026-11-16) lists 1.13 with latest version 1.13.0 and no stable version. The 1.12 branch is under active support, has a stable designation (1.12.1) and 1.12.2 as its latest patch. The chart uses 1.12.2, the newest patch of the newest branch that has a stable release.

## Profiles

| Setting | lab (single-node RKE2) | reference (3-node RKE2) |
| --- | --- | --- |
| StorageClass `longhorn` default class | no (local-path is the lab default) | yes |
| Replicas per volume (StorageClass and UI default) | 1 | 3 |
| CSI attacher, provisioner, resizer, snapshotter replicas | 1 | 3 |
| UI replicas / PodDisruptionBudget | 1 / none | 2 / minAvailable 1 |
| Node drain policy | `allow-if-replica-is-stopped` | upstream default `block-if-contains-last-replica` |
| Instance manager CPU reservation | 5% of node CPU | upstream default 12% |
| Manager requests / memory limit | 50m, 128Mi / 512Mi | 100m, 256Mi / 1Gi |
| Default backup target | none | `s3://CHANGE_ME-longhorn@CHANGE_ME/` |

Common to both profiles:

- `preUpgradeChecker.jobEnabled: false`, as Longhorn documents for Argo CD. The manager still refuses unsupported upgrade paths (`preUpgradeChecker.upgradeVersionCheck` stays on).
- `deletingConfirmationFlag: false`: the uninstall protection stays on (see Uninstall).
- Upgrade checker and usage metrics collection are off; versions come from Git.
- Volume engines are upgraded automatically after a manager upgrade, one per node at a time (`concurrentAutomaticEngineUpgradePerNodeLimit: 1`; upstream default 0 means a manual step in the UI).
- The UI is not exposed: no Ingress, no HTTPRoute, Service type ClusterIP. Use `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`.
- ServiceMonitor `longhorn-prometheus-servicemonitor` with label `release: monitoring`.
- Upstream NetworkPolicies (`networkPolicies.restrictInternalTraffic`, on by default) stay on. The manager port TCP/9500 is opened to pods labelled `app.kubernetes.io/name: prometheus` in namespace `monitoring` only.
- CSI sidecars get requests and memory limits through the `system-managed-csi-components-resource-limits` setting. CPU limits are left out on purpose to avoid throttling.
- Data-engine-specific settings use the per-engine format of Longhorn 1.12 (`{"v1": ..., "v2": ...}`). In values they are written as a map and the chart renders the JSON string.

Longhorn cannot run on kind: the V1 data engine needs open-iscsi with a running iscsid on every node, which kind node containers do not provide. Keep `toolchains.longhorn.enabled` false on kind.

## Node prerequisites

The provisioning layer must prepare every RKE2 node before Longhorn is enabled (Longhorn 1.12 installation requirements, V1 data engine):

| Requirement | Detail |
| --- | --- |
| open-iscsi | Installed, `iscsid` enabled and running, kernel module `iscsi_tcp` loaded before `iscsid` starts. Avoid open-iscsi 2.1.12, which breaks volume attachment. |
| NFSv4 client | `nfs-common` (Debian, Ubuntu), `nfs-utils` (RHEL family) or `nfs-client` (SUSE). Needed for RWX volumes (NFSv4.1) and NFS backup targets. |
| multipathd | Either disabled, or Longhorn devices blacklisted in `/etc/multipath.conf` with `blacklist { devnode "^sd[a-z0-9]+" }` followed by `systemctl restart multipathd`. Otherwise multipathd claims Longhorn block devices and mounts fail. |
| Tools | `bash`, `curl`, `findmnt`, `grep`, `awk`, `blkid`, `lsblk`; `dmsetup` (`device-mapper`); `cryptsetup` for encrypted volumes. |
| Filesystem | ext4 or XFS under the data path `/var/lib/longhorn/` (upstream default). A dedicated disk mounted there is recommended. |
| Mount propagation | Enabled (the RKE2 default). |

Check a node with `longhornctl check preflight`; `longhornctl install preflight` can install the missing packages.

## Secrets

| Secret | Namespace | Keys | Used by |
| --- | --- | --- | --- |
| `longhorn-s3-credentials` | `longhorn-system` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS` (S3 endpoint URL); optional `AWS_CERT` (CA bundle for a private CA), `VIRTUAL_HOSTED_STYLE` | default backup target (reference) |

Longhorn reads the Secret only from its own namespace. The backup target URL format is `s3://<bucket>@<region>/` and must end with `/`.

Reference, through External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: longhorn-s3-credentials
  namespace: longhorn-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: longhorn-s3-credentials
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: CHANGE_ME/longhorn-s3
        property: access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: CHANGE_ME/longhorn-s3
        property: secret_access_key
    - secretKey: AWS_ENDPOINTS
      remoteRef:
        key: CHANGE_ME/longhorn-s3
        property: endpoint
```

The lab profile sets no backup target. To back up lab volumes to SeaweedFS, set `defaultBackupStore.backupTarget: s3://longhorn@us-east-1/` and `backupTargetCredentialSecret: longhorn-s3-credentials` in `values-lab.yaml`, create bucket `longhorn` and create the Secret with the access key that SeaweedFS accepts:

```bash
kubectl -n longhorn-system create secret generic longhorn-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=CHANGE_ME \
  --from-literal=AWS_SECRET_ACCESS_KEY=CHANGE_ME \
  --from-literal=AWS_ENDPOINTS=http://seaweedfs-s3.seaweedfs.svc:8333
```

## Dependencies

| Component | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that selects `release: monitoring`. Prometheus pods must carry `app.kubernetes.io/name: prometheus` (Prometheus Operator default) to pass the manager NetworkPolicy. |
| Provisioning layer | Node prerequisites above, and the data disk under `/var/lib/longhorn/`. |
| S3 object storage (reference) | Bucket `CHANGE_ME-longhorn` and the credentials in `longhorn-s3-credentials`. |

## Upgrade

1. Read the upgrade page and important notes of the target version: <https://longhorn.io/docs/1.12.2/deploy/upgrade/> and <https://longhorn.io/docs/1.12.2/important-notes/> (replace the version in the URL).
2. Longhorn supports upgrades from one minor version to the next only (1.12.x to 1.13.x, never 1.11.x to 1.13.x), and no downgrades. Patch upgrades within a minor version are supported.
3. Change the dependency `version` and `appVersion` in `Chart.yaml`, run `helm dependency update`, then lint and render both profiles.
4. Compare the new upstream `values.yaml` with the old one; settings can change name or format between minor versions.
5. After Argo CD syncs, the manager upgrades volume engines automatically, one per node at a time.

## Uninstall

The chart's `longhorn-uninstall` Job is a Helm `pre-delete` hook, which Argo CD 3.3 and later run as a PreDelete hook when the Application is deleted. The Job fails while `deletingConfirmationFlag` is false, and a failed PreDelete hook blocks the deletion. To remove Longhorn on purpose:

1. Make sure no PersistentVolumes of class `longhorn` are still needed.
2. Set `longhorn.defaultSettings.deletingConfirmationFlag: true` in the profile values and let Argo CD sync.
3. Set `toolchains.longhorn.enabled: false` for the cluster.

## Known limitations

- CRDs: the chart renders its 25 CRDs from `templates/crds.yaml` without a value for annotations, so they do not carry the platform's CRD annotation `argocd.argoproj.io/sync-options: Prune=false,Delete=false` and have no `helm.sh/resource-policy: keep`. Deleting the Application or pruning a CRD would delete every Longhorn custom resource of that type. Protection relies on the uninstall Job above, which needs Argo CD 3.3 or later; older versions do not run Helm `pre-delete` hooks.
- Resources: the chart offers no resource values for the UI, the driver deployer, the `pre-pull-share-manager-image` container of the manager DaemonSet, and the post-upgrade and uninstall Jobs. Pods that the manager creates (instance managers, engine images, share managers, backing image managers) only get the CPU reservation from `guaranteedInstanceManagerCPU`.
- The `longhornUI.podDisruptionBudget` values of chart 1.12.2 are not used by any template. This wrapper renders the UI PodDisruptionBudget itself (`uiPodDisruptionBudget`); remove it once upstream renders its own.
- Argo CD cannot tell an install from an upgrade, so the `post-upgrade` Job runs as a PostSync hook after every sync, not only after a version change.
- Change Longhorn settings in the values files, not in the UI, so Git stays the source of truth.
- No recurring snapshot or backup jobs are defined. The backup target is configured, but volumes are only backed up by Longhorn when a `RecurringJob` (or an on-demand backup) exists; until then, rely on the platform backup tooling.
