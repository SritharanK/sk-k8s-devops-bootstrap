# Upgrade Argo CD

This runbook upgrades Argo CD through a pull request, one minor version at a time. It is for platform operators who review and merge dependency updates.

## How Argo CD is installed

- `helmcharts/system-charts/argo-cd` is a wrapper chart. Its `Chart.yaml` pins the upstream chart `oci://ghcr.io/argoproj/argo-helm/argo-cd` to an exact version, and `Chart.lock` records it. Platform settings live in `values.yaml` and the profile files `values-lab.yaml` and `values-reference.yaml`.
- The Helm release is `argocd` in the namespace `argocd`. `make bootstrap-gitops` installs it once through `hack/argocd-install.sh` (`make install-argocd PROFILE=<lab|reference>` runs the same script on its own). After that, the `argo-cd` Application manages Argo CD from Git, including its own upgrades.
- Renovate opens a pull request for every new chart version. Nothing auto-merges.
- The wrapper's [README](../../helmcharts/system-charts/argo-cd/README.md) holds the version-specific upgrade steps for this repository and the OIDC configuration. This page is the generic procedure around them.

The chart version and the Argo CD version differ. The Argo CD version is the chart's `appVersion`. The `argocd` CLI reaches the server through the Gateway and needs `--grpc-web`.

## Risks to check in every upgrade

- CRD changes. The chart ships the Argo CD CRDs. A new minor can add fields or versions that an older controller does not understand, which matters for rollback.
- RBAC changes. New minors have changed default permissions and the meaning of existing `policy.csv` rules. Check the notes against the generated `policy.csv` (groups mapped to `role:admin`, `role:deployer` and `role:readonly`) and the empty `policy.default`.
- Tracking method. A change of the resource tracking method (label or annotation) requires every Application to sync once afterwards.
- Removed or renamed settings. Keys in `argocd-cm`, `argocd-cmd-params-cm` and the chart values can move or disappear. The custom Application health check in the wrapper values must survive the upgrade, otherwise sync waves stop waiting for child Applications.
- Redis. Authentication must stay enabled.

## Procedure

### Purpose

Move Argo CD to the next minor version (or a patch of the current one) without losing control of the cluster.

### When to use

When Renovate opens a pull request that changes the `argo-cd` dependency in `helmcharts/system-charts/argo-cd/Chart.yaml`, or when a security advisory requires a newer version.

### Preconditions

- The pull request changes only `helmcharts/system-charts/argo-cd/Chart.yaml` and `Chart.lock`, plus any value changes you add for the upgrade notes.
- All Applications are Synced and Healthy before you start (`kubectl -n argocd get applications`).
- The target Argo CD version supports the cluster's Kubernetes minor version. Check [the support matrix](../reference/support-matrix.md) and the upstream list of tested Kubernetes versions.
- The `argocd`, `helm`, `yq` and `gh` CLIs, and an `argocd` login: `argocd login argocd.<domain> --grpc-web` (add `--sso` in the reference profile).

### Steps

1. Read the current and the proposed Argo CD versions:

   ```bash
   yq '.dependencies[] | select(.name == "argo-cd") | .version' helmcharts/system-charts/argo-cd/Chart.yaml
   helm show chart oci://ghcr.io/argoproj/argo-helm/argo-cd --version <current-chart-version> | yq '.appVersion'
   helm show chart oci://ghcr.io/argoproj/argo-helm/argo-cd --version <proposed-chart-version> | yq '.appVersion'
   ```

2. If the proposed `appVersion` is more than one minor ahead, do not merge the pull request as is. Pick the latest chart version of the next minor from the argo-helm releases, set it in `Chart.yaml` on the branch, and refresh the lock file:

   ```bash
   helm dependency update helmcharts/system-charts/argo-cd
   ```

   Repeat the whole procedure for each minor in between. Patch releases of the current minor need no special steps.

3. Read the upstream upgrade notes for every minor you cross (`<from>-<to>` pages under the upgrading overview), the "Upgrading" section of the upstream chart README, and the version-specific steps in the wrapper [README](../../helmcharts/system-charts/argo-cd/README.md). Add every required change to the wrapper values in the same pull request, and record new version-specific steps in the wrapper README.

4. Review the rendered diff. CI renders every chart for each profile but does not show the difference in the pull request, so run `make render` on both revisions and compare `_out/`:

   ```bash
   BEFORE="${TMPDIR:-/tmp}/render-before-$(date +%Y%m%dT%H%M%S)"
   git switch main && make render && cp -R _out "$BEFORE"
   gh pr checkout <pr-number> && make render
   diff -ru "$BEFORE" _out
   ```

   Look first at `CustomResourceDefinition`, `ClusterRole`, `argocd-cm`, `argocd-rbac-cm` and `argocd-cmd-params-cm`.

5. Optional for a minor upgrade, recommended before a major one: export the Argo CD state. The export contains Argo CD Secrets, so store it outside the repository with the same care as a credential:

   ```bash
   argocd admin export -n argocd > "argocd-export-$(date +%Y%m%d).yaml"
   ```

6. Wait for `ci-gate`. It includes `e2e-kind`, which installs the proposed version on kind in the lab profile, waits for every Application to become Synced and Healthy, and runs the platform assertions. The lab therefore runs every Argo CD upgrade before a real cluster does.

7. Merge the pull request. The `argo-cd` Application syncs the new chart and the Argo CD pods restart. Watch the rollout:

   ```bash
   kubectl -n argocd get pods -w
   ```

8. Apply any post-upgrade step from the notes. When the notes require a sync of every Application (for example after a tracking method change), automated sync performs it; check that no Application stays OutOfSync.

### Verification

```bash
argocd version --grpc-web
kubectl -n argocd get applications
argocd app get argo-cd --grpc-web
```

- The server reports the new version.
- Every Application is Synced and Healthy, including `argo-cd` itself.
- The UI answers at `https://argocd.<domain>`. In the reference profile, an SSO login works and maps groups as before (see [Argo CD SSO](../security/argocd-sso.md)).

### Rollback or abort

- Before the merge: close the pull request.
- After the merge: revert the merge commit in a new pull request (the GitHub "Revert" button or `git revert -m 1 <merge-commit>`), and merge it once `ci-gate` passes. Argo CD syncs the previous chart version.
- CRD changes may not roll back cleanly. The previous controller can reject fields that the newer CRD version stored, and a CRD whose stored versions changed cannot return to the old schema by a revert. Read the CRD diff from step 4 before you decide to roll back, and prefer a fix forward when the CRDs changed.
- If Argo CD can no longer reconcile itself, re-run `make install-argocd PROFILE=<lab|reference>` from a checkout of the reverted commit to apply the wrapper chart directly, then let the `argo-cd` Application take over again.
- If settings were lost, import the export from step 5 with `argocd admin import -n argocd - < argocd-export-<date>.yaml`.

## References

- Upgrading overview: <https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/>
- Disaster recovery (export and import): <https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/>
- Resource tracking: <https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/>
- Tested Kubernetes versions: <https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/>
- Upstream chart and its upgrading notes: <https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd>
- Argo CD releases: <https://github.com/argoproj/argo-cd/releases>
- Wrapper chart convention: [ADR 0007](../adr/0007-wrapper-charts-instead-of-vendoring.md)
