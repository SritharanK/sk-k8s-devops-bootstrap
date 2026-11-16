# Local demo on kind

`make demo` runs the lab profile on a local kind cluster: Argo CD, the app of apps, Envoy Gateway, cert-manager with a self-signed CA, Kyverno, Sealed Secrets and `hello-api` in `dev`, `stage` and `prod`, reachable at `https://hello-api.<env>.localtest.me`. `make e2e` runs the same bring-up followed by the Chainsaw suite in [`tests/e2e`](../../tests/e2e/README.md).

## Prerequisites

- Docker with about 6 GiB of memory and 4 CPUs available to it.
- kind v0.33.0, kubectl, Helm 4, jq, yq v4, git and curl. `hack/e2e/install-tools.sh` installs pinned, checksum-verified copies into `_out/tools/bin`.
- Host ports 80 and 443 free on 127.0.0.1, or set `DEMO_HTTP_PORT` and `DEMO_HTTPS_PORT`.

## Usage

```bash
make demo
```

```bash
export KUBECONFIG=_out/demo/demo/kubeconfig
kubectl -n argocd get applications
```

```bash
make demo-down
```

`hack/demo/up.sh --until cluster|git|argocd|bootstrap` stops after that stage, which is useful when working on one layer. Every step converges, so the script is safe to re-run on an existing cluster.

| Variable | Default | Meaning |
|---|---|---|
| `DEMO_CLUSTER` | `demo` | kind cluster name |
| `DEMO_GITOPS_CLUSTER` | `lab` | cluster definition in `clusters/<name>` |
| `DEMO_HTTP_PORT`, `DEMO_HTTPS_PORT` | `80`, `443` | host ports of the Gateway listeners |
| `DEMO_WORKERS` | `2` | kind worker nodes (0 to 2); fewer saves memory |
| `DEMO_TIMEOUT` | `1500` | seconds to wait for all Applications |
| `DEMO_INCLUDE_DIRTY` | `0` | `1` also publishes uncommitted changes of tracked files |
| `KIND_NODE_IMAGE` | from `kind/node-images.yaml` | kind node image |

## How it works

1. **Cluster.** `kind/cluster.yaml`: one control plane and two workers, default CNI disabled. The node image is the pinned image in `kind/node-images.yaml` that matches `cluster.kubernetesMinor` of the cluster definition. Host ports 80 and 443 map to NodePorts 30080 and 30443 of the Envoy proxy Service.
2. **CNI and metrics.** Calico from the upstream manifest, verified by SHA-256, so NetworkPolicies are enforced; metrics-server (RKE2 ships it, kind does not) so the prod HPA has metrics.
3. **Image.** `hello-api` is built from `sample-services/hello-api` and loaded into kind with a tag derived from the source tree.
4. **Git.** A Gitea instance in namespace `demo-git` receives the local `HEAD` plus one commit that points `envs/*/hello-api/values.yaml` at the loaded image, which is what the promotion step does with a registry image. Argo CD syncs from this server, so the demo needs no access to a hosted repository and nothing is pushed outside the cluster. The working tree is not modified.
5. **Argo CD and bootstrap.** `hack/argocd-install.sh`, then `hack/bootstrap-gitops.sh` with `REPO_URL` and `TARGET_REVISION` pointing at the in-cluster server. The override reaches every Application through the Helm values of the root Application.
6. **Checks.** The script waits until every Application is Synced and Healthy, then calls `https://hello-api.dev.localtest.me/readyz` through the Gateway, verified with the lab CA from the Gateway certificate Secret.

All commands use a dedicated kubeconfig in `_out/demo/<cluster>/kubeconfig`; the default kubeconfig and its current context are never used or changed.

## Recording

`hack/demo/record.sh` renders `hack/demo/demo.tape` with vhs into `_out/demo/recording/`.

## Troubleshooting

- **Port 80 or 443 in use:** `DEMO_HTTP_PORT=8080 DEMO_HTTPS_PORT=8443 make demo`, then use `https://hello-api.dev.localtest.me:8443/`.
- **Pods fail with "too many open files" on Linux:** raise `fs.inotify.max_user_watches` to 524288 and `fs.inotify.max_user_instances` to 512.
- **An Application stays OutOfSync or Degraded:** `hack/e2e/diagnostics.sh` writes cluster state and controller logs to `_out/e2e/<cluster>/diagnostics`.
