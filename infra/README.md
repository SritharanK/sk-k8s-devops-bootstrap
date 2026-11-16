# infra

Optional machine provisioning for the platform. The Ansible roles (`preflight`,
`base`, `firewall`, `rke2`) do not depend on anything in this directory. Any set
of hosts that satisfies the inventory contract below works, whether it was
created here, by another tool, or by hand.

## Targets

| Directory  | Target        | Tool     | Creates                                  |
|------------|---------------|----------|------------------------------------------|
| `hetzner/` | Hetzner Cloud | OpenTofu | The reference topology and its inventory |

Hetzner Cloud is the only target. Another provider fits in as a sibling
directory that renders the same inventory.

## Reference topology

The contract every target implements:

- One highly available RKE2 cluster: three server nodes (control plane and
  embedded etcd) plus agent nodes.
- Every node has a public IPv4 address for administration and a fixed private
  IPv4 address in one subnet. RKE2 traffic stays on the private network.
- A fixed registration address in front of the servers: a layer 4 load balancer
  that forwards 9345/tcp (RKE2 supervisor) and 6443/tcp (Kubernetes API).
- Inbound traffic on the public interfaces is limited to SSH from named admin
  networks, plus ICMP.

## Handover to Ansible

Ownership is split at the operating system boundary:

| Layer                                                          | Owner    |
|----------------------------------------------------------------|----------|
| Network, subnet, provider firewall, servers, load balancer     | OpenTofu |
| Admin user with SSH key and sudo (first boot only, cloud-init) | OpenTofu |
| Packages, sshd, host firewall (nftables), RKE2                 | Ansible  |

The only interface between the two is the inventory file. OpenTofu renders it
with `tofu output -raw ansible_inventory`; Ansible reads it from
`ansible/inventories/<profile>/hosts.yml`. OpenTofu does not run Ansible
(no provisioners) and Ansible does not call OpenTofu, so each side can be
re-run on its own.

Variables in the rendered inventory:

| Variable                     | Scope | Meaning                                                              |
|------------------------------|-------|----------------------------------------------------------------------|
| `ansible_user`               | all   | Admin user created by cloud-init                                     |
| `firewall_node_cidrs`        | all   | Private subnet; the host firewall allows cluster ports from it       |
| `firewall_ssh_cidrs`         | all   | Networks allowed to reach SSH                                        |
| `firewall_api_cidrs`         | all   | Networks allowed to reach the Kubernetes API on the nodes directly   |
| `infra_registration_address` | all   | Load balancer private IP; RKE2 registration address fallback         |
| `rke2_api_endpoint`          | all   | Address clients use for the API (load balancer public or private IP) |
| `rke2_tls_san_extra`         | all   | Extra SANs for the API server certificate                            |
| `ansible_host`               | host  | Public IPv4 Ansible connects to                                      |
| `rke2_node_ip`               | host  | Private IPv4 RKE2 binds to                                           |

The registration address the `rke2` role uses comes from
`clusters/<profile>/cluster.yaml` (`rke2.registrationAddress`) when that is set,
and from `infra_registration_address` otherwise.

## Fleet scale: Cluster API (not implemented)

For many clusters, Cluster API with the RKE2 bootstrap and control plane
providers and a Hetzner Cloud infrastructure provider is the alternative:
clusters become Kubernetes objects on a management cluster, nodes are replaced
instead of reconfigured, and upgrades roll machines one by one. The price is a
management cluster to run, back up and secure, and node configuration that moves
from Ansible roles into images and bootstrap configuration.

This repository manages one reference cluster and keeps OpenTofu plus Ansible.
Cluster API is recorded as an option; nothing here implements it.
