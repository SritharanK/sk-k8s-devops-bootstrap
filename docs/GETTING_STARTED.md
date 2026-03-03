# Getting started

This guide walks through the steps to run the Kubernetes DevOps bootstrap from scratch. All sensitive values use placeholders; replace them from `config/defaults.yaml` or your environment.

**Quick start validation (no cluster):** To confirm the repo and config flow without provisioning servers, run `./scripts/bootstrap_config.sh` to copy example configs, then run `helm template argocd-bootstrap ./argocd-bootstrap --set spec.source.repoURL=... --set spec.destination.server=https://kubernetes.default.svc` (see [CONTRIBUTING.md](CONTRIBUTING.md) or `.github/workflows/validate.yml`). A full quick start run with a real server is recommended once to confirm the flow.

---

## Prerequisites

- **Ansible** (2.15+): `brew install ansible` (macOS) or `sudo apt install ansible` (Ubuntu/WSL).
- **kubectl**: install from [kubernetes.io](https://kubernetes.io/docs/tasks/tools/).
- **helm**: install from [helm.sh](https://helm.sh/docs/intro/install/).
- **SSH** key-based access to your server(s). Ensure you can `ssh YOUR_SSH_USER@YOUR_MASTER_IP` without a password prompt.
- Optional: **kubeseal** for sealing secrets; **ansible-vault** for encrypting playbook variables.

---

## 1. Clone and configure

```bash
git clone https://github.com/YOUR_ORG/k8s-devops-bootstrap.git
cd k8s-devops-bootstrap

cp config/defaults.yaml.example config/defaults.yaml
cp ansible/inventories/dev/hosts.ini.example ansible/inventories/dev/hosts.ini
```

Edit **config/defaults.yaml**: set `YOUR_MASTER_IP`, `YOUR_WORKER_IP`, `YOUR_SSH_USER`, `git_repo_ssh` (or `git_repo_url`), and any other placeholders.

Edit **ansible/inventories/dev/hosts.ini**: replace `YOUR_MASTER_IP` and `YOUR_WORKER_IP` with your server IPs. For a single node, use the same IP everywhere.

---

## 2. Ansible Vault and playbook variables

- Create a vault password file (e.g. `ansible/.ansible_vault_pass`) with a strong password. **Do not commit it.**
- Encrypt sensitive playbook variables:
  ```bash
  ansible-vault encrypt_string "YOUR_SSH_USER"
  ansible-vault encrypt_string "YOUR_GIT_TOKEN_OR_PASSWORD"
  # etc.
  ```
  Paste the output into the playbooks (e.g. `ansible/playbooks/k8s_bootstrap.yml`, `jenkins_setup.yml`) or group_vars as documented in the playbook comments.
- Update playbook vars that are not vault-encrypted (e.g. `master_nodes`, `worker_nodes`, `ssh_port`, `jenkins_dsl_git_repo`) from your `config/defaults.yaml` or set them in group_vars.

---

## 3. Bootstrap Kubernetes

```bash
make install-common    # Docker, RKE, kubectl, etc.
make bootstrap-k8s     # RKE cluster bootstrap
```

Or run the playbooks manually:

```bash
cd ansible
ansible-playbook -i inventories/dev/hosts.ini playbooks/install_common.yml --vault-password-file .ansible_vault_pass
ansible-playbook -i inventories/dev/hosts.ini playbooks/k8s_bootstrap.yml --vault-password-file .ansible_vault_pass
```

After success, your kubeconfig is under `ansible/data/kube_config_cluster.yaml`. Do not commit it.

```bash
export KUBECONFIG=$PWD/ansible/data/kube_config_cluster.yaml
kubectl get nodes
```

---

## 4. Install Jenkins (optional)

```bash
make install-jenkins
```

Or:

```bash
cd ansible
ansible-playbook -i inventories/dev/hosts.ini playbooks/jenkins_setup.yml --vault-password-file .ansible_vault_pass
```

Set `jenkins_dsl_git_repo`, `jenkins_git_username`, `jenkins_git_password`, `docker_registry_*`, and `git_ssh_privatekey` in the playbook (vault-encrypted) before running.

**Jenkins agents:** CI pipelines include a Trivy container scan; builds fail on CRITICAL/HIGH vulnerabilities. Install [Trivy](https://github.com/aquasecurity/trivy) on Jenkins agents.

---

## 5. Install Argo CD

```bash
make install-argocd
```

Or:

```bash
cd helmcharts/system-charts
helm upgrade --install argocd argo-cd -f argo-cd/values-lab.yaml -n argocd --create-namespace
```

**Production:** Use Ingress + TLS only: install with `-f argo-cd/values-production.yaml`. NodePort is for local lab only. See `helmcharts/system-charts/argo-cd/values-production.yaml`.

Set `argocdServerAdminPassword` (and optionally `hostname`) in `helmcharts/system-charts/argo-cd/values-lab.yaml` (or `values-production.yaml` for production). Generate a bcrypt hash:

```bash
ARGO_PWD='YOUR_PASSWORD'
htpasswd -nbBC 10 "" $ARGO_PWD | tr -d ':\n' | sed 's/$2y/$2a/'
```

Access Argo CD at `http://YOUR_MASTER_IP:31980` (NodePort, lab only). For production use Ingress + TLS with `values-production.yaml`.

---

## 6. Bootstrap Argo CD app-of-apps

Edit `scripts/misc/argocd_prerequisite.sh`: set `ARGO_URL`, `ARGO_USER`, `ARGO_PASS`, `KUBECONFIG_PATH`, `GIT_REPO` (and SSH key path if needed) from your config.

Run:

```bash
chmod +x scripts/misc/argocd_prerequisite.sh
./scripts/misc/argocd_prerequisite.sh
```

**Optional Argo CD apps:** The `kyverno-policies` app deploys admission policies. If Kyverno is not installed in the cluster, disable or delete that Application (e.g. remove `argocd-bootstrap/templates/toolchains/kyverno-policies.yaml` from the bootstrap or leave it out of the rendered manifests) to avoid sync errors. LimitRange and ResourceQuota in `helmcharts/system-charts/00_misc/limitrange-resourcequota.yaml` are applied by the `misc` app—tune CPU/memory/pod limits to match your cluster size.

---

## 7. Seal secrets

Create unsealed secret manifests under `helmcharts/system-charts/argocd-config/unseal/` with your Docker registry and (if used) Helm repo credentials. Use placeholders in the repo; generate real files locally. Then:

```bash
export KUBECONFIG=path/to/your/kube_config_cluster.yaml
make seal-secrets
```

Commit only the sealed YAML under `helmcharts/system-charts/argocd-config/sealed/`. See [SECURITY.md](SECURITY.md).

---

## 8. Deploy a new service

See the main README and the repository guide: add a Jenkinsfile (CI/CD), Jenkins DSL job definition, an application Helm chart under `helmcharts/app-charts/`, and an Argo CD Application template under `argocd-bootstrap/templates/applications/`. Use `YOUR_*` placeholders for registry, repo URL, and Argo CD server in Jenkinsfiles and DSL.

---

**Change only IPs and links:** After the first-time setup, updating cluster IPs, Git repo URL, or registry usually means editing `config/defaults.yaml` and (if you use them) Ansible group_vars or playbook vars, then re-running the relevant make targets or playbooks.
