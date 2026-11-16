# argocd-bootstrap

Root chart of the app of apps. The root Application (`bootstrap/`) renders it with `values.yaml` and then `clusters/<name>/cluster.yaml`, so one cluster definition drives every Application below.

```bash
helm template root argocd-bootstrap -f clusters/lab/cluster.yaml
```

## What it renders

| Template | Objects | Wave |
|---|---|---|
| `templates/projects/platform.yaml` | AppProject `platform`: toolchains and the root Application. Enumerated source repositories, destinations (every value of `namespaces` plus `projects.platform.extraDestinationNamespaces`) and cluster-scoped kinds (`projects.platform.clusterResourceWhitelist`). | -1 |
| `templates/projects/apps.yaml` | AppProjects `apps-dev`, `apps-stage`, `apps-prod`: one namespace each, no cluster-scoped kinds, no ResourceQuota, LimitRange, Role or RoleBinding. Applications own their NetworkPolicies (rendered by helm-common); the platform keeps default deny and DNS. Roles `deployers` (get, sync), `viewers` (get) and `ci` (get, for `argocd app wait`). Prod sync window in the reference profile. | -1 |
| `templates/projects/default.yaml` | The built-in `default` project, locked: no sources, destinations or kinds. | -1 |
| `templates/toolchains/*.yaml` | One Application per platform component, owned by the component; see [Toolchain Applications](../docs/architecture/gitops.md#toolchain-applications). | 0 to 4 |
| `templates/cluster/secrets.yaml` | Application `cluster-secrets` for `clusters/<name>/secrets/` when `toolchains.cluster-secrets.enabled`. | 1 |
| `templates/tenants/applicationset.yaml` | When `toolchains.tenants.enabled` (off by default): AppProject `tenants` and ApplicationSet `tenants`, which creates one Application `tenant-<name>` per `tenants/<name>.yaml` from `tenants/chart`. Hub mode splits the ApplicationSet in two. | -1 (AppProject), 3 (ApplicationSet) |
| `templates/apps/applications.yaml` | One Application `<app>-<env>` per entry of `apps` and environment hosted by the cluster. | 10 |
| `templates/apps/applicationsets.yaml` | Instead of the above when `applicationSet.enabled`: one ApplicationSet `apps-<env>` per environment. | 10 |

Waves order work only because the Argo CD values add the Application health check, so a parent waits until a child Application is Healthy.

## Values

| Key | Source | Purpose |
|---|---|---|
| `git`, `cluster`, `namespaces`, `platform` | cluster definition (schema `clusters/schema.json`) | Repository, identity, namespaces, issuer, registry, groups. Defaults equal the lab profile. |
| `toolchains.<name>.enabled` | defaults here, deltas per cluster | Switch for each toolchain template. |
| `projects.*` | here | Extra source repositories, extra platform namespaces, the cluster-scoped whitelist, the app blacklist, sync windows per profile and environment. |
| `apps` | here | Application inventory: `name`, `chart`, `environments`. |
| `applicationSet.enabled` | here | Selects the ApplicationSet mode. |

## Application Applications

Each application environment gets one multi-source Application:

- source 1: the chart at `apps[].chart`, values `values.yaml` and `$values/envs/<env>/<app>/values.yaml`;
- source 2: the same repository as `ref: values`;
- `helm.valuesObject.global`: `environment`, `domain`, `cluster`, `profile` and `imageRegistry` from the cluster definition, so environment files stay cluster-independent;
- project `apps-<env>`, namespace `namespaces.<env>`, `CreateNamespace=false` (the `misc` toolchain owns the namespaces and their Pod Security labels);
- `argocd.argoproj.io/manifest-generate-paths` with absolute paths: the chart, `helmcharts/helm-common` and `envs/<env>/<app>`. Absolute paths are required for multi-source Applications, where a relative path would resolve against each source.

To add an application: create its chart under `helmcharts/app-charts/<app>`, add `envs/<env>/<app>/values.yaml` for each environment, and add an entry to `apps`.

## Switching between static Applications and ApplicationSets

Both modes render the same Application names and specs from the same inventory, and only one mode renders at a time.

1. Make sure every application is Synced and Healthy.
2. Remove the resources finalizer from each application Application, so that pruning it does not delete its workloads: `kubectl -n argocd patch application <name> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`.
3. Change `applicationSet.enabled` in one commit. The root Application prunes the static Applications (last, because of `PruneLast`) and creates the ApplicationSets, which create Applications with the same names; those adopt the running workloads.
4. Check that every application is Synced and Healthy again.

This switch is not covered by the end-to-end job. Rehearse it on a lab cluster before running it on a shared one.

The ApplicationSets use `goTemplate` with `missingkey=error` and `preserveResourcesOnDeletion`; the prod ApplicationSet uses `applicationsSync: create-update`, so the controller never deletes a prod Application.

## Turning a toolchain off without deleting its state

Toolchain Applications carry the resources finalizer, so disabling one deletes what it deployed. Namespaces and CRDs carry `Prune=false,Delete=false` and survive, except the CRDs of `velero`, `trivy-operator` and `longhorn`, which carry neither, and of `cloudnative-pg`, which carry `helm.sh/resource-policy: keep` only (see [the exceptions](../docs/architecture/gitops.md#namespaces-and-crds-survive-a-disabled-toolchain)). To hand a component over to another owner without any deletion, first run `argocd app delete <name> --cascade=false`, then set `enabled: false`.

## Hub mode

See `bootstrap/README.md`. Templates use the helpers in `templates/_helpers.tpl` (`argocd-bootstrap.name`, `argocd-bootstrap.platformProject`, `argocd-bootstrap.appsProject`, `argocd-bootstrap.destination`), which prefix names with the cluster name and render the destination by cluster name when `cluster.destination.name` is set.
