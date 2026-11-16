---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Wrapper charts instead of vendored upstream charts

This record explains how the platform sources upstream Helm charts and keeps them current. It is for anyone who adds, configures or upgrades a platform component.

## Context and problem statement

The platform installs many upstream charts: Argo CD, cert-manager, Kyverno, Envoy Gateway, the secrets controllers and the optional operations components. Each needs an exact pinned version, owner values kept apart from upstream defaults, small deltas per profile, reviewable updates and a path for sites without internet access. Copying full upstream charts into Git gives offline rendering and Git-level integrity, but it fills the repository with upstream code that no update tool can maintain.

How should the repository reference upstream charts?

## Decision drivers

- Exact, reviewable version pins with automated update pull requests.
- Owner values separate from upstream code, with per-profile deltas.
- A repository that contains owner code, not copies of upstream projects.
- Rendering in CI and in Argo CD from the same chart definition.
- Verification of chart provenance where the publisher signs.
- A workable answer for air-gapped sites.

## Considered options

- Vendor full upstream charts into Git
- Thin wrapper charts with a pinned dependency
- Argo CD multi-source Applications pointing at upstream repositories
- Mirror charts to an internal OCI registry

## Decision outcome

Chosen option: "Thin wrapper charts with a pinned dependency", because it is the only option that keeps the pin, the owner values and the profile deltas in one reviewable directory that Renovate, Helm, CI and Argo CD all understand.

Every platform component follows this layout:

```text
helmcharts/system-charts/<name>/
  Chart.yaml              dependencies: upstream name, exact version, oci:// repository where offered
  Chart.lock              committed
  values.yaml             owner values under the dependency key
  values-lab.yaml         lab deltas
  values-reference.yaml   reference deltas
  README.md               purpose, upstream source, pinned version, upgrade notes
```

The `charts/` directory is never committed. Renovate opens a pull request for each dependency update; nothing auto-merges. CI does not verify chart provenance; only `hack/argocd-install.sh` does, for the Argo CD chart at install time (`helm dependency build --verify` with `keys/argo-helm.asc`). Two components are vendored because upstream publishes no Helm repository for them: `local-path` keeps the upstream chart in `vendor/local-path-provisioner`, and `system-upgrade-controller` is a local chart built from the upstream release manifests in `upstream/`. The toolchain Application points at the wrapper directory and passes `values.yaml` plus `values-<profile>.yaml` ([ADR 0002](0002-argocd-app-of-apps-with-appprojects.md)).

Air-gapped sites mirror the charts and images to an internal OCI registry (for example Harbor or Zot) and point the dependencies at the mirror. They do not vendor charts into Git.

### Consequences

- Good, because the repository holds only owner code and values; upstream code stays upstream.
- Good, because each update is a small Renovate pull request that CI renders and validates for every profile.
- Good, because owner values are visible in one file per component, apart from upstream defaults.
- Good, because each wrapper README records the upstream source and the upgrade notes that apply to it.
- Bad, because rendering needs network access to the chart registries, in CI and in the Argo CD repository server, which runs `helm dependency build` for each wrapper. An unreachable registry delays syncs of changed charts.
- Bad, because `Chart.lock` pins versions, not chart content. A republished version is detected only where provenance is verified, which today is the Argo CD chart at install time.
- Bad, because owner values sit one level down, under the dependency key. A value under a misspelled key is silently ignored; Helm reports it only where a values schema rejects unknown keys.
- Bad, because a version bump hides the upstream diff. Reviewers read the upstream release notes or compare rendered output.
- Neutral, because air-gapped sites run a registry mirror, which they need for images anyway.

### Confirmation

- The `helm` job in `.github/workflows/validate.yml` runs dependency build and `helm lint --strict` per chart and profile, and helm-unittest where tests exist. The `argocd-bootstrap` job renders every chart per profile and validates the output with kubeconform against the profile's Kubernetes version and 1.35.
- The `trivy-config` job scans the rendered manifests.
- `make render` renders every chart for each profile into `_out/` for local review.
- Review: no `charts/` directory is committed, every wrapper has a `Chart.lock` and a README, and the Renovate configuration enables no auto-merge.

## Pros and cons of the options

### Vendor full upstream charts into Git

- Good, because rendering works offline and Git holds the full upstream content, with Git-level integrity.
- Bad, because upstream files dominate the repository and every review.
- Bad, because no update tool can bump a vendored chart; updates are manual copies.
- Bad, because local edits and owner values mix with upstream code and drift without notice.

### Thin wrapper charts with a pinned dependency

- Good, because Renovate and Helm understand `Chart.yaml` and `Chart.lock` natively.
- Good, because the pin, the values and the profile deltas change together in one pull request.
- Good, because a wrapper can add owner templates next to the upstream chart.
- Bad, because rendering depends on registry availability.

### Argo CD multi-source Applications pointing at upstream repositories

- Good, because no wrapper files are needed: the chart comes from upstream and the values from Git.
- Bad, because the chart version lives in the Application manifest, apart from the values.
- Bad, because CI must reproduce the source composition to lint and validate what Argo CD renders; plain `helm template` no longer matches.
- Bad, because owner templates next to the chart need yet another source.

### Mirror charts to an internal OCI registry

- Good, because it works air-gapped and controls availability and integrity at one point.
- Bad, because the mirror is another stateful service to run, secure and keep in sync.
- Neutral, because a mirror does not decide where owner values live; it complements wrapper charts rather than replacing them.

## More information

Upstream sources, checked on 2026-11-16:

- Helm chart dependencies: <https://helm.sh/docs/helm/helm_dependency/>
- Helm provenance and integrity: <https://helm.sh/docs/topics/provenance/>
- Helm OCI registries: <https://helm.sh/docs/topics/registries/>
- Renovate Helm manager: <https://docs.renovatebot.com/modules/manager/helmv3/>
- Argo CD multiple sources: <https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>
- Harbor: <https://goharbor.io/>, Zot: <https://zotregistry.dev/>

Related pages and decisions:

- [GitOps architecture](../architecture/gitops.md), [supply chain](../security/supply-chain.md), [support matrix](../reference/support-matrix.md)
- [Third-party notices](../../THIRD_PARTY_NOTICES.md)
- [ADR 0002: Argo CD app of apps with AppProjects](0002-argocd-app-of-apps-with-appprojects.md)
