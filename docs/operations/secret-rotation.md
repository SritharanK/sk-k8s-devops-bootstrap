# Secret rotation

This runbook rotates every class of secret the platform uses, and says what to do when a secret reaches Git. It is for platform operators; [secrets handling](../security/secrets-handling.md) describes where each secret lives and why.

## Secret classes

| Class | Profile | Where the value lives | Rotate |
| --- | --- | --- | --- |
| [Git repository credential for Argo CD](#git-repository-credential-for-argo-cd) | Both, private repositories only | Argo CD repository Secret in the `argocd` namespace | On exposure, on staff change, and on a fixed cadence |
| [Registry pull secrets](#registry-pull-secrets) | Both | Lab: one SealedSecret per namespace. Reference: OpenBao, synced by ESO | On exposure and on a fixed cadence |
| [Sealed Secrets controller key](#sealed-secrets-controller-key) | `lab` | Secrets in the controller namespace; copies in the Velero `sealing-key` backups and the offline escrow | Renewed automatically; early on suspected exposure |
| [Argo CD admin password](#argo-cd-admin-password) | `lab` only | `argocd-secret` | After the first login |
| [Argo CD OIDC client secret](#argo-cd-oidc-client-secret) | `reference` | Identity provider and OpenBao | On exposure and before it expires at the identity provider |
| [Argo CD API token for CI](#argo-cd-api-token-for-ci) | Both | AppProject role `ci` in `apps-dev` and `apps-stage`, and GitHub Actions secrets | Before it expires, on exposure |
| [RKE2 join token](#rke2-join-token) | RKE2 clusters | Server nodes and the Ansible vault | On exposure or when someone with access leaves |
| [Ansible vault password](#ansible-vault-password) | RKE2 clusters | Operator workstation or password manager | On staff change and on exposure |
| [Image signing](#image-signing) | Both | Nothing stored | Nothing to rotate |

Recommendation: rotate long-lived credentials at least every 90 days, and record each rotation (date, class, operator) in your change log.

## Git repository credential for Argo CD

### Purpose

Replace the credential Argo CD uses to read the Git repository.

### When to use

The repository is private and the credential may be exposed, someone with access to it leaves, or the cadence is due. A public repository needs no credential: Argo CD reads it anonymously over HTTPS and there is nothing to rotate.

### Preconditions

- The credential is a read-only SSH deploy key. Argo CD matches repository credentials by URL, so the Secret URL is the SSH form of the repository and `git.repoURL` in `clusters/<name>/cluster.yaml` uses the same URL.
- `make bootstrap-gitops CLUSTER=<name>` created the repository Secret from the template in `bootstrap/` (label `argocd.argoproj.io/secret-type=repository`).
- Admin rights on the repository for the deploy key, and `kubectl` access to the `argocd` namespace.

### Steps

1. Generate the new key outside the repository clone:

   ```bash
   KEY_DIR=<directory-outside-the-repository>
   ssh-keygen -t ed25519 -N '' -C "argocd-$(date +%Y%m%d)" -f "$KEY_DIR/argocd-deploy-key"
   ```

2. Register the public key as a read-only deploy key:

   ```bash
   gh repo deploy-key add "$KEY_DIR/argocd-deploy-key.pub" \
     --repo YOUR_ORG/sk-k8s-devops-bootstrap --title "argocd-$(date +%Y%m%d)"
   ```

3. Find the repository Secret and replace its key. The pipeline renders the Secret locally and applies it, so the key is not written to another file:

   ```bash
   kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository
   kubectl -n argocd create secret generic <repository-secret-name> \
     --from-literal=type=git \
     --from-literal=url=git@github.com:YOUR_ORG/sk-k8s-devops-bootstrap.git \
     --from-file=sshPrivateKey="$KEY_DIR/argocd-deploy-key" \
     --dry-run=client -o yaml \
     | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
     | kubectl apply -f -
   ```

4. After verification, remove the old deploy key:

   ```bash
   gh repo deploy-key list --repo YOUR_ORG/sk-k8s-devops-bootstrap
   gh repo deploy-key delete <old-key-id> --repo YOUR_ORG/sk-k8s-devops-bootstrap
   ```

5. Store the new private key in your password manager. `make bootstrap-gitops` needs it again when you rebuild the cluster.

### Verification

```bash
argocd repo list --grpc-web
kubectl -n argocd get applications
```

The repository shows a successful connection, and the Applications keep their sync status after the next refresh.

### Rollback or abort

Until step 4 the old key still works. Re-apply the previous Secret from your password manager to return to it.

## Registry pull secrets

### Purpose

Replace the registry credential that nodes use to pull application images.

### When to use

The registry token may be exposed, expires, or the cadence is due.

### Preconditions

- A new read-only registry token. For GHCR, a token limited to reading packages.
- Lab: `kubeseal` and `hack/seal.sh`, and the controller certificate committed at `clusters/<cluster>/sealed-secrets/cert.pem` with its pinned fingerprint in `cert.sha256`. See [secrets handling](../security/secrets-handling.md).
- Reference: the `bao` CLI with write access to the path that the pull-secret ExternalSecrets read.

### Steps

Lab profile, offline sealing:

1. Seal one pull secret per namespace. `hack/seal.sh` checks the committed certificate against its pinned fingerprint, prompts for the registry token without echo, and writes `clusters/<cluster>/secrets/<namespace>/regcred.yaml`. Strict scope binds each SealedSecret to its name and namespace, so repeat for `dev`, `stage` and `prod`:

   ```bash
   for env in dev stage prod; do
     hack/seal.sh docker-registry --cluster lab --namespace "$env" \
       --server ghcr.io --username <registry-user> --force
   done
   hack/seal.sh verify --cluster lab
   ```

   `--force` is needed because the files already exist. The token never appears on a command line, in an environment variable or in a file inside the repository.

2. Make sure `toolchains.cluster-secrets.enabled` is set in `clusters/<cluster>/cluster.yaml`, so the `cluster-secrets` Application applies `clusters/<cluster>/secrets/`.

3. Open a pull request with the three SealedSecret files, wait for `ci-gate`, and merge. Argo CD applies them and the controller updates the Secrets.

4. After verification, revoke the old token at the registry.

Reference profile, OpenBao and ESO:

1. Find the OpenBao path and property that the ExternalSecret reads (`spec.data[].remoteRef` or `spec.dataFrom`):

   ```bash
   kubectl -n <env> get externalsecret
   kubectl -n <env> get externalsecret <name> -o yaml
   ```

2. Write the new value and ask ESO to refresh now instead of at the next `refreshInterval`:

   ```bash
   bao kv patch -mount=<kv-mount> <path> <property>=@<file-with-new-value>
   kubectl -n <env> annotate externalsecret <name> force-sync="$(date +%s)" --overwrite
   ```

3. Repeat for each environment that has its own credential, then revoke the old token.

### Verification

```bash
kubectl -n <env> get sealedsecret,externalsecret
kubectl -n <env> get events --field-selector reason=Failed
```

The SealedSecret or ExternalSecret reports synced, and new pods start without `ErrImagePull` or `ImagePullBackOff`. Images already cached on a node do not test the credential; the next rollout does.

### Rollback or abort

Until you revoke the old token, re-sealing or writing the old value restores the previous state.

## Sealed Secrets controller key

### Purpose

Move the SealedSecrets in Git to a new sealing key, and retire old keys safely.

### When to use

- After every automatic renewal. The controller adds a new key every 30 days by default; `sealed-secrets.keyrenewperiod` in the wrapper values changes the period and `"0"` disables renewal. Old keys stay active, so existing SealedSecrets keep working.
- Early, when a key may be exposed.

### Preconditions

- Access to the controller namespace (`SS_NS`, `kube-system` by default for `kubeseal`) and the controller name `sealed-secrets-controller`.
- The current key escrow (see [export, escrow and restore the Sealed Secrets key](backup-and-restore.md#export-escrow-and-restore-the-sealed-secrets-key)).

### Steps

1. For an early renewal only: set `sealed-secrets.keycutofftime` in `helmcharts/system-charts/sealed-secrets/values-lab.yaml` to the output of `date -R`, open a pull request, and merge it. The controller generates a new key when it restarts.

2. Confirm the new key exists:

   ```bash
   SS_NS=kube-system
   kubectl -n "$SS_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
     --sort-by=.metadata.creationTimestamp
   ```

3. Escrow the full key set again. A backup taken before the renewal cannot decrypt secrets sealed with the new key.

4. Refresh the committed certificate, because offline sealing keeps using the old key until you do. `hack/seal.sh fetch-cert` rewrites `clusters/<cluster>/sealed-secrets/cert.pem` and its pinned fingerprint `cert.sha256` together:

   ```bash
   hack/seal.sh fetch-cert --cluster lab --force
   ```

5. Re-encrypt every committed SealedSecret with the newest key. The controller re-encrypts without the plaintext leaving the cluster:

   ```bash
   git grep -l 'kind: SealedSecret' -- clusters/lab/secrets | while read -r f; do
     kubeseal --re-encrypt --controller-namespace "$SS_NS" --controller-name sealed-secrets-controller \
       --format yaml < "$f" > "$f.new" && mv "$f.new" "$f"
   done
   ```

6. Open one pull request with the certificate, the fingerprint and the re-encrypted files, and merge it after `ci-gate`.

7. Keep every old key active until all SealedSecrets in Git use the new key and no backup you may restore depends on the old one. Keys are not removed automatically. To retire a key, relabel it instead of deleting it, restart the controller, and escrow again:

   ```bash
   kubectl -n "$SS_NS" label secret <old-key-name> sealedsecrets.bitnami.com/sealed-secrets-key=inactive --overwrite
   kubectl -n "$SS_NS" delete pod -l app.kubernetes.io/name=sealed-secrets
   ```

Re-encryption protects new copies only. If a key was exposed, every value sealed with it is disclosed: rotate the values themselves as well, starting with the [registry pull secrets](#registry-pull-secrets).

### Verification

```bash
kubectl get sealedsecrets -A
hack/seal.sh verify --cluster lab
```

Every SealedSecret is synced, and `hack/seal.sh verify` confirms that the committed certificate matches its pinned fingerprint and that every file under `clusters/lab/secrets/` is a SealedSecret for the namespace of its directory, with no plaintext data. It checks structure only; decryption needs the controller key.

### Rollback or abort

Old keys stay active until you relabel them, so a revert of the pull request in step 6 restores the previous files and they still decrypt. To reactivate a relabelled key, set its label back to `active` and restart the controller.

## Argo CD admin password

### Purpose

Replace the generated initial admin password of a lab cluster.

### When to use

After the first login to a lab cluster that lives longer than a demo. The `reference` profile disables the admin account and uses SSO; there is nothing to rotate there.

### Preconditions

- The `argocd` CLI and `kubectl` access to the `argocd` namespace.

### Steps

```bash
argocd admin initial-password -n argocd
argocd login argocd.localtest.me --username admin --grpc-web
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret
```

The login asks for the initial password and to confirm the self-signed lab certificate. `update-password` prompts for the current and the new password, so neither appears in the shell history. The initial admin Secret holds the old password in clear text and has no other use; Argo CD recreates it only when it generates a new admin password.

### Verification

A login with the new password works, and a login with the old one fails.

### Rollback or abort

If the new password is lost, reset it as described in the upstream FAQ, or recreate the lab cluster.

## Argo CD OIDC client secret

### Purpose

Replace the client secret that Argo CD presents to the identity provider in the `reference` profile.

### When to use

Before the secret expires at the identity provider, and on exposure.

### Preconditions

- Admin rights on the client registration at the identity provider.
- Write access to the OpenBao path that holds the client secret. [Argo CD SSO](../security/argocd-sso.md) and the Argo CD wrapper [README](../../helmcharts/system-charts/argo-cd/README.md) name the ExternalSecret and the Kubernetes Secret that `oidc.config` references.

### Steps

1. Create a second client secret at the identity provider. Keep the old one valid until step 4.
2. Write the new value to OpenBao and refresh the ExternalSecret:

   ```bash
   bao kv patch -mount=<kv-mount> <path> <property>=@<file-with-new-value>
   kubectl -n argocd annotate externalsecret <name> force-sync="$(date +%s)" --overwrite
   ```

3. Log in through SSO. If the server still presents the old secret, restart the server pods; deleting pods does not change the Deployment, so Argo CD sees no drift:

   ```bash
   kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
   ```

4. Revoke the old secret at the identity provider.

### Verification

An SSO login succeeds after step 4, and the user lands in the role that `policy.csv` maps from the group.

### Rollback or abort

Until step 4, writing the old value back to OpenBao restores the previous state.

## Argo CD API token for CI

### Purpose

Replace the Argo CD tokens that `promote.yml` uses to check that the source Application is Synced and Healthy on the digest it promotes. Each token belongs to the read-only AppProject role `ci` of one app project and can only read the Applications of that project.

### When to use

Before a token expires, and on exposure.

### Preconditions

- The role `ci` exists in `apps-dev` and `apps-stage` (rendered by `argocd-bootstrap/templates/projects/apps.yaml`, permission `applications, get`). Promotion reads only the source environment, so `apps-prod` needs no CI token.
- An Argo CD login allowed to update those AppProjects, for example a member of the admins group.
- Admin rights on the GitHub repository for its Actions secrets. `promote.yml` reads the repository variable `ARGOCD_SERVER` and the secrets `ARGOCD_CI_TOKEN_DEV` and `ARGOCD_CI_TOKEN_STAGE`.

### Steps

For each source environment (`dev`, then `stage`):

```bash
argocd proj role create-token apps-dev ci --expires-in 2160h --grpc-web
gh secret set ARGOCD_CI_TOKEN_DEV --repo YOUR_ORG/sk-k8s-devops-bootstrap
argocd proj role list-tokens apps-dev ci --grpc-web
argocd proj role delete-token apps-dev ci <old-token-issued-at> --grpc-web
```

`gh secret set` prompts for the value; paste the token printed by the first command. `list-tokens` shows the issue time of each token, which identifies the old one. Delete the old token only after the verification below.

### Verification

On the next due promotion, the step that verifies the source application in Argo CD passes. A 401 from that step means the secret holds a wrong or expired token; a 403 means the token is not of role `ci` in the source project.

### Rollback or abort

Until the old token is deleted, setting it back as the Actions secret restores the previous state.

## RKE2 join token

### Purpose

Replace the server token that nodes use to join the cluster.

### When to use

The token may be exposed, or someone who had it leaves. Rotate with care: the token also encrypts the bootstrap data in the datastore and in every etcd snapshot.

### Preconditions

- An etcd snapshot taken immediately before the rotation, escrowed together with the current token. Snapshots taken before the rotation contain bootstrap data encrypted with the old token: keep the old token with them until they leave the retention window.
- Root access to the server nodes, the Ansible vault, and a maintenance window: every server and agent restarts.

### Steps

1. Take the snapshot (see [take an on-demand etcd snapshot](backup-and-restore.md#take-an-on-demand-etcd-snapshot)).

2. On one server, as root, rotate the token:

   ```bash
   NEW_TOKEN=$(openssl rand -hex 32)
   rke2 token rotate --token "$(cat /var/lib/rancher/rke2/server/token)" --new-token "$NEW_TOKEN"
   ```

   The old token can no longer join new nodes.

3. Store the new token in the Ansible vault, in place of the old value:

   ```bash
   ansible-vault edit --vault-id <profile>@prompt <vault-file>
   ```

4. Re-run the provisioning playbook. It writes the new token into the RKE2 configuration of every server and agent and restarts them one at a time:

   ```bash
   make bootstrap-k8s CLUSTER=<profile>
   ```

5. Take a new etcd snapshot and escrow it with the new token.

### Verification

All nodes are Ready (`kubectl get nodes`), and `/var/lib/rancher/rke2/server/token` on every server contains the new value.

### Rollback or abort

The rotation cannot be undone. If a node fails to rejoin, check that its `/etc/rancher/rke2/config.yaml` holds the new token and restart its service.

## Ansible vault password

### Purpose

Re-encrypt the gitignored Ansible vault file with a new password.

### When to use

Someone who knew the password leaves, or the password may be exposed.

### Preconditions

- The current password and the vault file, the gitignored `group_vars/all/vault.yml` of the inventory you use (shown as `<vault-file>`). The vault uses the vault ID of the profile (`lab` or `reference`); see `ansible/README.md`.

### Steps

```bash
ansible-vault rekey --vault-id <profile>@prompt --new-vault-id <profile>@prompt <vault-file>
```

The command prompts for the current and the new password. The Make targets prompt for the password through the same vault ID, so there is no password file to update. Store the new password in your password manager.

A rekey changes the encryption, not the values. If the vault file itself may be exposed, rotate the secrets it contains, for example the [RKE2 join token](#rke2-join-token).

### Verification

```bash
ansible-vault view --vault-id <profile>@prompt <vault-file>
make preflight CLUSTER=<profile>
```

Both work with the new password.

### Rollback or abort

Copies of the vault file encrypted with the old password, such as backups, still open with the old password. Replace them as well.

## Image signing

Nothing to rotate. `build-image.yml` signs images with cosign keyless signing: each signature uses a short-lived certificate issued for the workflow's GitHub OIDC identity, and no long-lived signing key exists. The registry push uses the workflow's own token, issued per run.

The identity is part of the policy. If the repository is renamed or the build workflow moves, update `imageVerification.subjectRegExp` in the policy values and confirm with `cosign verify` (see [promotion](promotion.md#trace-a-running-image-to-its-source)) before the next promotion to stage.

## If a secret was committed

A secret that reached a commit on a remote is disclosed. In a public repository, assume it was copied the moment it was pushed.

1. Rotate first. Revoke or replace the credential at its issuer and roll out the new value with the procedure for its class above. Removing the file does not make the old value safe.
2. Then remove it from the tree in a pull request: replace the value with a placeholder, or move the file to a `*.example` template with placeholders.
3. Git history, forks and clones keep the old value. This repository does not rewrite history; rotation is the remedy. A history rewrite would not undo the disclosure.
4. Check that the `secrets` CI job (gitleaks) passes on the pull request. Its weekly full-history scan keeps reporting the old commit; add a fingerprint to `.gitleaksignore` only after the credential is revoked.
5. If the secret gives access to anything beyond this repository, follow [SECURITY.md](../../SECURITY.md).

## References

- Argo CD declarative repositories: <https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories>
- Argo CD project roles and tokens: <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/#project-roles>
- Argo CD FAQ (admin password reset): <https://argo-cd.readthedocs.io/en/stable/faq/>
- Sealed Secrets key renewal, re-encryption and secret rotation: <https://github.com/bitnami-labs/sealed-secrets#secret-rotation>
- External Secrets Operator FAQ (force sync): <https://external-secrets.io/latest/introduction/faq/>
- OpenBao KV commands: <https://openbao.org/docs/commands/kv/>
- RKE2 token management: <https://docs.rke2.io/security/token>
- Ansible Vault: <https://docs.ansible.com/ansible/latest/vault_guide/index.html>
- GitHub CLI deploy keys and secrets: <https://cli.github.com/manual/gh_repo_deploy-key> and <https://cli.github.com/manual/gh_secret_set>
- Sigstore cosign verification: <https://docs.sigstore.dev/cosign/verifying/verify/>
