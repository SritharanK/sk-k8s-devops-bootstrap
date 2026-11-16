# Quick start: the lab profile on kind

This tutorial runs the platform on your workstation with one command: a kind cluster, Argo CD, the platform toolchains and the `hello-api` sample in `dev`, `stage` and `prod`. It is for evaluators and contributors and takes about ten minutes on the first run. For a real cluster, follow the [production setup](production-setup.md).

Before you start, check the lab path in [prerequisites](prerequisites.md): Docker running, about 8 GB of memory free for it, and host ports 80 and 443 free.

## 1. Clone the repository

Clone your fork (see [your fork](prerequisites.md#your-fork)) or the upstream repository:

```bash
git clone https://github.com/SritharanK/sk-k8s-devops-bootstrap.git
cd sk-k8s-devops-bootstrap
```

## 2. Install the tools

```bash
mise trust
mise install
```

Or open the repository in the devcontainer, which ships the same pinned tools.

## 3. Start the demo

```bash
make demo
```

`make demo` runs `hack/demo/up.sh`, which does the following in order:

1. Creates a kind cluster with one control plane and two workers, with Calico as the CNI so NetworkPolicies are enforced. kind maps host ports 80 and 443 to the Gateway. The kind cluster is named `demo` (`DEMO_CLUSTER`). The demo writes its kubeconfig to `_out/demo/demo/kubeconfig` and leaves your own kubeconfig untouched.
2. Builds the `hello-api` image from `sample-services/hello-api` and loads it into the kind nodes. Image signature verification is off in the `lab` profile for this reason.
3. Starts an in-cluster Git server (Gitea, namespace `demo-git`) and seeds it from your local `HEAD`. Argo CD syncs from that server, so the demo runs your local tree, including commits you have not pushed. Uncommitted changes are not part of it.
4. Runs the GitOps bootstrap for cluster `lab`, as `make bootstrap-gitops CLUSTER=lab` does, with the repository URL pointing at the in-cluster Git server. It installs Argo CD from the wrapper chart `helmcharts/system-charts/argo-cd` with the `lab` values (Helm release `argocd` in namespace `argocd`), then applies the AppProjects and the root Application. From then on the self-managed `argo-cd` Application owns Argo CD.
5. Argo CD renders `argocd-bootstrap` with `clusters/lab/cluster.yaml` and creates one Application per enabled toolchain. They converge in sync-wave order: CRDs, cert-manager and Sealed Secrets first, then Kyverno, then Envoy Gateway with the namespaces and network policies, then the Kyverno policies, the platform Gateway and the Argo CD route. Optional components run only when the cluster file enables them.
6. Deploys `hello-api` to `dev`, `stage` and `prod` in the last wave.
7. Prints the URLs and the next steps.

[GitOps structure](../architecture/gitops.md) explains the app of apps, the AppProjects and the sync waves.

## 4. Point kubectl at the demo cluster

```bash
export KUBECONFIG="$PWD/_out/demo/demo/kubeconfig"
kubectl get nodes
```

Every command below assumes this `KUBECONFIG`.

## 5. Open Argo CD and the sample

| What | URL |
| --- | --- |
| Argo CD | `https://argocd.localtest.me` |
| `hello-api` in `dev` | `https://hello-api.dev.localtest.me` |
| `hello-api` in `stage` | `https://hello-api.stage.localtest.me` |
| `hello-api` in `prod` | `https://hello-api.prod.localtest.me` |

Log in to Argo CD as `admin`. The `lab` profile uses the initial admin password, which you read with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

The Gateway certificate `platform-tls` covers `localtest.me`, `*.localtest.me` and `*.<env>.localtest.me` for each environment. It comes from the CA-backed `selfsigned` ClusterIssuer, so your browser shows a warning. For curl, export the CA certificate (`ca.crt`) from the Secret `platform-tls` in `envoy-gateway-system` and pass it with `--cacert`:

```bash
kubectl -n envoy-gateway-system get secret platform-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-ca.crt
curl --cacert lab-ca.crt https://hello-api.dev.localtest.me/readyz
```

## Name resolution

`*.localtest.me` resolves to `127.0.0.1` through public DNS, so the URLs work without local DNS changes. A machine without internet access, or behind a resolver that drops public answers pointing at loopback addresses (DNS rebinding protection), needs a hosts entry. Hosts files do not support wildcards, so list every name:

```text
127.0.0.1 argocd.localtest.me hello-api.dev.localtest.me hello-api.stage.localtest.me hello-api.prod.localtest.me
```

The file is `/etc/hosts` on Linux and macOS and `C:\Windows\System32\drivers\etc\hosts` on Windows.

## 6. Try it

Watch the Applications converge. Every row should reach `Synced` and `Healthy`:

```bash
kubectl -n argocd get applications --watch
```

Try a policy denial. Ask for a privileged pod in `stage`:

```bash
kubectl -n stage run privileged-test --image=busybox:1.37 --privileged --restart=Never -- sleep 3600
```

The API server rejects the request with a `Forbidden` error. Two layers cover this case in `stage`: the Pod Security Standards `restricted` label on the namespace and the Kyverno policies in Enforce mode. The message names the control that rejected the pod first. The [threat model](../security/threat-model.md) lists the other denial cases and the expected output, and [security controls](../security/controls.md) shows which control enforces what in each environment.

## 7. Run the end-to-end checks

```bash
SKIP_UP=1 KEEP=1 make e2e
```

`make e2e` runs `hack/e2e/run.sh`: the same assertions the CI job `e2e-kind` runs on every pull request. They check that all Applications are Synced and Healthy within a time budget, that `hello-api` answers through the Gateway, that privileged, root and `:latest` pods are denied, and that cross-namespace traffic is blocked. `SKIP_UP=1` runs them against the running demo cluster; without it, the script runs `hack/demo/up.sh` first. `KEEP=1` keeps the cluster; without it, the script deletes the cluster at the end and step 8 is not needed. [CI and CD](../architecture/ci-cd.md) describes the job.

## 8. Remove the demo

```bash
make demo-down
```

`make demo-down` runs `hack/demo/down.sh` and deletes the kind cluster with everything in it.

## When something fails

[Troubleshooting](../operations/troubleshooting.md) lists symptoms, checks and fixes. Check the [lab prerequisites](prerequisites.md#lab) as well: kind cannot create the cluster while another process holds port 80 or 443, and with too little memory for Docker the platform pods stay Pending.

## Next steps

- [Add an app](../operations/add-an-app.md) on top of `helm-common`.
- [Promotion](../operations/promotion.md): how a digest moves from `dev` to `stage` and `prod`.
- [Production setup](production-setup.md): the `reference` profile on RKE2.
