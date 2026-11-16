---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Lab and reference topology profiles

This record explains the two topology profiles, `lab` and `reference`, and what running all environments in one cluster costs. It is for evaluators, operators who plan a production installation, and reviewers of the platform's risk profile.

## Context and problem statement

The platform must be runnable by anyone on a laptop, testable in CI on every pull request, and still show a credible production topology with a highly available control plane, hardening and backups. The same charts and the same environment model (`dev`, `stage`, `prod`) must work in both cases, selected by one value per cluster (`cluster.profile` in `clusters/<name>/cluster.yaml`).

Which topologies should the repository support and test?

## Decision drivers

- A local installation that runs from a fresh clone with one command and no virtual machines.
- A topology that the CI end-to-end job can install on every pull request.
- A production-grade control plane that survives the loss of one server, with scheduled etcd snapshots.
- One set of charts and one environment model, with per-profile deltas only (`values-lab.yaml`, `values-reference.yaml`).
- Infrastructure cost and maintenance effort that one maintainer can carry.

## Considered options

- `lab` only
- `lab` plus a single-cluster `reference`
- `lab` plus a two-cluster `reference`

## Decision outcome

Chosen option: "`lab` plus a single-cluster `reference`", because it proves an HA control plane and the RKE2 path at the lowest infrastructure cost. The two-cluster topology is available as an untested option (hub mode, see below).

The profiles:

| Aspect | `lab` | `reference` |
| --- | --- | --- |
| Cluster | kind with Calico through `make demo`, or a single node | One RKE2 cluster: three servers behind a registration address, plus agents |
| Git source for Argo CD | In the kind demo, an in-cluster Gitea seeded from the local `HEAD` | The repository in `git.repoURL` |
| Environments | Namespaces `dev`, `stage`, `prod` in one cluster | Namespaces `dev`, `stage`, `prod` in one cluster |
| Hardening | Pod Security, Kyverno, NetworkPolicies | Same, plus the optional RKE2 CIS profile |
| Secrets | Sealed Secrets | External Secrets Operator with OpenBao |
| Certificates | `selfsigned` issuer, `*.localtest.me` | `letsencrypt-staging` or `letsencrypt` issuer |
| Argo CD access | Initial admin secret | OIDC SSO, admin disabled |
| Image verification | Disabled | Enforced in `stage` and `prod` |
| Backups | Optional components, off by default | Scheduled etcd snapshots; Velero optional |

A two-cluster `reference` (a `nonprod` cluster for `dev` and `stage`, a `prod` cluster, and a hub Argo CD) is implemented in the bootstrap chart as hub mode: `HUB_MODE=1`, `cluster.destination.name` and `cluster.environments` in each remote cluster's definition, and the ApplicationSet in `bootstrap/templates/clusters-applicationset.yaml`. It is not tested in CI. The procedure is in [`bootstrap/README.md`](../../bootstrap/README.md).

Blast radius of one cluster that hosts `prod`, stated plainly:

- One control plane and one etcd serve all three environments. A failed Kubernetes upgrade, an etcd fault or an overloaded API server affects `prod` as much as `dev`.
- One instance of each platform component (Argo CD, Kyverno, Envoy Gateway, cert-manager, External Secrets Operator) serves all environments. A faulty platform change reaches `prod` in the same sync as `dev`. The only place to try platform changes first is the `lab` profile, not a copy of the `reference` cluster.
- Workloads from all environments share nodes and kernels unless the operator adds dedicated node pools. A container escape in `dev` reaches nodes that run `prod`. Pod Security, Kyverno and default-deny NetworkPolicies reduce this risk; they do not remove it.
- ResourceQuota and LimitRange cap each environment, but a load test in `dev` still competes with `prod` for the same nodes.

Recommendation: when this blast radius is not acceptable, run `prod` on a separate cluster, either with its own copy of the platform or as a remote cluster of a hub Argo CD in hub mode. Because CI does not test hub mode, rehearse it on non-production clusters first.

### Consequences

- Good, because evaluators get a working platform with `make demo`, and CI tests the same profile on every pull request.
- Good, because the `reference` profile shows an HA control plane, CIS hardening, etcd snapshots, SSO and image verification without doubling the infrastructure.
- Good, because both profiles use the same namespaces, AppProjects and promotion flow, so the environment model is identical.
- Bad, because `prod` shares its control plane, platform components and nodes with `dev` and `stage` in the `reference` profile.
- Bad, because the `reference` profile is not installed in CI. Its HA behaviour is checked by a manual drill.
- Bad, because `lab` and `reference` differ in secrets backend, issuer and image verification, so a green `lab` run does not prove those `reference` paths.
- Neutral, because the profiles differ only through cluster files and per-profile values files, which keeps the drift between them visible in Git.

### Confirmation

- The `config` job (`make validate-config`) validates `clusters/lab/cluster.yaml` and `clusters/reference/cluster.yaml` against `clusters/schema.json` and the consistency checks, and reports placeholder values. `make validate-config STRICT=1 CLUSTER=<name>` rejects them before a real install.
- `make render` and the `argocd-bootstrap` job render every chart for each profile; the `helm` job lints every chart with each profile's values.
- The `e2e-kind` job installs the `lab` profile end to end on every pull request.
- A manual drill on the `reference` cluster confirms that the API stays available when one server node is lost, and its result is recorded.

## Pros and cons of the options

### `lab` only

- Good, because it is the cheapest option and fully tested in CI.
- Bad, because it shows no HA control plane, no RKE2 installation and no production secrets backend, so it is not a reference for production.

### `lab` plus a single-cluster `reference`

- Good, because it proves the HA control plane and the RKE2 path with three servers and a small number of agents.
- Good, because one Argo CD and one set of platform components keep operations simple.
- Bad, because of the blast radius described above.

### `lab` plus a two-cluster `reference`

- Good, because `prod` gets its own control plane, nodes and platform components, and platform changes reach `nonprod` before `prod`.
- Bad, because it doubles the infrastructure and adds a hub Argo CD that holds credentials for both clusters.
- Bad, because it needs ApplicationSet cluster generators and promotion across clusters, which is more work to build and test.
- Neutral, because the bootstrap chart implements it as hub mode, which CI does not test; the single-cluster `reference` stays the tested default.

## More information

Upstream sources, checked on 2026-11-16:

- RKE2 high availability: <https://docs.rke2.io/install/ha>
- RKE2 etcd backup and restore: <https://docs.rke2.io/datastore/backup_restore>
- kind: <https://kind.sigs.k8s.io/>

Related pages and decisions:

- [Quick start](../getting-started/quick-start.md) and [production setup](../getting-started/production-setup.md)
- [Cluster configuration reference](../reference/configuration.md)
- [Backup and restore](../operations/backup-and-restore.md), [known limitations](../security/known-limitations.md), [threat model](../security/threat-model.md)
- [ADR 0001: RKE2 as the only provisioner](0001-rke2-only.md)
- [ADR 0002: Argo CD app of apps with AppProjects](0002-argocd-app-of-apps-with-appprojects.md)
- [ADR 0006: secrets management](0006-sealed-secrets-and-eso-with-openbao.md)
