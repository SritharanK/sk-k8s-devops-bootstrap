# Documentation

This page is the map of the documentation and a suggested reading order for three audiences. Each topic has one page; other pages link to it instead of repeating it.

## Reading order

### Evaluating the platform

1. [README](../README.md): scope, profiles, status and what is tested.
2. [Quick start](getting-started/quick-start.md): run the `lab` profile on kind and trigger a policy denial.
3. [Architecture overview](architecture/overview.md): principles, layering and component map.
4. [Decision records](adr/README.md): the trade-offs behind each choice.
5. [Security controls](security/controls.md) and [known limitations](security/known-limitations.md).

### Operating a cluster

1. [Prerequisites](getting-started/prerequisites.md) and [production setup](getting-started/production-setup.md) for the `reference` profile on RKE2.
2. [Configuration reference](reference/configuration.md): every key of `clusters/<name>/cluster.yaml`.
3. [GitOps structure](architecture/gitops.md): how Argo CD, AppProjects and sync waves are arranged.
4. Runbooks under [operations](#how-to-guides-operations): backup and restore, upgrades, secret rotation, promotion, troubleshooting.
5. [Support matrix](reference/support-matrix.md): component versions and end-of-life dates.

### Contributing or adding a service

1. [CONTRIBUTING](../CONTRIBUTING.md): toolchain, Make targets, commit conventions.
2. [Adding an app](operations/add-an-app.md) and the [helm-common values reference](reference/helm-common-values.md).
3. [CI/CD](architecture/ci-cd.md) and [promotion](operations/promotion.md).
4. [Make targets](reference/make-targets.md).

## Map by document type

The documentation follows four types: tutorials teach by doing, how-to guides solve one task, reference pages describe facts, and explanations give the reasoning.

### Tutorials (getting started)

| Page | Covers |
| --- | --- |
| [Prerequisites](getting-started/prerequisites.md) | Workstation tools, hardware, supported operating systems |
| [Quick start](getting-started/quick-start.md) | The `lab` profile on kind with `make demo` |
| [Production setup](getting-started/production-setup.md) | The `reference` profile on RKE2, end to end |

### How-to guides (operations)

| Page | Covers |
| --- | --- |
| [Backup and restore](operations/backup-and-restore.md) | etcd snapshots, Velero, key escrow, restore drill |
| [Upgrade Argo CD](operations/upgrade-argocd.md) | Minor-by-minor upgrade of the self-managed Argo CD |
| [Upgrade RKE2](operations/upgrade-rke2.md) | Automated and manual Kubernetes upgrades |
| [Secret rotation](operations/secret-rotation.md) | Rotation per secret class, response to a committed secret |
| [Add an app](operations/add-an-app.md) | Service, chart, environment values, Applications |
| [Promotion](operations/promotion.md) | Deployment policy, dev to stage to prod by digest |
| [Troubleshooting](operations/troubleshooting.md) | Symptoms, checks and fixes |
| [Observability contract](operations/observability-contract.md) | Probes, metrics, logs and traces every workload provides |

### How-to guides (optional features)

| Page | Covers |
| --- | --- |
| [Tracing](how-to/tracing.md) | OpenTelemetry in an app, Tempo, links between traces, logs and metrics |
| [Traffic and scaling](how-to/traffic-and-scaling.md) | Envoy Gateway BackendTrafficPolicy per app, KEDA instead of the HPA |
| [Preview environments](how-to/preview-environments.md) | One namespace per labelled pull request, removed when it closes |
| [Documentation site](how-to/documentation-site.md) | MkDocs build, strict checks, GitHub Pages |

### Reference

| Page | Covers |
| --- | --- |
| [Configuration](reference/configuration.md) | `clusters/<name>/cluster.yaml` and its schema |
| [helm-common values](reference/helm-common-values.md) | Library chart values and the workload contract |
| [Make targets](reference/make-targets.md) | Every target and the script behind it |
| [Support matrix](reference/support-matrix.md) | Generated component versions and end-of-life dates |

### Explanation (architecture, security, decisions)

| Page | Covers |
| --- | --- |
| [Overview](architecture/overview.md) | Scope, principles, layering, profiles |
| [GitOps](architecture/gitops.md) | Bootstrap, app of apps, AppProjects, sync waves, values layering |
| [CI/CD](architecture/ci-cd.md) | Validation, build, signing, end-to-end test |
| [Security controls](security/controls.md) | Enforcement matrix |
| [Threat model](security/threat-model.md) | Assets, trust boundaries, threats, policy demonstrations |
| [Secrets handling](security/secrets-handling.md) | Sealed Secrets, External Secrets Operator with OpenBao, Ansible vault |
| [Supply chain](security/supply-chain.md) | SBOM, provenance, signing, verification |
| [Known limitations](security/known-limitations.md) | Accepted risks and gaps |
| [Argo CD SSO](security/argocd-sso.md) | OIDC and Dex configuration, RBAC mapping |
| [Decision records](adr/README.md) | ADR index |

## Conventions

- Placeholders: `YOUR_ORG`, `CHANGE_ME`, `example.com` for real deployments and `localtest.me` for the lab. The CI `config` job reports placeholders left in cluster and tenant files as warnings; `make validate-config STRICT=1 CLUSTER=<name>` and `make preflight` reject them before a real install.
- Component versions are not written in prose. They are generated into the support matrix from the rendered manifests.
- Diagrams are Mermaid source in the Markdown files.
