# firewall

Host input firewall for RKE2 nodes, built on nftables only. The role keeps its rules in its own table
`inet rke2_host`, loaded by a dedicated systemd unit, and filters the input hook only: it never adds forward or output
chains and never flushes the ruleset, so the rules of the CNI and kube-proxy stay intact.

## Supported platforms

| Distribution | Versions |
|---|---|
| Ubuntu | 24.04 (noble) |
| Debian | 12 (bookworm), 13 (trixie) |
| Rocky Linux | 9 |

## Requirements

- ansible-core 2.20 or later. Only `ansible.builtin` modules are used.
- Gathered facts (`os_family`; `default_ipv4` of the servers for the etcd rule).
- Privilege escalation (`become: true` in the playbook).

## How it works

- `/etc/nftables.d/rke2-host.nft` (mode 0640) holds `table inet rke2_host`, then `delete table inet rke2_host`, then
  the full table. `nft -f` applies the file as one transaction, so a reload replaces the table atomically. The
  template is checked with `nft -c -f` before it is written.
- `rke2-host-firewall.service` is a oneshot unit with `RemainAfterExit`, ordered before `network-pre.target`.
  `ExecStart` and `ExecReload` run `nft -f`, `ExecStop` deletes the table. The distribution `nftables.service` is not
  used: the Debian default configuration starts with `flush ruleset`.
- Changed rules reload the unit; a changed unit triggers a daemon reload and a restart.
- `firewall_disable_conflicting` stops and disables `firewalld.service` and `ufw.service` when they are installed.
- `firewall_enabled: false` stops and disables the unit, which deletes the table. The files stay on disk.

Node role (set as the fact `firewall_node_role` and written into the rules file header):

| Role | Condition | Rules |
|---|---|---|
| `server` | host in `firewall_servers_group` | base, cluster, server, CNI, NodePort, ingress, extra |
| `agent` | host in `firewall_agents_group` | base, cluster, CNI, NodePort, ingress, extra |
| `none` | neither group (for example an NFS server) | base, extra |

Rules in the input chain (policy drop), from docs.rke2.io/install/requirements:

| Rule | Roles | Sources |
|---|---|---|
| Established and related accept, invalid drop, loopback | all | any |
| ICMP (echo request and errors), ICMPv6 (errors, neighbour discovery, MLD from link-local), DHCPv6 replies from link-local | all | any |
| SSH (`firewall_ssh_port`) | all | `firewall_ssh_cidrs` |
| Traffic from CNI interfaces (`cali*`, `flannel*`, `cni*`, `vxlan.calico`, `cilium*`, `lxc*`, `tunl0`) | server, agent | any |
| Pod network (`firewall_cluster_cidr`) | server, agent | pod CIDR |
| kubelet 10250/tcp | server, agent | node CIDRs |
| Kubernetes API 6443/tcp | server | node CIDRs and `firewall_api_cidrs` |
| RKE2 supervisor 9345/tcp | server | node CIDRs |
| etcd 2379-2381/tcp | server | server addresses or `firewall_etcd_sources` |
| canal: 8472/udp, 9099/tcp, 51820/udp (IPv4), 51821/udp (IPv6) | server, agent | node CIDRs |
| calico: 179/tcp, 4789/udp, 5473/tcp, 9098/tcp, 9099/tcp | server, agent | node CIDRs |
| cilium: ICMP echo request and reply, 4240/tcp, 8472/udp, 51871/udp | server, agent | node CIDRs |
| NodePort 30000-32767/tcp (`firewall_nodeport_enabled`) | server, agent | `firewall_nodeport_cidrs` |
| Ingress `firewall_ingress_ports` | server, agent | `firewall_ingress_cidrs` (empty: no rule) |
| `firewall_extra_rules` | all | per rule |
| Rate-limited log (`firewall_log_dropped`), counter, drop | all | any |

Sources are named sets per address family (`<name>_v4` with `ipv4_addr`, `<name>_v6` with `ipv6_addr`, both
`flags interval` and `auto-merge`), so IPv4 and IPv6 CIDRs can be mixed in every list. A set and its rule are only
rendered when the set has elements. VXLAN (8472/udp) is only reachable from the node CIDRs.

The etcd sources default to the address of each member of `firewall_servers_group`: `rke2_node_ip`, else
`ansible_facts['default_ipv4']['address']` (only when that host's facts were gathered in the same run), else
`ansible_host`. Set `rke2_node_ip` on the servers, or `firewall_etcd_sources`, when the play runs with `--limit` or
when `ansible_host` is a public address. A source that is not an IP address or CIDR fails the play.

### Limits of an input-hook firewall

- Traffic that is destination-NATed in the prerouting hook to a pod address takes the forward path, and this table
  never sees it. That applies to NodePort traffic forwarded by kube-proxy in iptables or nftables mode and to hostPort
  traffic (portmap CNI plugin). Cilium's eBPF kube-proxy replacement handles NodePort traffic before netfilter. For
  such traffic `firewall_nodeport_cidrs` and `firewall_ingress_cidrs` have no effect; restrict it with a network or
  cloud firewall, or with network policies. The rules do apply to host-network listeners and to kube-proxy in IPVS
  mode, where the service address is local to the node.
- Pods can reach every port of their host, because traffic from CNI interfaces and the pod network is accepted.
- Calico IP-in-IP (IP protocol 4) is not opened. `firewall_extra_rules` only covers TCP and UDP.

## Role variables

The full specification, with types, is in `meta/argument_specs.yml`.

| Variable | Default | Description |
|---|---|---|
| `firewall_enabled` | `true` | Manage the firewall; false stops and disables the unit. |
| `firewall_cni` | `canal` | `canal`, `calico` or `cilium`. Selects the CNI rules. |
| `firewall_node_cidrs` | `[]` | Private node network CIDRs. Required, no placeholder. |
| `firewall_ssh_cidrs` | `[]` | Sources allowed to reach SSH. Required, to avoid a lockout. |
| `firewall_ssh_port` | `22` | SSH port. |
| `firewall_api_cidrs` | `[]` | Extra sources for 6443/tcp on servers. |
| `firewall_cluster_cidr` | `10.42.0.0/16` | Pod CIDR, comma separated for dual stack. |
| `firewall_servers_group` | `rke2_servers` | Group whose members get the server rules. |
| `firewall_agents_group` | `rke2_agents` | Group whose members get the agent rules. |
| `firewall_etcd_sources` | `[]` | etcd sources; empty means the server addresses. |
| `firewall_nodeport_enabled` | `true` | Open 30000-32767/tcp. |
| `firewall_nodeport_cidrs` | `"{{ firewall_node_cidrs }}"` | Sources for the NodePort range. |
| `firewall_ingress_ports` | `[80, 443]` | Ingress TCP ports. |
| `firewall_ingress_cidrs` | `[]` | Sources for the ingress ports; empty means no rule. |
| `firewall_extra_rules` | `[]` | Items `{port, proto, sources, comment}`; port is a number or `"start-end"`, proto `tcp` or `udp`. |
| `firewall_disable_conflicting` | `true` | Stop and disable firewalld and ufw. |
| `firewall_log_dropped` | `false` | Log dropped packets, rate limited. |
| `firewall_log_rate` | `10/minute` | nft limit rate for the drop log. |

Output: the fact `firewall_node_role` (`server`, `agent` or `none`) is set on every run.

## Example playbook

```yaml
- name: Host firewall
  hosts: k8s_cluster:nfs_server
  become: true
  gather_facts: true
  roles:
    - role: firewall
      vars:
        firewall_node_cidrs: [10.10.0.0/24]
        firewall_ssh_cidrs: [192.0.2.0/24]
        firewall_api_cidrs: [198.51.100.10/32]
```

On an NFS server outside the cluster groups:

```yaml
firewall_extra_rules:
  - port: 2049
    proto: tcp
    sources: "{{ firewall_node_cidrs }}"
    comment: NFSv4 from cluster nodes
```

## Testing

```sh
cd ansible/roles/firewall
uvx --python 3.13 --from 'molecule==26.11.0' --with 'molecule-plugins[docker]==26.11.0' \
  --with 'ansible-core==2.21.6' --with 'docker==7.2.0' molecule test
```

The scenario runs on Ubuntu 24.04, Debian 12, Debian 13 and Rocky 9 containers, all in `rke2_servers` with canal.
`prepare.yml` installs iproute2 so the server addresses come from `default_ipv4`. `verify.yml` lists the loaded table
and checks the API, supervisor, etcd, kubelet and VXLAN rules, the active unit, the node role in the file header and
the file mode.

Not covered, and why:

- Packet filtering itself: the scenario checks the loaded ruleset, not traffic between nodes.
- Agent and `none` roles, calico, cilium and IPv6 sources: one scenario renders one combination. The node role and
  the CNI only select rules from `vars/main.yml` and the CNI interface block in the template.
- firewalld and ufw handling: the container images do not ship them.
- Boot ordering before `network-pre.target`: the containers are not rebooted.

## Licence

MIT
