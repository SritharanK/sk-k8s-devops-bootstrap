# Production setup guide

This guide lists **everything you need to do** to get from a cloned repo to a production-ready deployment. All steps are done **on your side** with **your** credentials and values; nothing here requires giving third parties access to Docker or your cluster.

---

## What you need to prepare (before starting)

Gather these **locally** (do not commit them):

| What | Example / note |
|------|-----------------|
| **Cluster IPs** | Master node IP, worker node IP(s). For single-node, use the same IP for both. |
| **SSH user** | OS user for Ansible (e.g. `ubuntu`, `root`). |
| **Git repo URL** | Your GitOps repo (this repo or your fork), e.g. `https://github.com/YOUR_ORG/k8s-devops-bootstrap.git` and `git@github.com:YOUR_ORG/k8s-devops-bootstrap.git`. |
| **Docker registry** | Registry URL (e.g. `https://index.docker.io/v1/` for Docker Hub), username, password, email. Use a token for Docker Hub if possible. |
| **Argo CD admin password** | Choose a strong password; you will generate a bcrypt hash from it. |
| **Ansible vault password** | One strong password to encrypt playbook variables. |
| **Optional: platform admin** | Kubernetes group or user name for RBAC (e.g. `platform-admins` or your IdP group). |
| **Optional: app DB password** | If you deploy python-django or java-springboot, the DB password for MySQL. |

---

## Step 1: Central config

1. Copy the example config:
   ```bash
   cp config/defaults.yaml.example config/defaults.yaml
   ```
2. Edit `config/defaults.yaml`. Replace every `YOUR_*` and placeholder with your values:
   - `master_ip`, `worker_ip`, `ansible_user`
   - `git_repo_url`, `git_repo_ssh`, `git_branch`
   - `argocd_host`, `argocd_url` (e.g. `http://YOUR_MASTER_IP:31980` for lab, or your Ingress URL for production)
   - `argocd_admin_password_hash` (see Step 4)
   - `docker_registry`, `docker_username`, `docker_email` (password goes in env/script only)
   - Optional: `nfs_server`, `cert_manager_email`, `ingress_external_ip`, `helm_chart_repo_url`
3. Do **not** commit `config/defaults.yaml` if it contains real IPs or secrets. Add it to `.gitignore` if needed.

---

## Step 2: Ansible inventory and vault

1. Copy the example inventory:
   ```bash
   cp ansible/inventories/dev/hosts.ini.example ansible/inventories/dev/hosts.ini
   ```
2. Edit `ansible/inventories/dev/hosts.ini`: set `YOUR_MASTER_IP`, `YOUR_WORKER_IP` (and any other group IPs) to your real IPs.
3. Create a vault password file (one-time):
   ```bash
   echo "YOUR_STRONG_VAULT_PASSWORD" > ansible/.ansible_vault_pass
   chmod 600 ansible/.ansible_vault_pass
   ```
   Ensure `ansible/.ansible_vault_pass` is in `.gitignore` and never commit it.
4. Encrypt sensitive playbook variables. For each value (e.g. SSH user, Jenkins Git password, Docker registry credentials), run:
   ```bash
   cd ansible
   ansible-vault encrypt_string "YOUR_VALUE"
   ```
   Paste the output into the playbook or group_vars as documented (e.g. `jenkins_setup.yml`, `install_jenkins/defaults/main.yml`). Set at least: `ansible_user`, `rke_user`, `jenkins_git_username`, `jenkins_git_password`, `docker_registry_username`, `docker_registry_password`, and optionally `git_ssh_privatekey`, `jenkins_admin_password`.

---

## Step 3: Docker registry secret (for image pulls)

1. Copy the env example and set your registry credentials:
   ```bash
   cp scripts/misc/.env.example scripts/misc/.env
   ```
2. Edit `scripts/misc/.env`:
   - `DOCKER_USERNAME` = your Docker Hub (or registry) username  
   - `DOCKER_PASSWORD` = your password or token  
   - `DOCKER_EMAIL` = your email  
   - For Docker Hub: `DOCKER_SERVER=https://index.docker.io/v1/`  
   - For another registry: `DOCKER_SERVER=https://your-registry.example.com`
3. Ensure your cluster is up and the Sealed Secrets controller is installed. Set `KUBECONFIG` to your kubeconfig.
4. Run:
   ```bash
   ./scripts/misc/create_k8s_docker_secret_seal.sh
   ```
   The script writes the sealed secret to `helmcharts/system-charts/argocd-config/sealed/dockerhub_secret.yaml`. If it wrote elsewhere, copy that file into `helmcharts/system-charts/argocd-config/sealed/dockerhub_secret.yaml`.
5. Commit only the **sealed** file. Do not commit `scripts/misc/.env`.

---

## Step 4: Argo CD admin password

1. Generate a bcrypt hash (on your machine):
   ```bash
   ARGO_PWD='your_chosen_password'
   htpasswd -nbBC 10 "" "$ARGO_PWD" | tr -d ':\n' | sed 's/$2y/$2a/'
   ```
2. Put the output into:
   - `config/defaults.yaml` → `argocd_admin_password_hash` (if you use it for templating), and/or  
   - `helmcharts/system-charts/argo-cd/values-lab.yaml` or `values-production.yaml` → `configs.secret.argocdServerAdminPassword`
3. Do not commit the plain password; only the hash is stored.

---

## Step 5: Argo CD bootstrap repo URL

1. Edit `argocd-bootstrap/values.yaml`.
2. Set `spec.source.repoURL` to your GitOps repo URL (e.g. the same as `git_repo_url` in `config/defaults.yaml`):
   ```yaml
   spec:
     source:
       repoURL: https://github.com/YOUR_ORG/k8s-devops-bootstrap.git  # or your fork
       targetRevision: main
   ```
3. Commit this change (the URL is not secret).

---

## Step 6: RBAC (platform admin)

1. Edit `helmcharts/system-charts/00_misc/platform-admin-rbac.yaml`.
2. Find the `subjects` section in the ClusterRoleBinding and set the group or user that should have platform admin:
   ```yaml
   subjects:
     - kind: Group
       name: platform-admins   # or your IdP group, e.g. your-org/platform-admins
       apiGroup: rbac.authorization.k8s.io
   ```
3. Commit if using a generic group name, or keep local if it’s environment-specific.

---

## Step 7: LimitRange and ResourceQuota

1. Edit `helmcharts/system-charts/00_misc/limitrange-resourcequota.yaml`.
2. Adjust the `limits` and `hard` values to match your cluster size and team quotas (CPU, memory, pod counts for `prod` and `dev` namespaces).
3. Commit or keep in a values overlay per environment.

---

## Step 8: App secrets (DB passwords, etc.)

For apps that need a DB (e.g. python-django, java-springboot), the chart values use a placeholder password. For production:

- **Option A:** Create a Kubernetes Secret with the DB password and reference it in the Helm values (e.g. `env` with `valueFrom.secretKeyRef`). Use a SealedSecret or external secrets so you don’t commit plaintext.
- **Option B:** Inject the password via your CD pipeline (e.g. from a secret store) into the values or an overlay; do not commit the real value.

Same idea for any other app-specific secrets (API keys, etc.): use Kubernetes Secrets or your CD/secrets pipeline, not hardcoded values in the repo.

### DB host and connection strings

Set `DB_HOST` (or `WORDPRESS_DB_HOST` for foggypay/surge-plugin) in the app's Helm values to your real DB host (e.g. a Kubernetes Service name like `mysql.prod.svc.cluster.local` or an external host). Create the DB and user in MySQL; then store the password in a Secret and reference it as below.

### Example: passing DB password from a Kubernetes Secret

The app charts use the common `env` list. You can pass the password from a Secret instead of a literal value:

1. Create a Secret (e.g. with Sealed Secrets or from CI):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: myapp-db-secret
     namespace: prod
   type: Opaque
   stringData:
     password: "your-db-password"
   ```
2. In the app's values (e.g. under `env`), use `valueFrom` so the deployment gets the password from the Secret:
   ```yaml
   env:
     - name: DB_HOST
       value: "mysql.prod.svc.cluster.local"
     - name: DB_PASSWORD
       valueFrom:
         secretKeyRef:
           name: myapp-db-secret
           key: password
   ```
   The helm-common deployment template supports standard Kubernetes `env` entries (including `valueFrom.secretKeyRef`), so this will be rendered into the Deployment.

---

## Step 9: Optional – Kyverno

If you **do not** install Kyverno in the cluster:

- Remove or disable the Argo CD Application that deploys `kyverno-policies` (e.g. delete or don’t include `argocd-bootstrap/templates/toolchains/kyverno-policies.yaml` in your bootstrap so it never syncs). Otherwise Argo CD will keep trying to apply ClusterPolicies and may report errors.

---

## Step 10: Run the stack

1. **Bootstrap the cluster (if not already):**
   ```bash
   make bootstrap-k8s
   ```
   Use your inventory and vault password as documented in GETTING_STARTED.md.
2. **Install Argo CD:**
   ```bash
   make install-argocd
   ```
   Use `values-production.yaml` for production (Ingress + TLS); use `values-lab.yaml` for lab (NodePort).
3. **Bootstrap Argo CD app-of-apps:**  
   Run `scripts/misc/argocd_prerequisite.sh` after setting inside it (or via env): `ARGO_URL`, `ARGO_USER`, `ARGO_PASS`, `KUBECONFIG_PATH`, `GIT_REPO`. That creates the root Argo CD Application that syncs the rest from Git.
4. **Seal any other secrets** (e.g. Helm repo) using the same pattern as the Docker secret; put sealed YAML under `helmcharts/system-charts/argocd-config/sealed/` and commit only the sealed files.
5. Push your branch (with sealed secrets and `argocd-bootstrap/values.yaml` repo URL). Argo CD will sync. Fix any sync issues (e.g. missing namespaces, quotas) as they appear.

---

## Checklist summary

- [ ] `config/defaults.yaml` created and filled (not committed if it has secrets).
- [ ] `ansible/inventories/dev/hosts.ini` created and filled with your IPs.
- [ ] Ansible vault password file created; sensitive playbook vars encrypted.
- [ ] Docker registry credentials in `scripts/misc/.env`; sealed secret generated and placed in `argocd-config/sealed/dockerhub_secret.yaml`.
- [ ] Argo CD admin password set (bcrypt) in Argo CD values and/or config.
- [ ] `argocd-bootstrap/values.yaml` has your Git repo URL.
- [ ] Platform-admin RBAC subject set in `platform-admin-rbac.yaml`.
- [ ] LimitRange/ResourceQuota tuned in `limitrange-resourcequota.yaml`.
- [ ] App DB (and other) secrets provided via Kubernetes Secrets or CD, not hardcoded.
- [ ] Optional: Kyverno app disabled if you don’t use Kyverno.
- [ ] Cluster and Argo CD installed; bootstrap script run; Git pushed; Argo CD syncing.

---

**Important:** Nobody else (including AI assistants) can do these steps for you without access to your Docker account, cluster, and secrets. Use this guide locally with your own credentials; never paste real passwords or tokens into the repo or into a chat.

For first-time cluster and Argo CD setup, see also [GETTING_STARTED.md](GETTING_STARTED.md) and [SECURITY.md](SECURITY.md).
