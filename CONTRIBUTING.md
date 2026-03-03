# Contributing

Updates and improvements are welcome via pull request.

## Before you submit

- **No secrets:** Do not commit real credentials, tokens, or unsealed secrets. Use placeholders (e.g. `YOUR_*`) or document "set locally." See [docs/SECURITY.md](docs/SECURITY.md).
- **Config:** Keep `config/defaults.yaml.example` and `ansible/inventories/dev/hosts.ini.example` as the single source of placeholders; do not add new hardcoded IPs or URLs in code.

## Code quality checks

Run these locally before pushing to catch errors early:

| Check | Command |
|-------|---------|
| **All charts + yamllint** | `make check` (requires `helm`; `yamllint` optional) |
| **Helm lint only** | `make helm-lint` |
| **Render all app charts** | `make helm-render` |
| **Resolve helm-common dep** | `make helm-deps` (run once after clone) |
| **YAML lint only** | `yamllint -d relaxed config/defaults.yaml.example argocd-bootstrap/values.yaml` |

On push/PR the [CI workflow](.github/workflows/validate.yml) runs automatically:
- **`helm-lint`** — `helm lint --strict` on all app and managed system charts (blocking)
- **`helm-template`** — renders `argocd-bootstrap` end-to-end (blocking)
- **`yamllint`** — relaxed YAML lint on key config files (non-blocking)
- **Trivy config scans** — four advisory jobs covering `sample-services/`, `helmcharts/`, `kyverno-policies/`, and `argocd-bootstrap/` (non-blocking; to make blocking set `exit-code: '1'` and remove `continue-on-error`)
- **Gitleaks** — secrets scan across full git history (non-blocking)

**Trivy enforcement:** Jenkins CI pipelines (`scripts/jenkinsfiles/ci/*.Jenkinsfile`) run `trivy image` and **block** on CRITICAL/HIGH findings. GitHub Actions Trivy is advisory only. See [docs/SECURITY.md](docs/SECURITY.md).

If you add new Ansible playbooks or Helm charts, run `ansible-playbook --syntax-check` or `make helm-lint` as appropriate so the repo stays in a good state for contributors.

## Scope

- **In scope:** Bug fixes, docs, dependency version bumps, new optional system charts (marked "optional / not tested in every combination"), security and lint improvements.
- **Out of scope:** We do not promise to keep every chart at latest forever; validated versions are documented in [docs/VERSIONS.md](docs/VERSIONS.md).

Thank you for contributing.
