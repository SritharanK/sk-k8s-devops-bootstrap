# install_jenkins

Installs and configures the Jenkins controller of the optional on-premises CI
adapter.

GitHub Actions is the reference CI of this repository. Jenkins is an adapter
for environments that must build on premises: it builds the protected `main`
branch, pushes signed images and opens promotion pull requests. Pull request
validation stays with GitHub Actions. Pipelines, Job DSL, pod templates and
the agent namespace live in `ci/jenkins/`; this role covers the controller
only.

## Supported platforms

| Distribution | Release | Java |
|---|---|---|
| Ubuntu | 24.04 | `openjdk-21-jre-headless` |
| Debian | 13 | `openjdk-21-jre-headless` |
| Rocky Linux, AlmaLinux, RHEL | 9 | `java-21-openjdk-headless` |

systemd is required. Jenkins 2.555.1 and later need Java 21 or 25, so Debian
12 (Java 17 only) and every other release are rejected before any change.
Ansible 2.17 or later on the control node. The role uses `ansible.builtin`
modules only; no collection is required.

## What the role does

1. `tasks/assert.yml`: checks the platform, that every required variable is
   set, that no setting of the active configuration still contains
   `CHANGE_ME`, the realm and build identity choices, the format of
   `install_jenkins_url` and of the pinned versions and checksums, that the secrets of
   the active configuration are set, and that the plugin list, `services.yaml`
   and the Job DSL script exist on the control node.
2. `tasks/repository_debian.yml` or `tasks/repository_redhat.yml`: adds the
   `pkg.jenkins.io` LTS repository. On Debian and Ubuntu the signing key file
   must match `install_jenkins_repo_key_sha256` and is referenced by `Signed-By`. On
   Enterprise Linux the key is imported only if its fingerprint equals
   `install_jenkins_repo_key_fingerprint`; the repository has `gpgcheck`,
   `repo_gpgcheck` and `exclude=jenkins`, so `dnf update` never moves Jenkins.
3. `tasks/install.yml`: installs Java 21 and fontconfig, then exactly
   `install_jenkins_version`. When the Jenkins package is about to change, Jenkins is
   stopped and its unit masked, so the package scripts (the Debian package
   starts the service on install) cannot boot Jenkins without its
   configuration. On Debian and Ubuntu the package is put on hold.
4. `tasks/configure.yml`: makes `install_jenkins_home` private (0750), creates
   `/etc/jenkins` and `/etc/jenkins/casc` (root, group jenkins, 0750), renders
   `templates/jenkins.yaml.j2` to `/etc/jenkins/casc/jenkins.yaml` (0640),
   writes one file per secret to `/etc/jenkins/casc-secrets` (directory 0700,
   files 0400, owner jenkins) and installs the systemd drop-in
   `/etc/systemd/system/jenkins.service.d/override.conf`. The vendor unit file
   is never edited.
5. `tasks/plugins.yml`: downloads the plugin installation manager (checksum
   pinned) and installs every plugin of `files/plugins.txt` at its exact
   version into `install_jenkins_home/plugins`, as the jenkins user. It runs only when
   the list differs from the last list applied successfully, or when no plugin
   is installed.
6. `tasks/service.yml`: runs pending handlers (systemd reload, restart), makes
   sure Jenkins is enabled and running, and waits until `/login` answers 200.

Jenkins restarts only through the handler, and only when the package, a
plugin, the configuration as code file, a secret file or the drop-in changed.
A second run with unchanged input reports no change.

## Security model

- Network: Jenkins listens on `127.0.0.1:8080`. A reverse proxy on the same
  host terminates TLS; `examples/nginx/jenkins.conf.example` redirects HTTP to
  HTTPS, allows TLS 1.2 and 1.3 only, sets HSTS and the `X-Forwarded-*`
  headers, and forwards WebSocket upgrades for the agents (`/wsagents/`) and
  the CLI. `install_jenkins_url` must be the HTTPS URL of that proxy.
- Configuration: Jenkins is configured only by configuration as code. The
  setup wizard is disabled through `JAVA_OPTS` in the drop-in. The role
  installs no Groovy init scripts. Changes made in the UI are replaced by the
  configuration as code file at the next restart.
- Secrets: `jenkins.yaml` contains no secret value. It references `${name}`,
  which the configuration as code plugin resolves from
  `/etc/jenkins/casc-secrets/<name>`, readable only by the jenkins user.
  Leading and trailing whitespace of a secret is removed and no trailing
  newline is written. Secret tasks run with `no_log` and without diff output.
- Controller isolation: the built-in node has 0 executors and the inbound
  TCP agent port is disabled. Builds run in ephemeral Kubernetes pods that
  connect to `install_jenkins_k8s_jenkins_url` over WebSocket through the proxy.
  Agent-to-controller security is always on in current Jenkins releases and
  cannot be disabled.
- Authorization (project matrix, see `templates/jenkins.yaml.j2`):
  administrators (`install_jenkins_admin_groups`, `install_jenkins_admin_users`, and the
  break-glass user of the local realm) get Overall/Administer; developers get
  read, discover, build and cancel on jobs; viewers get read access; the build
  identity gets read, build and credential use. Anonymous users get no
  permission, so there is no anonymous read and the API answers 403 before
  login.
- Build identity: Authorize Project runs every generated job as
  `install_jenkins_build_user` (`install_jenkins_build_run_as: user`). Jobs therefore only see
  credentials and items that this identity may use. With
  `install_jenkins_build_run_as: system` jobs run as SYSTEM: every build can use every
  credential in the global scope and access every item. Choose it only when
  the security realm cannot resolve a service account, and restrict who can
  merge to `main` accordingly.
- Other settings from the template: CSRF protection with the standard crumb
  issuer, plain-text markup formatter, no "remember me", no usage statistics,
  no legacy API tokens, Git hooks disabled, Job DSL with script security.
- systemd hardening in the drop-in: `NoNewPrivileges`, empty
  `CapabilityBoundingSet`, `PrivateTmp`, `ProtectSystem=full`,
  `ProtectHome`, kernel and control group protection, `RestrictSUIDSGID`,
  `RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`, native system
  calls only, `AF_UNIX AF_INET AF_INET6` sockets only and `UMask=0027`.
  `MemoryDenyWriteExecute` is not set because the JVM JIT compiler needs
  writable and executable memory.

## Providing configuration and secrets

1. Copy both examples into the inventory of the environment:

   ```sh
   mkdir -p ansible/inventories/<env>/group_vars/jenkins
   cp ansible/roles/install_jenkins/examples/group_vars/jenkins/vars.yml.example \
      ansible/inventories/<env>/group_vars/jenkins/vars.yml
   cp ansible/roles/install_jenkins/examples/group_vars/jenkins/vault.yml.example \
      ansible/inventories/<env>/group_vars/jenkins/vault.yml
   ```

2. Replace every `CHANGE_ME`, `example.com`, `YOUR_ORG` and `your-org` value. `vars.yml`
   maps each secret role variable to a `vault_` variable; put the values in
   `vault.yml` only.
3. Encrypt `vault.yml` before using it, with the vault ID that
   `make install-jenkins` passes (`VAULT_ID`, default `<profile>@prompt`, so
   Ansible prompts for the password; `ANSIBLE_VAULT_IDENTITY_LIST` replaces it
   when set). Never commit it unencrypted.

   ```sh
   ansible-vault encrypt --vault-id <env>@prompt \
     ansible/inventories/<env>/group_vars/jenkins/vault.yml
   ```

4. Put the controller in the `jenkins` inventory group and run
   `make install-jenkins`.

## Variables

The full reference, with types, defaults and choices, is
`meta/argument_specs.yml`. Ansible validates the variables against it before
the role runs. To read it:

```sh
ansible-doc --type role --roles-path ansible/roles install_jenkins
```

| Variable | Default | Purpose |
|---|---|---|
| `install_jenkins_version` | `2.580.2` | Jenkins LTS version, installed exactly and held |
| `install_jenkins_plugins_file` | `files/plugins.txt` | exact plugin versions |
| `install_jenkins_url` | `https://jenkins.example.com/` | public HTTPS URL of the reverse proxy |
| `install_jenkins_security_realm` | `oidc` | `oidc`, `ldap` or `local` (lab only) |
| `install_jenkins_admin_groups`, `install_jenkins_admin_users` | `[platform-admins]`, `[]` | administrators |
| `install_jenkins_developer_groups`, `install_jenkins_viewer_groups` | `[deployers]`, `[viewers]` | build and read access |
| `install_jenkins_build_run_as`, `install_jenkins_build_user` | `user`, `jenkins-ci` | identity of the generated jobs |
| `install_jenkins_k8s_api_url`, `install_jenkins_k8s_namespace` | example values | cluster that runs the agent pods |
| `install_jenkins_git_repo_url`, `install_jenkins_github_repository` | `YOUR_ORG` placeholders | source and GitOps repository |
| `install_jenkins_image_registry`, `install_jenkins_registry_username` | `ghcr.io/your-org`, `CHANGE_ME` | image registry (lowercase) |
| `install_jenkins_argocd_server` | empty | Argo CD API for the promotion health gate |
| `install_jenkins_http_listen_address`, `install_jenkins_http_port` | `127.0.0.1`, `8080` | local listener behind the proxy |
| `install_jenkins_java_heap_min`, `install_jenkins_java_heap_max` | `1g`, `2g` | JVM heap |

Secrets (no defaults): `install_jenkins_registry_password`, `install_jenkins_github_token`,
`install_jenkins_cosign_private_key`, `install_jenkins_cosign_password` and
`install_jenkins_k8s_agent_token` always; `install_jenkins_oidc_client_secret`,
`install_jenkins_ldap_manager_password`, or `install_jenkins_local_admin_password` and
`install_jenkins_local_build_user_password` depending on the realm;
`install_jenkins_argocd_tokens` (one read-only token per promotion source
environment, from the Argo CD project role `ci` of `apps-<env>`) when
`install_jenkins_argocd_server` is set.

## Upgrading Jenkins

1. Read the LTS changelog and upgrade guide of the target release on
   jenkins.io.
2. Set `install_jenkins_version` in `defaults/main.yml` (or per inventory).
3. Regenerate the plugin list for that release from the repository root:

   ```sh
   python3 ci/jenkins/scripts/resolve-plugins.py --core <version>
   ```

   To add or remove a plugin, edit `files/plugins.in.txt` first.
4. If the Jenkins project rotates its package signing key, update
   `install_jenkins_repo_key_fingerprint`, `install_jenkins_repo_key_sha256` and the key URL
   in `vars/Debian.yml` and `vars/RedHat.yml`.
5. Run the Molecule scenario (below), then `make install-jenkins`. The run
   stops Jenkins, installs the new package and plugins, and starts it once.
   Downgrades are refused by the package manager.

## Testing

From the role directory, with Docker running:

```sh
cd ansible/roles/install_jenkins
uvx --with 'molecule-plugins[docker]' molecule test
```

The scenario converges Ubuntu 24.04 and Rocky Linux 9 containers that run
systemd (privileged, host cgroup namespace), runs the role a second time to
prove idempotence, and verifies: service active and enabled, version pinned
and held or excluded, `/login` answers 200, anonymous `/api/json` answers 403,
no executor on the built-in node, no answer on the container's non-loopback
address, secret directory 0700 and secret files 0400 owned by jenkins,
`jenkins.yaml` 0640 root:jenkins without any test secret value, the drop-in,
and the configuration as code plugin. The local realm and obviously fake
secrets are set in `molecule/default/molecule.yml`.

## Limitations

- OIDC and Authorize Project: with `install_jenkins_build_run_as: user` the build
  identity must be resolvable by the security realm when a build is queued.
  With OIDC that usually means the account has signed in to Jenkins once (or
  the identity provider offers a resolvable service account). Otherwise use
  `install_jenkins_build_run_as: system` and accept the trade-off described above.
- Signing keys: the RPM key is pinned by fingerprint and the Debian key file
  by checksum. A key rotation by the Jenkins project needs a variable update
  before packages install again.
- Plugins removed from `plugins.txt` are not uninstalled; remove them from
  `install_jenkins_home/plugins` by hand.
- Secret files of a realm that is no longer selected stay in the secret
  directory until removed by hand.
- The role installs Java 21 but does not change the system default `java`.
  On a host that has another Java as default, select Java 21 with
  `update-alternatives` (Debian family) or `alternatives` (Red Hat family).
- Downgrades of `install_jenkins_version` are not supported.
