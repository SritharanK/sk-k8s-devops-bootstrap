# Kargo integration test

`run.sh` bootstraps the lab profile with Kargo on a local single-node kind cluster and drives a release of hello-api through `dev`, `stage` and `prod` the way [Promote with Kargo](../../../docs/how-to/promote-with-kargo.md) describes, with a local registry and the in-cluster Git server of the demo.

It is a laptop-scale test of the promotion design ([ADR 0012](../../../docs/adr/0012-kargo-promotion.md)). The last section lists what it cannot prove.

## Run

```bash
tests/integration/kargo/run.sh
```

| Variable | Default | Use |
|---|---|---|
| `KEEP_CLUSTER` | `0` | `1` keeps the kind cluster and the registry container after the run for inspection. |
| `MIN_FREE_GIB` | `5` | Free memory the Docker VM needs before the cluster is created. |
| `MEMORY_WAIT` | `0` | Seconds to wait for that memory; `0` fails at once. |
| `PHASE_TIMEOUT` | `1200` | Seconds for each long wait (platform convergence, Freight discovery, each promotion). |

Requirements: Docker with at least 5 GiB free in its VM, `kind`, `kubectl`, `helm`, `yq` (v4), `jq`, `git`, `openssl`, `curl` and `htpasswd`. The run pulls charts and images from their public registries and takes 25 to 40 minutes.

The script is idempotent: it deletes a leftover `it-kargo` cluster and registry before it starts, and deletes both on exit, also when a check fails (unless `KEEP_CLUSTER=1`). It never touches the current kubeconfig; the kubeconfig, the results and the port-forward logs go to `_out/integration/kargo/` (ignored by Git).

Last result (2026-11-16, commit 6080826): 22 of 22 checks passed in one run of about 20 minutes on kind v0.33.0 with Kubernetes 1.36.4; the cluster and the registry were deleted afterwards. Earlier runs found and fixed four harness issues (push path on Docker Desktop, credentials over HTTP, Promotion names) and one product bug: the pipelines synced before the app Applications, so the first automatic promotion could fail; they now sync in wave 11.

## What it does

1. Creates the kind cluster `it-kargo` from `kind.yaml` (one node, Kubernetes 1.36), with containerd reading registry hosts from `/etc/containerd/certs.d`, and installs metrics-server (chart 3.14.0), which RKE2 ships and kind does not.
2. Starts the registry container `it-kargo-registry` (distribution 3.1.2, pinned by digest) on the kind network with a self-signed certificate generated per run, and points containerd at it.
3. Builds hello-api twice from `sample-services/hello-api` with `VERSION` 0.1.0 and 0.1.1 (two different digests) and pushes `0.1.0`.
4. Starts the Gitea server of the demo (`hack/demo/manifests/git-server.yaml`, namespace `demo-git`) with an admin password generated per run, and creates a Gitea access token for Kargo. Both reach the pods through stdin only.
5. Publishes the committed `HEAD` to that server plus one test-only commit: `cluster.yaml` from this directory as `clusters/kargo-test/cluster.yaml`, and tag `0.1.0` without digest in `envs/{dev,stage,prod}/hello-api/values.yaml`. Uncommitted changes are not part of the test.
6. Creates the inputs that the lab profile expects from sealed secrets: the Kargo admin Secret `kargo/kargo-api` (random password, bcrypt hash) and, once the kargo chart has created its namespace, the Git credential `kargo-shared-resources/kargo-git`. Starts the Prometheus stand-in (`manifests/prometheus-stub.yaml`).
7. Runs `hack/bootstrap-gitops.sh kargo-test` against the in-cluster server and waits until every Application is Synced and Healthy.
8. Runs the checks below, prints a PASS/FAIL table and writes it to `_out/integration/kargo/results.txt`.

### Test-only deltas

`cluster.yaml` is `clusters/lab/cluster.yaml` with Kargo on and these changes, each marked `test-only` in the file:

| Delta | Reason |
| --- | --- |
| `platform.imageRegistry: it-kargo-registry:5000/your-org` | The local registry instead of ghcr.io. |
| `kyverno` and `kyverno-policies` off | Not needed for promotion; saves about 1 GiB. |
| `argo-rollouts` on, `analysis.prometheusAddress` pointing at the stand-in, its ServiceMonitor off | No monitoring stack on the laptop, so neither Prometheus nor the ServiceMonitor CRD exists. |
| `kargo.controller.allowCredentialsOverHTTP: true` | The in-cluster Git server is plain HTTP inside the cluster; Kargo refuses to send credentials over HTTP by default, and the real profiles keep that default. |
| Kargo pipelines: Warehouse interval 1 minute, `insecureSkipTLSVerify`, pull request provider `gitea`, timeout 30 minutes, verification forced on | Faster discovery, self-signed registry, the in-cluster Git server, verification without the monitoring toolchain. |

## What it proves

| Check | Evidence |
| --- | --- |
| Kargo under Pod Security `restricted` | Namespace `kargo` enforces `restricted` and every Kargo pod is Ready, so the wrapper's security context is sufficient. |
| Stage authorization | `hello-api-dev`, `-stage` and `-prod` carry `kargo.akuity.io/authorized-stage: kargo-hello-api:<env>` from the app templates. |
| Discovery | The Warehouse creates Freight for `0.1.0` and, after the push, for `0.1.1`, each with the digest that the registry serves for the tag. |
| `dev` auto-promotes | For both releases a Promotion to `dev` succeeds without any request. |
| Commit in Git | `main` on the Git server has `image.tag` and `image.digest` of the Freight in `envs/<env>/hello-api/values.yaml`, in a commit `chore(promote): hello-api <tag> to <env>`. |
| Argo CD deploys | `hello-api-<env>` is Synced and Healthy at that commit on both sources, and the Deployment runs `it-kargo-registry:5000/your-org/hello-api@<digest>`. Argo CD stays the deployer: Kargo only commits and requests a sync. |
| Verification | The Stage's verification (ClusterAnalysisTemplate `success-rate`, run by the Argo Rollouts controller) is Successful, and the Freight is marked verified in that stage. |
| `stage` waits | 90 seconds after `0.1.1` is verified in `dev`, `stage` has no Promotion and unchanged values. |
| Manual promotion | A Promotion of `0.1.1` to `stage` (what `kargo promote` creates) succeeds, with commit, sync and verification as above. |
| `prod` pull request | A Promotion to `prod` opens a pull request on the Git server and stays Running while `main` is unchanged. After the merge it succeeds, and Argo CD runs the digest in `prod` at the merge commit. |

## What it cannot prove

- GitHub specifics: the `github` provider of `git-open-pr`, branch rulesets, CODEOWNERS review and the bypass for direct pushes. The test uses Gitea and merges the pull request through its API.
- The PromQL of `success-rate` against real metrics. The stand-in answers every query with a fixed sample; the test proves that Kargo runs the platform template with the app's Service and namespace and gates on its result. The canary analysis itself is covered by the argo-rollouts chart.
- SSO and group mapping. The lab profile uses the local admin account; OIDC follows the same identity provider setup that `tests/integration/sso` proves for Argo CD, but Kargo's login is not exercised.
- The reference profile: ExternalSecrets for the credentials, two API replicas, the prod sync window, and admission with image signatures and vulnerability attestations (the images here are unsigned and Kyverno is off).
- Release tags created by `build-image.yml`. The test pushes the tags directly.
