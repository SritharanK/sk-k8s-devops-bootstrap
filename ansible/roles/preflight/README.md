# preflight

Read-only checks that stop an RKE2 deployment before anything changes on a host. The host checks reject placeholder
values, unsupported platforms, undersized hosts, occupied ports and an invalid cluster topology. The runtime checks
confirm the state that the base role prepares (swap, kernel modules, sysctls, time synchronisation).

## Supported platforms

| Distribution | Versions |
|---|---|
| Ubuntu | 24.04 (noble) |
| Debian | 12 (bookworm), 13 (trixie) |
| Rocky Linux | 9 |

Architectures: `x86_64`, `aarch64`.

## Requirements

- ansible-core 2.20 or later.
- Collection `community.general` 14.0.1 (`listen_ports_facts`, `counter` filter), see
  `ansible/collections/requirements.yml`.
- `ss` (iproute2) or `netstat` on the host for the port check, GNU `df` (coreutils) for the disk check. Cloud
  images of the supported distributions ship both.
- Privilege escalation (`become: true` in the playbook): without root, `ss` does not show the process that owns a
  socket of another user.

## Checks

| Entry point | File | Checks | On failure |
|---|---|---|---|
| `host` | `tasks/host.yml` | placeholders, distribution and version, architecture, kernel version, vCPU, memory, free disk, required ports, unique hostnames, at least one server, registration address for more than one server, even server count (warning) | fails the host |
| `runtime` | `tasks/runtime.yml` | swap off, kernel modules loaded or built in, sysctl values, clock synchronised | fails, or warns when `preflight_runtime_fatal: false` |
| `placeholders` | `tasks/placeholders.yml` | placeholders only | fails the host |
| `main` | `tasks/main.yml` | `host`, then `runtime` when `preflight_runtime_checks` is true | as above |

Details:

- Placeholders: every variable named in `preflight_placeholder_vars` and `preflight_placeholder_vars_extra` is
  serialised to JSON (nested lists and dictionaries included) and searched for `preflight_placeholder_pattern`. The scan
  runs with `no_log`; the failure message lists variable names only, never values.
- Platform: a value in `versions` matches either `distribution_version` (Ubuntu `24.04`) or
  `distribution_major_version` (Debian `12`, Rocky `9`).
- Kernel: the part of `ansible_facts['kernel']` before the first `-` is compared with the `version` test.
- Free disk: `df` runs on the nearest existing ancestor of `preflight_disk_path` (the path may not exist yet; df
  follows symlinks). `ansible_facts['mounts']` is not used because it leaves out file systems whose device does not
  start with `/`, such as the overlay root of a container or a ZFS dataset.
- Ports: a host in `preflight_servers_group` must have `preflight_server_ports` free, any other host
  `preflight_agent_ports`. A port held by a process whose name matches `preflight_port_owner_allowlist` is accepted,
  so the play runs again on an existing node.
- Topology: runs once, and only when at least one of the cluster, server or agent groups has hosts. Hostnames are
  compared case-insensitively for the hosts that have gathered facts.
- Time: `timedatectl show --property=NTPSynchronized --value`; when timedatectl does not answer, `chronyc -n tracking`
  (leap status `Normal` means synchronised). When neither answers, the state is reported as unknown.

The runtime checks look at state that the base role creates. On a fresh host run the `host` entry point before any
change and the `runtime` entry point after the base role, or set `preflight_runtime_checks: false` for the first run.

## Role variables

The full specification, with types, is in `meta/argument_specs.yml`.

| Variable | Default | Description |
|---|---|---|
| `preflight_placeholder_pattern` | `CHANGE_ME` | Regular expression that marks a value as not yet set. |
| `preflight_placeholder_vars` | `[rke2_version, rke2_token]` | Variables to check for the placeholder. |
| `preflight_placeholder_vars_extra` | `[]` | Additional variables to check, without copying the list. |
| `preflight_supported_platforms` | Ubuntu 24.04, Debian 12 and 13, Rocky 9 | List of `{distribution, versions}`. |
| `preflight_supported_architectures` | `[x86_64, aarch64]` | Supported `ansible_facts['architecture']` values. |
| `preflight_min_kernel_version` | `"5.14"` | Minimum kernel version. |
| `preflight_min_vcpus` | `2` | Minimum vCPUs. |
| `preflight_min_memory_mb` | `3500` | Minimum memory in MB (a 4 GB host reports less than 4096). |
| `preflight_disk_path` | `/var/lib/rancher` | Path whose file system needs free space. |
| `preflight_min_disk_free_gb` | `20` | Minimum free space in GiB. |
| `preflight_check_ports` | `true` | Check that required TCP ports are free. |
| `preflight_server_ports` | `[6443, 9345, 2379, 2380, 2381, 10250]` | Ports required on a server. |
| `preflight_agent_ports` | `[10250]` | Ports required on an agent. |
| `preflight_port_owner_allowlist` | rke2, etcd, kube-apiserver, kube-controller, kube-scheduler, kubelet, containerd, kube-proxy | Process name patterns that may hold a required port. |
| `preflight_servers_group` | `rke2_servers` | Inventory group of the servers. |
| `preflight_agents_group` | `rke2_agents` | Inventory group of the agents. |
| `preflight_cluster_group` | `k8s_cluster` | Inventory group of all cluster nodes. |
| `preflight_registration_address` | `"{{ rke2_registration_address \| default('') }}"` | Required when there is more than one server. |
| `preflight_runtime_checks` | `true` | Run the runtime checks from the main entry point. |
| `preflight_runtime_fatal` | `true` | Fail on runtime findings; false prints a warning. |
| `preflight_swap_off_required` | `true` | Require that no swap device is active. |
| `preflight_required_kernel_modules` | `[overlay, br_netfilter]` | Modules that must be loaded or built in. |
| `preflight_required_sysctls` | `net.ipv4.ip_forward: 1`, `net.bridge.bridge-nf-call-iptables: 1` | Kernel parameters and required values. |
| `preflight_time_sync_required` | `true` | Require a synchronised clock. |
| `preflight_time_sync_wait_seconds` | `120` | Wait this long for the clock to synchronise before the check fails. |

## Example playbook

```yaml
- name: Check the hosts before any change
  hosts: k8s_cluster
  become: true
  gather_facts: true
  tasks:
    - name: Run the host checks
      ansible.builtin.include_role:
        name: preflight
        tasks_from: host

# ... base role, firewall role ...

- name: Check the prepared hosts before installing RKE2
  hosts: k8s_cluster
  become: true
  gather_facts: true
  tasks:
    - name: Run the runtime checks
      ansible.builtin.include_role:
        name: preflight
        tasks_from: runtime
```

## Testing

```sh
cd ansible/roles/preflight
uvx --python 3.13 --from 'molecule==26.11.0' --with 'molecule-plugins[docker]==26.11.0' \
  --with 'ansible-core==2.21.6' --with 'docker==7.2.0' molecule test
```

The scenario runs on Ubuntu 24.04, Debian 12, Debian 13 and Rocky 9 containers. `prepare.yml` installs iproute2 and
procps and enables IP forwarding. Converge applies the role with container-sized thresholds (1 vCPU, 256 MB, 1 GiB);
idempotence expects no change. `verify.yml` runs the placeholder check against a nested `CHANGE_ME` value and
asserts that it fails and names the variable.

Not covered, and why:

- Kernel modules, swap and time synchronisation: a container shares the kernel, swap and clock of the Docker host,
  so `preflight_required_kernel_modules: []`, `preflight_swap_off_required: false` and
  `preflight_time_sync_required: false` in the scenario.
- Production thresholds (2 vCPU, 3500 MB, 20 GiB) and failing hardware checks: the result depends on the Docker host.
- Topology checks: the scenario inventory has no cluster groups, so they are skipped.
- Ports held by RKE2 processes: no RKE2 runs in the containers.

## Licence

MIT
