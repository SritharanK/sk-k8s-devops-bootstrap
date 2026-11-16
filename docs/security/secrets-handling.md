# Secrets handling

This page describes how secrets reach the platform without entering Git in plaintext: what is never committed, how the `lab` profile seals secrets, how the `reference` profile pulls them from OpenBao, where SOPS and Ansible Vault fit, and which CI checks enforce the rules. It is for operators who create or change a secret. Rotation is covered in [secret rotation](../operations/secret-rotation.md).

## Mechanism per secret class

| Secret class | `lab` | `reference` |
| --- | --- | --- |
| Runtime secrets for workloads and platform components | SealedSecret committed to Git, sealed offline | `ExternalSecret` committed to Git, value stored in OpenBao |
| Image pull secrets | One SealedSecret per app namespace | As runtime secrets |
| Bootstrap secrets needed before Argo CD and the secret store run | SOPS with age | SOPS with age |
| Node provisioning secrets, for example the RKE2 join token | Ansible Vault, gitignored `vault.yml` | Ansible Vault, gitignored `vault.yml` |

## What is never committed

| Item | Where it lives |
| --- | --- |
| Ansible Vault password | Entered at the prompt (`--vault-id <profile>@prompt`); no password file exists in the repository |
| Ansible secrets | `ansible/inventories/<profile>/group_vars/all/vault.yml`, gitignored and vault-encrypted |
| Real inventory | `ansible/inventories/<profile>/hosts.yml`, gitignored, copied from `hosts.yml.example` |
| Kubeconfig | `ansible/data/`, gitignored, mode 0600 |
| Plaintext inputs for sealing | Files outside the working tree, or stdin; `hack/seal.sh` reads nothing else |
| Private repository credential | A file outside the working tree, or a SOPS-encrypted `*.sops.yaml`, passed to `make bootstrap-gitops` through `REPO_SECRET_FILE` |
| Environment files | `.env` files anywhere in the tree, gitignored; the repository ships no `.env.example` |
| SOPS age private key | The operator's key file outside the repository (`SOPS_AGE_KEY_FILE`) |

The `.gitignore` entries that cover the files inside the working tree:

```text
ansible/inventories/*/hosts.yml
ansible/inventories/*/group_vars/*/vault.yml
ansible/data/*
**/.env
_out/
```

`.gitignore` only prevents accidents. The controls that fail a change are the CI checks at the end of this page.

## Lab: Sealed Secrets with offline sealing

The Sealed Secrets controller holds a private key in the cluster. Anyone with the matching public certificate can encrypt a Secret into a `SealedSecret`; only the controller can decrypt it. The `lab` profile seals offline: the controller certificate is committed to the repository and its fingerprint is pinned, so sealing needs no cluster access and cannot silently use a certificate from somewhere else.

A SealedSecret decrypts only with the key of the controller it was sealed for, so the files are per cluster:

```text
clusters/<name>/sealed-secrets/cert.pem       public controller certificate
clusters/<name>/sealed-secrets/cert.sha256    pinned SHA-256 fingerprint of cert.pem
clusters/<name>/secrets/<namespace>/<name>.yaml
```

The Application `cluster-secrets` (sync wave 1, after the Sealed Secrets controller) applies `clusters/<name>/secrets/` when `toolchains.cluster-secrets.enabled` is true in the cluster file.

### Seal a secret

`hack/seal.sh` does the sealing. It checks the committed certificate against the pinned fingerprint before every seal, seals offline, reads plaintext only from outside the repository or from stdin, rejects placeholder values, and never overwrites a sealed file without `--force`.

```bash
hack/seal.sh fetch-cert --cluster lab   # once per controller key; needs cluster access
hack/seal.sh secret --cluster lab --namespace dev --from-file /path/outside/repo/secret.yaml
hack/seal.sh verify --cluster lab
```

The plaintext Secret manifest stays outside the working tree. Commit only the sealed output under `clusters/lab/secrets/dev/`.

### Scope

`kubeseal` uses the `strict` scope by default: the ciphertext is bound to the Secret's name and namespace. A SealedSecret copied to another namespace or renamed does not decrypt. That is intended: a sealed value for `dev` cannot be replayed into `prod`.

### Pull secrets

Each app namespace has its own sealed pull secret of type `kubernetes.io/dockerconfigjson`, which GHCR requires for a private package. Use a registry token that can read packages and nothing else.

```bash
hack/seal.sh docker-registry --cluster lab --namespace dev --server ghcr.io --username <user>
```

Repeat per namespace. Because of the strict scope, the `dev` pull secret cannot be reused in `stage` or `prod`.

### Key escrow

The SealedSecrets in Git are only as recoverable as the controller's private key. If the cluster is lost without a copy of that key, every SealedSecret must be re-created from the original inputs. The key backup, its storage and the restore procedure are in [backup and restore](../operations/backup-and-restore.md).

## Reference: External Secrets Operator with OpenBao

In the `reference` profile, Git holds only references. External Secrets Operator (ESO) reads the values from OpenBao and writes ordinary Kubernetes Secrets into the namespace that asks for them. ESO talks to OpenBao through its `openBao` provider.

### The shared store

The OpenBao wrapper chart renders one `ClusterSecretStore`, named `openbao`, for all environments (`helmcharts/system-charts/openbao/templates/clustersecretstore.yaml`, values under `clusterSecretStore`). The `reference` render:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    openBao:
      server: https://openbao-active.openbao.svc:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: openbao-server-tls
        key: ca.crt
        namespace: openbao
      auth:
        kubernetes:
          path: kubernetes
          role: external-secrets
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

`clusterSecretStore.conditions` is empty by default, so every namespace may reference the store. The role `external-secrets` and its policy `external-secrets-read`, created by hand as the [OpenBao chart README](../../helmcharts/system-charts/openbao/README.md#configure-for-external-secrets) describes, read every path under `secret/`. A `dev` ExternalSecret can therefore read a `prod` value. This is listed in [known limitations](known-limitations.md).

### OpenBao Kubernetes auth

ESO authenticates with a Kubernetes ServiceAccount token. OpenBao checks the token with the Kubernetes TokenReview API and maps it to a role, so no static OpenBao token is stored in the cluster. The OpenBao chart README has the commands for the KV mount, the auth method, the policy and the role. `kubernetes_host=https://kubernetes.default.svc:443` applies when OpenBao runs in the same cluster. An OpenBao outside the cluster also needs the API server CA certificate and a token reviewer credential in its auth configuration.

### Recommended hardening: one store per environment

The repository does not render this. Give each environment its own `ClusterSecretStore`, OpenBao role and policy: the store accepts requests only from its namespace, and its role reads only that environment's path, so a `dev` ExternalSecret cannot read a `prod` value. Add the stores to the OpenBao wrapper chart, and restrict or disable the shared store. For `dev`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-dev
spec:
  conditions:
    - namespaces: ["dev"]
  provider:
    openBao:
      server: https://openbao-active.openbao.svc:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: openbao-server-tls
        key: ca.crt
        namespace: openbao
      auth:
        kubernetes:
          path: kubernetes
          role: eso-dev
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
            audiences: ["openbao"]
```

```bash
bao policy write eso-dev - <<'EOF'
path "secret/data/dev/*" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/eso-dev \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  audience=openbao \
  token_policies=eso-dev \
  token_ttl=15m
```

### Request a secret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example-credentials
  namespace: dev
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: example-credentials
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: dev/example-app/database
        property: password
```

With per-environment stores, `secretStoreRef.name` is the environment's store, for example `openbao-dev`.

ESO creates the Secret `example-credentials` in `dev` and refreshes it every hour, so a value changed in OpenBao reaches the cluster without a commit. The workload reads it through `secretKeyRef` or a volume, never through a literal in its values file.

### Cloud key vault as an alternative store

OpenBao is the self-hosted default. A cluster that runs in a cloud can use that cloud's managed key vault instead, through the matching ESO provider. Only the `ClusterSecretStore` changes; the ExternalSecrets and the workloads stay the same.

## Bootstrap secrets: SOPS with age

Some secrets must exist before Argo CD or the secret store can deliver anything: for example, the Git repository credential of a private fork. These secrets are encrypted with SOPS to one or more age public keys. The age private keys stay with the operators, outside the repository.

The repository credential starts from the template `bootstrap/repo-secret.example.yaml`. `hack/bootstrap-gitops.sh` applies it once through `REPO_SECRET_FILE`: either a plain file outside the repository, which the script refuses inside it, or a SOPS-encrypted `*.sops.yaml`, which the script decrypts with `sops`.

```bash
age-keygen -o "$HOME/.config/sops/age/keys.txt"
sops --encrypt --age <age public key> --encrypted-regex '^(data|stringData)$' \
  /path/outside/repo/repo-secret.yaml > bootstrap/secrets/reference/repo-secret.sops.yaml
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  REPO_SECRET_FILE=bootstrap/secrets/reference/repo-secret.sops.yaml \
  make bootstrap-gitops CLUSTER=reference
```

SOPS is limited to these few secrets on purpose. Decryption happens on an operator workstation, with no controller that reconciles, refreshes or audits the result. Every secret that can wait until the cluster's secret controller runs goes through Sealed Secrets or ESO instead.

## Ansible secrets

Node provisioning secrets live in `ansible/inventories/<profile>/group_vars/all/vault.yml`, copied from the committed `vault.yml.example`, gitignored and encrypted with Ansible Vault. Committed variables refer to them through a `vault_` prefix, so a reader can see which values are secret without decrypting anything:

```yaml
# Committed group variables
example_password: "{{ vault_example_password }}"
```

```yaml
# vault.yml (gitignored, encrypted)
vault_example_password: CHANGE_ME
```

Encrypt the file with a vault ID per profile and enter the password at the prompt:

```bash
ansible-vault encrypt --vault-id reference@prompt \
  ansible/inventories/reference/group_vars/all/vault.yml
```

Playbook runs that read the file need the same vault ID, for example `--vault-id reference@prompt`. No vault password file exists in the repository.

## CI checks

| Check | What it fails on | Job |
| --- | --- | --- |
| gitleaks | Credentials, tokens and private keys in a change; weekly over the full history | `secrets` |
| `hardcoded-ipv4` gitleaks rule | A single private host address or any public address in configuration, scripts and Dockerfiles; RFC 5737 documentation ranges and private CIDRs pass | `secrets` |
| `hardcoded-domain` gitleaks rule | Domains outside the allowlist; `example.com`, `localtest.me` and upstream project domains pass | `secrets` |
| Plaintext Secret check | A `kind: Secret` with `data` or `stringData` in a YAML file outside Helm `templates/` directories and `*.example.yaml` files (`hack/secrets.sh`) | `secrets` |

A finding blocks the merge. If a real secret reaches a branch, removing it is not enough: treat it as disclosed and rotate it, as described in [secret rotation](../operations/secret-rotation.md). The full list of controls is in [security controls](controls.md#enforcement-matrix).
