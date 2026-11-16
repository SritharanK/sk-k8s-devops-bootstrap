# Hetzner Cloud: reference topology

OpenTofu configuration that creates the reference topology from
[`infra/README.md`](../README.md) on Hetzner Cloud and renders the Ansible
inventory for it. It creates machines and network plumbing only; Ansible
installs and configures everything inside the operating system.

## What it creates

| Resource                  | Count (defaults) | Purpose                                                              |
|---------------------------|------------------|----------------------------------------------------------------------|
| `hcloud_network` + subnet | 1 + 1            | Private network `10.20.0.0/16`, subnet `10.20.0.0/24` (type `cloud`) |
| `hcloud_ssh_key`          | 1                | Admin key; also prevents the API from generating a root password     |
| `hcloud_firewall`         | 1                | Public interfaces: SSH from `admin_cidrs`, ICMP; nothing else        |
| `hcloud_placement_group`  | 1                | `spread`: each server on a different physical host                   |
| `hcloud_server` (servers) | 3                | RKE2 servers, private IPs from host 10 (`10.20.0.10` onward)         |
| `hcloud_server` (agents)  | 2                | RKE2 agents, private IPs from host 20 (`10.20.0.20` onward)          |
| `hcloud_load_balancer`    | 1                | Fixed registration address, private IP host 254 (`10.20.0.254`)      |
| Load balancer services    | 2                | TCP 6443 and TCP 9345 with TCP health checks, private IP targets     |

Every node gets a public IPv4 and IPv6 address. Nodes carry the labels
`cluster=<cluster_name>` and `role=server|agent`, plus anything in `labels`.

Cloud-init does one thing on first boot: it creates `admin_username` with the
SSH key and passwordless sudo, disables root and password logins, and leaves
packages alone.

## Prerequisites

- OpenTofu 1.10 or later (validated with 1.13.9). The provider is pinned to
  `hetznercloud/hcloud` 1.70.2 and locked in `.terraform.lock.hcl` for
  linux and darwin on amd64 and arm64.
- A Hetzner Cloud project and an API token with read and write permission.
- An ed25519 SSH key pair; the private key loaded in `ssh-agent` or passed to
  Ansible.
- The egress CIDRs of the networks you administer from (office, VPN, bastion).
- `jq` and `ssh-keyscan` for the host key step; Ansible for the handover.

## Defaults and availability

Checked on 2026-11-16 against the Hetzner price pages for
[Regular Performance](https://www.hetzner.com/cloud/regular-performance/) and
[Cost-Optimized](https://www.hetzner.com/cloud/cost-optimized/), the
[locations overview](https://docs.hetzner.com/cloud/general/locations/) and the
[Cloud API changelog](https://docs.hetzner.cloud/changelog):

- `server_type` and `agent_type` default to `cpx32`: 4 shared AMD vCPU, 8 GB
  RAM, 160 GB disk. RKE2 lists 2 CPU and 4 GB RAM as the minimum and
  recommends at least 4 CPU and 8 GB RAM. The Regular Performance page listed
  `cpx22` and larger for NBG1, HEL1 and SIN, not for FSN1.
- `location` defaults to `nbg1` (network zone `eu-central`) for that reason.
- The October 2025 lineup change replaced `cx22`-`cx52` with `cx23`-`cx53` and
  `cpx11`-`cpx51` with `cpx12`-`cpx62` in the EU and Singapore; the old types
  stopped being orderable there on 1 January 2026. On the check date the
  Cost-Optimized page marked every `cx` and `cax` plan as not available.
- `image` is limited to `ubuntu-24.04`, `debian-12`, `debian-13` and
  `rocky-9`, the distributions the Ansible roles support.

Hetzner states that cloud instances may occasionally be unavailable for
ordering. If `tofu apply` fails to create servers, pick another type or
location in the same network zone, or check the current offer with the
`hcloud` CLI (`hcloud server-type list`, `hcloud location list`).

## Usage

All commands run from `infra/hetzner` unless stated otherwise.

### 1. Configure

```sh
export TF_VAR_hcloud_token=CHANGE_ME     # never in a file under version control
cp terraform.tfvars.example reference.tfvars
$EDITOR reference.tfvars                 # ssh_public_key, admin_cidrs, labels
```

### 2. Create

```sh
tofu init
tofu plan  -var-file=reference.tfvars
tofu apply -var-file=reference.tfvars
```

`tofu apply` shows the plan again and asks for confirmation. If you save plans
with `-out`, enable plan encryption first (see [State](#state)): a saved plan
contains `hcloud_token`.

### 3. Render the inventory

```sh
mkdir -p ../../ansible/inventories/reference
tofu output -raw ansible_inventory > ../../ansible/inventories/reference/hosts.yml
```

The file contains real addresses. Keep it out of version control and render it
again after every apply that changes nodes or the load balancer.

### 4. Trust the host keys

Ansible verifies SSH host keys. Collect them once:

```sh
(tofu output -json servers; tofu output -json agents) \
  | jq -r '.[].public_ipv4' > reference.hosts
ssh-keyscan -t ed25519 -f reference.hosts > reference.known_hosts
ssh-keygen -lf reference.known_hosts
```

`ssh-keyscan` is trust on first use: it records whatever key answers on that
address at that moment. Anyone able to intercept the connection then would be
trusted from here on, and the Ansible run would hand them the cluster join
token and every other secret it deploys. Verify before trusting:

1. In the Hetzner Console, open each server and its console.
2. At first boot cloud-init prints a block between
   `-----BEGIN SSH HOST KEY FINGERPRINTS-----` and
   `-----END SSH HOST KEY FINGERPRINTS-----`.
3. Compare the `ED25519` fingerprint there with the `SHA256:` value printed by
   `ssh-keygen -lf` for the same address.

Only when all fingerprints match:

```sh
cat reference.known_hosts >> ~/.ssh/known_hosts
```

Do not disable host key checking instead (`ansible/ansible.cfg` sets
`host_key_checking = True`). If an address is already in your `known_hosts`
from an earlier server, `ssh-keygen -R <address>` clears the stale entry.

### 5. Hand over to Ansible

Allow a minute after `apply` for cloud-init to create the admin user. Then,
from the repository root:

```sh
make preflight     CLUSTER=reference
make bootstrap-k8s CLUSTER=reference
```

or directly:

```sh
cd ansible
ansible-playbook -i inventories/reference/hosts.yml playbooks/site.yml
```

Ansible connects as `admin_username` with the private key that matches
`ssh_public_key`.

## Registration address and API endpoint

- Agents and joining servers register through
  `https://<registration address>:9345`. The `rke2` role takes it from
  `clusters/reference/cluster.yaml` (`rke2.registrationAddress`) when that is
  set, and from `infra_registration_address` (the load balancer private IP)
  when it is empty. Set `registrationAddress` only when you put a DNS name in
  front of the load balancer.
- `rke2_api_endpoint` is the load balancer public IPv4 when
  `load_balancer_public = true`, otherwise its private IP.
  `rke2_tls_san_extra` always contains the private IP and, with a public load
  balancer, the public IPv4 as well, so the API certificate covers the address
  clients use.
- With a private load balancer, reach the API through a tunnel, for example
  `ssh -N -L 6443:10.20.0.254:6443 ops@<server public IPv4>`, and point the
  kubeconfig at `https://127.0.0.1:6443`, which RKE2 includes in the
  certificate by default.

## Network security model

Facts this configuration relies on (Hetzner
[Firewall FAQ](https://docs.hetzner.com/cloud/firewalls/faq/),
[Load Balancer FAQ](https://docs.hetzner.com/cloud/load-balancers/faq/),
[Cloud API reference](https://docs.hetzner.cloud/reference/cloud), checked
2026-11-16):

- Hetzner Cloud Firewalls apply to servers only, directly or by label
  selector. They cannot be applied to load balancers.
- They filter the public interfaces only. Traffic in private networks is not
  filtered, which includes load balancer to node traffic on 6443 and 9345.
  The host nftables rules from the Ansible `firewall` role cover the cluster
  ports on the private network.
- A load balancer's public interface can be disabled only when it is attached
  to a network and every target uses its private IP. This configuration always
  uses private IP targets, so `load_balancer_public` can be switched either way.
- For TCP services the targets see connections from the load balancer; Hetzner
  documents the proxy protocol as the only way to pass the client address.

The provider firewall opens neither 6443 nor 9345 on the nodes' public
interfaces. `firewall_api_cidrs` in the host firewall is therefore a second
layer for direct node access; API clients go through the load balancer.

Consequence of `load_balancer_public = true` (the default): the Kubernetes API
and the RKE2 supervisor listen on the load balancer's public IPv4 and IPv6 for
every source. `admin_cidrs` cannot restrict them, neither at the provider edge
nor on the hosts. Both services rely on their own authentication (client
certificates and tokens for the API, the cluster token for registration). For
anything beyond a lab, set `load_balancer_public = false` and reach the API over
a VPN or a tunnel.

## State

Without a backend, state lives in `terraform.tfstate` in this directory. Keep it
out of version control and treat it as a secret: it holds the complete address
and firewall map, and any secret a future resource handles lands in it in plain
text. Saved plan files also contain `hcloud_token`.

For shared use, enable the commented `s3` backend and `encryption` block in
[`versions.tf`](versions.tf): a private, versioned bucket with access limited
to the operators of this cluster, client-side encryption of state and plans with
a passphrase from `TF_VAR_state_passphrase`, credentials from the environment.

Native locking (`use_lockfile`) depends on conditional writes. Hetzner Object
Storage is S3 compatible, but its
[list of supported actions](https://docs.hetzner.com/storage/object-storage/supported-actions/)
names conditional PUT and DELETE on versioned buckets as not supported. Verify
that a second concurrent `tofu plan` is refused before relying on the lock, or
use an object store that supports it.

OpenTofu 1.11 and later support ephemeral input variables, which are never
written to plan or state. Raising `required_version` to `>= 1.11.0` allows
declaring `hcloud_token` with `ephemeral = true`.

## Cost

No prices here; they change. Check the current price list before applying.
With the defaults you pay for:

- five servers, billed per hour up to a monthly cap, including while powered
  off;
- five primary IPv4 addresses, one per server, billed separately from the
  server (primary IPv6 addresses are free of charge);
- one `lb11` load balancer, billed per hour up to a monthly cap;
- traffic above the included volume.

Firewalls are free of charge. Only deleting resources stops billing.

## Day-2 changes

- `user_data`, `ssh_keys` and `image` are ignored after creation, because
  changing them replaces the server. Roll such changes out node by node:
  `tofu apply -var-file=reference.tfvars -replace='hcloud_server.server["reference-server-1"]'`,
  then let Ansible bring the node back before the next one.
- Changing `server_type` or `agent_type` rescales in place: the provider powers
  the server off hard, changes the type and upgrades the disk, after which a
  downgrade is no longer possible. OpenTofu applies this to all servers in
  parallel, which takes etcd down. Rescale servers one at a time with
  `-target='hcloud_server.server["<name>"]'` and check etcd health between
  steps.
- Raising `agent_count` adds agents; render the inventory again and rerun
  Ansible. Lowering it removes the highest numbered agents without draining
  them; drain and delete the nodes in Kubernetes first.

## Destroy

```sh
tofu destroy -var-file=reference.tfvars
```

This removes every resource above, including the etcd data on the servers.
Take an etcd snapshot first if you need the cluster state. Afterwards the
rendered inventory and your `known_hosts` entries point at addresses that no
longer belong to you: render a new inventory before the next run and clear the
entries with `ssh-keygen -R <address>`.

## Tests

`tests/hetzner.tftest.hcl` runs offline against a mocked `hcloud` provider, so it needs no token and creates
nothing:

```sh
tofu init -backend=false
tofu test
```

It proves the node counts, the fixed private addresses, the placement group and firewall attachment, that the
firewall opens only SSH (from the admin CIDRs) and ICMP, the load balancer targets, services and private address,
the rendered Ansible inventory for a public and a private API, and that unsafe input (SSH from anywhere, an even
server count, a non-ed25519 key) is rejected. It cannot prove that Hetzner accepts the chosen server types,
images and locations, or that the cluster comes up; that needs a real `tofu apply`.

## Not included (follow-ups)

- DNS records for the API endpoint, and the name in `rke2_tls_san_extra` /
  `registrationAddress`.
- Hetzner Cloud Controller Manager for node metadata, routes and `LoadBalancer`
  services. It expects kubelets started with `--cloud-provider=external`;
  decide before the first bootstrap rather than retrofitting it.
- Hetzner Cloud CSI driver for persistent volumes.
- A load balancer for Gateway and ingress traffic (80/443). The API load
  balancer here serves 6443 and 9345 only.
- Delete protection, backups and snapshots, and monitoring of the load
  balancer health checks.
