# RKE2 integration test (local VM)

`run.sh` exercises the Ansible provisioning path end to end on one disposable Ubuntu 24.04 VM created with
[Lima](https://lima-vm.io/). It needs no cloud account.

## Steps

1. Wait until the host has at least `MIN_FREE_GIB` (default 7) GiB of available memory and the kind demo
   cluster (`make demo`, kind cluster `demo` by default) is not running.
2. Create the VM `it-rke2` in Lima plain mode (no host mounts, no port forwarding): 4 CPU, 6 GiB memory,
   40 GiB disk.
3. Read the VM's SSH host key over the loopback forward into a run-specific `known_hosts`, so host key checking
   stays on.
4. Render an inventory in a private temporary directory: the committed `ansible/inventories/lab/group_vars`
   (including the cluster definition mapping) plus a generated `hosts.yml` with one server. The firewall admits
   SSH only from the address the VM sees for this host. A random join token is passed as an extra-vars file.
5. Run `playbooks/preflight.yml`, then `playbooks/site.yml` with `clusters/lab/cluster.yaml`.
6. Verify:
   - the node reports `Ready`;
   - the kubelet version and `rke2 --version` equal `rke2.version` from the cluster definition;
   - `etcd-snapshot-schedule-cron` in `/etc/rancher/rke2/config.yaml` equals `rke2.etcdSnapshots.schedule`, and an
     on-demand `rke2 etcd-snapshot save` writes a snapshot;
   - `config.yaml` is mode 0600 and sets `ingress-controller: none`;
   - the nftables table `inet rke2_host` is loaded;
   - the fetched kubeconfig is mode 0600 and its server is the VM address set as `rke2_api_endpoint`.
7. Run `playbooks/site.yml` again and require `changed=0` (idempotence).
8. Run `playbooks/rke2_uninstall.yml` without confirmation and require a refusal, then with `-e confirm=yes`
   and require that the RKE2 binaries and `/var/lib/rancher/rke2` are gone.
9. Delete the VM and the temporary directory (also on failure). `KEEP_VM=1` keeps both for debugging.

## Usage

```bash
tests/integration/rke2/run.sh
```

Requirements on the host: `limactl`, `ansible-playbook` and `ansible-galaxy` (versions in
`ansible/requirements-dev.txt`), `yq`, `jq`, `openssl`, `ssh`. A run takes about 15 minutes, most of it package and
image downloads.

The harness runs by hand on a workstation; no CI workflow runs it.

Last result (2026-11-16, Ubuntu 24.04 VM, RKE2 v1.36.6+rke2r1 from `clusters/lab/cluster.yaml`): passed.

## What it proves

- The preflight, base, firewall and rke2 roles converge a supported OS from a cloud image to a Ready RKE2 server
  with the pinned version, using the same inventory mapping and cluster definition as a real lab install.
- The host firewall does not cut off SSH or break the node.
- The roles are idempotent on a real systemd host.
- The uninstall playbook refuses to run unconfirmed and removes RKE2 when confirmed.

## What it cannot prove

- HA: joining servers through a registration address, rolling restarts and quorum loss need three servers. The
  join, serial rollout and kube-vip paths are exercised only by rendering and `--check` runs.
- Agents, CNI traffic between nodes, and the firewall rules for cross-node ports.
- etcd snapshot upload to S3 (the lab profile keeps snapshots local).
- The CIS profile (the lab cluster definition sets `cisProfile: false`).
- Debian and Rocky Linux; the role Molecule scenarios cover the OS-specific parts of preflight, base, firewall and
  nfs_server in containers.
- Upgrades between RKE2 versions.
- The OpenTofu example; `infra/hetzner/tests/` covers it offline with a mocked provider.
