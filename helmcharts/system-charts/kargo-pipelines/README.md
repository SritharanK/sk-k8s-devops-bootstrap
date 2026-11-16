# kargo-pipelines

Kargo promotion pipelines for the apps of the inventory (`apps` in `argocd-bootstrap/values.yaml`), rendered as the Application `kargo-pipelines` (sync wave 11, after the app Applications) when the `kargo` toolchain is enabled. Decision and coexistence with `promote.yml`: [ADR 0012](../../../docs/adr/0012-kargo-promotion.md). Operator guide: [Promote with Kargo](../../../docs/how-to/promote-with-kargo.md).

The chart has no upstream dependency. Repository, branch, registry, Argo CD namespace, groups, Pod Security version and the app list are injected by `argocd-bootstrap/templates/toolchains/kargo.yaml` from the cluster definition, so a new app in the inventory gets a pipeline without a change here.

## What it renders per app

| Object | Name | Purpose |
| --- | --- | --- |
| Namespace | `kargo-<app>` | Adopted by the Project (label `kargo.akuity.io/project: "true"`), Pod Security `restricted` |
| Project | `kargo-<app>` | Kargo tenancy unit; Kargo adds the roles `kargo-admin`, `kargo-promoter`, `kargo-viewer` |
| ProjectConfig | `kargo-<app>` | Auto-promotion per stage (`stages.<name>.autoPromote`) |
| ServiceAccount, RoleBinding | `deployers`, `deployers-kargo-promoter` | Members of `groups.deployers` may promote in this Project |
| Warehouse | `<app>` | Release tags of `<imageRegistry>/<app>` matching `warehouse.constraint`; Freight records tag and digest |
| Stage | `dev`, `stage`, `prod` | Promotion steps and verification |

## Promotion steps

| Step | All stages | Pull request stages (default: `prod`) |
| --- | --- | --- |
| `git-clone` | `git.repoURL` at `git.branch` | same |
| `yaml-update` | `image.tag` and `image.digest` in `envs/<stage>/<app>/values.yaml` | same |
| `git-commit` | `chore(promote): <app> <tag> to <stage>` | same |
| `git-push` | to `git.branch` | to a generated branch `kargo/promotion/<promotion>` |
| `git-open-pr`, `git-wait-for-pr` | | opens a pull request into `git.branch` and waits up to `pullRequest.timeout` for the merge; a closed pull request fails the promotion |
| `argocd-update` | syncs `<app>-<stage>` and waits until it runs the pushed or merged commit | same |

Verification (`verification.enabled`) runs the ClusterAnalysisTemplate `success-rate` with `service-name=<app>`, `namespace=<stage namespace>` and `threshold`. The toolchain enables it when the `argo-rollouts` and `monitoring` toolchains are both on.

## Values

| Key | Default | Notes |
| --- | --- | --- |
| `warehouse.interval` | `5m0s` | Registry poll interval |
| `warehouse.constraint` | `>=0.1.0` | Semver constraint on release tags |
| `warehouse.discoveryLimit` | `20` | Newest tags considered |
| `warehouse.insecureSkipTLSVerify` | `false` | Test-only (self-signed local registry) |
| `stages.<name>.autoPromote` | dev `true`, stage and prod `false` | |
| `stages.<name>.pullRequest` | prod `true` | Set `true` for dev and stage too when the branch rules of `git.branch` forbid direct pushes |
| `pullRequest.provider` | empty (inferred) | `github`, `gitlab`, `gitea`, `azure`, `bitbucket` |
| `pullRequest.timeout` | `168h` | |
| `verification.enabled` | injected | Override in the cluster file under `toolchains.kargo.pipelines.values` |
| `verification.analysisTemplates` | `success-rate` (ClusterAnalysisTemplate) | |
| `verification.threshold` | `"0.99"` | |
| `projectPrefix` | `kargo-` | |

Override tunables per cluster, for example:

```yaml
toolchains:
  kargo:
    enabled: true
    pipelines:
      values:
        stages:
          stage: {autoPromote: false, pullRequest: true}
```

## Requirements

- The Application of each stage carries `kargo.akuity.io/authorized-stage: kargo-<app>:<stage>`. The app templates of argocd-bootstrap add it only when Kargo is enabled.
- A Git credential for `git.repoURL` (Secret `kargo-git` in `kargo-shared-resources`, see the [kargo chart](../kargo/README.md#secrets)).
- `envs/<stage>/<app>/values.yaml` exists for every stage and defines `image.tag` and `image.digest`.
