# Backup and restore

This page lists what the platform backs up, the recovery objectives, and the procedures to take and restore each backup. It is for operators of the `reference` profile and of `lab` clusters that run on RKE2.

## What is backed up

Git is the source of truth for everything declarative: charts, values, Applications, AppProjects, policies and the cluster file `clusters/<name>/cluster.yaml`. A rebuilt cluster converges back to the last merged commit through Argo CD. The backups below cover the state that Git does not hold.

| Data | Mechanism | Destination | Profile | Default |
| --- | --- | --- | --- | --- |
| Declarative configuration | Git | The Git remote and every clone | Both | Always |
| Kubernetes API state in etcd, including Secrets and the cluster CA keys | RKE2 etcd snapshots on the schedule in `rke2.etcdSnapshots` | Each server under `/var/lib/rancher/rke2/server/db/snapshots`, and S3 when `rke2.etcdSnapshots.s3.enabled` is true | RKE2 clusters (`reference`, and `lab` on a single RKE2 node) | On. kind clusters have no etcd snapshots |
| RKE2 server token | Manual escrow | Offline, next to the snapshots it decrypts | RKE2 clusters | Manual |
| The app namespaces `dev`, `stage` and `prod` and their persistent volumes | Velero with file-system backup through the Kopia uploader, Schedule `velero-platform-daily` | S3 bucket. SeaweedFS is the lab target | Both | Optional: `velero` and `seaweedfs` toolchains, off by default |
| Sealed Secrets controller keys | Velero Schedule `velero-sealing-key`, plus manual export and escrow | The Velero bucket, and offline. Never in Git | `lab` | The schedule comes with the `velero` toolchain; the offline escrow is manual |
| OpenBao data | Raft snapshot | Offline or S3 | `reference` | Manual or on the operator's schedule |

The cluster file sets the etcd snapshot schedule. Ansible writes it into the RKE2 configuration (`etcd-snapshot-schedule-cron`, `etcd-snapshot-retention` and the `etcd-s3-*` options):

```yaml
rke2:
  etcdSnapshots:
    schedule: "0 */6 * * *"   # every 6 hours
    retention: 10             # local snapshots kept per server node
    s3: {enabled: false, endpoint: "", bucket: "", folder: "", region: ""}
```

The cluster file is non-secret. The S3 credentials come from the gitignored Ansible vault file (`group_vars/all/vault.yml`), variables `vault_rke2_etcd_s3_access_key` and `vault_rke2_etcd_s3_secret_key`, never from the cluster file. See `ansible/README.md` for the vault layout.

Velero and SeaweedFS are optional components. Enable them per cluster in the `toolchains:` section of the cluster file; see [configuration](../reference/configuration.md). The `velero` wrapper chart defines the backup storage location and two Schedules (`helmcharts/system-charts/velero/values.yaml`, cron times in UTC): `velero-platform-daily` at 02:00, which backs up `dev`, `stage` and `prod`, and `velero-sealing-key` at 01:00, which backs up the Secrets labelled `sealedsecrets.bitnami.com/sealed-secrets-key` in the Sealed Secrets controller namespace (`kube-system` by default). The `seaweedfs` wrapper chart (`helmcharts/system-charts/seaweedfs`) provides the S3 endpoint in the lab. SeaweedFS runs inside the lab cluster, so it protects against the loss of a namespace, not against the loss of the cluster. A `reference` cluster uses an S3 target outside the cluster.

Treat every backup as a secret:

- An etcd snapshot contains every Kubernetes Secret and the private keys of the cluster CAs. Anyone with the snapshot and the server token can read all of it. Keep snapshots in a bucket with access control, server-side encryption and retention controls.
- The Sealed Secrets key export and the `velero-sealing-key` Velero backups decrypt every SealedSecret committed to the repository. Neither ever goes into Git.
- Velero encrypts its repositories with a static common key, so anyone with access to the bucket can read the backed-up data. Restrict access to the bucket.

## Recovery objectives

The table states targets, not measured guarantees. [`hack/dr/README.md`](../../hack/dr/README.md#recovery-objectives) states the same targets. Each RPO target is the interval of the schedule that takes the backup: the etcd snapshot schedule `0 */6 * * *` (`rke2.etcdSnapshots.schedule` in the reference cluster file) gives 6 hours, and the Velero Schedules `velero-platform-daily` (`0 2 * * *`) and `velero-sealing-key` (`0 1 * * *`) give 24 hours. A failed run extends the RPO until the next successful run; the monitoring chart alerts when the last successful Velero backup is older than 25 hours (`VeleroNoRecentBackup`). The RTO targets are not derived from a measurement: they are starting values for a small cluster. Confirm both with a restore drill on your own hardware and record the measured values.

| Scope | Mechanism | RPO target | RTO target | Confirm by |
| --- | --- | --- | --- | --- |
| Declarative configuration | Git | 0 for merged changes | Time for Argo CD to converge an empty cluster | `e2e-kind` time budget (lab), a rebuild drill (reference) |
| Control plane state | RKE2 etcd snapshot every 6 hours | 6 hours, less with an on-demand snapshot before a change | 1 hour | [Restore the control plane](#restore-the-control-plane-from-an-etcd-snapshot) on a non-production cluster |
| Namespaces and volumes (`dev`, `stage`, `prod`) | Velero Schedule `velero-platform-daily`, daily at 02:00 UTC | 24 hours | 1 hour per namespace, plus volume transfer time | [Restore a namespace](#restore-a-namespace-with-velero), `make dr-drill` |
| Sealed Secrets keys (lab) | Velero Schedule `velero-sealing-key`, daily at 01:00 UTC, and offline escrow after each key renewal | 24 hours from Velero alone; 0 if the offline escrow is refreshed after every renewal | 15 minutes | [Escrow the key](#export-escrow-and-restore-the-sealed-secrets-key), `make dr-drill` |
| OpenBao data (reference) | Raft snapshot | The snapshot interval you choose | 1 hour | [OpenBao snapshot](#take-and-restore-an-openbao-raft-snapshot) restore test |
| Full cluster recovery | etcd restore or fresh install, then the recovery order in `hack/dr/README.md` | As the rows above | 4 hours, not yet validated | A manual drill on a lab cluster |

Recommendation: record the measured restore times next to this table in your own runbook copy, and rerun the drill after every change to the backup configuration.

## Take an on-demand etcd snapshot

### Purpose

Capture the current etcd state of an RKE2 cluster outside the schedule.

### When to use

Before an RKE2 upgrade, before a change to CRDs or to a controller that rewrites stored objects, and before any manual intervention on the control plane.

### Preconditions

- Root access on one server node. Node commands on this page run as root (`sudo -i`).
- For an S3 copy: the S3 settings configured through `rke2.etcdSnapshots.s3`.

### Steps

1. Take the snapshot on one server node. The name prefix identifies the reason:

   ```bash
   rke2 etcd-snapshot save --name pre-change
   ```

2. List the snapshots and note the full name (`pre-change-<node>-<timestamp>`):

   ```bash
   rke2 etcd-snapshot ls
   ```

3. Copy the server token to the same escrow as the snapshot if it is not there yet. The token is required to restore the snapshot:

   ```bash
   cat /var/lib/rancher/rke2/server/token
   ```

### Verification

- `rke2 etcd-snapshot ls` lists the snapshot with a `file://` location, and with an `s3://` location when S3 is enabled. If the S3 copy is missing, copy the file off the node before you continue.
- From a workstation, `kubectl get etcdsnapshotfile` lists the snapshot for every cluster member.

### Rollback or abort

A snapshot changes nothing in the cluster. On-demand snapshots have no retention: remove one with `rke2 etcd-snapshot delete <snapshot-name>` once it is no longer needed.

## Restore the control plane from an etcd snapshot

### Purpose

Return an HA RKE2 cluster (three servers) to the state of an etcd snapshot. The steps follow the upstream RKE2 procedure for multiple servers.

### When to use

The datastore is corrupt or lost, a destructive change cannot be undone through Git, or an RKE2 rollback requires a snapshot from the previous minor version (see [upgrade RKE2](upgrade-rke2.md#rollback)).

### Preconditions

- The snapshot name, and for S3 the bucket settings. A snapshot can be restored by the same or a higher RKE2 minor version.
- The server token that was in use when the snapshot was taken. On the original servers it is in `/var/lib/rancher/rke2/server/token`. On new hosts, pass it with `--token` or set it in the RKE2 configuration.
- Root access on all three servers. In the steps, server 1 is the node that runs the restore, servers 2 and 3 are the peers.
- A maintenance window: the Kubernetes API is unavailable from step 2 until step 4 completes.
- Changes merged to Git after the snapshot are reapplied by Argo CD afterwards. Imperative changes made after the snapshot are lost.

### Steps

1. On server 1, confirm that the snapshot exists:

   ```bash
   rke2 etcd-snapshot ls
   ```

2. Stop RKE2 on all three servers:

   ```bash
   systemctl stop rke2-server
   ```

3. On server 1, restore the snapshot. For a local file, pass the full path:

   ```bash
   rke2 server \
     --cluster-reset \
     --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<snapshot-name>
   ```

   When `etcd-s3` is set in the RKE2 configuration, RKE2 downloads the snapshot from S3 and the restore path is the snapshot file name only. To restore a local file while S3 is configured, add `--etcd-s3=false` and pass the full local path. The S3 configuration Secret cannot be used during a restore, so pass S3 settings as flags when they are not in the configuration file.

   Wait for this message, then continue:

   ```text
   Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.
   ```

4. On server 1, start RKE2 and wait until the node is Ready:

   ```bash
   systemctl start rke2-server
   /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
   ```

5. On server 2, back up and remove the old datastore by moving it aside, then start RKE2 to rejoin the restored cluster. Repeat on server 3 once server 2 is Ready:

   ```bash
   mv /var/lib/rancher/rke2/server/db "/var/lib/rancher/rke2/server/db.pre-restore-$(date +%Y%m%dT%H%M%S)"
   systemctl start rke2-server
   ```

6. From a workstation, check that the agents reconnect. If an agent stays NotReady, restart it on that node with `systemctl restart rke2-agent`.

7. If the cluster was restored to new hosts, delete the Node objects of hosts that no longer exist (`kubectl delete node <old-node>`). Node objects are part of the snapshot.

### Verification

```bash
kubectl get nodes -o wide
kubectl get --raw '/readyz?verbose'
kubectl -n argocd get applications
```

All nodes are Ready, every readiness check reports `ok`, and every Application returns to Synced and Healthy. Restore application data with Velero afterwards if it changed after the snapshot.

### Rollback or abort

Until step 5, servers 2 and 3 still hold their original datastore, and RKE2 moved the previous etcd files of server 1 to `/var/lib/rancher/rke2/server/db/etcd-old-<timestamp>/`. If the restore on server 1 fails, stop, read `journalctl -u rke2-server`, and retry with another snapshot. RKE2 creates `/var/lib/rancher/rke2/server/db/reset-flag` to block a second reset in succession and removes it on a normal start. After step 5, the moved `db.pre-restore-*` directories are the only copy of the pre-restore state: keep them until the cluster is verified.

## Restore a namespace with Velero

### Purpose

Restore the objects and persistent volume data of one namespace from a Velero backup.

### When to use

A namespace was deleted, or its volume data is lost or corrupt. Objects defined in Git come back through Argo CD; Velero restores what Git does not hold: volume data and objects created at runtime.

### Preconditions

- The `velero` toolchain is enabled and the backup storage location is available (`velero backup-location get` reports `Available`).
- The `velero` CLI at the same version as the server. The commands assume Velero runs in the `velero` namespace, which is the CLI default; add `--namespace <velero-namespace>` otherwise.
- The name of the Argo CD Application that manages the namespace: `<app>-<env>` for app namespaces, the toolchain name for platform namespaces (`kubectl -n argocd get applications`).
- Velero does not overwrite objects that already exist (`--existing-resource-policy` defaults to `none`). A file-system backup restore also needs Velero to create the pods, so the pods and claims must not exist yet. Restoring into a namespace that still exists needs the upstream in-place procedure, or a restore into a new namespace with `--namespace-mappings <namespace>:<namespace>-restore` for comparison.

### Steps

1. Pick the backup:

   ```bash
   velero backup get
   velero backup describe <backup-name> --details
   ```

2. Stop Argo CD from recreating the namespace content during the restore. Turn off automated sync on the root Application (named `root`, rendered by the `bootstrap/` chart) first, because it would revert the change on the child Application:

   ```bash
   kubectl -n argocd patch application root --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   kubectl -n argocd patch application <application> --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

3. Restore the namespace:

   ```bash
   velero restore create <restore-name> \
     --from-backup <backup-name> \
     --include-namespaces <namespace> \
     --wait
   ```

4. Read the result:

   ```bash
   velero restore describe <restore-name> --details
   velero restore logs <restore-name>
   ```

5. Turn automated sync back on for the root Application. It then restores the child Application from Git, including its sync policy:

   ```bash
   kubectl -n argocd patch application root --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

### Verification

```bash
kubectl -n <namespace> get pods,pvc,sealedsecrets,secrets
kubectl -n argocd get application <application>
```

The restore phase is `Completed` without errors, the pods are Ready, the claims are Bound, and the Application is Synced and Healthy with automated sync back on.

### Rollback or abort

A failed or partial restore leaves the namespace in an intermediate state. Inspect `velero restore logs`, fix the cause, and run a new restore with another name. Re-enable automated sync on the root Application (step 5) in every case, so the cluster returns to GitOps control.

## Export, escrow and restore the Sealed Secrets key

### Purpose

Keep the private keys of the Sealed Secrets controller so that the SealedSecrets committed to Git stay decryptable after the cluster or the controller is lost.

### When to use

- Export after the first install and after every key renewal (the controller adds a new key every 30 days by default; see [secret rotation](secret-rotation.md#sealed-secrets-controller-key)). A backup taken before a renewal cannot decrypt secrets sealed with the newer key.
- Restore when you rebuild a lab cluster or reinstall the controller.

### Preconditions

- Access to the controller namespace. The examples use `kube-system`, the namespace `kubeseal` assumes by default; use the destination namespace of the Sealed Secrets toolchain Application if it differs.
- An offline encryption tool for the escrow file. The example uses `age`; any tool with an offline private key works.
- A working directory outside the repository clone.

### Steps

Export and encrypt the keys in one pipeline, so the private key never lands on disk in plain text:

```bash
SS_NS=kube-system
kubectl -n "$SS_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | yq 'del(.items[].metadata.resourceVersion) | del(.items[].metadata.uid) | del(.items[].metadata.creationTimestamp) | del(.items[].metadata.managedFields)' \
  | age -r <age-recipient> -o "sealed-secrets-keys-$(date +%Y%m%d).yaml.age"
```

Store the encrypted file offline in two separate locations, and the decryption identity separately from it. Never commit either to Git.

To restore into a new cluster, apply the keys before the controller starts for the first time. Otherwise the controller generates a new key and the committed SealedSecrets stay sealed. Run this before `make bootstrap-gitops CLUSTER=<name>`, which deploys the controller:

```bash
SS_NS=kube-system
kubectl create namespace "$SS_NS" --dry-run=client -o yaml | kubectl apply -f -
age -d -i <age-identity-file> sealed-secrets-keys-<date>.yaml.age | kubectl apply -f -
make bootstrap-gitops CLUSTER=<name>
```

To restore into a cluster where the controller already runs and generated a key of its own, apply the keys, deactivate the key that is not in the escrow file, and restart the controller pod. Relabelling removes a key from the controller without deleting it, and deleting the pod does not change the Deployment, so Argo CD sees no drift:

```bash
age -d -i <age-identity-file> sealed-secrets-keys-<date>.yaml.age | kubectl apply -f -
kubectl -n "$SS_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
kubectl -n "$SS_NS" label secret <key-not-in-escrow> sealedsecrets.bitnami.com/sealed-secrets-key=inactive --overwrite
kubectl -n "$SS_NS" delete pod -l app.kubernetes.io/name=sealed-secrets
```

On a lab cluster with the `velero` toolchain, the `velero-sealing-key` Schedule is a second source for the keys. Velero starts in a later sync wave than the controller, so this path always follows the "controller already runs" case above: restore the newest backup of the schedule, then deactivate the new key and restart the controller pod as shown.

```bash
velero backup get --selector velero.io/schedule-name=velero-sealing-key
velero restore create --from-backup <sealing-key-backup-name> --wait
```

### Verification

The active certificate matches the committed certificate that offline sealing uses, and every SealedSecret is synced:

```bash
kubeseal --fetch-cert --controller-namespace "$SS_NS" --controller-name sealed-secrets-controller \
  | openssl x509 -noout -fingerprint -sha256
openssl x509 -in <committed-sealing-certificate> -noout -fingerprint -sha256
kubectl get sealedsecrets -A
```

See [secrets handling](../security/secrets-handling.md) for the location of the committed certificate and its pinned fingerprint.

### Rollback or abort

Applying the key Secrets is additive. If decryption still fails, the SealedSecrets were sealed with a key that is not in the escrow file: find a newer escrow file, or re-seal the secrets from their source inputs (see [secret rotation](secret-rotation.md#registry-pull-secrets)).

## Take and restore an OpenBao Raft snapshot

### Purpose

Back up the secrets stored in OpenBao, which External Secrets Operator (ESO) reads in the `reference` profile.

### When to use

On a fixed schedule that matches your RPO target, and before an OpenBao upgrade.

### Preconditions

- The `bao` CLI, `BAO_ADDR` pointing at the active node (for example through `kubectl port-forward`), and a token allowed to use `sys/storage/raft/snapshot`.
- The unseal keys or recovery keys of the cluster, escrowed separately from the snapshots. A restored snapshot is still protected by the seal of the cluster it came from.

### Steps

```bash
bao operator raft snapshot save "openbao-$(date +%Y%m%dT%H%M%S).snap"
```

To restore, run against the active node:

```bash
bao operator raft snapshot restore <snapshot-file>
```

### Verification

`bao status` reports the node unsealed, `bao operator raft list-peers` lists every peer, and the ExternalSecrets report `SecretSynced` (`kubectl get externalsecrets -A`).

### Rollback or abort

A snapshot restore replaces the whole OpenBao state. Take a fresh snapshot before you restore an older one.

## Run the restore drill

### Purpose

Prove on every run that a namespace and a SealedSecret can be restored.

### When to use

After a change to the Velero, SeaweedFS or Sealed Secrets configuration, and before you rely on a new backup target. No CI workflow runs the drill; run it on demand with `make dr-drill`.

### Preconditions

- `kubectl`, and `kubeseal` for the SealedSecret part, from `mise.toml` or the devcontainer.
- The current kube context points at the cluster to test, preferably a non-production one such as the kind demo. The drill runs there; it does not create a cluster.
- Velero with its node agent and the BackupStorageLocation `default`, and a default StorageClass. `make dr-drill` runs the script without `--install`, so Velero must already be installed, for example through the `velero` and `seaweedfs` toolchains. On a cluster without them, run the script with `--install`.
- The drill does not exercise an RKE2 etcd restore; run that procedure on a non-production RKE2 cluster.

### Steps

```bash
make dr-drill
```

The target runs `hack/dr/restore-drill.sh` against the current kube context, which backs up, deletes and restores a namespace and a SealedSecret. To run the script directly with its options:

```bash
hack/dr/restore-drill.sh --install --namespace dr-drill --timeout 600
```

| Option | Effect |
| --- | --- |
| `--install` | Installs SeaweedFS and Velero with Helm and the lab values before the drill; not for clusters where Argo CD manages them |
| `--namespace <name>` | Namespace the drill backs up and restores (default `dr-drill`) |
| `--keep` | Keeps the drill namespace after the run for inspection |
| `--timeout <seconds>` | Time limit for each wait (default 600) |

### Verification

The command exits with status 0. Any other exit status is a failed drill.

### Rollback or abort

The drill only touches its own namespace in the current cluster, and removes it at the end unless you pass `--keep`. With `--install`, it also installs or upgrades the `seaweedfs` and `velero` Helm releases.

## References

- RKE2 backup and restore: <https://docs.rke2.io/datastore/backup_restore>
- RKE2 token management: <https://docs.rke2.io/security/token>
- Velero file-system backup (Kopia): <https://velero.io/docs/main/file-system-backup/>
- Velero restore reference: <https://velero.io/docs/main/restore-reference/>
- Velero disaster recovery: <https://velero.io/docs/main/disaster-case/>
- Sealed Secrets key backup and renewal: <https://github.com/bitnami-labs/sealed-secrets#how-can-i-do-a-backup-of-my-sealedsecrets>
- OpenBao Raft snapshot commands: <https://openbao.org/docs/commands/operator/raft/>
- age file encryption: <https://age-encryption.org/>
