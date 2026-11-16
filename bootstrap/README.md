# Bootstrap

Entry point from an empty cluster to a cluster that Argo CD manages from Git.

```bash
make bootstrap-gitops CLUSTER=lab
```

`hack/bootstrap-gitops.sh` validates `clusters/<name>/cluster.yaml`, installs Argo CD with `hack/argocd-install.sh`, applies the AppProjects rendered by `argocd-bootstrap`, then applies the root Application rendered by this chart. It is idempotent. After the first sync Argo CD manages the AppProjects, every toolchain (Argo CD included) and every application from Git.

Running the script again is safe: once the `argo-cd` Application exists, the installer only waits for the Argo CD rollouts. `ARGOCD_REINSTALL=1` forces a Helm recovery run of the installer; the variable passes through to it.

## Files

| File | Purpose |
|---|---|
| `templates/root-app.yaml` | Root Application `root`: renders `argocd-bootstrap` with `values.yaml` and `../clusters/<name>/cluster.yaml`. Project `platform`, automated sync with prune and self-heal, no cascading finalizer. |
| `templates/clusters-applicationset.yaml` | Hub mode only (`hub.enabled`): one root Application per registered remote cluster. |
| `repo-secret.example.yaml` | Repository credentials for a private fork. Never committed filled in. |

## Overrides

| Variable | Use |
|---|---|
| `REPO_URL` | Repository Argo CD reads, when the cluster file still holds the `YOUR_ORG` placeholder or for a fork. |
| `TARGET_REVISION` | Branch, tag or commit. The end-to-end job passes the commit under test. |
| `REPO_SECRET_FILE` | Repository Secret outside the repository, or a SOPS-encrypted file. |
| `HUB_MODE` | `1` adds the ApplicationSet that bootstraps registered remote clusters. |

The overrides end up in the root Application's `valuesObject.git`, so every child Application follows the same repository and revision.

## Changing the root Application

The root Application is not managed by itself. A change to this chart or to the git settings is applied by running the script again. Everything below the root is reconciled by Argo CD.

## Hub mode (two-cluster reference)

One Argo CD in the hub manages remote clusters as well as its own.

1. Give each remote cluster a definition, for example `clusters/prod/cluster.yaml` with `cluster.destination.name: prod` and `cluster.environments: [prod]`.
2. Register it: `argocd cluster add <context> --name prod --label cluster-definition=prod`.
3. Run the bootstrap for the hub's own definition with `HUB_MODE=1`, for example `HUB_MODE=1 make bootstrap-gitops CLUSTER=nonprod`.

The ApplicationSet `clusters` then creates `root-prod`, which renders `argocd-bootstrap` for the prod definition. Objects of a remote cluster are prefixed with its name (`prod-platform`, `prod-apps-prod`, `prod-hello-api-prod`), so several clusters share one Argo CD namespace without collisions. Toolchain Applications must use the helpers `argocd-bootstrap.name`, `argocd-bootstrap.platformProject` and `argocd-bootstrap.destination` for hub mode to work.
