# Reference profile integration test

`run.sh` bootstraps the reference profile on a local three-node kind cluster and checks that the GitOps layer behaves as designed: high availability of the control components, the secrets chain from OpenBao to a Kubernetes Secret, the AppProject boundaries, the sync waves and the prod sync window.

It is a laptop-scale test of the GitOps design. It is not a test of an RKE2 HA cluster; the last section lists what only a real one can prove.

## Run

```bash
tests/integration/reference/run.sh
```

| Variable | Default | Use |
|---|---|---|
| `KEEP_CLUSTER` | `0` | `1` keeps the kind cluster after the run for inspection. |
| `MIN_FREE_GIB` | `6` | Free memory the Docker VM needs before the cluster is created. |
| `MEMORY_WAIT` | `0` | Seconds to wait for that memory; `0` fails at once. |
| `PHASE_TIMEOUT` | `1500` | Seconds for each long wait (OpenBao pods, all Applications healthy). |

Requirements: Docker with at least 6 GiB free in its VM, `kind`, `kubectl`, `helm`, `yq` (v4), `jq`, `git` and `openssl`. The run pulls charts and images from their public registries and takes 20 to 35 minutes.

The script is idempotent: it deletes a leftover `it-reference` cluster before it starts, and it deletes the cluster on exit, also when a check fails (unless `KEEP_CLUSTER=1`). It never touches the current kubeconfig; the cluster's kubeconfig, the results and the port-forward logs go to `_out/integration/reference/` (ignored by Git).

Last result (2026-11-16): not green in a single run. Across runs, the Argo CD HA, Kyverno HA, AppProject, sync wave and prod sync window checks passed, and so did the External Secrets chain (ClusterSecretStore `openbao` Ready, an ExternalSecret in `dev` received the value written to OpenBao). The three-voter Raft check and the unseal of every follower have not passed together in one run. The OpenBao unseal is intermittent: in some runs a follower (`openbao-1` or `openbao-2`) does not report unsealed within the 300-second wait of step 6, and the run stops there: after the two sync wave checks that run while OpenBao is sealed, before all later checks. The cause is not established and the issue is open. Until one run passes end to end, this harness is partial evidence for the reference profile.

## What it does

1. Creates the kind cluster `it-reference` from `kind.yaml`: one control-plane node and two workers on Kubernetes 1.36. The control-plane taint is removed, as on RKE2 servers, so that the hard anti-affinity of redis-ha and of the OpenBao Raft voters finds three nodes. It then installs metrics-server (chart 3.14.0, with `--kubelet-insecure-tls` for kind's self-signed kubelet certificates): RKE2 ships it, kind does not, and the hello-api HorizontalPodAutoscaler in prod is Degraded without it.
2. Builds `ghcr.io/your-org/hello-api` from `sample-services/hello-api` with two tags (`ref-<commit>` and `ref-<commit>-b`) and loads both into the nodes.
3. Starts a Gitea server in the namespace `ref-git` (`manifests/git-server.yaml`), with an admin password generated per run and passed through stdin.
4. Publishes the committed `HEAD` to that server, plus one test-only commit: `cluster.yaml` from this directory as `clusters/ref-test/cluster.yaml`, the `ref-<commit>` tag in `envs/{dev,stage,prod}/hello-api/values.yaml`, and a prod sync window that is open at the time of the run. Uncommitted changes are not part of the test.
5. Runs `hack/bootstrap-gitops.sh ref-test` with `REPO_URL` pointing at the in-cluster server and `WAIT=0`: the root Application cannot finish before OpenBao is unsealed.
6. Checks the wave gate while OpenBao is sealed, then initialises and unseals OpenBao (test-only: one key share, kept in a private temporary file and passed to the pods on stdin) and configures it as the OpenBao chart README describes: KV v2 at `secret`, Kubernetes auth, the policy `external-secrets-read` and the role `external-secrets`.
7. Waits until every Application is Synced and Healthy, runs the checks below, prints a PASS/FAIL table and writes it to `_out/integration/reference/results.txt`.

### Test-only deltas

`cluster.yaml` is `clusters/reference/cluster.yaml` with the changes a laptop needs. Each is marked `test-only` in the file.

| Delta | Reason |
|---|---|
| Issuer `selfsigned` instead of `letsencrypt` | No public DNS name for ACME HTTP-01. |
| OpenBao data and audit volumes on the StorageClass `standard` | kind's local-path provisioner instead of Longhorn. |
| Gateway proxy Service `NodePort` | kind has no LoadBalancer implementation. |
| `kyverno-policies` image verification off | The locally built image carries no signature. |

Further test-only steps live in `run.sh` only: the in-cluster Git server, the one-share OpenBao initialisation, and the sync windows written into the published copy of `argocd-bootstrap/values.yaml`.

## What it proves

| Check | Evidence |
|---|---|
| Argo CD HA | `argocd-server`, `argocd-repo-server` and `argocd-applicationset-controller` with 2 ready replicas each, redis-ha with 3 Redis servers and 3 HAProxy replicas, every workload ready, pods on all 3 nodes. The `argo-cd` Application manages the installation from Git. |
| Kyverno HA | Admission controller with 3 ready replicas, background, cleanup and reports controllers ready, pods on at least 2 nodes. |
| Kyverno enforces in stage | A server-side dry run of a pod that meets Pod Security `restricted` but uses the tag `latest` is denied in `stage` by the policy engine, not by Pod Security. |
| OpenBao HA | All three pods unsealed, three Raft voters once autopilot has promoted the last server to join (stabilization time 10 s), the `openbao` Application Healthy. |
| External Secrets | Controllers ready, ClusterSecretStore `openbao` Ready over TLS with Kubernetes auth, and an ExternalSecret in `dev` materialises the value written to OpenBao during the run. |
| Sync waves | While OpenBao (wave 4) is sealed, every Application of waves 0 to 3 reports Healthy and no wave 10 Application exists in any sample over 120 seconds. After the unseal, the creation timestamps of the child Applications follow the wave order. Argo CD does not refresh an Application on status-only changes (default `ignoreResourceUpdates` on `/status`), so a wave 0 Application can show a stale Progressing for up to one reconcile period (120 s plus jitter) after its CRDs are Established; the check allows 300 seconds for that. |
| AppProjects | `apps-dev`, `apps-stage` and `apps-prod` each allow one namespace and no cluster-scoped kind; `default` is locked. An Application in `default`, an `apps-dev` Application aimed at `prod`, and an `apps-dev` Application carrying a ClusterRole and a ResourceQuota (`fixtures/forbidden/`) are all rejected, and the ClusterRole is never created. |
| Prod sync window | A commit moves the prod allow window to a later hour and a second commit changes the image of stage and prod. Stage deploys the new image; prod stays `OutOfSync` on the old image for two minutes. A manual sync then passes because the window sets `manualSync: true`. |
| Bootstrap path | The cluster comes up from `hack/bootstrap-gitops.sh` alone, with the in-cluster Git approach of the lab demo and the AppProjects applied before the root Application. |

## What only a real RKE2 HA cluster can prove

| Topic | Why kind cannot show it |
|---|---|
| RKE2 itself | kind runs kubeadm-style nodes in containers. The RKE2 CIS profile, its default PodSecurity and audit settings, Canal and the RKE2 upgrade path are not exercised. |
| Control-plane HA | One kind control-plane node. Three RKE2 servers with embedded etcd, quorum during a server loss and the kube-vip address are not tested. |
| etcd snapshots | Scheduled snapshots to S3 and a restore. |
| Node and zone loss | Pods are spread over three containers on one host. Failover after a real node failure, PodDisruptionBudgets during a drain and OpenBao re-election under load need real nodes. |
| Storage | local-path volumes, not Longhorn replication, backups or volume failover. |
| Load balancing and ingress | NodePort instead of a LoadBalancer Service; no external DNS, no real client traffic through the Gateway. |
| Certificates | `selfsigned` instead of ACME; HTTP-01 and DNS-01 issuance and renewal need public names. |
| Supply chain | Image signature verification is off. Keyless cosign verification against the build workflow and the transparency log needs images signed in CI. |
| Identity | No OIDC provider: Argo CD SSO and the group mappings of the AppProject roles are not exercised. |
| OpenBao operations | One key share and a root token held by the test. Real key custody, auto-unseal, audit log shipping and root token revocation are operational procedures. |
| Network | One Docker network. Firewalls, MTU, egress control and network policies under a real CNI with real cross-node traffic are not covered. |
| Capacity | Resource requests and limits are not validated against production load. |

## Files

| File | Purpose |
|---|---|
| `run.sh` | The test. |
| `kind.yaml` | Cluster `it-reference`: 1 control plane, 2 workers, pinned `kindest/node` v1.36 image. |
| `cluster.yaml` | Test-only cluster definition `ref-test`. |
| `manifests/git-server.yaml` | In-cluster Gitea server; the admin Secret is created by `run.sh`. |
| `fixtures/allowed/` | A ConfigMap, the source of the Applications that must be rejected for their project or destination. |
| `fixtures/forbidden/` | A ClusterRole and a ResourceQuota, kinds that `apps-<env>` must refuse. |
