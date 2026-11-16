# Contributing

Contributions are welcome through pull requests. This page covers the development setup, the checks a change must pass, and the conventions for commits, documentation and decisions.

## Development setup

All tools are pinned. Use one of the two options.

- mise: install [mise](https://mise.jdx.dev/), then run `make tools` (or `mise install`) in the repository root. It installs the versions pinned in `mise.toml` (helm, kubectl, kind, kyverno CLI, kubeconform, cosign, ansible-core, shellcheck, yq and the other tools the Make targets use).
- Devcontainer: open the repository in an editor or service that supports [development containers](https://containers.dev/). `.devcontainer/devcontainer.json` provides the same toolchain.

`make doctor` checks that every required tool is on `PATH` and prints its version.

Then install the Git hooks:

```bash
pre-commit install
pre-commit run --all-files
```

The hooks are fast. They cover file hygiene, YAML and Markdown lint, secret scanning with gitleaks, shellcheck and shfmt, actionlint and zizmor, hadolint, helm lint and ansible-lint. The helm-lint and ansible-lint hooks use the network on their first run, to download chart dependencies and Ansible collections; the others run offline. Heavier checks run in CI.

To run the platform locally, follow the [quick start](docs/getting-started/quick-start.md): `make demo` brings up the `lab` profile on kind.

## Checks before you open a pull request

`make help` lists every target. The ones you need most:

| Target | What it checks |
| --- | --- |
| `make lint` | YAML, Markdown, shell, workflow and Dockerfile linters |
| `make validate-config` | Cluster and tenant files against their schemas; placeholders are warnings, and `STRICT=1 CLUSTER=<name>` rejects them in one cluster file |
| `make render` | Renders every chart for each profile into `_out/` (gitignored) |
| `make kubeconform` | Validates the rendered manifests against the Kubernetes and CRD schemas |
| `make policy-test` | Kyverno policy tests and policy checks against the rendered apps |
| `make ansible-lint` | ansible-lint with the production profile |
| `make validate` | The static checks above in one run |
| `make e2e` | The end-to-end test on kind: brings the demo up, runs the assertions and deletes the cluster. `SKIP_UP=1` uses a running `make demo` cluster, `KEEP=1` keeps the cluster |

The full list with the script behind each target is in [Make targets](docs/reference/make-targets.md). CI runs the same checks; the single required status is `ci-gate` (see [CI/CD](docs/architecture/ci-cd.md)).

## Rules for changes

- No secrets, ever. Use placeholders (`CHANGE_ME`, `YOUR_ORG`, `example.com`, `localtest.me`). Real values live in gitignored files (`vault.yml`, `hosts.yml`, `.env`) or in the secrets backend. See [secrets handling](docs/security/secrets-handling.md).
- No real IP addresses, hostnames or organisation names in code, values, docs or tests. Use RFC 5737 addresses (`192.0.2.0/24`) or RFC 1918 examples.
- Pin versions exactly: chart dependencies, images (by digest where the contract asks for it), GitHub Actions (by full commit SHA with a version comment), and tools in `mise.toml`. Never use `latest`.
- Platform components are wrapper charts over upstream charts. Do not vendor upstream chart sources into the repository. The two existing exceptions, `local-path` (`vendor/`) and `system-upgrade-controller` (`upstream/`), exist because upstream publishes no Helm repository for them. See [ADR 0007](docs/adr/0007-wrapper-charts-instead-of-vendoring.md).
- Workloads must meet the workload contract enforced by the policies. Use `helm-common`; see [helm-common values](docs/reference/helm-common-values.md).
- A new CI check lands in the same pull request that makes it pass. CI is never red on `main`, and no job is advisory.
- Nothing merges automatically, including dependency updates.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
<type>(<optional scope>): <summary in the imperative, lower case, no trailing period>

<optional body: what and why, wrapped at 72 characters>
```

Types: `feat`, `fix`, `docs`, `style`, `chore`, `refactor`, `test`, `ci`, `build`, `perf`, `revert`. Common scopes: `ansible`, `gitops`, `charts`, `policy`, `ci`, `docs`, `hello-api`. Mark breaking changes with `!` after the type or scope and a `BREAKING CHANGE:` footer.

The CI job `commit-lint` checks every commit subject of a pull request; run the same check locally with `make lint-commits BASE=origin/main`. Keep one logical change per commit and one topic per pull request.

### Sign-off (optional)

Signing off commits with the [Developer Certificate of Origin](https://developercertificate.org/) is welcome but not required. Use `git commit -s` to add the `Signed-off-by` trailer.

## Pull requests

- Fill in the pull request template: what, why, risk and rollback, test plan.
- Include the rendered diff for chart or values changes when it is not obvious: run `make render` on the base branch and on your branch and compare the two `_out/` trees. No CI job posts a rendered diff.
- Changes under `envs/prod/` need a review from the code owners.
- Add a line under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for any change a user of the platform would notice.

## Documentation

- One topic, one page. Link to the owning page instead of repeating it. The map is [docs/README.md](docs/README.md).
- Plain, direct sentences. No marketing language, no emoji. Separate facts from recommendations.
- Do not write component versions in prose; they come from the generated [support matrix](docs/reference/support-matrix.md).
- Diagrams are Mermaid in the Markdown file.
- The `docs` CI job runs markdownlint and a lychee link check that also checks external links over the network. Run `make lint` and `make lint-links` before pushing.

## Architecture decisions

A change that alters a decision recorded in [docs/adr](docs/adr/README.md), or that introduces a new component, a new profile or a new trust boundary, needs an ADR. Copy `docs/adr/template.md`, use the next number, and open it with status `proposed` in the same pull request as the change. Accepted ADRs are not edited to change their decision; a new ADR supersedes them.

## Reporting security issues

Do not open public issues for vulnerabilities. Follow [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE) of this repository.
