# Security & Sanitization Checklist

This document describes what is **intentionally not committed** to the repository and how to handle secrets safely. It aligns with the README and playbook instructions for Ansible Vault and sealed secrets.

---

## What is not committed

The following must **never** be committed to the repository:

| Item | Location / usage | Reason |
|------|-------------------|--------|
| **Ansible Vault password** | `ansible/.ansible_vault_pass` | Used to decrypt vault-encrypted variables in playbooks. Anyone with this file can decrypt all vault secrets. |
| **Kubeconfig** | `ansible/data/kube_config_cluster.yaml` (or any path you copy it to) | Contains cluster API endpoint and credentials. Grants full access to the cluster. |
| **RKE cluster state** | `ansible/data/k8s_cluster.rkestate` | Sensitive cluster state; required for RKE operations. |
| **Unsealed Kubernetes secrets** | Any locally-generated YAML secret that contains real credentials | Plaintext secrets (Docker registry, Helm repo tokens, etc.). Use `argocd-config/templates/*.yaml.example` as starting points; fill in values locally and seal before committing. Never commit the plain YAML. |
| **Environment or config with real values** | `config/defaults.yaml` (if it contains real IPs/tokens) or `.env` | Use `config/defaults.yaml.example` and `.env.example` only in the repo; users copy and fill locally. |

These paths are listed in `.gitignore`. Before pushing, ensure they are not staged.

---

## How to generate sealed secrets safely

Sealed Secrets allow you to commit **encrypted** secrets to Git; the Sealed Secrets controller in the cluster decrypts them into standard Kubernetes secrets. Unsealed (plaintext) secrets must never be committed.

### 1. Use placeholder templates in the repo

`argocd-config/templates/` contains four annotated `*.yaml.example` files covering every secret the platform needs:

| Template | Secret |
|----------|--------|
| `docker-registry-secret.yaml.example` | Image pull secret (per namespace) |
| `argocd-repo-secret.yaml.example` | Git SSH deploy key for Argo CD |
| `jenkins-credentials-secret.yaml.example` | Jenkins Git + Docker + Argo CD credentials |
| `db-credentials-secret.yaml.example` | PostgreSQL / MySQL credentials (per namespace) |

Copy the relevant example locally, fill in real values — **never commit the filled copy**.

### 2. Generate unsealed secrets locally (never commit)

On your machine, with `kubectl` configured against the target cluster:

- Copy `argocd-config/templates/<secret>.yaml.example` to a location outside the repo, **or** generate from scratch with `kubectl create secret ... --dry-run=client -o yaml`.
- Fill in real credentials and keep the file local only.

### 3. Seal and commit only the sealed output

- Ensure the cluster has the Sealed Secrets controller installed (see main README / Argo CD bootstrap).
- Run the seal script (`make seal-secrets` or `scripts/misc/seal_k8s_secrets.sh`) with `KUBECONFIG` set so it can fetch the controller's public certificate.
- The script reads from `helmcharts/system-charts/argocd-config/unseal/` and writes **encrypted** YAML into `helmcharts/system-charts/argocd-config/sealed/`.
- Commit only the **sealed** files; the controller in the cluster will reconcile them into normal secrets.

### 4. Rotate if exposed

If an unsealed secret or a vault password was ever committed (or pushed to a remote), consider it compromised. Rotate the credential (e.g. new Docker Hub token, new GitLab/GitHub token, new Argo CD admin password), update your local unseal sources and vault variables, then re-seal and push only the new sealed secrets.

---

## Ansible Vault

- Store the vault password in `ansible/.ansible_vault_pass` **only on your local machine** (or in a secure secret manager). Never commit it.
- Use `ansible-vault encrypt_string "SECRET"` to produce encrypted values for playbook vars; paste the result into the playbook or group_vars.
- To rotate: re-encrypt with a new value and replace the vault blob; optionally re-key the vault file with a new password if the old one was exposed.

---

## Quick checklist before each push

- [ ] No file named `.ansible_vault_pass` or containing vault passwords is staged.
- [ ] No `kube_config_*.yaml` or `*.rkestate` under `ansible/data/` (or similar) is staged.
- [ ] No unseal secret files contain real credentials (only placeholders or you didn’t add them to Git).
- [ ] Sealed secrets in `argocd-config/sealed/` were produced from your local unseal sources and are safe to commit (encrypted for your cluster).

Never commit unsealed secrets, vault passwords, or kubeconfig. Use placeholders in the repo and generate real values locally. Redact any credentials before making the repo public.

---

## Trivy (vulnerability and config scanning)

- **Enforcement (blocking):** Jenkins CI pipelines (`scripts/jenkinsfiles/ci/*.Jenkinsfile`) run a Trivy **image** scan on the built container and **fail the build** on CRITICAL or HIGH vulnerabilities. No image is pushed if the gate fails.
- **Advisory (non-blocking):** The GitHub Actions workflow [.github/workflows/validate.yml](../.github/workflows/validate.yml) runs four Trivy **config** scans covering `sample-services/` (Dockerfiles), `helmcharts/` (all Helm templates), `helmcharts/system-charts/kyverno-policies/` (admission policies), and `argocd-bootstrap/` (Argo CD manifests). None of these jobs fail the workflow; use the job log to fix findings. To make any gate blocking, set `exit-code: '1'` and remove `continue-on-error` on that job.

This split avoids ambiguity: Jenkins is the deployment gate; GitHub Actions provides visibility without blocking PRs until config findings are resolved. **PRs show advisory findings; merges are gated by Jenkins in the reference pipeline.** That is an explicit governance choice, not weak security.

---

## RBAC

We do **not** use cluster-admin for routine operations. Argo CD and platform admins use namespace-scoped or custom cluster roles. Argo CD does not manage cluster-wide resources except CRDs defined in the platform namespace. Restrict Argo CD via AppProject destination namespaces first; then reduce cluster-scope permissions gradually (see `helmcharts/system-charts/argocd-project/` and `00_misc/platform-admin-rbac.yaml`).
