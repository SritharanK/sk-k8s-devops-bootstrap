# Cluster definitions

One directory per cluster. `clusters/<name>/cluster.yaml` is the only non-secret input that differs between clusters. It is committed and validated against `clusters/schema.json`.

| Consumer | How it reads the file |
|---|---|
| Ansible | `vars_files`, keys `cluster`, `rke2`, `namespaces` |
| Argo CD | The root Application passes it to `argocd-bootstrap` as an extra Helm values file, after `argocd-bootstrap/values.yaml` |
| `hack/bootstrap-gitops.sh` | `git.*`, `cluster.profile`, `namespaces.argocd` |

The `rke2` section is read by Ansible only; Helm ignores it.

## Profiles

| Cluster | Profile | Runs on | Secrets |
|---|---|---|---|
| `lab` | `lab` | kind (`make demo`) or a single RKE2 node | Sealed Secrets, sealed per cluster |
| `reference` | `reference` | RKE2 HA: three servers behind `rke2.registrationAddress`, CIS profile, etcd snapshots to S3 | External Secrets Operator with OpenBao |

## Validation

```bash
make validate-config                               # every cluster and tenant file; placeholders are warnings
make validate-config STRICT=1 CLUSTER=reference    # one cluster file; fails on placeholders
```

Strict mode fails on placeholders (`CHANGE_ME`, `YOUR_*`, `your-org`, `<TOKEN>`) in every file it validates, and on an `example.com` domain in a `reference` profile file. Without `CLUSTER`, it validates every cluster and tenant file; the shipped `lab` file and `tenants/team-a.yaml` keep placeholders, so strict mode fails on them. CI runs `make validate-config` without `STRICT`, so placeholders are warnings there.

Beyond the schema, the validator checks that `cluster.name` equals the directory name, that the argocd, dev, stage and prod namespaces are distinct, and that every `toolchains.<name>` key is read by a template under `argocd-bootstrap/templates`.

## Adding a cluster

1. Copy `lab/` or `reference/` to `clusters/<name>/` and set `cluster.name: <name>`.
2. Replace every placeholder, then run `make validate-config STRICT=1 CLUSTER=<name>`.
3. Provision the nodes (`make bootstrap-k8s`), then run `make bootstrap-gitops CLUSTER=<name>`.

## Secrets

Nothing in a cluster definition is secret. Secrets follow the profile.

### Lab: Sealed Secrets

A SealedSecret decrypts only with the key of the controller it was sealed for, so sealed files are per cluster:

```text
clusters/<name>/sealed-secrets/cert.pem      public controller certificate
clusters/<name>/sealed-secrets/cert.sha256   pinned SHA-256 fingerprint of cert.pem
clusters/<name>/secrets/<namespace>/<name>.yaml
```

```bash
hack/seal.sh fetch-cert --cluster lab                     # once per controller key
hack/seal.sh docker-registry --cluster lab --namespace dev --server ghcr.io --username <user>
hack/seal.sh secret --cluster lab --namespace dev --from-file /path/outside/repo/secret.yaml
hack/seal.sh verify --cluster lab
```

`hack/seal.sh` seals offline against the committed certificate after checking its fingerprint, reads plain text only from outside the repository or from stdin, rejects placeholder values and never overwrites a sealed file without `--force`. Each namespace gets its own image pull secret. Enable `toolchains.cluster-secrets` in the cluster definition to let Argo CD apply `clusters/<name>/secrets/`.

The controller key is the only way to decrypt these files. Back it up outside the cluster and restore it before the controller starts on a rebuilt cluster; otherwise reseal everything (see the backup and restore runbook).

### Reference: External Secrets Operator with OpenBao

No secret value is stored in Git, sealed or not:

- OpenBao runs in the cluster (or outside it) as the secret store. Its unseal keys and root token are kept offline by the operators.
- External Secrets Operator reads from OpenBao through one shared `ClusterSecretStore` named `openbao` (KV v2 at `secret`), which authenticates with the Kubernetes auth method as role `external-secrets`, bound to the operator's ServiceAccount. The store has no namespace conditions by default, and the policy in the OpenBao chart runbook reads every path under `secret/`, so a `dev` ExternalSecret can read a `prod` path. Per-environment stores are the recommended hardening; see [secrets handling](../docs/security/secrets-handling.md).
- Applications declare `ExternalSecret` objects that name a store and a path; the operator writes the Kubernetes Secret.
- Bootstrap secrets that must exist before OpenBao (for example private repository credentials) are SOPS files encrypted with age, applied once by `hack/bootstrap-gitops.sh` through `REPO_SECRET_FILE`.
