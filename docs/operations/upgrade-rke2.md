# Upgrade RKE2

This runbook upgrades the RKE2 version, and with it the Kubernetes version, of a cluster built with this repository. It is for operators of the `reference` profile and of `lab` clusters on RKE2; kind clusters are recreated, not upgraded.

## Choose a path

| Path | How it works | Use it when |
| --- | --- | --- |
| Automated | system-upgrade-controller runs `Plan` objects that replace the RKE2 binary node by node, servers first | The optional `system-upgrade-controller` toolchain is enabled and RKE2 was installed from the tarball |
| Manual | `make bootstrap-k8s` re-runs `ansible/playbooks/site.yml` with the new `rke2.version` from the cluster file | The controller is not installed, or you want to drive each node from the workstation |

Both paths upgrade servers one at a time, then agents. Neither drains by default: the Plans only cordon (the agent Plan drains when `plans.agent.drain` is set), and the Ansible playbook neither cordons nor drains, so the manual path below adds the drain. Run the upgrade on a non-production cluster first (a lab cluster on RKE2), then on the production cluster.

## Preconditions for both paths

- An on-demand etcd snapshot taken immediately before the upgrade, and the server token in escrow (see [take an on-demand etcd snapshot](backup-and-restore.md#take-an-on-demand-etcd-snapshot)). It is the only way back to the previous minor version.
- The target is at most one Kubernetes minor version above the current one. To cross several minors, upgrade one minor at a time and verify after each step. RKE2 does not prevent a skipped minor.
- The Kubernetes version skew policy holds: during the upgrade the API servers differ by at most one minor, and no kubelet is newer than an API server.
- Every component in [the support matrix](../reference/support-matrix.md) supports the target minor: Argo CD, Kyverno, cert-manager, Envoy Gateway and the Gateway API CRDs, and every optional component you run. Upgrade a component first when it does not.
- The rendered manifests pass against the target minor. Set `cluster.kubernetesMinor` to the target in the cluster file on a branch, then run:

  ```bash
  make validate-config
  make render
  make kubeconform
  ```

- The live cluster does not use APIs that the target removes. Check the API server metric for deprecated requests:

  ```bash
  kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
  ```

- PodDisruptionBudgets allow a drain of one node at a time (`kubectl get pdb -A`). A budget with no allowed disruptions blocks the upgrade of that node.
- You read the RKE2 release notes for the target version.

## Automated upgrade with system-upgrade-controller

### Purpose

Upgrade RKE2 declaratively: a reviewed change to the Plans in Git drives the upgrade of every node.

### When to use

The `system-upgrade-controller` toolchain is enabled for the cluster. It is an optional component, off by default; enable it in the `toolchains:` section of `clusters/<name>/cluster.yaml` (see [configuration](../reference/configuration.md)).

### Preconditions

- Every item in [preconditions for both paths](#preconditions-for-both-paths).
- RKE2 was installed from the tarball. Upstream directs RPM-based installations to the package manager instead of the controller. On Rocky nodes, check with `rpm -q rke2-server rke2-agent`.
- The cluster is not managed by Rancher. Rancher manages upgrades of the clusters it provisions or imports.

### Steps

1. On a branch, set the target version for the Plans in the `system-upgrade-controller` wrapper values for the profile you upgrade (`values-lab.yaml` first, `values-reference.yaml` later), and set `rke2.version` in `clusters/<name>/cluster.yaml` to the same value. Keeping both equal stops a later `make bootstrap-k8s CLUSTER=<profile>` from installing the older version. The wrapper's `README.md` names the values key.

   The chart renders two Plans, `rke2-server` and `rke2-agent` (`templates/plans.yaml`), which follow the upstream examples, pinned to a version instead of a release channel so that every upgrade passes review. Trimmed:

   ```yaml
   apiVersion: upgrade.cattle.io/v1
   kind: Plan
   metadata:
     name: rke2-server
     namespace: system-upgrade
   spec:
     concurrency: 1
     cordon: true
     nodeSelector:
       matchExpressions:
         - key: node-role.kubernetes.io/control-plane
           operator: In
           values: ["true"]
     serviceAccountName: system-upgrade
     upgrade:
       image: rancher/rke2-upgrade
     version: <rke2-version>
   ---
   apiVersion: upgrade.cattle.io/v1
   kind: Plan
   metadata:
     name: rke2-agent
     namespace: system-upgrade
   spec:
     concurrency: 1
     cordon: true
     nodeSelector:
       matchExpressions:
         - key: node-role.kubernetes.io/control-plane
           operator: DoesNotExist
     prepare:
       image: rancher/rke2-upgrade
       args: ["prepare", "rke2-server"]
     serviceAccountName: system-upgrade
     upgrade:
       image: rancher/rke2-upgrade
     version: <rke2-version>
   ```

   `concurrency: 1` upgrades one node at a time and `cordon: true` cordons it first. The `prepare` step makes the agent jobs wait until `rke2-server` has finished. The agent Plan drains a node only when `plans.agent.drain` is set in the values.

2. Open a pull request, wait for `ci-gate`, and merge it. Argo CD applies the Plans and the controller starts.

3. Watch the Plans, the upgrade jobs and the nodes. The commands use the upstream namespace `system-upgrade`; use the destination namespace of the toolchain Application if it differs:

   ```bash
   kubectl -n system-upgrade get plans -o wide
   kubectl -n system-upgrade get jobs
   kubectl get nodes -o wide -w
   ```

4. After the non-production cluster passes verification, repeat steps 1 to 3 for the production profile.

### Verification

See [verification](#verification-after-either-path).

### Rollback or abort

- To stop before a node starts, revert the pull request. Jobs that have started run to completion.
- Neither the controller nor the upgrade image prevents a downgrade, and Kubernetes does not support an in-place downgrade of the control plane. Do not set an older version in a Plan. Follow [rollback](#rollback).

## Manual upgrade with Ansible

### Purpose

Upgrade RKE2 by re-running the provisioning playbook with a new version from the cluster file.

### When to use

The system-upgrade-controller is not installed, or you want each node to be upgraded from the workstation under direct observation.

### Preconditions

- Every item in [preconditions for both paths](#preconditions-for-both-paths).
- The inventory `ansible/inventories/<lab|reference>/hosts.yml`, the vault file and the vault password used for the original install. The Make targets take the profile as `PROFILE=<lab|reference>` and ask for the vault password (`--vault-id <profile>@prompt`). See `ansible/README.md` and [production setup](../getting-started/production-setup.md).
- The kubeconfig `ansible/data/kubeconfig-<cluster>.yaml` in a second terminal to watch the nodes.

### Steps

1. On a branch, set `rke2.version` in `clusters/<name>/cluster.yaml` to the exact target release in the form `vX.Y.Z+rke2rN`, and `cluster.kubernetesMinor` when the minor changes. Open a pull request, wait for `ci-gate`, and merge it.

2. On an up-to-date checkout of `main`, run the preflight checks:

   ```bash
   make preflight CLUSTER=<lab|reference>
   ```

3. Run the provisioning playbook `ansible/playbooks/site.yml` one node at a time: first the first host in `rke2_servers`, then the other servers, then the agents. A full run would upgrade the servers one at a time and the agents in batches of 25 percent, waiting for each node to be Ready, but it does not cordon or drain any node; no drain logic exists under `ansible/`. Kubernetes requires a drain before a minor kubelet upgrade, so drain each node yourself, limit the playbook to it, and uncordon it once it is Ready on the new version:

   ```bash
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
   make bootstrap-k8s CLUSTER=<lab|reference> ANSIBLE_ARGS="--limit <inventory-host>"
   kubectl uncordon <node>
   ```

   `<node>` is the Kubernetes node name (`kubectl get nodes`), `<inventory-host>` the host name in `hosts.yml`.

4. In the second terminal, watch the versions change node by node:

   ```bash
   export KUBECONFIG="$PWD/ansible/data/kubeconfig-<cluster>.yaml"
   kubectl get nodes -o wide -w
   ```

   If a node stays NotReady, stop the playbook (Ctrl+C) before it moves on, and read `journalctl -u rke2-server` or `journalctl -u rke2-agent` on that node.

### Verification

See [verification](#verification-after-either-path).

### Rollback or abort

Stopping between nodes leaves a mixed-version cluster, which the skew policy allows for the duration of an upgrade. Uncordon any node you drained, fix the cause and continue with the next node; nodes already on the target version are unchanged. To return to the previous minor version, follow [rollback](#rollback).

## Verification after either path

```bash
kubectl get nodes -o wide
kubectl version
kubectl get --raw '/readyz?verbose'
kubectl -n argocd get applications
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

- Every node is Ready and reports the target version in the `VERSION` column. No node is still cordoned (`SchedulingDisabled`).
- The API server readiness checks all report `ok`.
- Every Argo CD Application is Synced and Healthy.
- No pod is stuck outside Running or Succeeded.
- `hello-api` answers through the Gateway at `https://hello-api.<env>.<domain>/readyz`.

## Rollback

Upstream supports a rollback only as a binary downgrade combined with the restore of an etcd snapshot taken on the minor version you return to. Without that snapshot there is no way back to the previous minor version. The rollback stops every workload in the cluster.

1. If the API is available, drain all nodes:

   ```bash
   kubectl drain --ignore-daemonsets --delete-emptydir-data <node-1> <node-2> <node-3>
   ```

2. On every node, as root, stop RKE2 and all pod processes:

   ```bash
   rke2-killall.sh
   ```

3. On every node, as root, install the previous version. Servers:

   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=<previous-version> sh -
   ```

   Agents:

   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=<previous-version> INSTALL_RKE2_TYPE=agent sh -
   ```

4. Restore the pre-upgrade snapshot on the first server and rejoin the other servers, as in [restore the control plane](backup-and-restore.md#restore-the-control-plane-from-an-etcd-snapshot), steps 3 to 5.

5. Start the agents with `systemctl start rke2-agent`, then uncordon every node.

6. Revert the version change in `clusters/<name>/cluster.yaml` (and in the Plan values) through a pull request, so that the next `make bootstrap-k8s CLUSTER=<profile>` or Plan does not upgrade again.

Check the result with `rke2 --version` on each node and the [verification](#verification-after-either-path) commands.

## References

- RKE2 automated upgrades: <https://docs.rke2.io/upgrades/automated>
- RKE2 manual upgrades and release channels: <https://docs.rke2.io/upgrades/manual>
- RKE2 rollback: <https://docs.rke2.io/upgrades/roll-back>
- RKE2 backup and restore: <https://docs.rke2.io/datastore/backup_restore>
- system-upgrade-controller and the Plan specification: <https://github.com/rancher/system-upgrade-controller/blob/master/doc/plan.md>
- Kubernetes version skew policy: <https://kubernetes.io/releases/version-skew-policy/>
- Deprecated API migration guide: <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>
