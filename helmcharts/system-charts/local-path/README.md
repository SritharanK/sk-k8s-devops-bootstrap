# local-path

Rancher local-path-provisioner, which turns a directory on the node into PersistentVolumes. It gives a single-node RKE2 lab a default StorageClass without running a distributed storage system.

| Item | Value |
| --- | --- |
| Upstream chart | local-path-provisioner 0.0.37, vendored from the Git repository because upstream publishes no Helm repository (see `vendor/README.md`) |
| Upstream app version | v0.0.37 |
| Upstream source | <https://github.com/rancher/local-path-provisioner> |
| Namespace | local-path (Pod Security: privileged, the helper pods mount the node path through hostPath and run as root) |
| Enabled by default | No. Switch on with `toolchains.local-path.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Where it runs

| Cluster | Use this chart |
| --- | --- |
| Single-node RKE2 lab | Yes. StorageClass `local-path` is the default class. |
| kind | No. kind already ships the same provisioner and its own default class. Keep `toolchains.local-path.enabled` false. |
| Reference (3-node RKE2) | No. Longhorn is the default class there. The reference profile exists only so a render does not fail; it never sets the default class. |

The names are chosen so the chart does not collide with the provisioner that kind installs, in case both end up on one cluster:

| Object | This chart | kind built-in |
| --- | --- | --- |
| Namespace | `local-path` | `local-path-storage` |
| StorageClass | `local-path` | `standard` |
| Provisioner name | `cluster.local/local-path-provisioner` | `rancher.io/local-path` |

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Default StorageClass | yes | no |
| Provisioner requests / memory limit | 10m, 32Mi / 128Mi | 20m, 64Mi / 256Mi |
| Helper pod requests / memory limit | 10m, 16Mi / 64Mi | 10m, 16Mi / 64Mi |
| Replicas | 1 | 1 |

Common to both profiles:

- Volume type `hostPath`, reclaim policy `Delete`, binding mode `WaitForFirstConsumer`.
- Provisioner image `docker.io/rancher/local-path-provisioner:v0.0.37`, helper image `docker.io/library/busybox:1.36.1` (upstream defaults to the floating `latest` tag; 1.36.1 is the release behind the busybox `stable` tag).
- The provisioner pod is restricted-compliant: UID 65534, `runAsNonRoot`, read-only root filesystem, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp. The image is a static binary on `scratch`.
- CPU limits are left out on purpose to avoid throttling; memory limits are set.

## Node path

Volumes are created under `/var/lib/rancher/local-path-provisioner` on every node (`nodePathMap` entry `DEFAULT_PATH_FOR_NON_LISTED_NODES`; upstream default is `/opt/local-path-provisioner`).

| Reason | Detail |
| --- | --- |
| Same filesystem as RKE2 data | RKE2 keeps container images, etcd and other state in `/var/lib/rancher/rke2`, so that filesystem is already sized for bulk data. `/opt` is usually part of the root filesystem. |
| Survives an RKE2 uninstall | `rke2-uninstall.sh` removes `/var/lib/rancher/rke2` and only removes `/var/lib/rancher` when it is empty, so volume data outside the RKE2 data directory is kept. |
| Familiar location | k3s keeps its built-in local-path volumes under `/var/lib/rancher/k3s/storage`. |

The helper pod creates the directory with `mkdir -p`, so the node needs no preparation, with one exception: on nodes with SELinux in enforcing mode, the provisioning layer must label the path for container use, for example `semanage fcontext -a -t container_file_t '/var/lib/rancher/local-path-provisioner(/.*)?'` followed by `restorecon -R /var/lib/rancher/local-path-provisioner`.

## Secrets

None.

## Dependencies

None. The upstream chart has no metrics port and no ServiceMonitor, so nothing is scraped.

## Upgrade

The chart is vendored, not pulled. Follow the update procedure in `vendor/README.md`: download the new tag, record its sha256, replace the vendored directory, bump the dependency `version`, `appVersion` and `image.tag`, then run `helm dependency update`. Read the release notes at <https://github.com/rancher/local-path-provisioner/releases> first.

## Known limitations

- Volumes are node-local. A PV is pinned to its node through node affinity; if the node is lost, the data is lost. Use it for lab data and caches, not for data that must survive a node.
- The requested capacity is not enforced (upstream: "No support for the volume capacity limit currently"). A volume can fill the node filesystem.
- Only single-node access modes are useful with `nodePathMap`; there is no `ReadWriteMany`.
- The provisioner runs with leader election disabled upstream, so it must stay at one replica. No PodDisruptionBudget is created.
- The upstream chart offers no security context for the helper pods. They run as root with a hostPath mount, which is why the namespace enforces `privileged` instead of `restricted`.
