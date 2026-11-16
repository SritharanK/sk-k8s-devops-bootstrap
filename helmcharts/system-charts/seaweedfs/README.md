# seaweedfs

In-cluster S3 endpoint for the lab profile: Velero backups, CloudNativePG backups, Loki chunks and RKE2 etcd snapshots need object storage, and a lab cluster has none. The reference profile writes to external S3 and keeps this toolchain off.

The platform plan named MinIO as the lab backup target, but the MinIO community edition stopped publishing images in October 2025 and its repository was archived in 2026. SeaweedFS replaces it because it is Apache-2.0 licensed, publishes releases weekly and ships an official Helm chart.

| Item | Value |
| --- | --- |
| Upstream chart | seaweedfs 4.53.0 from `https://seaweedfs.github.io/seaweedfs/helm` (no OCI artifact is published) |
| Upstream app version | 4.53 (image `chrislusf/seaweedfs:4.53`) |
| Upstream source | <https://github.com/seaweedfs/seaweedfs> |
| Namespace | seaweedfs (Pod Security: baseline; the pods themselves are restricted-compliant, audit stays on restricted) |
| Enabled by default | No. Switch on with `toolchains.seaweedfs.enabled: true` in `clusters/<cluster>/cluster.yaml`. Lab only. |

Topology: one `weed server` process in the upstream all-in-one mode (master, volume server, filer and S3 gateway in one pod) on one PersistentVolumeClaim. The split master, volume, filer and S3 components of the upstream chart are switched off.

| Object | Name |
| --- | --- |
| Deployment | `seaweedfs-all-in-one` (1 replica, `Recreate`) |
| PersistentVolumeClaim | `seaweedfs-all-in-one-data` (default StorageClass, annotated `argocd.argoproj.io/sync-options: Delete=false`) |
| Service, S3 only (added by this chart) | `seaweedfs-s3`, port 8333 |
| Service, all ports (upstream) | `seaweedfs-all-in-one`: master 9333, filer 8888, volume 8080, S3 8333, metrics 9324 |
| Bucket Job | `seaweedfs-bucket-hook` (Helm post-install hook, an Argo CD PostSync hook) |

## S3 endpoint

| Item | Value |
| --- | --- |
| Endpoint | `http://seaweedfs-s3.seaweedfs.svc:8333` |
| Region | `us-east-1` (platform convention; SigV4 clients need a region to sign with) |
| Addressing | path-style (`s3ForcePathStyle: "true"`, `forcePathStyle`, `bucket_lookup_type: path`, depending on the client) |
| TLS | none (cluster-internal HTTP) |
| Buckets | `velero`, `cnpg`, `loki`, `etcd` |

The buckets are created declaratively by the upstream bucket hook on every sync; existing buckets are skipped. Add a bucket under `seaweedfs.allInOne.s3.createBuckets` in `values.yaml`.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Enabled | yes, when the toolchain is switched on | no, external S3 (`https://s3.example.com`, buckets `CHANGE_ME-<purpose>`) |
| Pods | 1 all-in-one | not deployed |
| Volume | 10Gi claim on the default StorageClass | not deployed |
| Requests / memory limit | 50m, 128Mi / 512Mi | not deployed |
| Bucket hook requests / memory limit | 10m, 64Mi / 256Mi | not deployed |
| ServiceMonitor (`release: monitoring`) | yes | not deployed |

`values-reference.yaml` only documents that the reference profile does not use this chart. CPU limits are not set on purpose, to avoid throttling; the upstream limit of 2 cores is removed with `limits.cpu: null`.

Security context of the all-in-one pod and the bucket hook: UID and GID 1000 (the `seaweed` user of the image), `fsGroup: 1000`, `runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem with an `emptyDir` on `/tmp`. The pod does not mount a service account token, and the upstream ClusterRole is not created.

Storage tuning for a single small disk: volumes are limited to 512 MB (`master.volumeSizeLimitMB`) and grow one at a time per bucket (`[master.volume_growth] copy_1 = 1`), instead of 1000 MB and seven at a time. Every bucket is a separate collection with its own volumes, so the defaults exhaust the volume slots of a 10Gi claim quickly.

## Secrets

| Secret | Namespace | Key | Content |
| --- | --- | --- | --- |
| `seaweedfs-s3-config` | seaweedfs | `seaweedfs_s3_config` | S3 identities as JSON (format below) |

The all-in-one pod mounts the key as `/etc/sw/s3/seaweedfs_s3_config` and starts the gateway with `-s3.config` on it. One identity per consumer, each limited to its own bucket with the `Action:bucket` form:

```json
{
  "identities": [
    {
      "name": "velero",
      "credentials": [{ "accessKey": "<20 characters>", "secretKey": "<40 characters>" }],
      "actions": ["Read:velero", "Write:velero", "List:velero", "Tagging:velero"]
    },
    {
      "name": "cnpg",
      "credentials": [{ "accessKey": "<20 characters>", "secretKey": "<40 characters>" }],
      "actions": ["Read:cnpg", "Write:cnpg", "List:cnpg", "Tagging:cnpg"]
    }
  ]
}
```

Supported actions are `Admin`, `Read`, `Write`, `List`, `Tagging`, `ReadAcp` and `WriteAcp`, optionally scoped as `Action:bucket` (<https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials>). The same key pair goes into the consumer's own Secret, for example `velero-s3-credentials` in namespace `velero` (see the velero README).

Lab, by hand, with generated keys for the `velero` identity:

```bash
ACCESS_KEY="$(od -An -tx1 -N10 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"
SECRET_KEY="$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')"
kubectl create namespace seaweedfs --dry-run=client -o yaml | kubectl apply -f -
kubectl -n seaweedfs create secret generic seaweedfs-s3-config --from-file=seaweedfs_s3_config=/dev/stdin <<EOF
{"identities":[{"name":"velero","credentials":[{"accessKey":"${ACCESS_KEY}","secretKey":"${SECRET_KEY}"}],"actions":["Read:velero","Write:velero","List:velero","Tagging:velero"]}]}
EOF
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
kubectl -n velero create secret generic velero-s3-credentials --from-file=cloud=/dev/stdin <<EOF
[default]
aws_access_key_id=${ACCESS_KEY}
aws_secret_access_key=${SECRET_KEY}
EOF
unset ACCESS_KEY SECRET_KEY
```

`hack/dr/restore-drill.sh --install` does the same when both Secrets are missing, and never changes existing ones.

Reference: not applicable, the chart is not deployed there.

SeaweedFS reads the identities file only at start. After changing the Secret, restart the pod:

```bash
kubectl -n seaweedfs rollout restart deployment/seaweedfs-all-in-one
```

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | ServiceMonitor CRD and the Prometheus that scrapes the metrics port (`release: monitoring`); Grafana sidecar for the upstream dashboard ConfigMap (label `grafana_dashboard: "1"`) |
| local-path, or any default StorageClass | The data claim uses the default StorageClass |

Consumers: velero (bucket `velero`), cloudnative-pg (bucket `cnpg`), RKE2 etcd snapshots (bucket `etcd`). Each needs an identity in `seaweedfs-s3-config`. The lab `logging` values store Loki data on the local filesystem, not in SeaweedFS.

## Upgrade

1. Change `dependencies[0].version` in `Chart.yaml`; the image tag follows the chart `appVersion` (4.53 for chart 4.53.0).
2. Run `helm dependency update helmcharts/system-charts/seaweedfs` and commit `Chart.lock`.
3. Read the release notes at <https://github.com/seaweedfs/seaweedfs/releases> and diff the chart values (`helm show values seaweedfs --repo https://seaweedfs.github.io/seaweedfs/helm --version <new>`), in particular the `allInOne` section and the templates that render without being asked for (see Known limitations).
4. Render both profiles and run the drill (`make dr-drill`) on a lab cluster.

## Known limitations

- Single pod, single claim, no replication. This is a lab target, not durable storage: losing the node disk loses every backup on it, and backups inside the cluster they protect do not survive the loss of that cluster. The reference profile uses external S3 for that reason.
- The upstream chart sets the `checksum/s3config` pod annotation from a `lookup` of the existing Secret. Argo CD renders with `helm template`, where `lookup` returns nothing, so the annotation is constant and a changed `seaweedfs-s3-config` does not roll the pod. Restart it by hand (command above).
- In all-in-one mode the upstream chart always renders the Secret `seaweedfs-sftp-secret` (generated SFTP passwords and an SSH host key), even though SFTP is off. It is a Helm pre-install hook, which Argo CD creates once as a named PreSync hook and does not update. No pod mounts it.
- The `etcd` bucket is prepared, but RKE2 uploads etcd snapshots from the host, where the cluster DNS name `seaweedfs-s3.seaweedfs.svc` does not resolve. Using it needs a host-reachable endpoint (for example a NodePort Service), which this chart does not provide.
- The upstream Grafana dashboard references a `${DS_PROMETHEUS}` datasource variable; whether it binds automatically depends on the Grafana sidecar settings of the monitoring chart.
- No CRDs, so the CRD sync options of the toolchain convention (`Prune=false,Delete=false`) do not apply.
