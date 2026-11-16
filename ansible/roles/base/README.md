# base

OS baseline for every managed host, cluster nodes and Jenkins hosts alike. It installs a small package set, prepares
Kubernetes nodes (kernel modules, sysctls, swap), applies conservative sysctl hardening, configures chrony and
unattended security updates, hardens sshd and manages key-only admin users. It installs no container runtime, Java,
Docker or CLI tooling.

## Supported platforms

| Distribution | Versions |
|---|---|
| Ubuntu | 24.04 (noble) |
| Debian | 12 (bookworm), 13 (trixie) |
| Rocky Linux | 9 |

Architectures: `x86_64`, `aarch64`.

## Requirements

- ansible-core 2.20 or later.
- Collections `ansible.posix` 2.2.2 and `community.general` 14.0.1 (see `ansible/collections/requirements.yml`).
- The playbook sets `become: true` and gathers facts. The role does not escalate privileges itself; the only task that
  sets `become` switches it off to read the SSH login user (see "SSH lockout guard").

## Role variables

The full list with types and choices is in `meta/argument_specs.yml`.

| Variable | Default | Description |
|---|---|---|
| `base_packages` | `[ca-certificates, jq, openssh-server, sudo, tar]` | Packages on every host. Per-OS packages are added from `vars/`. |
| `base_packages_extra` | `[]` | Additional packages. |
| `base_kubernetes_node` | `true` | Kernel modules, Kubernetes sysctls and swap handling. Set `false` on Jenkins hosts. |
| `base_kernel_modules` | `[overlay, br_netfilter]` | Persisted in `/etc/modules-load.d/kubernetes.conf`. |
| `base_kubernetes_sysctls` | IPv4 and IPv6 forwarding, bridge netfilter, inotify limits | Written to `/etc/sysctl.d/90-kubernetes.conf`. |
| `base_disable_swap` | `"{{ base_kubernetes_node }}"` | `swapoff -a` and comment out swap lines in `/etc/fstab`. |
| `base_hardening_sysctls` | redirects and source routing off, syncookies, `dmesg_restrict`, `kptr_restrict` | Written to `/etc/sysctl.d/80-base-hardening.conf`. |
| `base_kernel_runtime_apply` | `true` | Load modules, set sysctls and run `swapoff` now. `false` writes the files only. |
| `base_storage_clients` | `false` | NFS client, open-iscsi, `iscsi_tcp` and iscsid (Longhorn prerequisites). |
| `base_chrony_servers` | `[]` | NTP servers. Empty keeps the distribution sources. |
| `base_unattended_upgrades` | `true` | Security-only automatic updates. `false` leaves the image configuration untouched. |
| `base_automatic_reboot` | `false` | Reboot after updates that need it. |
| `base_unattended_upgrades_exclude` | `[rke2-*]` | Package globs never upgraded automatically. |
| `base_ssh_hardening` | `true` | Write `/etc/ssh/sshd_config.d/00-base-hardening.conf`. |
| `base_ssh_permit_root_login` | `"no"` | `PermitRootLogin`. |
| `base_ssh_allow_tcp_forwarding` | `false` | `AllowTcpForwarding`. |
| `base_ssh_max_auth_tries` | `3` | `MaxAuthTries`. |
| `base_ssh_login_grace_time` | `30` | `LoginGraceTime` (seconds). |
| `base_ssh_client_alive_interval` | `300` | `ClientAliveInterval` (seconds). |
| `base_ssh_client_alive_count_max` | `2` | `ClientAliveCountMax`. |
| `base_ssh_log_level` | `VERBOSE` | `LogLevel`; VERBOSE logs the key fingerprint of each login. |
| `base_ssh_allow_groups` | `[]` | `AllowGroups`; empty writes no line. |
| `base_admin_users` | `[]` | Items `{name, ssh_public_keys, sudo: true, shell: /bin/bash, state: present}`. |
| `base_admin_users_allowed_key_types` | `[ssh-ed25519, sk-ssh-ed25519@openssh.com]` | Accepted key types. |

## Behaviour notes

### Kubernetes node preparation

Modules are loaded with `community.general.modprobe` and persisted through one template per file in
`/etc/modules-load.d/`. Sysctls are managed key by key with `ansible.posix.sysctl`, so a key removed from the variable
stays in the file until it is removed by hand.

`net.ipv6.conf.all.forwarding=1` makes the kernel ignore router advertisements on interfaces with `accept_ra=1`. A host
that takes its IPv6 default route from SLAAC needs `accept_ra=2` on that interface, or the key removed from
`base_kubernetes_sysctls`. On a kernel booted with `ipv6.disable=1` the IPv6 keys do not exist; remove them from both
sysctl variables.

### Time synchronisation

chrony is installed, enabled and started; `systemd-timesyncd` is stopped and disabled when present. A non-empty
`base_chrony_servers` is applied per OS family:

- Debian family: the servers go to `/etc/chrony/sources.d/base.sources` with `iburst prefer`. `chrony.conf` is a dpkg
  conffile and stays untouched (a local edit would turn later conffile updates into prompts, and unattended-upgrades
  holds such packages back). The distribution pool stays configured as a fallback; chronyd selects the preferred
  servers while at least one of them is usable. The role asserts that `chrony.conf` still reads the sources directory.
- RedHat family: `/etc/chrony.conf` (`%config(noreplace)`) has no include for local sources, so the role templates the
  full file with the listed servers and without the distribution pool. Emptying the list later does not restore the
  distribution file.

### Unattended security updates

- Debian family: `/etc/apt/apt.conf.d/20auto-upgrades` enables the periodic jobs.
  `/etc/apt/apt.conf.d/52unattended-upgrades-base` is read after the distribution file `50unattended-upgrades`, uses
  `#clear` to empty `Allowed-Origins`, `Origins-Pattern` and `Package-Blacklist`, and defines only the security
  origins (`<codename>-security`; on Ubuntu also the ESM security pockets, which exist only with Ubuntu Pro). The role
  owns these three lists: entries added in other files read earlier are cleared. The globs in
  `base_unattended_upgrades_exclude` become anchored regular expressions (`rke2-*` becomes `rke2-.*$`), because
  unattended-upgrades matches `Package-Blacklist` entries with Python `re.match`.
- RedHat family: `/etc/dnf/automatic.conf` is templated with `upgrade_type = security` (only updates with a security
  advisory), `apply_updates = yes`, `reboot = never` (or `when-needed` with `base_automatic_reboot`) and
  `emit_via = stdio`. The exclusions go to `excludepkgs` in the `[base]` section, which dnf-automatic applies on top of
  `dnf.conf` for its own runs only; interactive `dnf` is not affected. `dnf-automatic.timer` is enabled.

Automatic reboots on cluster nodes are off by default: a reboot without a drain disrupts workloads. Use a coordinated
reboot tool (for example a reboot daemon in the cluster that drains one node at a time) instead.

### SSH hardening

The drop-in `/etc/ssh/sshd_config.d/00-base-hardening.conf` is validated with `sshd -t -f` before it is installed and
sshd is reloaded through a handler. sshd uses the first value it reads for most keywords, and the `00-` prefix sorts
the file before the drop-ins written by cloud-init (`50-cloud-init.conf`) and the EL installer
(`01-permitrootlogin.conf`). The role asserts that `/etc/ssh/sshd_config` includes `sshd_config.d/*.conf`. Missing host
keys are created with `ssh-keygen -A` first, because `sshd -t` needs at least one.

Fixed settings: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`,
`PermitEmptyPasswords no`, `X11Forwarding no`, `AllowAgentForwarding no`. The others come from the variables above.

When `base_ssh_allow_groups` is set, the account Ansible logs in with must be in one of the groups.

### SSH lockout guard

With `base_ssh_permit_root_login: "no"`, the role fails before any change when the play logs in over SSH as `root`.
The login user is read with `id -un` in a task that sets `become: false`. Variables are not reliable for this: the
user may come from `ansible_user`, the play keyword `remote_user`, `-u` on the command line, `ansible.cfg` or the
`User` directive in `~/.ssh/config`, and of these only `ansible_user` is a variable a role can read. The check runs
only for the SSH connection plugins (`ansible_connection` unset, `ssh`, `paramiko` or `smart`); the Docker connection
used by Molecule is not affected.

Bootstrap of an image that only allows root login: run once with `base_ssh_permit_root_login: prohibit-password` and
an entry in `base_admin_users`, set `ansible_user` to that admin user, then run again with the default.

### Admin users

Each present user gets a locked password (`password_lock: true`), its keys through `ansible.posix.authorized_key` with
`exclusive: true` (unlisted keys are removed), and with `sudo: true` the file `/etc/sudoers.d/90-<name>` (mode 0440,
validated with `visudo -cf`) granting passwordless sudo. Dots in the name become underscores in the file name, because
sudo skips files in `sudoers.d` whose name contains a dot. Keys must have the form `<type> <base64> [comment]` and a
type listed in `base_admin_users_allowed_key_types`. `state: absent` removes the account and its sudo rule and keeps
the home directory.

When the Ansible login user is one of the admin users, its `ssh_public_keys` must contain the key Ansible uses;
`exclusive: true` removes every other key.

### Packages

`kmod` and `procps` (`procps-ng` on Rocky Linux) are installed because the role runs `modprobe` and `sysctl`.
`curl` is installed on the Debian family only. Every Rocky Linux 9 image ships `curl` or `curl-minimal`, and
requesting `curl` on a host with `curl-minimal` fails on a package conflict.

### Check mode

In `--check` mode, tasks that need a package the same run would install (service units, files shipped by the
package) are skipped while that package is not installed yet.

## Example playbook

```yaml
- name: Apply the OS baseline
  hosts: k8s_cluster
  become: true
  gather_facts: true
  roles:
    - role: base
      vars:
        base_storage_clients: true
        base_chrony_servers:
          - ntp1.example.com
          - ntp2.example.com
        base_admin_users:
          - name: opsadmin
            ssh_public_keys:
              - ssh-ed25519 AAAA... CHANGE_ME

- name: Apply the OS baseline to Jenkins hosts
  hosts: jenkins
  become: true
  gather_facts: true
  roles:
    - role: base
      vars:
        base_kubernetes_node: false
```

## Testing

```bash
cd ansible/roles/base
molecule test
```

The scenario converges Ubuntu 24.04, Debian 12, Debian 13 and Rocky Linux 9 containers (systemd as PID 1), runs the
idempotence check and verifies the module and sysctl files, the fstab state, the effective sshd settings (`sshd -T`),
the chrony unit, the admin user (locked password, key, sudoers file passing `visudo -cf`) and the update configuration
per family.

Not covered, and why:

- `base_kernel_runtime_apply` is `false`: a container shares the host kernel, so it cannot load modules, and setting
  sysctls or running `swapoff` would change the host.
- `base_storage_clients` keeps its default `false`: iscsid needs the `iscsi_tcp` kernel module, which the test
  containers cannot load.
- The SSH lockout guard does not run: Molecule uses the Docker connection, not SSH.
- Time synchronisation itself is not checked, only that the chrony unit is enabled.

## Licence

MIT
