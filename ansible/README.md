# Provisioning with Ansible

Ansible prepares the hosts and installs RKE2. Infrastructure for the reference profile can come from the OpenTofu
example in [`infra/`](../infra/README.md); GitOps takes over once the cluster answers.

## Layout

| Path | Purpose |
|---|---|
| `ansible.cfg` | Hardened defaults: host key checking on, no agent forwarding, become per play. Run Ansible from this directory. |
| `collections/requirements.yml` | Pinned collections (`ansible.posix`, `community.general`). |
| `requirements-dev.txt` | Pinned Python tooling for linting and Molecule. |
| `inventories/lab/`, `inventories/reference/` | One inventory per profile. See [inventories/README.md](inventories/README.md). |
| `playbooks/preflight.yml` | Read-only checks before anything changes. |
| `playbooks/site.yml` | Builds or converges a cluster, including rolling RKE2 upgrades. |
| `playbooks/rke2_uninstall.yml` | Removes RKE2 from every node; refuses to run without `-e confirm=yes`. |
| `playbooks/jenkins_setup.yml` | Optional Jenkins host (separate concern, see its role README). |
| `roles/preflight` | Placeholder rejection, OS and kernel matrix, resources, ports, topology, runtime prerequisites. |
| `roles/base` | Packages, kernel modules, sysctls, swap, chrony, unattended security upgrades, SSH hardening, admin users. |
| `roles/firewall` | nftables input filter with source-restricted RKE2 and CNI ports per node role. |
| `roles/nfs_server` | Optional NFSv4 server exporting only to the node network. |
| `roles/rke2` | RKE2 servers and agents, HA join, upgrades, CIS profile, audit policy, etcd snapshots, kube-vip, kubeconfig. |
| `data/` | Fetched kubeconfig (gitignored). |
| `molecule/` | Shared Molecule test image and requirements. |

## Supported platforms

Ubuntu 24.04, Debian 12 and 13, Rocky Linux 9, on x86_64 and aarch64. The preflight role rejects anything else.
RKE2 is the only Kubernetes distribution. RKE1 reached end of life on 2025-07-31.

## Where values come from

| Source | Holds | Committed |
|---|---|---|
| `clusters/<name>/cluster.yaml` | Cluster settings shared with GitOps: RKE2 version, CNI, CIDRs, registration address, CIS profile, etcd snapshots. Loaded through `vars_files` by every play of `preflight.yml` and `site.yml` (not by `jenkins_setup.yml` or `rke2_uninstall.yml`) and mapped to role variables in `inventories/<name>/group_vars/all/cluster.yml`. | yes |
| `inventories/<name>/hosts.yml` | Hosts, addresses, SSH user, node network and admin CIDRs. Written from `hosts.yml.example` or rendered by `infra/`. | no |
| `inventories/<name>/group_vars/all/vault.yml` | RKE2 tokens and S3 credentials, encrypted with `ansible-vault`. Template: `vault.yml.example`. | no |
| `inventories/<name>/group_vars/*/` | Profile tuning (storage clients, server taint, kube-vip). | yes |
| `roles/<role>/defaults/main.yml` | Defaults, documented in each role's `meta/argument_specs.yml`. | yes |

## Usage

Run from this directory.

```bash
ansible-galaxy collection install -r collections/requirements.yml
cp inventories/lab/hosts.yml.example inventories/lab/hosts.yml
cp inventories/lab/group_vars/all/vault.yml.example inventories/lab/group_vars/all/vault.yml
# edit both files, replace every CHANGE_ME, then encrypt the vault file
ansible-vault encrypt --vault-id lab@prompt inventories/lab/group_vars/all/vault.yml
```

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/preflight.yml --vault-id lab@prompt
```

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml --vault-id lab@prompt
```

The admin kubeconfig lands in `data/kubeconfig-<cluster>.yaml` with mode 0600. To remove RKE2 again:

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/rke2_uninstall.yml -e confirm=yes
```

The Makefile at the repository root wraps these commands and selects the inventory with `CLUSTER`
(`lab` or `reference`): `make preflight CLUSTER=lab`, `make bootstrap-k8s CLUSTER=lab`,
`make rke2-uninstall CLUSTER=lab CONFIRM=yes`. The targets already pass `--vault-id <profile>@prompt` (`VAULT_ID`); set
`VAULT_ID=<profile>@<absolute path to a password file or client script>`, or export `ANSIBLE_VAULT_IDENTITY_LIST`, to
change the password source. Other options go through `ANSIBLE_ARGS`, for example `ANSIBLE_ARGS="--limit <host>"`.

## Upgrades

Set the new exact version in `clusters/<name>/cluster.yaml` (`rke2.version`) and run `site.yml` again. The bootstrap
server upgrades first, the other servers follow one at a time, then the agents in batches of 25 percent. Each node
must report Ready before the play moves on. Downgrades are refused.

## Testing

```bash
ansible-lint
```

```bash
ansible-playbook -i localhost, playbooks/site.yml --syntax-check
```

To check that a committed inventory example still parses (the extension override applies to the inventory
plugin only, so `vault.yml.example` is never loaded as variables):

```bash
ANSIBLE_INVENTORY_PLUGIN_EXTS=.yml,.yaml,.json,.example ansible-inventory -i inventories/lab/hosts.yml.example --graph
```

Molecule scenarios (Docker driver, Ubuntu 24.04, Debian 12 and 13, Rocky Linux 9) exist for the roles that can run in
a container; each role README lists what its scenario does not cover.

```bash
cd roles/base && molecule test
```
