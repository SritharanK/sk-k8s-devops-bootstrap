# system-upgrade-controller

Rancher system-upgrade-controller, so RKE2 node upgrades are declared in Git as upgrade Plans and rolled out node by node by the cluster itself, instead of by hand or through Ansible on running clusters.

| Item | Value |
| --- | --- |
| Upstream chart | None published as a standalone chart. The Rancher catalog chart is hidden, managed by Rancher and one minor version behind. This is a local chart built from the release manifests of upstream v0.21.1 (`upstream/`). |
| Upstream app version | v0.21.1 (`rancher/system-upgrade-controller:v0.21.1`) |
| Upstream source | <https://github.com/rancher/system-upgrade-controller> |
| Namespace | system-upgrade (Pod Security: privileged, the upgrade Jobs use the host IPC, network and PID namespaces, `CAP_SYS_BOOT` and the host root filesystem mounted at `/host`, and the controller mounts the host CA directories) |
| Enabled by default | No. Switch on with `toolchains.system-upgrade-controller.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

What the chart renders:

| Object | Template | Source |
| --- | --- | --- |
| CRD `plans.upgrade.cattle.io` | `crd.yaml` | `upstream/crd.yaml` unchanged, plus `argocd.argoproj.io/sync-options: Prune=false,Delete=false` |
| ServiceAccount `system-upgrade`, Role, RoleBinding, ClusterRoles `system-upgrade-controller` and `system-upgrade-controller-drainer`, ClusterRoleBindings | `serviceaccount.yaml`, `rbac.yaml` | Upstream manifest, same names and rules |
| ConfigMap `default-controller-env` | `configmap.yaml` | Upstream defaults in `controllerEnv` |
| Deployment `system-upgrade-controller` | `deployment.yaml` | Upstream manifest, plus resources, replicas, `readOnlyRootFilesystem: true` and a checksum annotation for the ConfigMap |
| PodDisruptionBudget | `poddisruptionbudget.yaml` | Added, reference profile only |
| Plans `rke2-server` and `rke2-agent` | `plans.yaml` | RKE2 documentation, only when `plans.enabled` |

The upstream Namespace object is left out: Argo CD creates the namespace with the Pod Security labels (`CreateNamespace=true` and `managedNamespaceMetadata` in the Application).

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Controller replicas | 1 | 2 on different control-plane nodes, leader election |
| PodDisruptionBudget | none | `minAvailable: 1` |
| Requests / memory limit | 10m, 48Mi / 128Mi | 25m, 64Mi / 256Mi |
| Plans | disabled | disabled |
| Maintenance window | none | none (commented example in `values-reference.yaml`) |

The controller runs on control-plane nodes only (upstream node affinity and tolerations). On kind that is the kind control-plane node. CPU limits are not set on purpose, to avoid throttling. Upgrade Jobs are created by the controller from the Plans and have no resource settings in this chart.

## Secrets

None.

## Dependencies

None at install time. The controller has no metrics endpoint, so there is no ServiceMonitor. Plans only make sense on RKE2 nodes; keep them disabled on kind.

## RKE2 upgrades with Plans

The Plans follow <https://docs.rke2.io/upgrades/automated> with a pinned `version` instead of a release channel, so an upgrade only starts from a reviewed commit.

| Plan | Nodes | Behaviour |
| --- | --- | --- |
| `rke2-server` | `node-role.kubernetes.io/control-plane In ["true"]` | `concurrency: 1`, `cordon: true`, tolerates `CriticalAddonsOnly`, `node-role.kubernetes.io/control-plane:NoSchedule` and `node-role.kubernetes.io/etcd:NoExecute` |
| `rke2-agent` | `node-role.kubernetes.io/control-plane DoesNotExist` | `concurrency: 1`, `cordon: true`, optional `drain` (`plans.agent.drain`, example in `values.yaml`), `prepare` step `rke2-upgrade prepare rke2-server` waits until the server Plan is complete |

| Value | Default | Meaning |
| --- | --- | --- |
| `plans.enabled` | `false` | Render both Plans |
| `plans.version` | `CHANGE_ME` | Target RKE2 release, for example `v1.36.6+rke2r1`. Rendering fails when Plans are enabled and the version is empty, `CHANGE_ME` or not of the form `vX.Y.Z+rke2rN`. |
| `plans.image` | `rancher/rke2-upgrade` | Without a tag on purpose: the controller appends the version with `+` replaced by `-` (`rancher/rke2-upgrade:v1.36.6-rke2r1`) |
| `plans.window` | `{}` | Optional `days`, `startTime`, `endTime`, `timeZone` (kured format). Jobs are only created inside the window; a Job that started may run past it. |
| `plans.server.tolerations`, `plans.agent.tolerations` | server taints / none | Extra taints on your nodes go here. Jobs always tolerate `node.kubernetes.io/unschedulable`. |

The reference cluster has three server nodes and no agents, so there the agent Plan selects no nodes and stays idle.

### Nonprod first

1. Choose the target release from <https://github.com/rancher/rke2/releases> and read its notes. Do not skip a Kubernetes minor version (1.35 to 1.37 goes through 1.36): the controller does not enforce the version skew policy.
2. Take an etcd snapshot on a server node of the lab cluster, for example `rke2 etcd-snapshot save --name pre-v1.36.7`. Without a snapshot from the old version there is no way back (see rollback below).
3. In `clusters/lab/cluster.yaml` set `rke2.version` to the target release, and set `toolchains.system-upgrade-controller.values.plans.enabled: true` if the Plans are not enabled yet. Merge; Argo CD passes `rke2.version` to this chart as `plans.version`, and the server Plan starts on the next control-plane node.
4. Watch progress until both Plans report complete and every node shows the new version (commands below).
5. Check workloads: all Argo CD Applications Healthy and Synced, and no pods outside `Running` or `Completed` (`kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`).
6. Repeat steps 2 to 5 for the reference cluster with `clusters/reference/cluster.yaml`.

### Watching progress

```bash
kubectl -n system-upgrade get plans,jobs
kubectl -n system-upgrade get plans -o wide
kubectl get nodes -L plan.upgrade.cattle.io/rke2-server,plan.upgrade.cattle.io/rke2-agent
kubectl -n system-upgrade logs deploy/system-upgrade-controller
kubectl -n system-upgrade logs job/<job-name> --all-containers
```

The node `VERSION` column shows the RKE2 release once a node is done. The controller labels each finished node with `plan.upgrade.cattle.io/<plan>` set to the Plan hash; nodes with the current hash are skipped. Upgrade Jobs are kept for 900 seconds after they finish (`SYSTEM_UPGRADE_JOB_TTL_SECONDS_AFTER_FINISH`).

### Rollback limits

Kubernetes does not support downgrading control-plane components, and the `rke2-upgrade` image has no check that prevents a Plan from moving nodes to an older release. Never lower `plans.version` to undo an upgrade. A rollback is a manual procedure: drain the nodes, stop RKE2 with `rke2-killall.sh`, reinstall the previous RKE2 release on every node, and restore an etcd snapshot taken on the old version with `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`. See <https://docs.rke2.io/upgrades/roll-back>. Without a snapshot from the previous minor version, rolling back to that minor version is not possible.

### Relation to `rke2.version` in the cluster definition

`rke2.version` in `clusters/<name>/cluster.yaml` is the single source for the RKE2 release. Ansible installs it on new nodes, and the toolchain Application (`argocd-bootstrap/templates/toolchains/system-upgrade-controller.yaml`) passes it to this chart as `plans.version`, so the controller moves existing nodes to the same release. `plans.version` in the values files only applies when the chart is rendered outside Argo CD, and a `CHANGE_ME` placeholder in `rke2.version` is not passed on.

With Plans enabled, a version bump in the cluster definition is the upgrade. Lowering `rke2.version` would ask the controller for a downgrade; see the rollback section instead.

## Upgrade

Upgrading the controller itself (not RKE2):

1. Download `crd.yaml` and `system-upgrade-controller.yaml` of the new release and verify their sha256 against the digests GitHub shows for the release assets.
2. Replace the files in `upstream/` and update `upstream/README.md` (version, URLs, checksums).
3. Compare the templates with the new upstream manifest with the procedure in `upstream/README.md`, and carry over every change to RBAC, the ConfigMap, the Deployment and the image tag (`image.tag` in `values.yaml`, `appVersion` in `Chart.yaml`).
4. Read <https://github.com/rancher/system-upgrade-controller/releases> for new Plan fields and controller env variables.
5. Render both profiles, once with `--set plans.enabled=true --set plans.version=<release>`, and sync the lab cluster first.

## Known limitations

- At every start the controller creates or updates the Plan CRD from a copy built into its binary, with a full update. That update drops annotations and labels added outside the controller, including the Argo CD sync options and tracking metadata. Argo CD then shows the CRD OutOfSync and self-heal adds them back. The spec is identical (the built-in copy equals `upstream/crd.yaml` for v0.21.1), so this is metadata churn only. There is no controller option to switch the registration off.
- The cordon and drain init containers of upgrade Jobs use `rancher/kubectl:v1.36.2` (`controllerEnv.SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE`) instead of the upstream default `v1.30.3`, which is outside the kubectl version skew policy for 1.36 clusters. Move it with the cluster minor version.
- The Plans and their `rancher/rke2-upgrade` image tag are not pinned by digest: the tag is derived from `plans.version` at runtime by the controller.
- No metrics and no alerts. Follow upgrades with the commands above.
