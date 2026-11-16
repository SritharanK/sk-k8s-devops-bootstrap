# Prerequisites

This page lists what you need before you start: workstation tools for each path, hardware for the `lab` and `reference` profiles, the supported node operating systems, network access and your own fork. Read it before the [quick start](quick-start.md) or the [production setup](production-setup.md).

## Workstation tools

`mise.toml` at the repository root pins every command-line tool on this page except Docker, make and git, which come from your operating system. Install the pinned set from the repository root:

```bash
mise trust
mise install
```

The alternative is the devcontainer in `.devcontainer/devcontainer.json`, which ships the same pinned tools. This page does not repeat versions: `mise.toml` is the source, and [the support matrix](../reference/support-matrix.md) lists the versions of the components that run in the cluster.

### Lab path (kind)

| Tool | Why you need it |
| --- | --- |
| Docker, or another runtime kind supports | kind runs each Kubernetes node as a container. `make demo` also builds the `hello-api` image locally and loads it into the cluster. CI runs the demo with Docker. |
| kind | Creates the local cluster: one control plane and two workers, with Calico as the CNI. |
| kubectl | Reads cluster state, Application status and the Argo CD initial admin password. |
| helm | Installs Argo CD once and renders the charts. |
| make | Entry point for every workflow. `make help` lists the targets. |
| git | Clones the repository. The demo seeds an in-cluster Git server from your local `HEAD`, so Argo CD syncs your committed local tree. |

### Validation (every contributor)

| Tool | Why you need it |
| --- | --- |
| kubeconform | `make kubeconform` validates the rendered manifests against the Kubernetes and CRD schemas. |
| kyverno CLI | `make policy-test` runs the policy test suite and applies the policies to the rendered apps. |
| yq | The scripts read `clusters/<name>/cluster.yaml` with it, including `make validate-config`. |
| shellcheck | `make lint` checks every shell script. |
| cosign | Verifies image signatures and attestations by hand. See [supply chain](../security/supply-chain.md). With Docker, it also signs and attests the test images of `make policy-test-attestations`. |
| Node.js 22 or later, npm | `make lint` validates `catalog-info.yaml` with the Backstage entity validator pinned in `hack/catalog`. |

`make validate-config` runs `check-jsonschema` at a pinned version. When that tool is not installed, the script runs it through `uvx`, so `uv` must be on your `PATH`.

Contributors who change Ansible roles also run `make ansible-lint` and `make molecule`; Molecule uses Docker. The Python tools for that work are pinned in `ansible/requirements-dev.txt`. [CONTRIBUTING](../../CONTRIBUTING.md) covers the pre-commit hooks.

### RKE2 path (reference profile)

| Tool | Why you need it |
| --- | --- |
| ansible-core | Runs the playbooks behind `make preflight`, `make bootstrap-k8s` and `make rke2-uninstall`. |
| Ansible collections | Modules the roles use, pinned in `ansible/collections/requirements.yml`. |
| SSH client and key pair | Ansible connects to every node over SSH with key authentication. |
| A password manager | Holds the Ansible vault password. Ansible prompts for it; it is never stored in the repository. |

Install the collections once per workstation:

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

SSH access requirements:

- Every node accepts your public key for a user that can become root with `sudo`.
- `ansible/ansible.cfg` enables host key checking. Add each node's host key to `~/.ssh/known_hosts` after you compare its fingerprint with the one shown on the node's console or by your provisioning system.

[`ansible/README.md`](../../ansible/README.md) describes the roles, playbooks and variables in detail.

## Hardware

### Lab

| Resource | Guidance |
| --- | --- |
| Memory | About 8 GB free for Docker. On Docker Desktop, set the VM memory limit to at least that. |
| CPU | 4 CPUs. |
| Disk | 20 GB free for node images and container images. |
| Host ports | 80 and 443 free on the host. kind maps them to the cluster so the Gateway answers on `127.0.0.1`. |

On Linux hosts, multi-node kind clusters can exhaust the default inotify limits. The fix is in [kind's known issues](https://kind.sigs.k8s.io/docs/user/known-issues/).

### Reference

The reference profile needs three server nodes (control plane and etcd) and at least one agent node.

RKE2 documents a minimum of 2 CPUs and 4 GB of RAM per node and recommends at least 4 CPUs and 8 GB, with SSDs where possible. Server sizing grows with the number of agents; see the hardware section and VM sizing guide in [RKE2 requirements](https://docs.rke2.io/install/requirements).

Recommendation: size every node at RKE2's recommended values or above, and size the agents for the workloads you plan to run. The platform components run with several replicas in this profile and take capacity before any application does.

You also provide:

- A fixed registration address: a virtual IP or a TCP load balancer that forwards ports 9345 (RKE2 supervisor) and 6443 (Kubernetes API) to the three servers. See [RKE2 high availability](https://docs.rke2.io/install/ha).
- An address for the Gateway. Envoy Gateway exposes the Gateway `platform` through a Service of type LoadBalancer, which on bare metal needs a load balancer implementation, for example [MetalLB](https://metallb.io/) or the [kube-vip](https://kube-vip.io/) cloud provider. The alternative is NodePorts behind an external load balancer that forwards ports 80 and 443.
- A DNS zone in which you can create records for the platform domain.
- For a Let's Encrypt certificate, one of two setups: port 80 of the Gateway reachable from the internet for HTTP-01 with an explicit list of host names, or a DNS provider that cert-manager supports for DNS-01 with wildcard names. See [production setup](production-setup.md#11-issue-the-certificate).
- An S3-compatible bucket and credentials when you send etcd snapshots off the nodes (`rke2.etcdSnapshots.s3`).
- An OIDC identity provider for Argo CD single sign-on. See [Argo CD SSO](../security/argocd-sso.md).

## Supported node operating systems

| Distribution | Releases |
| --- | --- |
| Ubuntu | 24.04 |
| Debian | 12 and 13 |
| Rocky Linux | 9 |

The `preflight` role asserts this list and stops on any other release.

## Network

| Path | Ports and notes |
| --- | --- |
| Between nodes | The `firewall` role opens the ports RKE2 and the selected CNI need, per node role and limited to source CIDRs. The reference list is in [RKE2 networking requirements](https://docs.rke2.io/install/requirements#networking). Open the same ports on any firewall the role does not manage, such as cloud security groups or network firewalls between subnets. |
| Workstation to nodes | 22 (SSH) to every node for Ansible. 6443 to the registration address for kubectl. |
| Clients to the Gateway | 80 and 443 to the address of the Gateway `platform`. |
| Nodes to the internet | HTTPS to download RKE2 and pull images. Argo CD needs HTTPS to your Git host. This repository does not document an air-gapped install. |
| Lab workstation | Outbound HTTPS to pull images. Argo CD reads the in-cluster Git server, not GitHub. `*.localtest.me` resolves to `127.0.0.1` through public DNS; the [quick start](quick-start.md#name-resolution) covers offline machines. |

## Your fork

For a real cluster, the GitOps source is your fork: Argo CD reads the desired state from `git.repoURL` in the cluster file, and every change reaches the cluster through a commit to it. The kind demo is the exception: it seeds an in-cluster Git server from your local `HEAD`.

1. Fork the repository on GitHub. The image signature policy trusts the `build-image.yml` workflow on `main` of the repository in `git.repoURL`, so signatures from your fork are accepted once step 3 points `git.repoURL` at it. See [supply chain](../security/supply-chain.md).
2. Enable GitHub Actions on the fork. GitHub disables workflows on a new fork until you enable them in the Actions tab.
3. Replace the placeholders with your account or organisation. They appear only in the configuration an adopter owns:
   - `clusters/<name>/cluster.yaml` of each real cluster: `YOUR_ORG` in `git.repoURL`, and the lowercase `your-org` in `platform.imageRegistry` (image references allow no capitals). The [configuration reference](../reference/configuration.md) describes every key.
   - `envs/<env>/<app>/values.yaml`: the lowercase `your-org` in `image.repository`.
   - `tenants/<name>.yaml`, if you onboard tenants: `YOUR_ORG` in `sourceRepos`.

   Files that name the upstream repository `SritharanK/sk-k8s-devops-bootstrap` work unchanged in a fork, but you will want your own values there: the owners in `.github/CODEOWNERS`, `repo_url` and `site_url` in `mkdocs.yml`, the Go module path in `sample-services/hello-api/go.mod` and its imports, and `home` and `sources` in the `Chart.yaml` files.
4. A public fork needs no repository credentials. For a private fork, fill a copy of `bootstrap/repo-secret.example.yaml` outside the repository, or encrypt it with SOPS, and pass it to `make bootstrap-gitops` with `REPO_SECRET_FILE`; see [production setup](production-setup.md#8-prepare-the-secrets-path).

Next: the [quick start](quick-start.md) for the `lab` profile, or the [production setup](production-setup.md) for the `reference` profile.
