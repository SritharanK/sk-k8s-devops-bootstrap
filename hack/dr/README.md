# Disaster recovery

Restore drill, recovery objectives, key escrow and the RKE2 etcd restore runbook. The narrative (roles, decision points, communication) is in [docs/operations/backup-and-restore.md](../../docs/operations/backup-and-restore.md). Component details are in the READMEs of [velero](../../helmcharts/system-charts/velero/README.md) and [seaweedfs](../../helmcharts/system-charts/seaweedfs/README.md).

## Restore drill

`restore-drill.sh` runs a full Velero backup and restore of a throwaway namespace against the current kube context and measures how long the restore takes.

| Claim | How the drill checks it |
| --- | --- |
| Velero can write to and read from the backup storage location | BackupStorageLocation `default` is `Available`; the Backup and the Restore reach phase `Completed` (`Failed`, `PartiallyFailed` and `FailedValidation` fail the drill) |
| Kubernetes objects survive a namespace loss | A ConfigMap and a Secret with random values are compared after the restore |
| Volume data survives a namespace loss | The workload writes a random marker to its claim; after the restore the marker is read with `kubectl exec` and compared. Every PodVolumeBackup and PodVolumeRestore must be `Completed`. The marker is generated inside the pod, so an empty restored volume cannot produce the same value |
| Sealed Secrets keys still decrypt after a restore | A SealedSecret is created with `kubeseal`; the Secret the controller generates is labelled `velero.io/exclude-from-backup=true`. After the restore that Secret only exists if the controller decrypts the restored SealedSecret. Skipped with a log line when the SealedSecret CRD or `kubeseal` is missing |
| A namespace under Pod Security `restricted` can be restored | The drill namespace enforces `restricted`; the Velero restore helper init container must be admitted |
| Namespace restore time | Measured from the namespace deletion to the end of verification and printed as the RTO figure |

What it does not prove: the scheduled backups themselves (the drill takes its own Backup), restores into another cluster, etcd recovery and full cluster recovery. Those are covered by the manual drill below.

### Run

```bash
make dr-drill                                            # current kube context
hack/dr/restore-drill.sh --install                       # lab: install seaweedfs and velero from this repository first
hack/dr/restore-drill.sh --namespace dr-drill-2 --keep --timeout 900
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--install` | off | `helm upgrade --install` of the `seaweedfs` and `velero` charts of this repository (`values.yaml` plus `values-lab.yaml`, after `helm dependency build`), Pod Security labels on both namespaces, and the Secrets `seaweedfs-s3-config` and `velero-s3-credentials` with one generated key pair when they do not exist. Idempotent. Not for clusters where Argo CD manages these charts |
| `--namespace NAME` | `dr-drill` | Drill namespace; it must not exist. System and application namespaces are refused |
| `--keep` | off | Keep the restored namespace for inspection |
| `--timeout SECONDS` | 600 | Limit for each wait step |
| `-h` | | Help, including the environment variables (`VELERO_NAMESPACE`, `SEALED_SECRETS_NAMESPACE`, `SEALED_SECRETS_CONTROLLER`, `DRILL_IMAGE`, `DRILL_STORAGE_CLASS`) |

Requirements: `kubectl`; `helm` with `--install`; `kubeseal` for the SealedSecret part; Velero with its node agent and BackupStorageLocation `default`; a default StorageClass (or `DRILL_STORAGE_CLASS`); the drill image `docker.io/library/busybox:1.37.0` must be pullable. The Velero CLI is not needed.

The Backup (`<namespace>-<UTC timestamp>`) and Restore objects are kept; Velero removes the backup data after its TTL of 168h. The script exits non-zero with a message on the first failed step and removes the drill namespace unless `--keep` is set.

Record every run (date, cluster, profile, RTO line) in `docs/operations/backup-and-restore.md`.

## Recovery objectives

These are the targets of [docs/operations/backup-and-restore.md](../../docs/operations/backup-and-restore.md#recovery-objectives). Each RPO target is the interval of the schedule that takes the backup: etcd `0 */6 * * *` gives 6 hours; the Velero Schedules `velero-platform-daily` (`0 2 * * *`) and `velero-sealing-key` (`0 1 * * *`) in `helmcharts/system-charts/velero/values.yaml` give 24 hours. A failed run extends the RPO until the next successful run. The RTO targets are starting values for a small cluster, not measurements.

| Scope | Target | Mechanism | How it is measured |
| --- | --- | --- | --- |
| Cluster state (etcd) | RPO at most 6 hours; RTO 1 hour | RKE2 scheduled etcd snapshots every 6 hours (`0 */6 * * *`), 10 retained per server node, uploaded to S3 | Age of the newest snapshot: `kubectl get etcdsnapshotfile`, sorted by creation time |
| Namespaces and volume data (`dev`, `stage`, `prod`) | RPO at most 24 hours | Velero schedule `velero-platform-daily`, daily at 02:00 UTC | `velero_backup_last_successful_timestamp{schedule="velero-platform-daily"}`; the monitoring chart alerts on it and on `velero_backup_failure_total` |
| Sealed Secrets keys | RPO at most 24 hours from Velero, 0 with an offline copy after each key renewal; RTO 15 minutes | Velero schedule `velero-sealing-key`, daily at 01:00 UTC; offline escrow (below) | `velero_backup_last_successful_timestamp{schedule="velero-sealing-key"}`; escrow date in the escrow record |
| Namespace restore | RTO 1 hour per namespace, plus volume transfer time | Velero restore from the latest backup | Measured by the restore drill (`RTO (deletion to verified)`), every run recorded |
| Full cluster recovery | RTO 4 hours (not yet validated) | Recovery order below | Manual drill on a lab cluster: time from the start of the etcd restore or fresh install to all Argo CD Applications `Healthy` and the Velero restores `Completed` |

The etcd RPO holds for the loss of the whole cluster only when the snapshots leave the nodes. RKE2 server configuration (`/etc/rancher/rke2/config.yaml` on every server):

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10
etcd-s3: true
etcd-s3-endpoint: s3.example.com
etcd-s3-bucket: CHANGE_ME-etcd
etcd-s3-region: CHANGE_ME
etcd-s3-folder: CHANGE_ME
# Cluster-wide since v1.34.0+rke2r1: about servers x snapshots per server (3 x 10).
etcd-s3-retention: 30
# Credentials: etcd-s3-config-secret, or etcd-s3-access-key and etcd-s3-secret-key
# in this file (mode 0600). Never in Git.
```

## Key escrow

Some material cannot be rebuilt from Git and is useless or dangerous without the rest. Keep it outside the cluster and outside the backup bucket, in the platform secret store and an offline copy, with access limited to the platform administrators.

| Item | Where it lives | Why it is needed |
| --- | --- | --- |
| Sealed Secrets controller keys | Secrets in `kube-system` labelled `sealedsecrets.bitnami.com/sealed-secrets-key` | Without them no SealedSecret in Git can be decrypted on a rebuilt cluster; every secret would have to be sealed again from source values |
| RKE2 server token | `/var/lib/rancher/rke2/server/token` on a server node | An etcd snapshot can only be restored with the token that was in use when it was taken; it decrypts the bootstrap data in the snapshot |
| Velero Kopia repository password | Secret `velero/velero-repo-credentials`, key `repository-password` | Without it the volume data in the bucket cannot be read |
| S3 credentials for Velero and etcd snapshots | `velero/velero-s3-credentials`, RKE2 config | Needed to read the backups during recovery |

### Sealing key

The controller renews its key every 30 days by default and keeps the old keys, so a copy taken after the latest renewal contains every key still in use.

Two copies:

1. Daily Velero backup `velero-sealing-key` (Secrets with the label above, in the controller namespace).
2. An offline copy after each renewal, encrypted before it leaves the admin workstation:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-keys.yaml
```

Restore on a rebuilt cluster, before Argo CD syncs any SealedSecret:

```bash
kubectl apply -f sealed-secrets-keys.yaml
# If the controller is already running, it reads the keys at start:
kubectl -n kube-system rollout restart deployment/sealed-secrets-controller
```

From Velero instead of the offline copy, restore the latest `velero-sealing-key` backup. This needs Velero running against the backup bucket before Argo CD syncs SealedSecrets, for example installed with Helm from this repository, so the offline copy is the faster path:

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: sealing-key-recovery
  namespace: velero
spec:
  backupName: CHANGE_ME   # latest velero-sealing-key-<timestamp>
  includedNamespaces:
    - kube-system
  includedResources:
    - secrets
  existingResourcePolicy: none
```

After an etcd restore the keys are already in the cluster; check that the labelled Secrets exist.

## RKE2 etcd snapshot restore

This follows the RKE2 documentation, <https://docs.rke2.io/datastore/backup_restore>, with one deliberate change: the database directory on the other servers is moved aside instead of removed. Run the commands as root on the server nodes. The default data directory is `/var/lib/rancher/rke2`.

### Snapshots

| Task | Command |
| --- | --- |
| List the snapshots of this node | `rke2 etcd-snapshot ls` |
| List the snapshots of all nodes and S3 | `kubectl get etcdsnapshotfile` |
| Take an on-demand snapshot | `rke2 etcd-snapshot save` (optional `--name <base>`; no retention applies, prune by hand with `rke2 etcd-snapshot prune --snapshot-retention <n>`) |
| List or save in S3 | `rke2 etcd-snapshot --s3 --s3-bucket=CHANGE_ME-etcd --s3-access-key=CHANGE_ME --s3-secret-key=CHANGE_ME ls` (or `save`) |

Scheduled snapshots are named `etcd-snapshot-<node>-<timestamp>` and stored in `/var/lib/rancher/rke2/server/db/snapshots`. Take an on-demand snapshot before any planned change to the control plane.

### Token

The snapshot must be restored with the server token that was in use when it was taken. Save `/var/lib/rancher/rke2/server/token` to escrow when the cluster is installed and after every token rotation. If a `token` is set in the RKE2 config file, it must match the escrowed value, or RKE2 fails to start.

### Restore on a single server

1. Stop RKE2:

   ```bash
   systemctl stop rke2-server
   ```

2. Reset the cluster from the snapshot:

   ```bash
   rke2 server \
     --cluster-reset \
     --cluster-reset-restore-path=<PATH-TO-SNAPSHOT>
   ```

   Expected result: `Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.` RKE2 moves the current etcd files to `/var/lib/rancher/rke2/server/db/etcd-old-<timestamp>/` and creates `/var/lib/rancher/rke2/server/db/reset-flag`, which blocks a second reset until the next normal start. `--cluster-reset` without `--cluster-reset-restore-path` only resets membership and restores nothing.

3. Start RKE2:

   ```bash
   systemctl start rke2-server
   ```

### Restore in an HA cluster

Three servers, N1, N2 and N3; the snapshot is on N1 (or in S3).

1. Stop RKE2 on all servers:

   ```bash
   systemctl stop rke2-server
   ```

2. On N1, reset the cluster from the snapshot:

   ```bash
   rke2 server \
     --cluster-reset \
     --cluster-reset-restore-path=<PATH-TO-SNAPSHOT>
   ```

   Expected result: `Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.` followed by `Backup and delete ${datadir}/server/db on each peer etcd server and rejoin the nodes.`

3. On N1, start RKE2:

   ```bash
   systemctl start rke2-server
   ```

4. On N2 and N3, move the database directory aside. The RKE2 documentation removes it (`rm -rf /var/lib/rancher/rke2/server/db/`); moving it has the same effect for RKE2, because the server only needs the directory to be absent to join the restored cluster as a new member. It also does what the reset output asks (back up, then remove), keeps the old member data and the local snapshots of that node (they live in `db/snapshots`) for analysis or as a fallback, and cannot be undone by mistake. Keep the moved directory until the restored cluster has been verified; it uses space on the data disk.

   ```bash
   mv /var/lib/rancher/rke2/server/db "/var/lib/rancher/rke2/server/db.old-$(date +%Y%m%d-%H%M%S)"
   ```

5. On N2 and N3, start RKE2 to join the restored cluster:

   ```bash
   systemctl start rke2-server
   ```

Agents and control-plane-only servers can then be started normally, as the RKE2 documentation states.

### Restore from S3

In step 2 above, pass the S3 settings and only the file name of the snapshot as the restore path. The S3 configuration Secret (`etcd-s3-config-secret`) cannot be used during a restore, because the API server is not running.

```bash
rke2 server \
  --cluster-reset \
  --etcd-s3 \
  --etcd-s3-endpoint=s3.example.com \
  --etcd-s3-bucket=CHANGE_ME-etcd \
  --etcd-s3-region=CHANGE_ME \
  --etcd-s3-folder=CHANGE_ME \
  --etcd-s3-access-key=CHANGE_ME \
  --etcd-s3-secret-key=CHANGE_ME \
  --cluster-reset-restore-path=<SNAPSHOT-FILE-NAME>
```

Command-line flags are visible in the process list and the shell history. When the `etcd-s3` settings are already in `/etc/rancher/rke2/config.yaml`, RKE2 pulls the snapshot from that bucket and only `--cluster-reset` and `--cluster-reset-restore-path=<SNAPSHOT-FILE-NAME>` are needed. To restore a local file on a server whose config enables `etcd-s3`, add `--etcd-s3=false` and pass the full path.

### Restore to new hosts

1. Take the token from escrow (`<BACKED-UP-TOKEN-VALUE>`) and copy the snapshot to the first new server.
2. Run step 2 with the token:

   ```bash
   rke2 server \
     --cluster-reset \
     --cluster-reset-restore-path=<PATH-TO-SNAPSHOT> \
     --token=<BACKED-UP-TOKEN-VALUE>
   ```

   The token can also be set in the RKE2 config file.

3. Node objects are part of the snapshot. Remove the Node objects of hosts that are no longer part of the cluster (`kubectl delete node <name>`).

### Post-restore checks

| Check | Command or signal |
| --- | --- |
| API server healthy | `kubectl get --raw='/readyz?verbose'` |
| All nodes `Ready`, no stale Node objects | `kubectl get nodes -o wide` |
| etcd running on every server | `kubectl -n kube-system get pods -l component=etcd -o wide` |
| Reset flag cleared by the normal start | `/var/lib/rancher/rke2/server/db/reset-flag` absent on N1 |
| Snapshots continue | a new `etcd-snapshot-*` entry in `kubectl get etcdsnapshotfile` after the next scheduled run |
| GitOps state | `kubectl -n argocd get applications`: all `Synced` and `Healthy`; anything created after the snapshot time comes back from Git on sync |
| Sealed Secrets | labelled key Secrets present in `kube-system`; SealedSecrets report `Synced` |
| Backups | `kubectl -n velero get backupstoragelocations.velero.io` shows `Available`; schedules present |

## Full recovery order

1. Cluster: restore etcd from a snapshot (runbook above), or install a fresh RKE2 cluster when no usable snapshot exists.
2. Sealing key: restore the Sealed Secrets keys before Argo CD syncs any SealedSecret (offline copy, or the Velero `velero-sealing-key` backup). After an etcd restore, only check that they are present.
3. Argo CD bootstrap: `make bootstrap-gitops CLUSTER=<name>`, which installs Argo CD and applies the app of apps, as in [production setup](../../docs/getting-started/production-setup.md#9-bootstrap-gitops). Argo CD rebuilds the platform toolchains, Velero included, from Git.
4. Velero restore of volume data: restore `dev`, `stage` and `prod` from the latest `velero-platform-daily` backup before the application Applications sync into those namespaces. Velero restores volume data only into pods and claims it creates itself; an existing claim is skipped. While restoring, set the BackupStorageLocation to `accessMode: ReadOnly` in the profile values (a `kubectl` patch is reverted by Argo CD self-heal) so that nothing is written to or removed from the bucket, and set it back to `ReadWrite` afterwards.

The decision points and the per-application steps are in [docs/operations/backup-and-restore.md](../../docs/operations/backup-and-restore.md).
