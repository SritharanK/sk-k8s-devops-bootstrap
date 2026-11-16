# Inventories

One inventory per profile:

| Profile | Topology |
|---|---|
| `lab` | One RKE2 server, optionally one agent. The kind-based demo does not use Ansible. |
| `reference` | Three RKE2 servers behind a registration address (load balancer or kube-vip VIP) plus agents. |

## Groups

```text
all
  k8s_cluster          RKE2 nodes
    rke2_servers       the first server bootstraps the cluster, the others join one at a time
    rke2_agents
  nfs_server           optional NFS server (may be one of the nodes)
  jenkins              optional Jenkins host
```

## Files

| File | Committed | Content |
|---|---|---|
| `hosts.yml.example` | yes | Template for `hosts.yml`. |
| `hosts.yml` | no | Hosts, `ansible_user`, `firewall_node_cidrs`, `firewall_ssh_cidrs`, API endpoint. |
| `group_vars/all/main.yml` | yes | `cluster_name`, which selects `clusters/<cluster_name>/cluster.yaml`. |
| `group_vars/all/cluster.yml` | yes | Maps the cluster definition and the vault variables onto role variables. |
| `group_vars/all/vault.yml.example` | yes | Template for the encrypted `vault.yml`. |
| `group_vars/all/vault.yml` | no | Secrets, encrypted with `ansible-vault --vault-id <profile>@...`. |
| `group_vars/k8s_cluster/`, `group_vars/nfs_server/`, `group_vars/jenkins/` | yes | Profile tuning per group. |

Variable precedence matters: `group_vars/all` overrides the `all.vars` section of `hosts.yml`. Topology values are
therefore only defined in `hosts.yml`, and the cluster mapping uses `infra_registration_address` from `hosts.yml` only
as a fallback when `cluster.yaml` leaves the registration address empty.

## SSH host keys

`ansible.cfg` keeps host key checking on. Before the first run, add each host key to `~/.ssh/known_hosts` after
checking its fingerprint through an independent channel (the provider console or the server's boot log):

```bash
ssh-keyscan -t ed25519 192.0.2.10 >> ~/.ssh/known_hosts
```

Accepting keys blindly (`StrictHostKeyChecking=no` or `accept-new` without a fingerprint check) trusts whoever
answers first on that address.
