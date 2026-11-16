## What

<!-- One or two sentences on what changes. -->

## Why

<!-- The problem, issue or decision behind the change. Link the issue, for example "Closes #123". -->

## How it was tested

<!-- Tick what you ran and add anything else: profile (lab or reference), cluster, commands and results. -->

- [ ] `make lint`
- [ ] `make validate`
- [ ] `make render` and `make kubeconform` (charts, values, Argo CD applications)
- [ ] `make policy-test` (Kyverno policies)
- [ ] `make ansible-lint` (Ansible)
- [ ] Deployed and checked on a lab cluster

## Risk and rollback

<!-- What can break and for whom, and how to roll back: revert this pull request, pin the previous chart or image version, or roll back the Argo CD application. -->

## Checklist

- [ ] The pull request title follows Conventional Commits (`type(scope): summary`).
- [ ] `make lint` and `make validate` pass.
- [ ] Documentation is updated, or no change is needed.
- [ ] No secrets, credentials or environment data (real hostnames, IP addresses, domains, account or organisation names); `make secrets` (gitleaks) passes.
- [ ] Changes under `envs/prod/` are reviewed and approved by the production code owners.
- [ ] When a chart, image or tool version changes, `make support-matrix` was run and `docs/reference/support-matrix.md` is part of this pull request.
