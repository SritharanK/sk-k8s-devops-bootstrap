# nfs-subdir-external-provisioner

Optional wrapper chart for the NFS subdir external provisioner. It creates the StorageClass `nfs` and provisions every PersistentVolumeClaim of that class as a subdirectory of one existing NFS export.

## Upstream and versions

| Item | Value |
|---|---|
| Upstream chart | `nfs-subdir-external-provisioner` 4.0.18 |
| Application | 4.0.2 (`registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`) |
| Wrapper chart | 0.1.0 |
| Source | <https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner> |
| Helm repository | <https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner> |

The project does not publish the chart as an OCI artifact, so the dependency uses its Helm repository. 4.0.18 (2023) is the newest release. Upstream activity is low; the chart is optional and no other component depends on it.

## When to use it

Use it for shared `ReadWriteMany` storage in the lab or on small on-premises clusters that already have an NFS server.

Do not use it where volumes need high availability, snapshots, capacity enforcement or per-volume isolation. The provisioner only creates directories: the NFS server is a single point of failure, requested sizes are not enforced, and every volume on the share is reachable by any client that can mount the export. Prefer Longhorn or a CSI driver for the storage backend in those cases.

## Configuration

Owner values live in `values.yaml` under the `nfs-subdir-external-provisioner` key.

- `nfs.server` is `CHANGE_ME` and must be set per cluster. `nfs.path` is `/srv/nfs`, mounted with `nfsvers=4.1`.
- StorageClass `nfs` is never the default class, so no claim lands on the share by accident. Workloads opt in with `storageClassName: nfs`.
- `reclaimPolicy: Delete` with `archiveOnDelete: true`: when a PVC is deleted, its directory is renamed `archived-<name>` on the share instead of removed. Archived directories are cleaned up by hand.
- `allowVolumeExpansion: true`, access mode `ReadWriteMany`.
- The provisioner name is pinned to `cluster.local/nfs-subdir-external-provisioner`. It is immutable in the StorageClass and recorded on every provisioned PersistentVolume.
- No nodeSelector: the provisioner runs on any worker node.
- CPU and memory requests and limits are explicit.
- Security context: `RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped. The pod is not forced to run as non-root, because the provisioner creates, chmods and renames directories on the export as the container user and the upstream image runs as root. The namespace therefore runs Pod Security Standards `baseline`, set by the toolchain Application.

Because `nfs.mountOptions` is set, the upstream chart mounts the export into the provisioner through a cluster-scoped static PersistentVolume (`pv-nfs-subdir-external-provisioner`, reclaim policy `Retain`) and a PersistentVolumeClaim, instead of an inline `nfs` volume.

## Profiles

| Profile | Delta |
|---|---|
| `lab` | None. Set `nfs.server` when the chart is enabled. |
| `reference` | None in values. The file documents the export restriction below. |

## Export restriction

The previous setup exported the share read-write to every client and made it the default StorageClass. The NFS export must be restricted to the node CIDR, read-write only for the cluster nodes, with `root_squash` where possible. With `root_squash` the export root must be writable by the squashed user (`nobody` or the `anonuid` set on the export). The export is provisioned by the Ansible `nfs_server` role, not by this chart.

## Deployment

Argo CD Application `nfs-subdir-external-provisioner`, namespace `nfs-provisioner`, sync wave 4. Disabled by default in every profile. Enable it per cluster in `clusters/<name>/cluster.yaml`:

```yaml
toolchains:
  nfs-subdir-external-provisioner:
    enabled: true
```

## Upgrades

1. Read the upstream release notes for every chart and application version in between.
2. Bump `dependencies[0].version` and `appVersion` in `Chart.yaml`.
3. Run `helm dependency update helmcharts/system-charts/nfs-subdir-external-provisioner` and commit the new `Chart.lock`.
4. Diff the `helm template` output for both profiles against the previous version before merging. The StorageClass `provisioner` and `parameters` are immutable: a change there means recreating the StorageClass.
