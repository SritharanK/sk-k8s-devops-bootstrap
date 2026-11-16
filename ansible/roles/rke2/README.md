# rke2

Installs, joins, configures and upgrades RKE2 servers and agents from a pinned release. It covers the HA
join through a fixed registration address (load balancer or kube-vip), the CIS profile, an API server audit
policy, etcd snapshots with optional S3 upload, the admin kubeconfig on the control node, and uninstall.

## Supported platforms

| Distribution | Versions |
|---|---|
| Ubuntu | 24.04 (noble) |
| Debian | 12 (bookworm), 13 (trixie) |
| Rocky Linux | 9 |

Architectures `x86_64` and `aarch64`. RKE2 releases v1.34 and later; the role accepts older releases but
they are not tested.

## Requirements

- ansible-core 2.20 or later, collections `ansible.builtin` only (no extra collection on the managed hosts).
- Facts gathered for the play (`gather_facts: true`).
- `become: true` in the play. The role itself never sets `become`, except `become: false` on the two tasks
  that write the kubeconfig on the control node.
- Outbound HTTPS from the nodes to `raw.githubusercontent.com`, `github.com` (release artifacts) and, for RPM
  installs, `rpm.rancher.io`.
- The `preflight`, `base` and `firewall` roles run first (kernel modules, sysctls, swap, firewall ports).

## How it works

### Topology and rollout order

The node type follows the inventory groups: hosts in `rke2_servers` run `rke2-server`, hosts in `rke2_agents`
run `rke2-agent`. The first host of `rke2_servers` (`rke2_bootstrap_host`) initialises the cluster; its
configuration has no `server:` key. Every other server and every agent gets
`server: https://<registration address>:9345`. With a single server and no registration address, the join
address falls back to the bootstrap server's `rke2_node_ip`, then its default IPv4 address from the facts,
then its `ansible_host`.

The playbook, not the role, sets the rollout order (`playbooks/site.yml`):

1. the bootstrap server alone;
2. the other servers with `serial: 1`, so only one etcd member restarts or joins at a time and quorum holds;
3. the agents, in batches.

On each node the role validates its input, prepares the host, installs or upgrades the binary, writes the
configuration, then starts or restarts the service and waits until the node reports `Ready`. A start or restart
blocks until RKE2 reports ready to systemd, bounded by `rke2_service_start_timeout`. A service that was
running is restarted only when its binary or configuration changed; a fresh node is started once.

etcd keeps working membership on disk: once a server has joined, RKE2 ignores its `server:` key. The bootstrap
server must therefore stay the original one. When it is replaced, put an existing server first in
`rke2_servers` or set `rke2_bootstrap_host` to it, otherwise the new host would initialise a second cluster.

### High availability

Run an odd number of servers (three is the usual choice) behind a fixed registration address that forwards
TCP 9345 (supervisor, used to join) and 6443 (Kubernetes API) to every server. The address is added to the API
server certificate and written into the kubeconfig unless `rke2_api_endpoint` overrides it.

Two ways to provide it:

- **Load balancer.** A layer 4 load balancer, for example the private load balancer of a cloud provider.
  This is the right choice on public clouds.
- **kube-vip** (`rke2_kube_vip_enabled: true`). kube-vip v1.3.1 runs as a static pod on every server in ARP
  mode with leader election and announces the VIP from the current leader (control plane only,
  `svc_enable: "false"`). ARP needs a layer 2 network shared by the servers, such as a lab, a VLAN or a
  bare-metal rack. Most public clouds drop gratuitous ARP for addresses they did not assign, so use a cloud load
  balancer there. Set `rke2_registration_address` to a free address in the node subnet and
  `rke2_kube_vip_interface` to the interface on that subnet. The pod reads `/etc/rancher/rke2/rke2.yaml` and
  talks to the local API server on `127.0.0.1:6443`.

### Upgrades

1. Change `rke2.version` in `clusters/<name>/cluster.yaml` to the next release, for example
   `v1.36.6+rke2r1`.
2. Run `playbooks/site.yml`.

Each node reads its installed version with `rke2 --version`. When it differs from the target, the install
script for the target tag runs and the service restarts; the play moves to the next node only after this node
is `Ready`. The servers roll one at a time, then the agents, as recommended in
[docs.rke2.io/upgrades/manual](https://docs.rke2.io/upgrades/manual). The role refuses a downgrade unless
`rke2_allow_downgrade: true`, and refuses to skip a Kubernetes minor version (v1.34 to v1.36), which the
Kubernetes version skew policy does not support.

For RPM installs the install script writes an `rpm.rancher.io` repository for the target minor and the channel
in `rke2_channel`. Keep `stable` unless the pinned release is only in `latest` or `testing`. The `base` role
excludes `rke2-*` from unattended upgrades so packages never move outside this procedure.

Automated in-cluster upgrades with the system-upgrade-controller are an alternative owned by the operations
layer, not by this role. Do not use both on the same cluster.

### Ingress

This platform uses Envoy Gateway, so `rke2_ingress_controller` defaults to `none`: RKE2 deploys neither
Traefik (the default for new clusters from v1.36) nor ingress-nginx (removed in v1.37). Releases older than
v1.33 do not accept the `ingress-controller` option; for those the role renders
`disable: [rke2-ingress-nginx]` instead.

From v1.37 RKE2 installs the standard Gateway API CRDs through its own `rke2-gateway-api-crd` chart, whatever
the ingress setting. If the Envoy Gateway installation manages the Gateway API CRDs itself, add
`rke2-gateway-api-crd` to `rke2_disable_components` so that only one owner remains.

### CIS profile

`rke2_cis_profile: true` renders `profile: cis` on every node and prepares the hosts as the
[hardening guide](https://docs.rke2.io/security/hardening_guide) requires:

- an `etcd` system user and group (no login shell, no home) on the servers, in `/etc/passwd` and `/etc/group`;
- `/etc/sysctl.d/60-rke2-cis.conf`, copied from the `rke2-cis-sysctl.conf` that RKE2 ships
  (`/usr/local/share/rke2` for tar, `/usr/share/rke2` for RPM). It sets `vm.panic_on_oom`,
  `vm.overcommit_memory`, `kernel.panic` and `kernel.panic_on_oops`, which RKE2 checks at every start in CIS
  mode. The role applies only this file with `sysctl -p` before the service starts; it never restarts
  `systemd-sysctl`, which the guide warns against on a running cluster.

Consequences for everything deployed later:

- Pod Security Admission enforces `restricted` in every namespace except `kube-system`,
  `compliance-operator-system` and `tigera-operator`. Every platform namespace that runs privileged or host
  level workloads (CNI add-ons, storage, node agents, ingress gateways with host ports) needs explicit
  `pod-security.kubernetes.io/enforce` labels, set by the component that creates the namespace.
- RKE2 applies NetworkPolicies to `kube-system`, `kube-public` and `default` that only allow traffic inside the
  namespace (plus DNS and a few system endpoints). Other namespaces need their own policies.
- `protect-kernel-defaults` is set for the kubelet.
- The `default` service account of new namespaces still mounts its token; CIS 5.1.5 expects
  `automountServiceAccountToken: false`, which the operations layer must set.

Enable the profile when the cluster is created. Turning it on later restarts every node, and from then on
every new or restarted pod outside the exempt namespaces must meet the restricted policy.

### Audit logging

With `rke2_audit_policy_enabled: true` (the default) the servers get `/etc/rancher/rke2/audit-policy.yaml` and
`audit-policy-file` in the configuration. The policy skips the `RequestReceived` stage, health, version and
metrics probes, events, leases and routine node and kube-proxy reads; it records Secrets, ConfigMaps, token
requests and TokenReviews at `Metadata` only (never their content), RBAC changes at `RequestResponse`, and
everything else at `Metadata`. The log is `/var/lib/rancher/rke2/server/logs/audit.log`, rotated after
`rke2_audit_log_maxsize` MB and kept for `rke2_audit_log_maxage` days and `rke2_audit_log_maxbackup` files
(the values match the RKE2 built-in defaults; the role states them so they can be changed). Without a policy
file RKE2 writes one with `level: None`, which logs nothing.

### API server OIDC

`rke2_apiserver_oidc.enabled: true` adds the `--oidc-*` flags to kube-apiserver. The `oidc:` prefixes are
prepended to every user name and group taken from a token, so an identity provider cannot issue a token for
`system:masters`, `system:nodes` or a Kubernetes service account. RBAC bindings must use the prefixed names,
for example `oidc:platform-admins`. With `username_claim: email`, a token that carries an `email_verified`
claim is rejected unless that claim is true.

### etcd snapshots

Every server takes a snapshot on `rke2_etcd_snapshot_schedule` (default every six hours) into
`/var/lib/rancher/rke2/server/db/snapshots` and keeps `rke2_etcd_snapshot_retention` of them. With
`rke2_etcd_s3.enabled` the snapshots are also uploaded to the bucket; the credentials come from the vault through
`rke2_etcd_s3_access_key` and `rke2_etcd_s3_secret_key` and are written to the root-only `config.yaml`.
S3 retention is cluster-wide: every server prunes the bucket to `etcd-s3-retention` objects (RKE2 default 5).
Set `rke2_etcd_s3_retention` to servers times the cycles you want to keep. A restore needs the cluster token as
well as the snapshot, so back the token up with the vault.

### Kubeconfig

The bootstrap server's `/etc/rancher/rke2/rke2.yaml` (mode 0600, root only) is copied to
`rke2_kubeconfig_local_path` on the control node, by default `ansible/data/kubeconfig-<cluster>.yaml`, mode
0600. The server address is rewritten to `rke2_api_endpoint`, else the registration address, else the bootstrap
server's `ansible_host`, and the cluster, context and user are renamed from `default` to `rke2_cluster_name`.
The file holds cluster-admin credentials.

On the servers, `kubectl` stays where RKE2 puts it:

```bash
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
```

### Uninstall

The `uninstall` entry point runs the upstream `rke2-uninstall.sh` (`/usr/local/bin` for tar, `/usr/bin` for
RPM, `/opt/rke2/bin` when `/usr/local` was read-only). It refuses to run unless `rke2_uninstall_confirm: true`
and the host is in `k8s_cluster`. Uninstalling deletes the node's cluster data, including etcd data and local
snapshots on servers. `playbooks/rke2_uninstall.yml` removes the agents first and the bootstrap server last.
To remove one node from a running cluster, drain it and `kubectl delete node` it first.

### Other behaviour

- NetworkManager, when installed, gets `/etc/NetworkManager/conf.d/rke2-canal.conf` so that it leaves the CNI
  interfaces alone, and `nm-cloud-setup` is disabled when present
  ([known issues](https://docs.rke2.io/known_issues)). On a node where RKE2 already ran, reboot once after this
  file first appears.
- SELinux: on hosts with SELinux enabled the configuration sets `selinux: true`. Leave
  `rke2_install_method` empty there; the RPM install pulls in the `rke2-selinux` policy, the tar install does
  not, and the role refuses that combination.
- Node labels and taints are applied when a node registers. Changing them later does not update an existing
  node; use `kubectl label` or `kubectl taint`.
- Disabling kube-vip removes its static pod manifest from the servers, and the kubelet stops the pod. Setting
  `rke2_registries` back to `{}` leaves an existing `registries.yaml` untouched, because the file may be
  managed outside this role; remove it by hand and restart RKE2 if the role wrote it.
- The install script is downloaded from the release tag on GitHub to `/var/cache/rke2-install-<version>.sh`
  (root only, mode 0700) and kept there for reference. It verifies the SHA-256 checksum of the release tarball
  before installing.

## Role variables

The full list with types is in `meta/argument_specs.yml`.

| Variable | Default | Description |
|---|---|---|
| `rke2_servers_group` | `rke2_servers` | Group of server nodes |
| `rke2_agents_group` | `rke2_agents` | Group of agent nodes |
| `rke2_cluster_group` | `k8s_cluster` | Group of all nodes (uninstall guard) |
| `rke2_bootstrap_host` | first host of `rke2_servers_group` | Server that initialises the cluster |
| `rke2_cluster_name` | `rke2` | Name used in the fetched kubeconfig |
| `rke2_version` | `CHANGE_ME` | Exact release, for example `v1.36.6+rke2r1` |
| `rke2_channel` | `stable` | Channel; selects the RPM repository |
| `rke2_install_method` | `""` | `""` (script decides), `tar` or `rpm` |
| `rke2_token` | `""` | Cluster join secret (required, from the vault) |
| `rke2_agent_token` | `""` | Agent-only join secret |
| `rke2_data_dir` | `/var/lib/rancher/rke2` | RKE2 state directory |
| `rke2_cni` | `canal` | `canal`, `calico` or `cilium` |
| `rke2_cluster_cidr` | `10.42.0.0/16` | Pod network |
| `rke2_service_cidr` | `10.43.0.0/16` | Service network |
| `rke2_registration_address` | `""` | VIP or load balancer; required for more than one server |
| `rke2_api_endpoint` | `""` | Address in the fetched kubeconfig |
| `rke2_tls_san_extra` | `[]` | Extra API server certificate SANs |
| `rke2_ingress_controller` | `none` | `none`, `traefik` or `ingress-nginx` |
| `rke2_disable_components` | `[]` | Packaged components to disable |
| `rke2_cis_profile` | `false` | Run with `profile: cis` |
| `rke2_audit_policy_enabled` | `true` | Install the audit policy and enable audit logging |
| `rke2_audit_log_maxage` | `30` | Days to keep rotated audit logs |
| `rke2_audit_log_maxbackup` | `10` | Rotated audit log files to keep |
| `rke2_audit_log_maxsize` | `100` | Audit log rotation size in MB |
| `rke2_apiserver_oidc` | `enabled: false`, claims `email` and `groups`, prefixes `oidc:` | API server OIDC |
| `rke2_kube_apiserver_args` | `[]` | Extra kube-apiserver flags |
| `rke2_kubelet_args` | `[]` | Extra kubelet flags |
| `rke2_server_taint` | `false` | Taint servers `CriticalAddonsOnly=true:NoExecute` when agents exist |
| `rke2_etcd_snapshot_schedule` | `0 */6 * * *` | Snapshot cron schedule |
| `rke2_etcd_snapshot_retention` | `10` | Local snapshots kept per server |
| `rke2_etcd_s3` | `enabled: false`, other keys empty | S3 upload: `endpoint`, `bucket`, `folder`, `region` |
| `rke2_etcd_s3_access_key` | `""` | S3 access key (vault) |
| `rke2_etcd_s3_secret_key` | `""` | S3 secret key (vault) |
| `rke2_etcd_s3_retention` | `0` | Snapshots kept in S3 for the cluster; 0 keeps the RKE2 default (5) |
| `rke2_registries` | `{}` | Content of `registries.yaml` |
| `rke2_kube_vip_enabled` | `false` | kube-vip static pod on the servers |
| `rke2_kube_vip_image` | `ghcr.io/kube-vip/kube-vip` | kube-vip image |
| `rke2_kube_vip_version` | `v1.3.1` | kube-vip tag |
| `rke2_kube_vip_interface` | `""` | Interface that announces the VIP |
| `rke2_service_start_timeout` | `900` | Seconds allowed for a service start or restart |
| `rke2_node_ready_retries` | `60` | Readiness attempts |
| `rke2_node_ready_delay` | `10` | Seconds between readiness attempts |
| `rke2_allow_downgrade` | `false` | Allow an older release than the installed one |
| `rke2_kubeconfig_fetch` | `true` | Copy the kubeconfig to the control node |
| `rke2_kubeconfig_local_path` | `{{ playbook_dir }}/../data/kubeconfig-{{ rke2_cluster_name }}.yaml` | Local kubeconfig path |
| `rke2_uninstall_confirm` | `false` | Required for the `uninstall` entry point |
| `rke2_node_ip` | `""` | Host: private address; empty uses the default IPv4 address |
| `rke2_node_external_ip` | `""` | Host: external address |
| `rke2_node_labels` | `[]` | Host: labels `key=value` |
| `rke2_node_taints` | `[]` | Host: taints `key=value:Effect` |
| `rke2_node_name` | `""` | Host: node name; empty uses the lowercased hostname |

## Example playbook

```yaml
- name: Bootstrap the first RKE2 server
  hosts: rke2_servers[0]
  become: true
  roles:
    - role: rke2

- name: Join the remaining RKE2 servers one at a time
  hosts: rke2_servers[1:]
  become: true
  serial: 1
  roles:
    - role: rke2

- name: Join RKE2 agents
  hosts: rke2_agents
  become: true
  serial: "25%"
  roles:
    - role: rke2
```

Uninstall:

```yaml
- name: Uninstall RKE2
  hosts: rke2_agents
  become: true
  tasks:
    - name: Run the RKE2 uninstall script
      ansible.builtin.import_role:
        name: rke2
        tasks_from: uninstall.yml
      vars:
        rke2_uninstall_confirm: true
```

## Testing

The role has no Molecule scenario. Running a real RKE2 server inside a Docker container (kernel modules,
cgroups, iptables and a kubelet) is not reliable, and a scenario that skips those parts would test little.
Coverage today:

- `ansible-lint` with the production profile (`ansible-lint roles/rke2` from `ansible/`);
- `ansible-playbook playbooks/site.yml --check --diff` against the lab inventory: the role is check-mode safe,
  the install, start and readiness steps report what they would do without running;
- a local VM harness, [`tests/integration/rke2`](../../../tests/integration/rke2/README.md): one Ubuntu 24.04 server in a
  Lima VM, with `preflight.yml`, `site.yml`, an idempotence run and `rke2_uninstall.yml`. It runs on a workstation,
  not in CI.

Not covered yet: an agent node and Rocky Linux 9 in the VM harness.

## Licence

MIT
