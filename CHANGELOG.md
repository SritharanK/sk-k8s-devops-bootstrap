# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Component version changes are not listed here one by one; the generated [support matrix](docs/reference/support-matrix.md) records the current versions.

No version is tagged yet. The first release takes the Unreleased section with its version and date.

## [Unreleased]

First public release: an RKE2 and Argo CD platform reference with current components, secure delivery, a tested lab path and documentation.

### Added

- RKE2 HA reference topology: three servers behind a registration address, optional CIS profile, audit policy and PriorityClasses.
- Backup and restore: scheduled RKE2 etcd snapshots to S3, Velero with Kopia, SeaweedFS as the lab S3 target, sealing key escrow, and `make dr-drill` (`hack/dr/restore-drill.sh`), run on demand against the current kube context.
- Optional observability profile: kube-prometheus-stack, Grafana Alloy, Loki, optional Tempo, SLOs as code, dashboards in Git.
- Optional progressive delivery: Argo Rollouts with the Gateway API traffic router plugin and a `success-rate` analysis template; `helm-common` renders a Rollout when `rollout.enabled` is set.
- Optional RKE2 upgrade automation with system-upgrade-controller Plans, nonprod first.
- Storage: Longhorn as the default StorageClass of the `reference` profile; local-path and CloudNativePG as optional toolchains, off by default (kind brings its own local-path provisioner).
- Off by default: KEDA, OpenCost, Falco and Trivy Operator wrapper charts.
- Gateway API with Envoy Gateway: a platform `Gateway` with HTTP and HTTPS listeners and one certificate from cert-manager, with wildcard names for the self-signed issuer and ACME DNS-01 and the explicit host names for ACME HTTP-01. `helm-common` renders an `HTTPRoute`; the Argo CD UI is served through the Gateway.
- Reference CI in GitHub Actions: `build-image.yml` tests, builds with SBOM and provenance, pushes to GHCR, scans the pushed digest with Trivy, and only then signs with cosign keyless and publishes artifact attestations.
- Admission-time image signature verification with a Kyverno `ImageValidatingPolicy` in `stage` and `prod` of the `reference` profile.
- Promotion by pull request and digest: `envs/<env>/<app>/values.yaml`, `promote.yml`, CODEOWNERS on `envs/prod/` and a prod sync window.
- External Secrets Operator with OpenBao in the `reference` profile; offline sealing for Sealed Secrets in `lab`.
- Argo CD SSO through OIDC with group mapping per AppProject; the local admin is disabled in the `reference` profile.
- Generated support matrix (`make support-matrix`) with end-of-life dates, checked in CI.
- Renovate for chart dependencies, actions (by digest), Dockerfiles and tool versions. Nothing merges automatically.
- OpenSSF Scorecard and dependency review workflows.
- Baseline NetworkPolicies for the `argocd`, `envoy-gateway-system`, `cert-manager` and `kyverno` namespaces; platform-admin RBAC (the `admin` ClusterRole per environment namespace, cluster-wide read and node maintenance) and an operational `deployer` Role; no `cluster-admin` binding, break-glass through the RKE2 admin kubeconfig and the API server audit log.
- Documentation restructure: getting started, architecture, reference, security and operations runbooks, ADRs 0001 to 0011, `SECURITY.md`, `THIRD_PARTY_NOTICES.md` and this changelog.
- `clusters/<name>/cluster.yaml` with a JSON Schema, read by Ansible and by the root Argo CD Application; `make validate-config`.
- Blocking CI in `validate.yml` with a single required `ci-gate` check. Actions pinned by commit SHA.
- `make demo` and `make e2e`: the `lab` profile on kind, with assertions for convergence, routing, policy denials and network isolation in the `e2e-kind` job.
- Owned sample service `hello-api` in Go, with a distroless non-root image and unit tests.
- `helm-common` as a real library chart with named templates, a NetworkPolicy template, a values schema and a helm-unittest suite.
- Ansible roles `preflight`, `base`, `rke2` and `firewall`, pinned collections, ansible-lint with the production profile and Molecule scenarios.
- AppProjects `platform`, `apps-dev`, `apps-stage` and `apps-prod`; `default` locked.
- Kyverno policy tests run with `make policy-test` and in CI.
- Optional promotion orchestration with Kargo v1.12.5 (`kargo` toolchain, on in the `reference` profile): a Project, Warehouse and `dev`, `stage` and `prod` Stages per app of the inventory, auto-promotion to `dev`, manual `stage` and `prod`, a pull request for `prod`, `success-rate` verification, SSO with the Argo CD groups, and a kind harness (`tests/integration/kargo`). One writer by default: when a cluster file enables Kargo, `build-image.yml` and `promote.yml` stop writing the environment files (`hack/promotion-engine.sh`, tested with fixture cluster files); the repository variable `PROMOTION_ENGINE` (`workflows` or `kargo`) overrides that (ADR 0012).
- Release tags from `sample-services/<app>/VERSION`, added by `build-image.yml` only after scan, signature and attestations.
- Trivy vulnerability attestations (cosign keyless) on every published image, renewed daily for deployed digests; the `reference` profile admits images in `stage` and `prod` only with a fresh attestation without CRITICAL findings.
- Backstage catalog descriptors (`catalog-info.yaml`) with an OpenAPI description of `hello-api`, validated in `make lint` and CI.
- Pinned toolchain in `mise.toml` and a devcontainer; shared shell library `scripts/lib/common.sh`.
- `THIRD_PARTY_NOTICES.md`.
- Distributed tracing: OpenTelemetry in `hello-api` (spans, `trace_id` and `span_id` in the JSON logs), `otel.*` values in `helm-common` that set the `OTEL_*` environment and the egress NetworkPolicy, an optional `tracing` toolchain with Grafana Tempo, and `make integration-tracing` on kind.
- Pull request preview environments: a labelled pull request gets the namespace `pr-<number>` with quota, limits and default-deny network policies and the apps built from its head commit, removed when the pull request closes; off by default (`toolchains.previews.enabled`), render-tested in CI.
- Documentation site: MkDocs with the Material theme, a strict build in CI (`.github/workflows/docs.yml`) and publishing to GitHub Pages from `main`; `make docs-build` and `make docs-serve`.
- `helm-common` options for an Envoy Gateway BackendTrafficPolicy per application route and for KEDA scaling on request rate instead of the HorizontalPodAutoscaler.
- Argo CD 3.x as a wrapper chart on the upstream OCI chart, with Redis authentication, HA values and a self-managed Application.
- cert-manager, Sealed Secrets and Kyverno as wrapper charts on supported releases; Kyverno policies as CEL `ValidatingPolicy`.
- An optional, hardened Jenkins adapter: one sandboxed declarative pipeline per job type with jobs generated from a service list, Kubernetes agents with rootless BuildKit, no executors on the controller, file-based secrets, TLS, cosign signing, pinned LTS and plugins.
- Argo CD bootstrap is declarative (`bootstrap/templates/root-app.yaml`); sync waves are effective through an Application health check.
- Namespaces and CRDs are protected from cascade deletion.
- Secret scanning with gitleaks is blocking, with a weekly full-history scan.

### Security

- No component on a default path is past its end of life.
- The image signing identity is pinned to the owner and repository of `git.repoURL`.
- `make secrets` fails on a committed Kubernetes Secret with data outside Helm templates and example files.
- Kyverno and the NFS provisioner run with complete pod security contexts; the Trivy scan of the rendered manifests is blocking, with every accepted controller permission scoped to one rule and one component and an expiry date.
- Manifests are validated against the Kubernetes 1.35 and 1.36 schemas.

[Unreleased]: https://github.com/SritharanK/sk-k8s-devops-bootstrap/commits/main
