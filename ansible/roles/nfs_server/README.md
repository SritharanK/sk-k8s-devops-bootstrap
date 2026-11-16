# nfs_server

Optional NFS server for lab clusters, off by default in the reference inventory. The role installs the kernel NFS
server, exports directories to client networks only and disables NFSv3, so clients need 2049/tcp and nothing else.

## Supported platforms

| Distribution | Versions | Package |
|---|---|---|
| Ubuntu | 24.04 (noble) | nfs-kernel-server |
| Debian | 12 (bookworm), 13 (trixie) | nfs-kernel-server |
| Rocky Linux | 9 | nfs-utils |

`/etc/nfs.conf.d` needs nfs-utils 2.5.3 or later; all supported releases ship a newer version.

## Requirements

- ansible-core 2.20 or later. Only `ansible.builtin` modules are used.
- Gathered facts (`os_family`).
- Privilege escalation (`become: true` in the playbook).
- A firewall rule for 2049/tcp from the clients, for example through `firewall_extra_rules` of the firewall role.

## What it configures

- Exports in `/etc/exports.d/kubernetes.exports`, one line per item: `<path> <client>(<options>) ...`.
- `/etc/nfs.conf.d/50-nfs-server.conf` with `[nfsd] vers3=n` (NFSv4 only).
- The exported directories, with the owner, group and mode of each item.
- `nfs-server.service` enabled and started when `nfs_server_manage_service` is true. Changed exports run
  `exportfs -ra`; a changed nfsd configuration restarts the service.

Validation fails the play when an item has a relative path, the path `/`, whitespace in the path or options, an empty
client list, a `CHANGE_ME` client, or a client that matches every host (`*`, `0.0.0.0/0`, `::/0`), and when two items
share a path.

With the default `root_squash`, root on a client maps to the anonymous user. A dynamic provisioner that creates
subdirectories as root therefore needs the export owned by that user (`nobody:nogroup` on Debian and Ubuntu,
`nobody:nobody` on Rocky) or a more open mode.

## Role variables

The full specification, with types, is in `meta/argument_specs.yml`.

| Variable | Default | Description |
|---|---|---|
| `nfs_server_exports` | `[]` | Items `{path, clients, options, owner, group, mode}`; `path` and `clients` are required, owner and group default to `root`, mode to `"0755"`. |
| `nfs_server_export_options` | `rw,sync,no_subtree_check,root_squash` | Options for an item without `options`. |
| `nfs_server_manage_service` | `true` | Enable and start nfs-server and re-export on changes. |

## Example playbook

```yaml
- name: NFS server
  hosts: nfs_server
  become: true
  gather_facts: true
  roles:
    - role: nfs_server
      vars:
        nfs_server_exports:
          - path: /srv/nfs/kubernetes
            clients: [10.10.0.0/24]
```

## Testing

```sh
cd ansible/roles/nfs_server
uvx --python 3.13 --from 'molecule==26.11.0' --with 'molecule-plugins[docker]==26.11.0' \
  --with 'ansible-core==2.21.6' --with 'docker==7.2.0' molecule test
```

The scenario runs on Ubuntu 24.04, Debian 12, Debian 13 and Rocky 9 containers with one export to `10.10.0.0/24`.
`verify.yml` checks the exports line, `vers3=n` in the nfsd configuration and the exported directory.

nfsd runs inside the kernel, so it cannot run in a container: the container shares the kernel of the Docker host,
cannot load the `nfsd` module itself, and the test containers have no nfsd file system mounted. The scenario
therefore sets `nfs_server_manage_service: false` and does not cover:

- starting and enabling `nfs-server.service`, and the restart handler;
- `exportfs -ra`, which parses the exports and loads them into the kernel export table;
- mounting an export from a client, NFSv4-only behaviour and `root_squash`.

## Licence

MIT
