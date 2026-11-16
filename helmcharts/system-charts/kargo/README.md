# kargo

Optional promotion orchestration ([ADR 0012](../../../docs/adr/0012-kargo-promotion.md)): the Kargo controller, API and UI, and webhooks. Kargo writes promotions to Git and asks Argo CD to sync; Argo CD stays the only deployer. The promotion pipelines themselves (Projects, Warehouses, Stages) come from the separate chart [kargo-pipelines](../kargo-pipelines/README.md), rendered as the Application `kargo-pipelines` in sync wave 11, after the app Applications (wave 10).

| Item | Value |
| --- | --- |
| Upstream chart | kargo 1.12.5 from `oci://ghcr.io/akuity/kargo-charts` |
| Upstream app version | v1.12.5 |
| Upstream source | <https://github.com/akuity/kargo> |
| Namespace | `kargo` (Pod Security: restricted). The chart also creates `kargo-shared-resources` (shared credentials) and `kargo-system-resources`. |
| Sync wave | 4, after cert-manager (0), the Gateway (3) and the argo-rollouts CRDs (4, same wave) |
| Enabled by default | No. `toolchains.kargo.enabled: true` in `clusters/<cluster>/cluster.yaml`; on in the `reference` profile. |

What this chart adds or changes on top of the upstream chart:

| Setting | Why |
| --- | --- |
| `kargo.global.securityContext` | The upstream default is empty and fails Pod Security `restricted`. Non-root, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem (the controller writes clones to an emptyDir at `/tmp`). |
| Resource requests and memory limits for every component | The upstream chart sets none. No CPU limits, to avoid throttling of reconcile loops. |
| `kargo.api.tls.enabled: false`, `terminatedUpstream: true` and `templates/httproute.yaml` | TLS terminates at the platform Gateway (`https` listener, certificate `platform-tls`); the route serves `kargo.<domain>`. |
| `kargo.controller.argocd.watchArgocdNamespaceOnly: true` | The controller reads and patches Argo CD Applications through a Role in the Argo CD namespace instead of a ClusterRole. |
| `kargo.externalWebhooksServer.enabled: false` | No public webhook endpoint. Warehouses poll the registry. |
| `templates/credentials.yaml` | Git and image credentials as ExternalSecrets in `kargo-shared-resources` (reference profile). |

Webhook and certificate Secrets come from cert-manager (namespaced `Issuer` and `Certificate` of the upstream chart), so the `cert-manager` toolchain is required.

## Profiles

| Setting | lab | reference |
| --- | --- | --- |
| Login | Local admin account; hash and signing key from Secret `kargo-api` | OIDC with PKCE (no client secret); admin account off |
| API replicas | 1 | 2 |
| API requests / memory limit | 50m, 128Mi / 512Mi | 100m, 256Mi / 1Gi |
| Controller requests / memory limit | 100m, 256Mi / 1Gi | 200m, 512Mi / 2Gi |
| Credentials | SealedSecrets that the adopter seals | ExternalSecrets from OpenBao |

## Access control

The toolchain injects the groups of the cluster definition (`platform.groups`):

| Group | Kargo role |
| --- | --- |
| `admins` | `kargo-admin` on every Project (`api.oidc.admins`) |
| `viewers`, `deployers` | `kargo-viewer`, read-only on every Project (`api.oidc.viewers`) |
| `deployers` | `kargo-promoter` in each app Project (ServiceAccount `deployers` with the claim annotation and a RoleBinding, rendered by kargo-pipelines) |

Register a public OIDC client at the identity provider of Argo CD with the redirect URIs `https://kargo.<domain>/login` and `http://localhost/auth/callback` (CLI), the `groups` claim in the ID token, and set `issuerURL`, `clientID` and `cliClientID` in `values-reference.yaml`.

## Secrets

| Secret | Namespace | lab | reference |
| --- | --- | --- | --- |
| `kargo-api` (`ADMIN_ACCOUNT_PASSWORD_HASH` from `kargo hash-password`, `ADMIN_ACCOUNT_TOKEN_SIGNING_KEY`) | `kargo` | SealedSecret under `clusters/<name>/secrets/kargo/` | not used (admin account off) |
| `kargo-git` (label `kargo.akuity.io/cred-type: git`; `repoURL`, `username`, `password`) | `kargo-shared-resources` | SealedSecret under `clusters/<name>/secrets/kargo-shared-resources/` | ExternalSecret, store key `platform/kargo/git` |
| `kargo-image` (label `kargo.akuity.io/cred-type: image`, `repoURLIsRegex: "true"`) | `kargo-shared-resources` | only for a private registry | `credentials.image.enabled: true`, store key `platform/kargo/registry` |

The Git credential needs contents write and pull requests write on this repository and nothing else. Kargo uses credentials only over HTTPS (`kargo.controller.allowCredentialsOverHTTP: false`, the upstream default); the kind harness relaxes this for its in-cluster Git server only. The [how-to](../../../docs/how-to/promote-with-kargo.md) shows how to create and seal each Secret.

## Dependencies

| Toolchain | Why |
| --- | --- |
| cert-manager | Certificates of the webhooks server |
| gateway-api, envoy-gateway, platform-gateway | HTTPRoute `kargo-api` |
| argo-rollouts | Runs the AnalysisRuns that Kargo creates for verification, and provides the `success-rate` ClusterAnalysisTemplate |
| monitoring | Prometheus for the `success-rate` analysis |
| external-secrets, openbao (reference) | Credentials |

## Cluster-scoped kinds

CustomResourceDefinition (11, group `kargo.akuity.io`), ClusterRole, ClusterRoleBinding, Namespace, MutatingWebhookConfiguration and ValidatingWebhookConfiguration from this chart; `kargo.akuity.io/Project` from kargo-pipelines. All are in the `platform` AppProject whitelist.

## Upgrade notes

- Read the release notes of every version between the pinned and the target release (<https://github.com/akuity/kargo/releases>). v1.12.0 removed `controller.globalCredentials.namespaces` and `global.clusterSecretsNamespace`; v1.9.0 renamed the image subscription field `semverConstraint` to `constraint`. The upstream project has announced v2.0.0 with a new state store as the release after 1.12; treat it as a migration, not a chart bump.
- CRDs upgrade with the chart and are never pruned. Run the kind harness `tests/integration/kargo/run.sh` before changing the pin.
