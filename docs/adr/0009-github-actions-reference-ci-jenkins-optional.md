---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# GitHub Actions as reference CI, Jenkins as an optional adapter

This record explains where CI runs for this repository and what role Jenkins keeps. It is for contributors, reviewers who read the pipelines, and operators who need CI on premises.

## Context and problem statement

The repository needs CI for two purposes: validating every change (lint, render, schema checks, policy tests, end-to-end on kind) and building, signing and promoting the sample service image. Reviewers should be able to see every pipeline run without access to private infrastructure. Some sites cannot use a hosted CI service and run Jenkins on premises.

Where should the reference CI run, and what happens to Jenkins?

## Decision drivers

- Pipelines and their results visible to anyone who reads the repository.
- An OIDC identity for keyless signing and native artifact attestations ([ADR 0008](0008-keyless-image-signing.md)).
- No CI server to operate for the reference path.
- One required status check that gates merges.
- A supported option for sites that must build on premises.
- Limited maintenance effort for a second CI implementation.

## Considered options

- GitHub Actions only
- Jenkins only
- Both, with GitHub Actions as the reference and Jenkins as an optional adapter
- Move Jenkins to a separate repository

## Decision outcome

Chosen option: "Both, with GitHub Actions as the reference and Jenkins as an optional adapter", because GitHub Actions meets every driver for the reference path, while a hardened, optional Jenkins adapter keeps an on-premises path without making it a dependency.

GitHub Actions, the reference:

- `.github/workflows/validate.yml` runs the jobs `workflow-lint`, `secrets`, `commit-lint`, `yaml-lint`, `docs`, `shell-lint`, `config`, `ansible`, `opentofu`, `helm`, `argocd-bootstrap`, `policy-test`, `policy-test-attestations`, `dockerfile-lint`, `trivy-config`, `jenkins-lint` and `e2e-kind`. The aggregator job `ci-gate` depends on all of them and is the only required check.
- Separate workflows: `build-image.yml` (build, scan, sign, attest), `promote.yml`, `e2e.yml`, `scorecard.yml` (OpenSSF Scorecard) and `dependency-review.yml`.
- Every action is pinned by full commit SHA. Renovate updates the pins; nothing auto-merges.

Jenkins, the optional adapter:

- Installed with `make install-jenkins` (role `ansible/roles/install_jenkins`, playbook `ansible/playbooks/jenkins_setup.yml`). It is not part of the default installation.
- One declarative Jenkinsfile per job type, `ci/jenkins/pipelines/build.Jenkinsfile` and `ci/jenkins/pipelines/promote.Jenkinsfile`, run from SCM and therefore inside the Groovy sandbox. Job DSL (`ci/jenkins/jobs/services.groovy`) generates `services/<name>/build` and `services/<name>/promote` for every entry of `ci/jenkins/services.yaml`; it is applied through configuration as code when the role runs, so no repository Groovy runs on the controller at build time. A global shared library was rejected because global libraries run outside the sandbox.
- Builds run on Kubernetes agents with rootless BuildKit; the controller has zero executors. Jenkins signs images with a cosign key pair (transparency log upload off by default), and its promote job also accepts the keyless GitHub Actions identity.
- Secrets are JCasC file secrets, and TLS terminates in front of the controller.

### Consequences

- Good, because every pipeline, its configuration and its results are public and reviewable.
- Good, because keyless signing and attestations need no secret in CI.
- Good, because `ci-gate` gives branch protection one stable check name, regardless of how many jobs it aggregates.
- Good, because sites that cannot use a hosted CI service still have a documented, hardened path.
- Bad, because two CI implementations must be kept in step when the build contract changes, and the Jenkins path is the one most likely to drift.
- Bad, because CI only lints the Jenkins pipelines (`jenkins-lint`); it does not run them end to end.
- Bad, because images built by Jenkins are signed with a long-lived cosign key pair, not with the GitHub Actions identity. A site that builds with Jenkins and enables image verification must add the Jenkins public key to the verification policy, and must protect and rotate that private key.
- Bad, because the reference path depends on GitHub: its runners, its OIDC issuer and its registry. Workflow files are GitHub-specific.
- Neutral, because standard hosted runners are free for public repositories; a private copy of the repository consumes the account's included minutes.

### Confirmation

- `ci-gate` is the only required status check on `main`; it fails when any job it depends on fails.
- The `workflow-lint` job runs actionlint and zizmor on every workflow.
- The `jenkins-lint` job lints the Jenkins pipelines with the declarative linter in a pinned Jenkins LTS container. The `ansible` job covers the `install_jenkins` role with ansible-lint.
- Review: a new workflow or job is added to `ci-gate` and documented in [CI/CD architecture](../architecture/ci-cd.md).

## Pros and cons of the options

### GitHub Actions only

- Good, because there is one CI implementation to maintain.
- Bad, because sites that must build on premises have no supported path.

### Jenkins only

- Good, because it runs anywhere, including air-gapped sites.
- Bad, because reviewers cannot see the pipelines run, and the platform must operate and secure a CI server.
- Bad, because keyless signing through an OIDC identity and native attestations are not available without extra infrastructure.

### Both, with GitHub Actions as the reference and Jenkins as an optional adapter

- Good, because the reference path is visible and needs no CI server, while the on-premises path stays available.
- Bad, because two implementations must follow the same build contract.

### Move Jenkins to a separate repository

- Good, because this repository becomes smaller and has one CI implementation.
- Bad, because the adapter would drift from the build contract it implements, with no shared review or lint.
- Neutral, because it remains the fallback if the Jenkins adapter stops being maintained.

## More information

Upstream sources, checked on 2026-11-16:

- GitHub Actions workflow syntax: <https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions>
- GitHub OIDC: <https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect>
- Jenkins controller isolation: <https://www.jenkins.io/doc/book/security/controller-isolation/>
- Jenkins shared libraries (global libraries run outside the sandbox): <https://www.jenkins.io/doc/book/pipeline/shared-libraries/>
- Jenkins adapter details: `ci/jenkins/README.md` and `ansible/roles/install_jenkins/README.md`
- Jenkins Kubernetes plugin: <https://plugins.jenkins.io/kubernetes/>
- Jenkins Configuration as Code: <https://www.jenkins.io/projects/jcasc/>

Related pages and decisions:

- [CI/CD architecture](../architecture/ci-cd.md), [Make targets](../reference/make-targets.md), [supply chain](../security/supply-chain.md)
- [Contributing](../../CONTRIBUTING.md)
- [ADR 0008: keyless image signing](0008-keyless-image-signing.md)
- [ADR 0011: promotion by pull request and digest](0011-promotion-by-pull-request-and-digest.md)
