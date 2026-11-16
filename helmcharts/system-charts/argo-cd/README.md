# Argo CD wrapper chart

Platform wrapper around the upstream Argo CD Helm chart from [argo-helm](https://github.com/argoproj/argo-helm/tree/argo-cd-10.18.0/charts/argo-cd). The wrapper pins the upstream chart, carries the platform configuration in values files per profile, and adds two objects the upstream chart cannot render from platform values: the RBAC ConfigMap built from the identity provider groups, and the HTTPRoute on the platform Gateway.

Argo CD is installed once with `hack/argocd-install.sh` and then manages itself through the toolchain Application `argo-cd` (`argocd-bootstrap/templates/toolchains/argo-cd.yaml`).

## Contents

| Path | Purpose |
| --- | --- |
| `Chart.yaml`, `Chart.lock` | Dependency on `oci://ghcr.io/argoproj/argo-helm/argo-cd`, exact version. `charts/` is built locally and never committed. |
| `keys/argo-helm.asc` | Public signing key of the argo-helm releases, used to verify the chart provenance. Not packaged. |
| `values.yaml` | Base values shared by every profile. Upstream values live under the `argo-cd:` key; `global:` is shared with the upstream chart. |
| `values-lab.yaml` | Lab profile: kind or a single node. |
| `values-reference.yaml` | Reference profile: single RKE2 HA cluster with three or more nodes. |
| `templates/argocd-rbac-cm.yaml` | `argocd-rbac-cm` rendered from `platform.groups` and `rbac.appProjects`. |
| `templates/httproute.yaml` | HTTPRoute `argocd-server` for `global.domain` on Gateway `platform`, listener `https`. |

## Pinned version

| Item | Value |
| --- | --- |
| Upstream chart | `oci://ghcr.io/argoproj/argo-helm/argo-cd` version `10.18.0` (released 2026-11-11) |
| Argo CD | `v3.6.1` (appVersion of the chart; [release](https://github.com/argoproj/argo-cd/releases/tag/v3.6.1), 2026-11-04) |
| OCI manifest digest | `sha256:b9e529e96ae02d215dd4a3d354a40f7f393f4a3379337114de5926f99b7ac52e` |
| Chart archive hash (provenance) | `sha256:9785aff67197402aab26d7ab3928ac8e611c292dacdee47f0e8ded16c2cd5a47` |
| Signing key | Argo Helm maintainers, fingerprint `2B8F22F57260EFA67BE1C5824B11F800CD9D2252` (the `artifacthub.io/signKey` annotation of the chart) |
| Redis image | `8.6.4-alpine` (chart default) |

Why this version. Argo CD 2.14 reached end of life on 2025-11-04. Advisory [GHSA-fmxq-cgp8-87wp](https://github.com/argoproj/argo-cd/security/advisories/GHSA-fmxq-cgp8-87wp) (CVE-2026-77459, CVSS 9.9, published 2026-10-07) lets PreDelete and PostDelete hooks bypass AppProject restrictions. It affects every release from 2.10.0. The advisory lists no patch for v2 and the patched versions 3.3.15, 3.4.10, 3.5.4 and 3.6.0-rc2. Version 3.6.1 is the newest stable release and contains the fix.

Verify the provenance before changing the pin:

```bash
helm pull oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.18.0 \
  --verify --keyring helmcharts/system-charts/argo-cd/keys/argo-helm.asc
helm dependency build helmcharts/system-charts/argo-cd \
  --verify --keyring helmcharts/system-charts/argo-cd/keys/argo-helm.asc
```

`hack/argocd-install.sh` runs the second command on every install. A wrong or missing signature fails the build (`openpgp: signature made by unknown entity`).

## Profiles

| Setting | `lab` | `reference` |
| --- | --- | --- |
| API server, repo server, ApplicationSet controller | 1 replica each | 2 replicas each, hard pod anti-affinity |
| Application controller | 1 replica, no sharding | 1 replica, no sharding |
| Redis | single Deployment, password required | Redis HA (3 Redis with Sentinel, 3 HAProxy), password required, NetworkPolicies |
| Local admin | enabled, password from `argocd-initial-admin-secret` | disabled |
| SSO | none | OIDC placeholder (`CHANGE_ME`) |
| Host | `argocd.localtest.me` | `argocd.example.com`, replaced from the cluster definition |
| Log format | text | json |

Both profiles: Redis authentication, one NetworkPolicy per component with default deny ingress, PodDisruptionBudgets with `maxUnavailable: 1`, requests and limits, exec disabled, anonymous access disabled, notifications controller enabled, Dex and the commit server disabled.

## Install

```bash
PROFILE=lab hack/argocd-install.sh
CLUSTER=reference hack/argocd-install.sh
```

The script is idempotent (`helm upgrade --install`, release `argocd`, namespace `argocd`). It verifies the chart provenance, labels the namespace for Pod Security Admission (`restricted`), installs without the HTTPRoute when the Gateway API CRDs are not present yet, waits for every Deployment and StatefulSet, and prints how to log in without printing secrets. Once an Application for this chart exists (Argo CD manages itself), the script skips Helm, waits for the rollouts and exits 0, so repeated bootstrap runs stay idempotent. Variables: `PROFILE`, `CLUSTER`, `DOMAIN`, `ARGOCD_NAMESPACE`, `TIMEOUT`, `VERIFY`, `CONFIRM`, `ARGOCD_REINSTALL`, `DRY_RUN` (see the header of the script).

Lab login: user `admin`, password from

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Without the Gateway, use `kubectl -n argocd port-forward svc/argocd-server 8080:80` and open `http://localhost:8080`. Through the Gateway, the CLI needs gRPC-Web: `argocd login argocd.localtest.me --grpc-web`.

## Self-management

The toolchain Application `argo-cd` renders this chart with the same release name (`argocd`) and values files as the install script, plus three values from the cluster definition: `global.domain` (`argocd.<cluster.domain>`), `platform.groups` and the Gateway namespace. It therefore adopts the running installation without a rollout. It deviates from the toolchain convention on purpose:

- No `resources-finalizer.argocd.argoproj.io`: deleting the Application must not delete Argo CD. CRDs carry `Prune=false,Delete=false` and `helm.sh/resource-policy: keep`.
- `releaseName: argocd`: Deployment selectors contain the release name and are immutable.
- Sync wave `3`, the wave of the platform Gateway: Argo CD 3.1 added a health check for HTTPRoute, which reports `Progressing` until a Gateway programs the route.
- `ServerSideApply=true`: required since 3.3 because the ApplicationSet CRD exceeds the client-side apply annotation limit. Since 3.6 it also switches the diff to Server-Side Diff.
- `skipTests: true`: the redis-ha subchart contains Helm test pods.
- `ignoreDifferences` with `RespectIgnoreDifferences=true` for the keys that `argocd-server` writes into `argocd-secret` at runtime (`server.secretkey`, `admin.password`, `admin.passwordMtime`).
- Not rendered for a remote cluster of a hub (`cluster.destination.name` set to a cluster other than `in-cluster`): Argo CD runs only where the root app runs. For a hub, list the remote app projects (`<cluster>-apps-<env>`) in the hub's cluster file under `toolchains.argo-cd.values.rbac.appProjects`.

Values from the cluster definition under `toolchains.argo-cd.values` are merged over these computed values, so a cluster can override any wrapper value; lists replace.

Recovery: if a bad commit breaks Argo CD, check out the last good revision and run `ARGOCD_REINSTALL=1 hack/argocd-install.sh`. After self-management, Helm no longer owns every object (for example the HTTPRoute that the Application created once the Gateway API CRDs existed), so the recovery run uses `--take-ownership` and `--force-conflicts`; it needs Helm 3.17 or later. Automated sync restores the state of Git once the fix is merged. Planned upgrades go through Git (the dependency version in `Chart.yaml`), not through the script.

## Access, TLS and SSO

TLS terminates at the `https` listener of the shared Gateway `platform` in `envoy-gateway-system` with the certificate `platform-tls` of the platform issuer: wildcard names with `selfsigned` or ACME DNS-01, the explicit names in `platform.gateway.hostnames` (including `argocd.<domain>`) with ACME HTTP-01. `argocd-server` runs with `server.insecure: true` and the route targets its HTTP port 80. The template fails when `route.enabled` is true without `server.insecure`.

Reference SSO uses direct OIDC (`configs.cm."oidc.config"` in `values-reference.yaml`):

1. Register an application at the identity provider with redirect URI `https://<global.domain>/auth/callback` and a `groups` claim.
2. Replace `CHANGE_ME` in `issuer` and `clientID`.
3. Deliver the client secret as Secret `argocd-oidc`, key `clientSecret`, label `app.kubernetes.io/part-of: argocd`, through External Secrets Operator. Never commit it.
4. Put the group identifiers from the `groups` claim into `platform.groups` in the cluster definition. For Entra ID these are group object IDs unless the app registration emits names.

Dex is disabled. It is only needed for providers without OIDC, for example GitHub OAuth. To use it, set `argo-cd.dex.enabled: true` and `configs.cm."dex.config"`, and remove `oidc.config`. Since 3.0, Dex logins use `federated_claims.user_id` as RBAC subject instead of `sub`.

## RBAC

`argocd-rbac-cm` is rendered by this wrapper (`argo-cd.configs.rbac.create: false`).

| Subject | Role | Permissions |
| --- | --- | --- |
| `platform.groups.admins` | `role:admin` | Built-in. Everything. |
| `platform.groups.deployers` | `role:deployer` | `applications` get, sync and `action/*`, `logs` get, `projects` get, in each project of `rbac.appProjects` (`apps-dev`, `apps-stage`, `apps-prod`). |
| `platform.groups.viewers` | `role:readonly` | Built-in. Read everything, including logs. |
| anyone else | `policy.default: ""` | Nothing. |

`policy.default` is empty instead of `role:readonly`: with a tenant-wide identity provider, an SSO login alone would otherwise grant read access to every Application, including the platform project.

Pipelines have no local account. Their only identity is the project role `ci` of each `apps-<env>` AppProject (`argocd-bootstrap/templates/projects/apps.yaml`), limited to `applications, get` in that project; syncing is Argo CD's job after the Git merge. Issue a short-lived token with:

```bash
argocd proj role create-token apps-dev ci --expires-in 24h --grpc-web
```

## Health checks and sync waves

Argo CD removed the health assessment of `argoproj.io/Application` in 1.8 and 3.6 still does not ship one. Without it, the root app treats a child Application as done as soon as it is applied, and sync waves order nothing. `configs.cm."resource.customizations.health.argoproj.io_Application"` restores the check, based on the Lua snippet in the upstream [health documentation](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/health.md). The root app now waits until every Application of a wave is Healthy before it syncs the next wave.

The check extends the upstream snippet in one point: a child whose own sync is requested (`operation` set) or running (`operationState.phase: Running`) is Progressing. Without that, a child that syncs its own chart in waves can read Healthy between two of its waves, before its later resources exist, and the root moves on too early (observed in the reference harness with OpenBao at wave 4 and the apps at wave 10). Otherwise the child's health is passed through: no status gives Progressing, a finished sync gives the child's health (also after a failed sync), Missing stays Missing. Side effect: a child, and with it the root, shows Progressing for the duration of each of its syncs.

`resource.exclusions` keeps the upstream defaults. `resourceExclusionsAdditional` appends report kinds that are generated in the cluster and never declared in Git (OpenReports, Trivy Operator reports).

## Network policies

`global.networkPolicy.create` and `defaultDenyIngress` are true. The upstream component policies then allow: any source to the API server; the API server, controller, ApplicationSet controller and notifications controller to the repo server; the API server, repo server and controller to Redis; metrics ports from any namespace. In the reference profile, the redis-ha policies allow Redis peers and HAProxy, and HAProxy accepts Redis traffic from the API server, repo server and controller only. Egress is not restricted.

## Decisions

| Decision | Reason |
| --- | --- |
| Wrapper on the OCI chart instead of vendoring | The vendored copy drifted from its label (chart 6.6.0 content under 7.8.0) and pinned an end-of-life Argo CD. A lock file and provenance verification give the same reproducibility. |
| Jump from 2.14 directly to 3.6.1 | The upstream upgrade overview allows skipping minors when the notes of every step are applied. Every 3.x release before 3.3.15 is affected by CVE-2026-77459, and 3.0 to 3.2 are out of support. |
| TLS at the Gateway, `server.insecure: true` | One certificate and one TLS policy for every route ([ADR 0003](../../../docs/adr/0003-gateway-api-with-envoy-gateway.md)). In-cluster traffic is limited by NetworkPolicy. Backend TLS (BackendTLSPolicy) is experimental in the upstream chart. |
| Direct OIDC, no Dex | One component less. Dex stays available for providers without OIDC. |
| `policy.default` empty | Stricter than `role:readonly`; access follows group membership only. |
| One application controller, no sharding | A single cluster with tens of Applications does not need sharding. Sharding adds a moving part to the HA story. |
| No resources finalizer on the self-managing Application | Deleting the Application must never uninstall Argo CD. |
| SSH known hosts limited to GitHub (`configs.ssh.knownHosts`) | Trust only the Git host in use. The keys match the fingerprints GitHub publishes. Private Git servers go into `configs.ssh.extraHosts`, never `--insecure-skip-server-verification`. |

## Upgrade from Argo CD 2.14 (vendored chart 7.8.0) to 3.6.1

The release name (`argocd`) and resource names (`argocd-server`, `argocd-repo-server`, and so on) are unchanged, so the upgrade is an in-place `helm upgrade`. Every item below was checked against the upstream upgrade notes at tag v3.6.1 and the argo-helm changelog at `argo-cd-10.18.0`.

### Breaking changes that apply

| Version | Change | Action here |
| --- | --- | --- |
| 3.0 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/2.14-3.0.md)) | Annotation-based resource tracking is the default (`application.resourceTrackingMethod`). | Set explicitly to `annotation`. Sync every Application once after the upgrade, even when it shows Synced. Applications with `ApplyOutOfSyncOnly=true` must be synced once without that option from the UI or API. |
| 3.0 | `update` and `delete` on an Application no longer apply to its resources (`server.rbac.disableApplicationFineGrainedRBACInheritance`). | No custom role here grants update or delete. Grant `update/*` or `delete/*` explicitly if you add such a role. |
| 3.0 | Logs RBAC is enforced; `server.rbac.log.enforce.enable` is removed. | `role:readonly` contains `logs, get`; `role:deployer` grants it per project. Remove the key from `argocd-cm` if it was set. |
| 3.0 | `argocd-cm` ships default `resource.exclusions`. | Kept; additions go to `resourceExclusionsAdditional`. |
| 3.0 | Legacy repository config in `argocd-cm` (`repositories`, `repository.credentials`, `helm.repositories`) is removed. | Before the upgrade, check `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.repositories}{.data.repository\.credentials}{.data.helm\.repositories}'` is empty. Repositories are Secrets here. |
| 3.0 | Metrics `argocd_app_sync_status`, `argocd_app_health_status`, `argocd_app_created_time` are removed. | Use labels of `argocd_app_info` in dashboards and alerts. |
| 3.0 | `.status.resources[].health` is no longer stored in the Application (`controller.resource.health.persist`). | Read per-resource health from the API or CLI. |
| 3.0 | Status fields are ignored in diffs for all kinds; `ignoreDifferences` also ignores resource updates. | No action. |
| 3.1 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.0-3.1.md)) | The server handles the OIDC code flow, also with PKCE; health checks for Gateway API kinds added. | Redirect URI `https://<global.domain>/auth/callback`. HTTPRoute health drives the sync wave of the self-managing Application. |
| 3.2 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.1-3.2.md)) | Built-in CronJob health check. | Applications with failing CronJobs can turn Degraded. |
| 3.3 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.2-3.3.md)) | The ApplicationSet CRD exceeds the client-side apply annotation limit. `helm upgrade` is not affected. | The self-managing Application uses `ServerSideApply=true`. |
| 3.4 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.3-3.4.md)) | `Missing` health only when all resources are missing; cluster version stored as `vMajor.Minor.Patch`. | Automation that detected missing resources through health must check `OutOfSync`. |
| 3.5 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.4-3.5.md)) | Charts are rendered with Helm v4; `spec.source.helm.version: v3` is ignored. SSH repositories use `argocd-ssh-known-hosts-cm`. Impersonation, when enabled, covers all API operations. | Render every chart with Helm v4 in CI (this repository does). Pin known hosts in `configs.ssh`. |
| 3.6 ([notes](https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/upgrading/3.5-3.6.md)) | `ServerSideApply=true` implies Server-Side Diff. More API server load; validating webhooks take part in the diff. | Expected. Opt out per Application with `argocd.argoproj.io/compare-options: ServerSideDiff=false`. |
| 3.6 | `ARGOCD_REPO_OTLP_HEADERS` renamed to `ARGOCD_REPO_SERVER_OTLP_HEADERS`. | Only if tracing is configured. |
| Chart 9.0.0 | Defaults under `configs.params` removed; `applicationsetcontroller.policy` default changes from `sync` to empty. | `server.insecure` is set explicitly. Set the ApplicationSet policy explicitly if you rely on it. |
| Chart 9.1.0 | redis-ha HAProxy Deployment selector changed (immutable). | Only for releases that already ran redis-ha. The vendored lab install did not. |
| Chart 10.0.0 | `global.networkPolicy.create` defaults to true. | Enabled on purpose, with `defaultDenyIngress`. |
| Chart 10.13.0 | Headless Service for the application controller. | Delete a hand-made Service of that name first. |
| Chart 10.17.0 | `helm.sh/chart` label removed from pod templates; every pod rolls once. | Expected. |

### Procedure

1. Back up the Argo CD state: `argocd admin export -n argocd > argocd-backup.yaml`. Store it outside the cluster and outside Git; it contains repository credentials.
2. Check the legacy repository keys in `argocd-cm` (command in the table above). Migrate them to repository Secrets if any is set.
3. Record which Applications use `ApplyOutOfSyncOnly=true`.
4. Upgrade: `CONFIRM=yes PROFILE=lab hack/argocd-install.sh` (or `CLUSTER=<name>`). The script refuses a 2.x to 3.x upgrade without `CONFIRM=yes`. Changes during the upgrade: Argo CD 3.6.1 images, Redis 8.6 with a password (the cache is rebuilt), Service type ClusterIP instead of NodePort, Dex removed, NetworkPolicies added, the committed admin hash removed. In the lab profile `argocd-server` then generates a new admin password into `argocd-initial-admin-secret`.
5. Verify: `kubectl -n argocd get pods`, `argocd version --grpc-web`, and that `argocd-cm` contains `resource.customizations.health.argoproj.io_Application`.
6. Sync every Application once (annotation tracking), the ones from step 3 from the UI or API without `ApplyOutOfSyncOnly`.
7. Apply the root Application. From then on the toolchain Application `argo-cd` manages this release.

Rollback: Helm rollback to 2.14 is not supported once the 3.x CRDs and tracking annotations are applied. Restore by reinstalling the previous chart and importing the backup with `argocd admin import -n argocd - < argocd-backup.yaml`.

### Updating the pin later

Renovate proposes new versions of the dependency in `Chart.yaml`. For each update: read the upstream upgrade notes of every minor in between, verify the provenance with the commands above, run `helm dependency update` to refresh `Chart.lock`, and compare `helm template` output for both profiles before and after.
