# Preview environments for pull requests

This guide turns on short-lived preview environments: a pull request with the `preview` label gets its own namespace `pr-<number>` on the cluster, with the applications built from the pull request head commit, and loses it again when the pull request closes or the label is removed. It is for platform engineers who enable the feature and for reviewers who use it.

## What it does

Argo CD's ApplicationSet controller polls GitHub with the Pull Request generator. For every open pull request that carries all labels in `previews.github.labels`, two ApplicationSets in `argocd-bootstrap/templates/previews/` generate:

| Application | Project | Renders | Revision |
| --- | --- | --- | --- |
| `pr-<number>-namespace` | `preview-namespaces` | [`preview-namespace` chart](../../helmcharts/app-charts/preview-namespace/README.md): Namespace with Pod Security `restricted`, ResourceQuota, LimitRange, `default-deny` and `allow-dns` NetworkPolicies | `git.targetRevision` (`main`) |
| `pr-<number>-<app>` | `apps-preview` | One per entry in `previews.apps`; the app chart with `values.yaml`, `envs/dev/<app>/values.yaml` and `envs/preview/<app>/values.yaml` | the pull request head commit |

In hub mode every name carries the cluster prefix, as elsewhere in the app of apps. Each new commit on the pull request changes the head commit, so the app Application re-renders and syncs it. `global.environment` is `pr-<number>`, so helm-common derives the route hostname `<app>.pr-<number>.<domain>`.

## Prerequisites

- A GitHub token for the generator: a fine-grained personal access token (or a machine user's) limited to this repository, with the repository permissions Pull requests: Read-only and Metadata: Read-only. Nothing else; the generator only lists pull requests. A GitHub App works too, see `appSecretName` below.
- The Secret `github-previews` in the Argo CD namespace, key `token`, labelled `argocd.argoproj.io/secret-type: scm-creds`. The label is required when the ApplicationSet controller runs with token reference strict mode (`applicationsetcontroller.enable.tokenref.strict.mode`) and harmless otherwise. In hub mode the Secret belongs in the hub's Argo CD namespace.
- Create the Secret as a SealedSecret (lab, `hack/seal.sh secret --cluster <name> --namespace argocd --from-file <plaintext outside the repository>`, delivered by the `cluster-secrets` toolchain) or as an ExternalSecret (reference profile). Never commit the token. The plaintext manifest to seal:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-previews
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: scm-creds
type: Opaque
stringData:
  token: CHANGE_ME
```

## Enable

Previews are off by default. Switch them on per cluster in `clusters/<name>/cluster.yaml`; `values` is optional and merged over the `previews:` section of `argocd-bootstrap/values.yaml`:

```yaml
toolchains:
  previews:
    enabled: true
    values:
      hostnameStyle: flat
```

The root Application then creates the two AppProjects (wave -1) and the two ApplicationSets (wave 10). Owner and repository are derived from `git.repoURL`; set `github.owner` and `github.repo` when the URL is not `https://github.com/<owner>/<repo>[.git]`, and `github.api` for GitHub Enterprise.

| Key under `previews` | Default | Meaning |
| --- | --- | --- |
| `github.owner`, `github.repo` | derived from `git.repoURL` | Repository the generator polls |
| `github.api` | empty (github.com) | GitHub Enterprise API URL, for example `https://github.example.com/api/v3` |
| `github.labels` | `[preview]` | A pull request needs all of them; at least one is required |
| `github.tokenRef` | `github-previews`, key `token` | Token Secret in the Argo CD namespace |
| `github.appSecretName` | empty | GitHub App credential Secret (repo-creds format); replaces `tokenRef` |
| `requeueAfterSeconds` | `300` | Polling interval |
| `hostnameStyle` | `nested` | `nested`: `<app>.pr-<number>.<domain>`; `flat`: `<app>-pr-<number>.<domain>` |
| `image.tagFromHeadSha` | `false` | Run image tag `sha-<head commit>` instead of the dev image |
| `apps` | `hello-api` | Applications per preview: `name` (DNS label) and `chart` |
| `namespace.chart`, `namespace.values` | `helmcharts/app-charts/preview-namespace`, `{}` | Guardrail chart and overrides for its quota and limit range |

## Use a preview

1. Open the pull request. A maintainer adds the `preview` label once the change has been read.
2. Within `requeueAfterSeconds` (or at once with a webhook, see below), Argo CD shows `pr-<number>-namespace` and `pr-<number>-<app>`. The app Application may retry a few times until the namespace exists; that is expected.
3. Open `https://hello-api.pr-<number>.<domain>` (`nested`) or `https://hello-api-pr-<number>.<domain>` (`flat`), for example `https://hello-api.pr-7.localtest.me` in the lab with the default style.
4. Push more commits; the preview follows the head commit.

## Cleanup

Closing or merging the pull request, or removing the label, removes it from the generator output. The controller then deletes both Applications (`applicationsSync` stays at the default, `preserveResourcesOnDeletion: false`), and their resources finalizer deletes what they manage: the namespace Application deletes Namespace `pr-<number>` and with it everything in it. Nothing in a preview carries `Prune=false` or `Delete=false`.

Setting `toolchains.previews.enabled: false` prunes the ApplicationSets, and with them every preview, and the two AppProjects. The project finalizer keeps each project until its last Application is gone.

## Webhook instead of polling

By default the generator polls every `requeueAfterSeconds`, which costs about one GitHub API call per ApplicationSet and interval, well within the authenticated rate limit. For a faster reaction, send GitHub webhooks to the ApplicationSet controller, which serves `/api/webhook` on its Service (port 7000): in the repository settings add a webhook with content type `application/json`, the event Pull requests, and a secret that is also stored as `webhook.github.secret` in `argocd-secret`. This repository does not expose that endpoint; it needs an HTTPRoute on the platform Gateway and an ingress allowance for the Gateway in the `argocd` namespace (`platformNamespaces.argocd.extraIngress` in the network-policies values). Polling stays active as a fallback.

## Images

By default a preview runs the image tag and digest from `envs/dev/<app>/values.yaml` as of the pull request head commit. Chart, values and configuration changes are previewed; application code changes are not, because `.github/workflows/build-image.yml` builds and scans pull request images but never pushes them.

`image.tagFromHeadSha: true` sets `image.tag: sha-<head commit>` and clears the digest. It only works with a CI workflow that pushes pull request images under that tag. Such a workflow must not hand registry credentials to code from forks.

## TLS and hostnames

The platform certificate covers `<domain>`, `*.<domain>` and `*.<env>.<domain>` for the configured environments. A `nested` name such as `hello-api.pr-7.<domain>` matches the Gateway's `*.<domain>` listener, because Gateway API wildcards match several labels, but not the certificate, because a certificate wildcard matches exactly one label. Clients then see a name mismatch. `flat` names such as `hello-api-pr-7.<domain>` are covered by `*.<domain>`: use `flat` in the reference profile. The lab's self-signed issuer is untrusted anyway, but `flat` avoids the extra mismatch there too.

`flat` sets `route.hostnames` explicitly, so it only works for charts whose route uses that key, as helm-common charts do.

## Security model

- Label gate. Only users with triage or write access can label a pull request, so a maintainer decides which pull requests deploy. At least one label is required; the render fails on an empty list.
- Later commits deploy automatically. The generator follows the head commit, so a commit pushed after labelling deploys without another review. Remove the label before reviewing new commits from an untrusted author, and add it again afterwards.
- Pull requests from forks are listed like any other and pass the same label gate.
- Two projects, two trust levels. `apps-preview` renders untrusted input: it may deploy only into `pr-*` namespaces, no cluster-scoped kinds, and not ResourceQuota, LimitRange, Role or RoleBinding. `preview-namespaces` owns the Namespace, quota, limits and network policies and renders them from `main`. If one project allowed both, a pull request could render its own Namespace without Pod Security labels or raise its own quota.
- Only `.number` and `.head_sha` from the generator reach the Application templates. Branch names and titles are chosen by the pull request author and are never templated.
- The token is read-only and scoped to one repository.
- NetworkPolicy is allowed in `apps-preview`, as in the `apps-<env>` projects, so that the chart can admit the Gateway. A pull request can therefore add allow rules, including egress, for its own pods. It cannot remove the default deny, and the other namespaces keep their own ingress deny.

## Known gaps

- The Kyverno workload policies match the `dev`, `stage` and `prod` namespaces only, so `pr-*` namespaces get no registry allow-list, signature or `latest` tag checks. Pod Security `restricted`, the quota, the limit range and the default deny still apply.
- Previews of application code need CI that pushes pull request images, see [Images](#images).
- The ApplicationSets are not expanded by `argocd-bootstrap/tests/check-projects.sh`; it reports them as warnings. `argocd-bootstrap/tests/previews_test.yaml` covers the rendered templates.
