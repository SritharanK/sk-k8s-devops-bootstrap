# Production setup: the reference profile on RKE2

This guide takes a fork of the repository to a running `reference` cluster: RKE2 on your own machines, Argo CD with single sign-on, and the platform toolchains managed from Git. It is for platform engineers who operate the cluster. Read [prerequisites](prerequisites.md) first; the [quick start](quick-start.md) is the faster way to evaluate the platform.

## Scope of the reference profile

The `reference` profile is one RKE2 cluster:

- three server nodes behind a fixed registration address, plus one or more agent nodes;
- the RKE2 CIS profile, switched on with `rke2.cisProfile`;
- scheduled etcd snapshots, optionally copied to S3;
- the environments `dev`, `stage` and `prod` as namespaces in that cluster, separated by AppProjects, Pod Security Standards labels, Kyverno policies, NetworkPolicies and quotas;
- Argo CD with OIDC single sign-on, secrets from OpenBao through External Secrets Operator (ESO), and in `stage` and `prod` image signature verification and the vulnerability attestation gate;
- Longhorn storage, the monitoring stack, Argo Rollouts and Kargo as the promotion engine, all switched on in the shipped cluster file.

What it is not:

- It is not a multi-cluster fleet. `dev`, `stage` and `prod` share one control plane, and namespace isolation is not a cluster boundary; see [known limitations](../security/known-limitations.md). A two-cluster topology (nonprod and prod with a hub Argo CD) is implemented in the bootstrap chart as hub mode and not tested in CI; the procedure is in [`bootstrap/README.md`](../../bootstrap/README.md).
- It does not create machines by default. You provide the nodes, DNS, the registration address, an address for the Gateway (see [prerequisites](prerequisites.md#reference)) and the S3 bucket. An optional OpenTofu example under `infra/` creates machines at one cloud provider and renders the reference inventory; nothing else depends on it.

[ADR 0005](../adr/0005-lab-and-reference-profiles.md) records why the platform has these two profiles.

## 1. Fork and clone

Fork the repository and prepare it as described in [your fork](prerequisites.md#your-fork), then clone it:

```bash
git clone https://github.com/YOUR_ORG/sk-k8s-devops-bootstrap.git
cd sk-k8s-devops-bootstrap
mise trust
mise install
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

## 2. Describe the cluster

Edit `clusters/reference/cluster.yaml`. The [configuration reference](../reference/configuration.md) describes every key; these are the ones you set for a real install:

| Key | Set it to |
| --- | --- |
| `cluster.domain` | Your platform domain. Routes become `argocd.<domain>` and `<app>.<env>.<domain>`. |
| `git.repoURL` | The URL of your fork. |
| `platform.imageRegistry` | The registry and namespace of your images, for example `ghcr.io/your-org` with your account. |
| `rke2.version` | An exact RKE2 release in the form `v<major>.<minor>.<patch>+rke2r<n>`; `make preflight` rejects `CHANGE_ME`. [Upgrade RKE2](../operations/upgrade-rke2.md) covers changing it later. |
| `rke2.registrationAddress` | The virtual IP or load balancer address in front of the three servers. |
| `rke2.cni` | `canal`, `calico` or `cilium`. All three enforce NetworkPolicy. |
| `rke2.etcdSnapshots` | `schedule`, `retention`, and under `s3` the `enabled` flag, `endpoint`, `bucket`, `folder` and `region`. The S3 credentials do not go here; they go into the Ansible vault in step 4. |
| `platform.issuer` | `letsencrypt-staging` for the first install. Step 11 explains the switch to `letsencrypt`. |
| `platform.acme.solver` | `http01` (the default for ACME issuers) with the explicit list `platform.gateway.hostnames`, or `dns01` with a provider block in `platform.acme.dns01` for wildcard names. Step 11 explains both modes. |
| `platform.certManagerEmail` | The contact address for the ACME account. |
| `platform.groups` | The group names in your identity provider for `admins`, `deployers` and `viewers`. |

Validate the file in strict mode, which fails on any remaining placeholder, then commit and push it. `CLUSTER=reference` limits the check to this file; without it, strict mode also checks the lab file and `tenants/team-a.yaml`, which keep their placeholders. Argo CD reads this file from Git, so the cluster only sees what is pushed.

```bash
make validate-config STRICT=1 CLUSTER=reference
git add clusters/reference/cluster.yaml
git commit -m "chore: configure the reference cluster"
git push
```

## 3. Write the inventory

```bash
cp ansible/inventories/reference/hosts.yml.example ansible/inventories/reference/hosts.yml
```

`hosts.yml` is gitignored. Put the three servers in the group `rke2_servers` and the agents in `rke2_agents`. [`ansible/inventories/README.md`](../../ansible/inventories/README.md) describes the inventory layout and the group variables.

Host key checking is on. Add each node's host key to `~/.ssh/known_hosts` after you verify its fingerprint, as described in [prerequisites](prerequisites.md#rke2-path-reference-profile).

## 4. Store the Ansible secrets

Secrets for the playbooks live in a gitignored vault file. Plain variables in the inventory's `group_vars/all/` refer to `vault_`-prefixed variables in that file, so every variable name stays readable without the vault password.

```bash
cp ansible/inventories/reference/group_vars/all/vault.yml.example ansible/inventories/reference/group_vars/all/vault.yml
"${EDITOR:-vi}" ansible/inventories/reference/group_vars/all/vault.yml
ansible-vault encrypt --vault-id reference@prompt ansible/inventories/reference/group_vars/all/vault.yml
```

Fill in every value the example file lists, including the etcd snapshot S3 credentials when `rke2.etcdSnapshots.s3.enabled` is true. The vault password is never stored in the repository or in a password file next to it: the Make targets run Ansible with `--vault-id <profile>@prompt`, so Ansible asks for it. To read it from a password manager instead, set `ANSIBLE_VAULT_IDENTITY_LIST` to a vault ID whose source is a script that prints the password. [`ansible/README.md`](../../ansible/README.md) has the details, [secrets handling](../security/secrets-handling.md) explains the layout, and [secret rotation](../operations/secret-rotation.md) covers changing these values later.

## 5. Run the preflight checks

```bash
make preflight CLUSTER=reference
```

`make preflight` runs `ansible/playbooks/preflight.yml` against `ansible/inventories/reference/hosts.yml`. It checks that every node runs a [supported operating system](prerequisites.md#supported-node-operating-systems), that swap is off, that the required kernel modules and sysctl settings are available, and that no placeholder such as `rke2.version: CHANGE_ME` is left. Fix every failure before you continue.

## 6. Install RKE2

```bash
make bootstrap-k8s CLUSTER=reference
```

`make bootstrap-k8s` runs `ansible/playbooks/site.yml` with the roles `base`, `firewall` and `rke2` (and `nfs_server` when you enable it):

1. `base` prepares the operating system.
2. `firewall` opens the ports RKE2 and the selected CNI need, per node role and limited to source CIDRs.
3. `rke2` installs the exact release from `rke2.version`. The first server initialises the cluster, the other two servers join one at a time through the registration address, then the agents join. It applies the CIS profile when `rke2.cisProfile` is true and configures the etcd snapshot schedule.

The same target applies later changes to the nodes, including RKE2 upgrades; see [upgrade RKE2](../operations/upgrade-rke2.md).

## 7. Use the kubeconfig

The playbook fetches the admin kubeconfig to `ansible/data/kubeconfig-reference.yaml` with mode 0600 and the server address set to the registration address. Never commit it.

```bash
export KUBECONFIG="$PWD/ansible/data/kubeconfig-reference.yaml"
kubectl get nodes -o wide
```

All three servers and every agent should be `Ready`.

Recommendation: treat this kubeconfig as a break-glass credential and keep it offline. Make changes through Git and Argo CD.

## 8. Prepare the secrets path

In this profile, platform and application secrets come from OpenBao through External Secrets Operator, through one shared `ClusterSecretStore` named `openbao`. Both are toolchains, so they arrive with the GitOps bootstrap in the next step. The few secrets needed before they run are bootstrap secrets, encrypted with SOPS and age.

Read [secrets handling](../security/secrets-handling.md) before you continue. It covers how the `ClusterSecretStore` authenticates, how to restrict it per environment, and the bootstrap secrets. OpenBao initialisation, unsealing and where the unseal material is kept are in the [OpenBao chart README](../../helmcharts/system-charts/openbao/README.md). A `kind: Secret` with data never goes into the repository; CI rejects one outside Helm `templates/` directories and `*.example.yaml` files.

OpenBao keeps its Raft data on PersistentVolumes, and RKE2 ships no StorageClass. The reference cluster file therefore enables Longhorn as the default class; the `base` role installs its node prerequisites (open-iscsi, the NFS client). Longhorn's backup target needs the Secret `longhorn-s3-credentials` in `longhorn-system` (see [`helmcharts/system-charts/longhorn/README.md`](../../helmcharts/system-charts/longhorn/README.md)). To use another storage provider instead, set `toolchains.longhorn.enabled: false` and make sure a default StorageClass exists before step 9.

A public fork needs no repository credentials. For a private fork, copy `bootstrap/repo-secret.example.yaml` to a file outside the repository and fill in a read-only deploy key, or encrypt the filled copy with SOPS and age into `bootstrap/secrets/reference/repo-secret.sops.yaml`. The next step applies it through `REPO_SECRET_FILE`.

## 9. Bootstrap GitOps

```bash
make bootstrap-gitops CLUSTER=reference
kubectl -n argocd get applications --watch
```

For a private fork, prefix the first command with `REPO_SECRET_FILE=<path of the Secret file>`.

`make bootstrap-gitops` runs `hack/bootstrap-gitops.sh`, which:

1. validates `clusters/reference/cluster.yaml`;
2. installs Argo CD with `hack/argocd-install.sh`: the wrapper chart `helmcharts/system-charts/argo-cd` as Helm release `argocd` in namespace `argocd`, with its `reference` values (several replicas, Redis with authentication, the UI behind the Gateway at `argocd.<domain>`);
3. applies the repository Secret from `REPO_SECRET_FILE`, when it is set, decrypting a `*.sops.yaml` file with SOPS;
4. applies the AppProjects and the root Application;
5. waits until the root Application is Synced.

The script is idempotent; run it again after a change to the `bootstrap/` chart or to the git settings. A separate `make install-argocd` is not needed. The root Application renders `argocd-bootstrap` with `clusters/reference/cluster.yaml` and creates the toolchain Applications, which converge in sync-wave order, then the `hello-api` Applications for `dev`, `stage` and `prod`. From then on the self-managed `argo-cd` Application owns Argo CD, and every later change goes through Git; see [upgrade Argo CD](../operations/upgrade-argocd.md). [GitOps structure](../architecture/gitops.md#bootstrap) explains the bootstrap, the waves and the AppProjects.

When OpenBao is running, initialise and unseal it and configure the Kubernetes auth role as the [OpenBao chart README](../../helmcharts/system-charts/openbao/README.md) describes. The Applications that depend on secrets become Healthy once the `ClusterSecretStore` `openbao` is ready.

The `apps-prod` project has a sync window in this profile. Outside it, `prod` Applications wait for the window instead of syncing; see [promotion](../operations/promotion.md).

## 10. Give the Gateway an address and create the DNS records

Envoy Gateway exposes the Gateway `platform` through a Service of type LoadBalancer. On bare metal, nothing assigns that Service an address unless the cluster has a load balancer implementation, for example [MetalLB](https://metallb.io/) or the [kube-vip](https://kube-vip.io/) cloud provider. The alternative is to expose the Service through NodePorts behind an external load balancer that forwards ports 80 and 443.

Read the address of the Gateway `platform`:

```bash
kubectl -n envoy-gateway-system get gateway platform -o jsonpath='{.status.addresses[*].value}'
```

Create DNS records that point to it: a wildcard record `*.<domain>`, or one record per host name. Use an A or AAAA record for an IP address and a CNAME for a host name. If the address stays empty, see [troubleshooting](../operations/troubleshooting.md).

## 11. Issue the certificate

The Gateway serves one Certificate, `platform-tls` (Secret `platform-tls` in `envoy-gateway-system`), on its `https` listener. The ClusterIssuer that signs it is the one named in `platform.issuer`; the ClusterIssuer names equal the values `selfsigned`, `letsencrypt-staging` and `letsencrypt`. With a Let's Encrypt issuer, the names on the certificate depend on `platform.acme.solver`:

| `platform.acme.solver` | Names on `platform-tls` | What you provide |
| --- | --- | --- |
| `http01` (default) | Exactly the host names in `platform.gateway.hostnames`; no wildcard | Each host name in DNS, pointing to the Gateway, and port 80 reachable from the ACME servers |
| `dns01` | `<domain>`, `*.<domain>` and `*.<env>.<domain>` for every environment | A DNS provider that cert-manager supports, configured in `platform.acme.dns01`, and its credential in a Secret |

Let's Encrypt issues wildcard certificates only through the DNS-01 challenge ([challenge types](https://letsencrypt.org/docs/challenge-types/)). A wildcard covers one label, so `*.<domain>` alone does not cover `hello-api.dev.<domain>`; that is why the `dns01` mode adds `*.<env>.<domain>` for every environment.

In `http01` mode, cert-manager solves each challenge with its `gatewayHTTPRoute` solver: a temporary HTTPRoute on the listener `http` of Gateway `platform` in `envoy-gateway-system`, served by a short-lived solver pod. That listener accepts routes only from `envoy-gateway-system` and otherwise redirects plain HTTP to HTTPS with a 301. A Kyverno `PolicyException` admits the solver pods. List every host name the Gateway serves, including `argocd.<domain>`; the render fails when the list is empty, contains a wildcard or names a host outside `cluster.domain`:

```yaml
platform:
  issuer: letsencrypt-staging
  acme:
    solver: http01
  gateway:
    hostnames:
      - argocd.platform.example.com
      - grafana.platform.example.com
      - kargo.platform.example.com
      - hello-api.dev.platform.example.com
      - hello-api.stage.platform.example.com
      - hello-api.prod.platform.example.com
```

A new app host name is a change to this list; until it is merged and cert-manager has reissued the certificate, the new route serves a certificate that does not cover its name.

In `dns01` mode, `platform.acme.dns01` has the shape `{provider, config, credentialsSecretRef}`: the cert-manager DNS-01 provider, its non-secret settings, and a reference to a Secret in the `cert-manager` namespace, which you deliver like any other runtime secret. The chart renders `credentialsSecretRef` as the provider's own reference field, `tsigSecretSecretRef` for RFC 2136. For example, with an RFC 2136 DNS server:

```yaml
platform:
  issuer: letsencrypt-staging
  acme:
    solver: dns01
    dns01:
      provider: rfc2136
      config:
        nameserver: 192.0.2.53
        tsigKeyName: CHANGE_ME
        tsigAlgorithm: HMACSHA512
      credentialsSecretRef:
        name: rfc2136-tsig
        key: tsig-secret
```

With `letsencrypt-staging` set in step 2, check that the certificate is issued:

```bash
kubectl -n envoy-gateway-system get certificate platform-tls
```

When `READY` is `True`, set `platform.issuer: letsencrypt` in `clusters/reference/cluster.yaml`, run `make validate-config STRICT=1 CLUSTER=reference`, commit and push. Browsers do not trust staging certificates; that is expected before the switch. The design behind these modes is recorded in [ADR 0003](../adr/0003-gateway-api-with-envoy-gateway.md#tls-certificate).

## 12. Configure SSO and disable the admin account

Single sign-on needs the DNS record and a trusted certificate for `argocd.<domain>`, so it comes after steps 10 and 11. Follow [Argo CD SSO](../security/argocd-sso.md):

1. Register Argo CD as an OIDC client in your identity provider, directly or through Dex.
2. Add the issuer and client settings to the Argo CD wrapper's `reference` values as that page describes, commit and push. The self-managed `argo-cd` Application applies the change.
3. Log in with SSO as a member of the admins group. The `argocd` CLI reaches the server through the Gateway only with gRPC-Web: `argocd login argocd.<domain> --sso --grpc-web`.
4. Make sure the local `admin` account is disabled (`admin.enabled: false` in the reference values) and commit if you had to change it.

The role mapping comes from `platform.groups` in the cluster file:

| Group | Argo CD role | Access |
| --- | --- | --- |
| `admins` | `role:admin` | Full access. |
| `deployers` | `role:deployer` | Get, sync, actions and logs in the app projects. |
| `viewers` | `role:readonly` | Read-only access. |

`policy.default` is empty, so a user in none of these groups gets no access after login.

### Kargo, Grafana and the vulnerability gate

The shipped cluster file also turns on `kargo` and `monitoring`, and the `reference` policies require vulnerability attestations:

- Kargo: register its OIDC client and deliver the Git credential it pushes and opens pull requests with, as [promote with Kargo](../how-to/promote-with-kargo.md#enable) describes. That page also covers the branch ruleset: Kargo commits `dev` and `stage` directly. With Kargo enabled, `build-image.yml` and `promote.yml` stop writing the environment files; set the repository variable `PROMOTION_ENGINE` to `workflows` to keep them as the writer.
- Grafana: the admin credentials come from OpenBao through an ExternalSecret (`grafanaAdmin` in the `monitoring` chart). Single sign-on is prepared but off in `helmcharts/system-charts/monitoring/values-reference.yaml` (`auth.generic_oauth`) until its client exists.
- Vulnerability gate: `stage` and `prod` admit an image only with a Trivy attestation younger than seven days. The daily `rescan` job of `build-image.yml` renews it for the digests in `envs/`; when that job stops, new pods in `stage` and `prod` are denied after seven days ([supply chain](../security/supply-chain.md)).

## 13. Verify

```bash
DOMAIN=platform.example.com
kubectl get nodes
kubectl -n argocd get applications
curl "https://hello-api.dev.${DOMAIN}/readyz"
```

Set `DOMAIN` to your `cluster.domain`. Expect every node `Ready`, every Application `Synced` and `Healthy` (`prod` Applications may wait for the sync window), and an answer from `hello-api` without certificate errors. Open `https://argocd.<domain>` and log in with SSO.

Check that etcd snapshots are taken, on any server node:

```bash
sudo rke2 etcd-snapshot list
```

[Backup and restore](../operations/backup-and-restore.md) covers restores and the restore drill.

## Checklist

- [ ] The fork keeps the name `sk-k8s-devops-bootstrap`, and GitHub Actions is enabled on it.
- [ ] `make validate-config STRICT=1 CLUSTER=reference` passes and the cluster file is pushed.
- [ ] Every node runs a supported operating system and its host key is in `known_hosts`.
- [ ] The registration address forwards ports 9345 and 6443 to the three servers.
- [ ] `hosts.yml` lists three hosts in `rke2_servers` and at least one in `rke2_agents`.
- [ ] `vault.yml` is encrypted with the `reference` vault ID, and the vault password is in a password manager, not in the repository.
- [ ] `make preflight CLUSTER=reference` passes without failures.
- [ ] All nodes are `Ready` after `make bootstrap-k8s CLUSTER=reference`.
- [ ] `ansible/data/kubeconfig-reference.yaml` is kept offline as a break-glass credential and never committed.
- [ ] OpenBao is initialised, and its unseal material is stored as secrets handling requires.
- [ ] Every Application is `Synced` and `Healthy`.
- [ ] The Gateway has an address, from a load balancer implementation or an external load balancer.
- [ ] The DNS records point to the Gateway address.
- [ ] `platform.acme.solver` matches your DNS setup, and with `http01` every served host name is in `platform.gateway.hostnames`.
- [ ] The certificate `platform-tls` comes from `letsencrypt`, not the staging issuer.
- [ ] SSO login works for each group in `platform.groups` with the expected role, and the local `admin` account is disabled.
- [ ] Kargo has its OIDC client and Git credential, and the promotion engine (`PROMOTION_ENGINE`, or Kargo by default with this cluster file) is the one you intend.
- [ ] The `rescan` job of `build-image.yml` runs daily, so the vulnerability attestations in `stage` and `prod` stay younger than seven days.
- [ ] `hello-api` answers on `https://hello-api.dev.<domain>/readyz`.
- [ ] An etcd snapshot exists, and the copy in S3 is present when S3 is enabled.
- [ ] A restore drill is scheduled, as [backup and restore](../operations/backup-and-restore.md) describes.
