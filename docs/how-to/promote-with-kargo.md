# Promote with Kargo

This guide turns on Kargo as the promotion engine of a cluster and shows the daily work with it: releasing a version, watching `dev` follow it, promoting to `stage` and `prod`, and rolling back. It is for platform engineers who enable it and for app owners who promote. Why Kargo is optional and how it coexists with `promote.yml`: [ADR 0012](../adr/0012-kargo-promotion.md).

## What changes

Without Kargo, `build-image.yml` opens a pull request for `dev` and `promote.yml` opens pull requests for `stage` and `prod` ([Promotion and deployment policy](../operations/promotion.md)). With Kargo:

| Step | Without Kargo | With Kargo |
| --- | --- | --- |
| Release | merge to `main` builds `sha-<commit>` | raise `sample-services/<app>/VERSION` (for example `0.1.1`); the build adds that tag after scan, signature and attestations |
| `dev` | pull request from `build-image.yml`, merged by hand | automatic: the Warehouse finds the tag, Kargo commits `image.tag` and `image.digest` to `main` |
| `stage` | `promote.yml` pull request | manual promotion in Kargo; Kargo commits to `main` |
| `prod` | `promote.yml` pull request, code owner review | manual promotion in Kargo; Kargo opens a pull request, a code owner merges it, Kargo continues |
| Deploy | Argo CD syncs the merged commit | the same; Kargo asks Argo CD to sync and waits until it runs the commit |
| Check | Synced and Healthy | Synced and Healthy, then the `success-rate` analysis when verification is on |

Kargo writes only `image.tag` and `image.digest` in `envs/<env>/<app>/values.yaml`, like the workflows.

## Prerequisites

- The `cert-manager` toolchain (on by default) and the platform Gateway, so the UI is reachable at `https://kargo.<domain>`.
- For verification: the `argo-rollouts` and `monitoring` toolchains (both on in the `reference` profile), and apps that expose `http_requests_total` ([observability contract](../operations/observability-contract.md)). The app Applications enable the app ServiceMonitor while `monitoring` runs. Without those toolchains promotions still work; only the analysis is skipped.
- A Git credential for `git.repoURL`: a fine-grained token (or a GitHub App's) limited to this repository with Contents: Read and write and Pull requests: Read and write. Kargo uses it to clone, push and open the `prod` pull request.
- The branch rules of `main`. Kargo pushes `dev` and `stage` commits directly. If the ruleset requires pull requests, either add the credential's identity to the bypass list, or set `pullRequest: true` for those stages (below).
- For a private registry: an image credential with read access (`credentials.image` in the [kargo chart](../../helmcharts/system-charts/kargo/README.md)).

## Enable

1. Check the writer. Once a cluster file enables Kargo (step 4), the workflows stand back on their own: with the repository variable `PROMOTION_ENGINE` unset, `build-image.yml` skips its `dev` bump and `promote.yml` refuses to run, so Kargo is the only writer of the environment files. Leave the variable unset, or set it to `kargo` (Settings, Secrets and variables, Actions, Variables) to state the choice explicitly. Do not set it to `workflows` while Kargo runs: both engines would then write. Close open bump and promotion pull requests after the merge.
2. Deliver the credentials.

   Reference profile: write the credential to OpenBao; the `kargo` chart renders the ExternalSecret `kargo-git` in `kargo-shared-resources`.

   ```bash
   bao kv put secret/platform/kargo/git username=<token user> password=-
   ```

   Lab profile: seal two Secrets with `hack/seal.sh` from plaintext files outside the repository, and enable the `cluster-secrets` toolchain if it is not on yet. The plaintext manifests:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: kargo-git
     namespace: kargo-shared-resources
     labels:
       kargo.akuity.io/cred-type: git
   type: Opaque
   stringData:
     repoURL: https://github.com/YOUR_ORG/sk-k8s-devops-bootstrap.git  # exactly git.repoURL
     username: CHANGE_ME
     password: CHANGE_ME
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: kargo-api
     namespace: kargo
   type: Opaque
   stringData:
     ADMIN_ACCOUNT_PASSWORD_HASH: CHANGE_ME     # kargo hash-password, or a bcrypt hash
     ADMIN_ACCOUNT_TOKEN_SIGNING_KEY: CHANGE_ME # openssl rand -hex 32
   ```

   ```bash
   hack/seal.sh secret --cluster lab --namespace kargo-shared-resources --from-file /path/outside/repo/kargo-git.yaml
   ```

   ```bash
   hack/seal.sh secret --cluster lab --namespace kargo --from-file /path/outside/repo/kargo-api.yaml
   ```

3. SSO (reference profile). Register a public client with PKCE at the identity provider that Argo CD uses, with the redirect URIs `https://kargo.<domain>/login` and `http://localhost/auth/callback` and the `groups` claim. Set `issuerURL`, `clientID` and `cliClientID` in `helmcharts/system-charts/kargo/values-reference.yaml`. The groups of `platform.groups` map as listed in the [kargo chart](../../helmcharts/system-charts/kargo/README.md#access-control).
4. Turn it on in `clusters/<name>/cluster.yaml` (the reference cluster file already does):

   ```yaml
   toolchains:
     kargo: {enabled: true}
   ```

   For verification, enable `monitoring` and `argo-rollouts` as well, as the reference cluster file does.

   Optional tuning under `toolchains.kargo.pipelines.values`, for example pull requests for every stage when the branch rules forbid direct pushes:

   ```yaml
   toolchains:
     kargo:
       enabled: true
       pipelines:
         values:
           stages:
             dev: {autoPromote: true, pullRequest: true}
             stage: {autoPromote: false, pullRequest: true}
   ```

5. Merge. Argo CD syncs `kargo` (wave 4), then the app Applications (wave 10), then `kargo-pipelines` (wave 11), and adds `kargo.akuity.io/authorized-stage` to each `<app>-<env>` Application. Check that the Warehouse found the existing release tags:

   ```bash
   kubectl -n kargo-hello-api get warehouses,freight,stages
   ```

## Release and promote

1. Release: raise the version in `sample-services/hello-api/VERSION` in a pull request and merge it. `build-image.yml` builds, scans, signs and attests the image and then tags the digest `0.1.1`. An existing version tag is never moved.
2. `dev`: within the Warehouse interval (5 minutes) Kargo creates Freight for `0.1.1` and promotes it to `dev`. The commit on `main` reads `chore(promote): hello-api 0.1.1 to dev`. With verification on, the Stage shows the AnalysisRun; Freight that passes is marked verified in `dev`.
3. `stage`: in the UI, drag the Freight onto `stage`, or with the CLI:

   ```bash
   kargo login https://kargo.<domain> --sso
   ```

   ```bash
   kargo get freight --project kargo-hello-api
   ```

   ```bash
   kargo promote --project kargo-hello-api --freight <freight name> --stage stage
   ```

   Only Freight verified in `dev` is offered.
4. `prod`: promote the same way. Kargo pushes a branch `kargo/promotion/<promotion>`, opens a pull request into `main` and waits up to `pullRequest.timeout` (7 days). A code owner reviews and merges it; Kargo then asks Argo CD to sync `hello-api-prod`. Closing the pull request fails the promotion. In the reference profile Argo CD syncs `prod` only inside the sync window, so a merge outside it waits for the window.

Roll back by promoting an older verified Freight to the stage. It produces a new commit with the older tag and digest; nothing is reverted by force.

## Switch back to promote.yml

1. Set `toolchains.kargo.enabled: false` (or `toolchains.kargo.pipelines.enabled: false` to keep the UI) in every cluster file that enables Kargo, and merge. The authorization annotations disappear with the pipelines.
2. If the repository variable `PROMOTION_ENGINE` is `kargo`, delete it. With no cluster file running the Kargo pipelines, the workflows write the environment files again; the `discover` job of `build-image.yml` prints the engine and the reason as a notice.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `build-image.yml` opens no `dev` pull request, or `promote.yml` fails with `Kargo writes the environment files` | Expected while Kargo is the engine. The notice of the `discover` job names the cluster file that enables Kargo. To return to the workflows, follow [Switch back to promote.yml](#switch-back-to-promoteyml). |
| No Freight | The tag is a semantic version that matches `warehouse.constraint` (`>=0.1.0`); `kubectl -n kargo-hello-api describe warehouse hello-api` shows registry errors. A private registry needs the image credential. |
| Promotion fails at `git-push` | Credential scope, or the branch rules reject direct pushes: use the bypass or `pullRequest: true`. |
| Promotion fails at `git-push` with `could not read Username` | No credential matched `git.repoURL` exactly, or the repository URL is plain HTTP: Kargo sends credentials only over HTTPS (`kargo.controller.allowCredentialsOverHTTP` stays `false` outside tests). |
| `stage` or `prod` rejects the Freight as not available | It is not yet verified in the stage before; wait for the verification to finish. |
| Promotion fails at `argocd-update` with an authorization error | The Application lacks `kargo.akuity.io/authorized-stage: kargo-<app>:<stage>`; check that the root Application synced after enabling Kargo. |
| Verification Errored | The `argo-rollouts` controller runs, and Prometheus answers at `analysis.prometheusAddress` of the argo-rollouts chart. |
| Verification Inconclusive | No traffic in the 2-minute window: the analysis neither passes nor fails. Send traffic or re-run verification from the UI. |

The integration test `tests/integration/kargo/run.sh` exercises this guide end to end on kind; its README states what it proves.
