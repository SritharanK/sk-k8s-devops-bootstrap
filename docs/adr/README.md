# Architecture decision records

This page explains how the platform records its architecture decisions and lists every decision taken so far. It is for contributors who propose a change to the platform's structure and for reviewers who want the reasoning behind it.

## What an ADR is in this repository

An architecture decision record (ADR) is a short Markdown file that captures one significant decision: the context, the options considered, the option chosen, and its consequences, including the downsides. An ADR is needed when a change:

- adds, replaces or removes a core component (distribution, GitOps engine, ingress, policy engine, secrets backend, CI system);
- changes a contract between parts of the repository, such as the cluster file, the helm-common values, the workload contract or the signing identity;
- changes a security control or the tenancy model;
- changes how environments, profiles or promotion work.

Version bumps, bug fixes and new options inside an existing decision do not need an ADR.

An accepted ADR is not edited to change its decision. When a decision changes, a new ADR supersedes the old one, so the history of the reasoning stays readable.

## Format

ADRs use [MADR 4](https://adr.github.io/madr/) in a minimal-plus form: the required MADR sections plus decision drivers, consequences, confirmation, pros and cons per option, and more information. The optional `consulted` and `informed` front matter keys are left out. Each ADR has:

- YAML front matter with `status`, `date` and `decision-makers`;
- one H1 title that names the problem and the chosen solution;
- the sections `Context and problem statement`, `Decision drivers`, `Considered options`, `Decision outcome` (with `Consequences` and `Confirmation`), `Pros and cons of the options` and `More information`.

The status is one of `proposed`, `accepted`, `rejected`, `deprecated` or `superseded by ADR-NNNN`. The date is the day the status last changed.

The `Confirmation` section names how compliance is checked: a CI job, a test, a Make target, a manual drill or a review rule. The `More information` section links the upstream sources, with the date they were checked, and the related docs pages and ADRs.

## How to add an ADR

1. Copy [`template.md`](template.md) to `NNNN-short-title.md`, where `NNNN` is the next free number with four digits and the title is lowercase with hyphens.
2. Fill in every section. State the downsides of the chosen option as concretely as its benefits, and keep facts, interpretation and recommendations apart.
3. Set `status: proposed` and open a pull request. Add a row to the index below in the same pull request.
4. When the pull request is approved, set `status: accepted`, update `date`, and merge.
5. To change an accepted decision, write a new ADR. In the old ADR, change only the status to `superseded by ADR-NNNN` and add a link to the new one. The new ADR links back to the one it supersedes.

Typo fixes and broken links in an accepted ADR can be corrected without a new record.

The `docs` job in `.github/workflows/validate.yml` checks every ADR with markdownlint and the lychee link checker.

## Index

ADRs 0001 to 0011 were recorded retrospectively on 2026-11-16. They document the decisions of the initial design, which is why they share one date. Later ADRs are written before the change they decide, as described in [How to add an ADR](#how-to-add-an-adr).

| Number | Title | Status | Date |
| --- | --- | --- | --- |
| [0001](0001-rke2-only.md) | RKE2 as the only Kubernetes provisioner | Accepted | 2026-11-16 |
| [0002](0002-argocd-app-of-apps-with-appprojects.md) | Argo CD app of apps with AppProjects | Accepted | 2026-11-16 |
| [0003](0003-gateway-api-with-envoy-gateway.md) | Gateway API with Envoy Gateway for ingress | Accepted | 2026-11-16 |
| [0004](0004-kyverno-cel-policies.md) | Kyverno CEL policies for admission control | Accepted | 2026-11-16 |
| [0005](0005-lab-and-reference-profiles.md) | Lab and reference topology profiles | Accepted | 2026-11-16 |
| [0006](0006-sealed-secrets-and-eso-with-openbao.md) | Sealed Secrets in lab, External Secrets Operator with OpenBao in reference | Accepted | 2026-11-16 |
| [0007](0007-wrapper-charts-instead-of-vendoring.md) | Wrapper charts instead of vendored upstream charts | Accepted | 2026-11-16 |
| [0008](0008-keyless-image-signing.md) | Keyless image signing with admission verification | Accepted | 2026-11-16 |
| [0009](0009-github-actions-reference-ci-jenkins-optional.md) | GitHub Actions as reference CI, Jenkins as an optional adapter | Accepted | 2026-11-16 |
| [0010](0010-go-sample-service.md) | One owned Go sample service | Accepted | 2026-11-16 |
| [0011](0011-promotion-by-pull-request-and-digest.md) | Promotion by pull request and digest | Accepted | 2026-11-16 |
| [0012](0012-kargo-promotion.md) | Kargo as optional promotion orchestration | Accepted | 2026-11-16 |
