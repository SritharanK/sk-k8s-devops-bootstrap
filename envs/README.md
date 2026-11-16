# Environment values

One directory per environment and application: `envs/<env>/<app>/values.yaml`.

- Each file is passed to the application chart after the chart's own `values.yaml`, through the `$values` source of the Application `<app>-<env>` (see `argocd-bootstrap/templates/apps/`).
- A file holds only what differs per environment. Anything shared belongs in the chart.
- `image.tag` and `image.digest` are the only keys automation changes. The image build proposes dev; `.github/workflows/promote.yml` proposes stage from dev and prod from stage. Every change is a pull request merged by hand.
- With Kargo as the promotion engine (a cluster file enables Kargo and the repository variable `PROMOTION_ENGINE` is not `workflows`, [ADR 0012](../docs/adr/0012-kargo-promotion.md)) Kargo writes the same two keys instead: it commits dev and stage to the target branch and opens a pull request for prod. The workflows then leave these files alone, so there is one writer at a time.
- When `image.digest` is set, the workload runs `repository@digest`. A digest is promoted only after it ran in the previous environment.
- Cluster facts are not repeated here. Each Application passes `global.environment`, `global.domain`, `global.cluster`, `global.profile` and `global.imageRegistry` from the cluster definition, so the same file works on the `lab` and the `reference` cluster.
- Secrets never go here. Use a SealedSecret under `clusters/<name>/secrets/<namespace>/` (lab) or an ExternalSecret (reference).

## Pull request previews

`envs/preview/<app>/values.yaml` holds the deltas for pull request previews (namespace `pr-<number>`, see [preview environments](../docs/how-to/preview-environments.md)): one replica, no autoscaling, no canary, small resources. A preview Application applies the chart's `values.yaml`, then `envs/dev/<app>/values.yaml` (the image tag and digest that run in dev), then this file, all read at the pull request head commit. It is not an environment: nothing promotes into or out of it, and automation never changes it.
