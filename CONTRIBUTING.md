# Contributing

Updates and improvements are welcome via pull request.

## Before you submit

- **No secrets:** Do not commit real credentials, tokens, or unsealed secrets. Use placeholders (e.g. `YOUR_*`) or document "set locally." See [docs/SECURITY.md](docs/SECURITY.md).
- **Config:** Keep `config/defaults.yaml.example` and `ansible/inventories/dev/hosts.ini.example` as the single source of placeholders; do not add new hardcoded IPs or URLs in code.

## Code quality checks

Run these locally before pushing to catch errors early:

| Check | Command / where |
|-------|------------------|
| **Helm (argocd-bootstrap)** | From repo root: `helm template argocd-bootstrap ./argocd-bootstrap --set spec.source.repoURL=https://github.com/example/repo.git --set spec.destination.server=https://kubernetes.default.svc --set spec.destination.app_ns=prod --set spec.destination.argo_ns=argocd --set spec.source.targetRevision=main` |
| **YAML lint** | `yamllint -d relaxed config/defaults.yaml.example argocd-bootstrap/values.yaml` (optional; install with `pip install yamllint`) |
| **CI workflow** | On push/PR, [.github/workflows/validate.yml](.github/workflows/validate.yml) runs Helm template, **Trivy config scan** (advisory), and optional yamllint; fix any failures. |
| **Trivy policy** | **Enforcement:** Jenkins CI pipelines (see `scripts/jenkinsfiles/ci/*.Jenkinsfile`) run Trivy image scan and **block** the build on CRITICAL/HIGH. **Advisory:** GitHub Actions Trivy step runs config scan on `sample-services/` but does not fail the workflow; use the job log to fix findings. To make CI blocking, set `exit-code: '1'` and remove `continue-on-error` in the workflow. See [docs/SECURITY.md](docs/SECURITY.md). |

If you add new Ansible playbooks or Helm charts, run `ansible-playbook --syntax-check` or `helm template` as appropriate so the repo stays in a good state for contributors.

## Scope

- **In scope:** Bug fixes, docs, dependency version bumps, new optional system charts (marked "optional / not tested in every combination"), security and lint improvements.
- **Out of scope:** We do not promise to keep every chart at latest forever; validated versions are documented in [docs/VERSIONS.md](docs/VERSIONS.md).

Thank you for contributing.
