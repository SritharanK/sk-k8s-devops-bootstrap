# Operations

## RKE / Kubernetes version

**RKE1 (RKE) is end-of-life July 2025.** For new clusters, consider [RKE2](https://docs.rke2.io/) or [K3s](https://k3s.io/). Migration from RKE1 requires provisioning a new cluster and moving workloads; see SUSE/Rancher migration guidance. This repo’s Ansible roles target RKE1; adapt for RKE2/K3s if needed.

## Backup and recovery

- **RKE / etcd:** RKE supports [etcd snapshots](https://rancher.com/docs/rke/latest/en/etcd-snapshots/). Configure a snapshot schedule and store backups off-cluster. Restore from snapshot when recovering the control plane.
- **Workload-level backup:** For persistent volumes and application data, consider [Velero](https://velero.io/). Install Velero and configure BackupStorageLocation and Schedule resources; document your RPO/RTO in runbooks.

This repo does not implement backup automation; the above are recommendations for production.

## Audit logging

Kubernetes audit logging should be enabled at the API server level for production (outside scope of this repo). Configure your cluster (e.g. RKE, kube-apiserver flags or cluster YAML) to write audit logs to a file or backend. See [Kubernetes audit documentation](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/).
