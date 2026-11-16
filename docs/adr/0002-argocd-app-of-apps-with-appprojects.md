---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Argo CD app of apps with AppProjects

This record explains how Argo CD delivers the platform and the apps from this repository, and where the tenancy boundaries sit. It is for operators and for anyone who adds a component or an app.

## Context and problem statement

After provisioning, everything in the cluster comes from Git through Argo CD: CRDs, controllers, policies, the Gateway, optional operations components, and every app in `dev`, `stage` and `prod`. Components depend on each other (CRDs before custom resources, the policy engine before its policies), app owners must not change cluster-scoped objects or namespace guardrails, and Argo CD itself needs upgrades.

How should the Argo CD configuration be structured so that a cluster converges from empty in a defined order, every change is reviewable before it reaches a cluster, and each project can change only what it owns?

## Decision drivers

- Convergence from an empty cluster without manual steps, in a defined order.
- Least privilege: app Applications cannot create cluster-scoped objects or change quotas, limits or RBAC, and cannot remove the platform's default-deny NetworkPolicy.
- Every Application, project and destination visible in the rendered output, so CI can check it.
- One switch per component per profile (`toolchains.<name>.enabled`).
- Argo CD upgrades through the same pull request flow as every other component.
- A path to more clusters later.

## Considered options

- App of apps with static Applications rendered by a Helm chart
- ApplicationSets only
- Flux
- Plain Helm releases from CI

## Decision outcome

Chosen option: "App of apps with static Applications rendered by a Helm chart", because it is the only option that orders components across Applications with sync waves, shows every Application in the rendered output, and keeps the AppProject and SSO model that Argo CD provides.

The structure:

- `make bootstrap-gitops CLUSTER=<name>` runs the idempotent script `hack/bootstrap-gitops.sh`. It validates the cluster file, installs the wrapper chart `helmcharts/system-charts/argo-cd` with Helm through `hack/argocd-install.sh`, applies an optional repository Secret from `REPO_SECRET_FILE`, applies the AppProjects, then the root Application `root` rendered by the Helm chart `bootstrap/`, and waits until it is Synced. From then on the `argo-cd` Application manages Argo CD itself. `make install-argocd` remains for installing or reinstalling Argo CD alone.
- The root Application (project `platform`, automated prune and self-heal, no cascading finalizer) renders `argocd-bootstrap/` with its `values.yaml` and then `clusters/<name>/cluster.yaml`. It does not manage itself: a change to the `bootstrap/` chart or to the git settings is applied by running the script again.
- `argocd-bootstrap/` renders the AppProjects, one Application per toolchain from `templates/toolchains/<name>.yaml`, guarded by `toolchains.<name>.enabled`, and one multi-source Application `<app>-<env>` per app and environment from the `apps:` list in `argocd-bootstrap/values.yaml`.
- AppProjects, at sync wave `-1`: `platform` holds every toolchain, with an enumerated cluster-scoped whitelist. `apps-dev`, `apps-stage` and `apps-prod` each allow one namespace, no cluster-scoped kinds, and deny ResourceQuota, LimitRange, Role and RoleBinding. Each app renders its own NetworkPolicy through helm-common; the platform keeps `default-deny` and `allow-dns` in the app namespaces. `default` is locked. In the `reference` profile `apps-prod` carries a sync window.
- Sync waves order the toolchains: `0` CRDs and core controllers, `1` Kyverno, `2` Envoy Gateway, `misc` and network policies, `3` policies, the platform Gateway and the `argo-cd` Application (its HTTPRoute needs the Gateway), `4` optional components, `10` apps. Argo CD removed the health assessment of `argoproj.io/Application` in version 1.8, so without it the root Application treats every child as healthy at once and the waves order nothing. The Argo CD values restore it with a Lua health check (`resource.customizations.health.argoproj.io_Application`).

ApplicationSet mode stays as an opt-in alternative for the app Applications (`applicationSet.enabled`): one ApplicationSet `apps-<env>` per environment, with `goTemplate` and `preserveResourcesOnDeletion`, generating the same Application names; the `prod` ApplicationSet uses `applicationsSync: create-update`. The two modes are mutually exclusive. It is kept because it suits large app inventories. It is not the default because the Applications it generates do not appear in the rendered output, so the CI project check sees only the ApplicationSet, and with `preserveResourcesOnDeletion` an app removed from the list leaves its resources running until someone deletes them.

Hub mode: the `bootstrap/` chart can also add the ApplicationSet `clusters` (`HUB_MODE=1`), whose cluster generator creates one root Application per remote cluster registered in a hub Argo CD. Each remote cluster has its own definition with `cluster.destination.name` and `cluster.environments`. Hub mode is implemented and not tested in CI; the procedure is in [`bootstrap/README.md`](../../bootstrap/README.md).

### Consequences

- Good, because a fresh cluster converges without manual steps, in wave order.
- Good, because every Application, project and destination is in the output of `make render` and is checked in CI.
- Good, because app Applications cannot change cluster-scoped objects or the guardrails of their namespace.
- Good, because Argo CD upgrades arrive as reviewed pull requests to the `argo-cd` wrapper chart.
- Bad, because a broken change to the Argo CD values can take Argo CD down, and then it cannot repair itself. Recovery is `make install-argocd` from a known good revision.
- Bad, because the root Application is not self-managed: a change to the `bootstrap/` chart or to the git settings takes effect only when an operator runs `make bootstrap-gitops` again.
- Bad, because the root Application can create Applications in every project: whoever can merge to `argocd-bootstrap/` controls the cluster. Branch protection on `main` is part of the security boundary.
- Bad, because the `platform` project is broad by necessity (webhook configurations, CRDs, ClusterRoles), even with an enumerated whitelist.
- Bad, because adding a toolchain touches several places: its toolchain template, its wrapper chart, the cluster files and, if it renders cluster-scoped kinds, the `platform` whitelist.
- Neutral, because sync waves depend on the Application health check in the Argo CD values. Removing it disables the ordering without any error.

### Confirmation

- The `argocd-bootstrap` job renders both modes, validates them with kubeconform against the Argo CD CRD schemas, and asserts unique names, existing annotation paths and that every rendered kind and namespace is permitted by its AppProject.
- The `e2e-kind` job installs the `lab` profile on an empty kind cluster and waits until every Application is Synced and Healthy within a time budget. It also checks that a values commit rolls out without a hard refresh.
- Review: new toolchains follow the Application convention in [GitOps architecture](../architecture/gitops.md).

## Pros and cons of the options

### App of apps with static Applications rendered by a Helm chart

- Good, because sync waves order Applications, once the Application health check is in place.
- Good, because the rendered output contains every Application, which CI and reviewers can inspect.
- Good, because the templates are plain Helm, with one file per toolchain.
- Bad, because each toolchain template repeats the same Application skeleton.
- Bad, because one root Application serves one cluster; more clusters need another root or ApplicationSets.

### ApplicationSets only

- Good, because list, Git and cluster generators scale to many apps and clusters from one object.
- Bad, because generated Applications are not part of the root Application's sync, so they do not follow its waves. Ordering needs Progressive Syncs, which the Argo CD documentation marks as beta and which must be enabled on the controller.
- Bad, because the generated Applications do not appear in the rendered output.
- Bad, because per-toolchain differences (namespace labels, sync options, waves) turn into template conditionals.

### Flux

- Good, because it is a CNCF graduated project with `dependsOn` ordering, native Helm releases and tenant isolation through service account impersonation.
- Bad, because it has no built-in web UI, and the AppProject, sync window and SSO model documented for this platform would have to be rebuilt with different objects.

### Plain Helm releases from CI

- Good, because it needs no controller in the cluster and the tooling is familiar.
- Bad, because CI must hold cluster-admin credentials (push model).
- Bad, because nothing detects or corrects drift between Git and the cluster.
- Bad, because ordering, retries and rollbacks must be scripted by hand.

## More information

Upstream sources, checked on 2026-11-16:

- Cluster bootstrapping with app of apps: <https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/>
- Application health assessment removed in 1.8: <https://argo-cd.readthedocs.io/en/stable/operator-manual/health/>
- Sync waves: <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/>
- Projects: <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/>
- Progressive Syncs: <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/>
- `manifest-generate-paths`: <https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/>
- Flux: <https://fluxcd.io/flux/>

Related pages and decisions:

- [GitOps architecture](../architecture/gitops.md), [Argo CD SSO](../security/argocd-sso.md), [Argo CD upgrades](../operations/upgrade-argocd.md), [Add an app](../operations/add-an-app.md)
- [ADR 0005: lab and reference profiles](0005-lab-and-reference-profiles.md)
- [ADR 0007: wrapper charts](0007-wrapper-charts-instead-of-vendoring.md)
- [ADR 0011: promotion by pull request and digest](0011-promotion-by-pull-request-and-digest.md)
