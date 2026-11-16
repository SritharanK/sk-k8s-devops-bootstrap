---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Sealed Secrets in lab, External Secrets Operator with OpenBao in reference

This record explains how secrets are stored, delivered to the cluster and rotated in each profile. It is for operators who manage credentials and for reviewers of the secrets lifecycle.

## Context and problem statement

The platform needs secrets: image pull credentials per namespace, the Argo CD repository credential, OIDC client secrets, app secrets and Ansible host credentials. The repository is public, so no plaintext secret may ever reach Git. The `lab` profile must run offline on a laptop. The `reference` profile needs rotation without Git commits, access audit and recovery after the loss of the cluster.

Which mechanism should deliver secrets in each profile, and where do the few secrets that must exist before any in-cluster store runs come from?

## Decision drivers

- No plaintext secret in Git, enforced by CI.
- `lab` works offline, with no external service.
- `reference` supports central storage, rotation without commits, access audit and recovery.
- Works on premises and air-gapped; no cloud account is required.
- An OSI-approved licence, so adopters can run the stack without a licence review.
- A small bootstrap surface: few secrets must exist before the cluster's own secret store runs.

## Considered options

- Sealed Secrets only
- SOPS with age everywhere
- External Secrets Operator (ESO) with OpenBao
- External Secrets Operator with a cloud key vault
- External Secrets Operator with HashiCorp Vault

## Decision outcome

Chosen option: "External Secrets Operator with OpenBao" for the `reference` profile, combined with Sealed Secrets in the `lab` profile, because together they meet every driver: `lab` stays offline and self-contained, and `reference` gets a central store with rotation and audit under an open-source licence.

Per profile:

- `lab`: Sealed Secrets (wave 0) with offline sealing. The controller certificate is committed at `clusters/<name>/sealed-secrets/cert.pem` with its fingerprint pinned in `cert.sha256`, so sealing needs no cluster access. `hack/seal.sh` reads plaintext only from outside the repository or from stdin and writes sealed files to `clusters/<name>/secrets/<namespace>/`, which the Application `cluster-secrets` (wave 1) applies. Each namespace gets its own sealed pull secret. The sealing key is escrowed as described in [backup and restore](../operations/backup-and-restore.md).
- `reference`: External Secrets Operator (wave 0) with one shared OpenBao `ClusterSecretStore`, `openbao`, rendered by the `openbao` chart. It authenticates with the OpenBao Kubernetes auth method as the role `external-secrets` and has no namespace conditions, so as shipped `dev` can read `prod` paths (see the recommendation below and [known limitations](../security/known-limitations.md#one-clustersecretstore-serves-every-environment)). `ExternalSecret` objects in the app namespaces produce ordinary Kubernetes Secrets. ESO reads OpenBao through its `openBao` provider.
- Bootstrap secrets only: SOPS with age, for the secrets that must exist before ESO and OpenBao run, such as the repository credential of a private fork. `hack/bootstrap-gitops.sh` applies them once through `REPO_SECRET_FILE`. The age private key stays outside Git and outside the cluster.
- Alternative store: a site that runs in a public cloud can replace the OpenBao store with a cloud key vault store in ESO. Workloads keep consuming the same Kubernetes Secrets.
- Ansible: host credentials live in a gitignored `group_vars/all/vault.yml`, copied from `vault.yml.example`, and are referenced through `vault_` variables.

Recommendation: restrict each `ClusterSecretStore` to the namespace of its environment with ESO store conditions, so `dev` cannot read `prod` paths.

### Consequences

- Good, because no plaintext secret is committed, and CI blocks attempts to commit one.
- Good, because `lab` needs no external service and runs from a fresh clone.
- Good, because in `reference` a secret is rotated in OpenBao and ESO refreshes the Kubernetes Secret on its refresh interval, with no Git commit.
- Good, because OpenBao can record every access through an audit device.
- Bad, because there are two mechanisms to document, test and operate. The end-to-end job installs the `lab` profile only, so it does not exercise the ESO path.
- Bad, because OpenBao is a stateful, security-critical service: unseal keys, storage backups, high availability and upgrades become platform duties. When it is unreachable, existing Secrets stay in place, but new and rotated values wait.
- Bad, because losing the Sealed Secrets key makes every SealedSecret in Git unreadable. Key escrow is mandatory, and sealed values are bound to one cluster's key.
- Bad, because the age key for bootstrap secrets must reach every operator who bootstraps a cluster, through a channel outside Git.
- Neutral, because both mechanisms end in ordinary Kubernetes Secrets, so encryption at rest in etcd and RBAC on Secrets still matter.

### Confirmation

- The `secrets` job runs gitleaks as a blocking check on every pull request and as a weekly full-history scan.
- A CI check (`hack/secrets.sh`, job `secrets`) rejects any `kind: Secret` with `data` or `stringData` outside Helm `templates/` directories and `*.example.yaml` files.
- `make dr-drill` (script `hack/dr/restore-drill.sh`) restores a namespace and a SealedSecret in the cluster of the current kube context, for example the kind demo, which proves that a restored SealedSecret still decrypts. It runs on demand, not in CI.
- Review: `ExternalSecret` objects reference only their own environment's paths, because the shared store does not enforce it.

## Pros and cons of the options

### Sealed Secrets only

- Good, because it needs no external service and works offline, with encrypted values reviewable in Git.
- Bad, because rotation means resealing and committing every value, and nothing audits who read a secret.
- Bad, because sealed values are bound to one cluster's key, and losing the key loses every secret.

### SOPS with age everywhere

- Good, because encrypted files are portable between clusters and readable by anyone who holds the key.
- Bad, because Argo CD has no native SOPS support; decryption needs a config management plugin in the repository server, which then holds the decryption key.
- Bad, because rotation and audit stay manual, as with Sealed Secrets.

### External Secrets Operator with OpenBao

- Good, because OpenBao offers central storage, leases, rotation and an audit log, and runs on premises and air-gapped.
- Good, because OpenBao is a community fork of Vault under the MPL 2.0 licence with open governance.
- Bad, because it is another stateful service to secure, back up, unseal and upgrade.

### External Secrets Operator with a cloud key vault

- Good, because the provider operates the store, with managed availability, audit and identity integration.
- Bad, because it requires a cloud account and workload identity setup, and does not work on premises or air-gapped.
- Neutral, because ESO supports it as a drop-in store, so a cloud site can choose it without changing workloads.

### External Secrets Operator with HashiCorp Vault

- Good, because it is mature and widely deployed, and OpenBao keeps its API, so the ESO configuration is nearly the same.
- Neutral, because Vault moved from the MPL 2.0 to the Business Source License 1.1 in August 2023. The BSL is not an OSI-approved licence, so each adopter would need to review its terms.
- Bad, because it offers no technical advantage over OpenBao for the drivers above.

## More information

Upstream sources, checked on 2026-11-16:

- Sealed Secrets: <https://github.com/bitnami-labs/sealed-secrets>
- SOPS: <https://getsops.io/>
- External Secrets Operator: <https://external-secrets.io/latest/> and its Vault provider: <https://external-secrets.io/latest/provider/hashicorp-vault/>
- OpenBao: <https://openbao.org/>
- Vault licence: <https://github.com/hashicorp/vault/blob/main/LICENSE>

Related pages and decisions:

- [Secrets handling](../security/secrets-handling.md), [secret rotation](../operations/secret-rotation.md), [backup and restore](../operations/backup-and-restore.md)
- [ADR 0005: lab and reference profiles](0005-lab-and-reference-profiles.md)
