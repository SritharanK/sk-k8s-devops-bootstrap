# Make targets reference

This page lists the Make targets, the variables they take and the script or playbook behind each one. It is for operators and contributors who run the platform from a workstation or reproduce a CI job locally.

`make help` prints the authoritative list with a one-line description per target. Run every target from the repository root. Recipes run in bash with `-eu -o pipefail`, so the first failing command stops the target and the exit code reaches CI. Targets whose script comes from another part of the repository fail with a clear message when that script is missing.

Targets that talk to a cluster use the current kubeconfig (`KUBECONFIG` or `~/.kube/config`). The kubeconfig of an RKE2 cluster is fetched to `ansible/data/`; the kind demo writes its own under `_out/demo/`.

## Variables

| Variable | Default | Used by |
| --- | --- | --- |
| `CLUSTER` | `lab` | Cluster definition `clusters/<CLUSTER>/cluster.yaml` and inventory `ansible/inventories/<CLUSTER>/hosts.yml` for the Ansible and GitOps targets |
| `PROFILE` | `$(CLUSTER)` | Ansible inventory, `VAULT_ID` and `make install-argocd` |
| `INVENTORY` | `inventories/$(PROFILE)/hosts.yml`, relative to `ansible/` | Ansible targets; set it to use another inventory file |
| `VAULT_ID` | `$(PROFILE)@prompt` | Ansible targets; passed as `--vault-id`, so Ansible prompts for the vault password. For automation set `<profile>@<absolute path to a password file or client script>`. See [`ansible/README.md`](../../ansible/README.md) |
| `ANSIBLE_VAULT_IDENTITY_LIST` | empty | Ansible targets; when set (exported), it replaces `VAULT_ID` and the Makefile passes no `--vault-id` |
| `ANSIBLE_ARGS` | empty | Extra arguments for `ansible-playbook`, for example `--limit` or `--check` |
| `OUT_DIR` | `_out` | Render output of `make render` and the targets that depend on it |
| `BASE` | none | Start commit for `make lint-commits` and `make secrets-range` |
| `STRICT` | empty | `make validate-config STRICT=1` fails on placeholders; combine with `CLUSTER=<name>` to check one cluster file |
| `CONFIRM` | empty | `make rke2-uninstall CONFIRM=yes` |
| `RENDER_ARGS` | empty | Extra arguments for `hack/render.sh` in `make render` and the targets that run it, for example `--profile lab`. `make argocd-bootstrap` sets `--skip-lint` |
| `KUBECONFORM_EXTRA_VERSIONS` | `1.35.0` | `make kubeconform`: Kubernetes versions validated in addition to the one of each cluster file |
| `TRIVY` | `trivy` | Trivy binary for `make trivy-config` |
| `GH_TOKEN` | empty | `make lint-workflows`: without a token zizmor runs with `--offline`; with one it also runs its online audits |
| `JENKINS_LINT_ARGS` | empty | Arguments for `hack/jenkins-lint.sh`; `--static-only` skips the Docker part |
| `PUSH` | empty | `make publish-chart PUSH=1` (or `yes`, `true`) pushes; otherwise the target is a dry run |
| `CHART` | empty; the script defaults to `helmcharts/helm-common` | `make publish-chart`: chart directory relative to the repository root |
| `HELM_OCI_REPO` | empty; the script defaults to `oci://ghcr.io/your-org/charts` | `make publish-chart`: target OCI repository. Read by the script from the environment or the command line |
| `DOCS_ADDR` | `127.0.0.1:8000` | Listen address of `make docs-serve` |

## Help

| Target | What it does |
| --- | --- |
| `make help` | Prints every target with its description, grouped by section, and the current values of `CLUSTER`, `PROFILE`, `INVENTORY`, `VAULT_ID` and `OUT_DIR`. It is the default target, so `make` alone does the same. |

## Setup

| Target | What it does |
| --- | --- |
| `make tools` | Installs the toolchain pinned in `mise.toml` (`mise trust` and `mise install`). |
| `make doctor` | Checks that every required tool is on `PATH` and prints its version. |
| `make helm-plugins` | Installs the helm-unittest plugin at the version pinned in the Makefile: downloads the release archive into `OUT_DIR/.cache`, verifies its SHA-256 and runs `helm plugin install`. Does nothing when that version is installed, and fails when another version is, with the command to remove it. The unit test targets run it first. |

## Lint

These targets need no cluster and no credentials.

| Target | What it does |
| --- | --- |
| `make lint` | Runs `lint-yaml`, `lint-markdown`, `lint-links-offline`, `lint-shell`, `lint-workflows`, `lint-dockerfiles` and `lint-catalog`. |
| `make lint-yaml` | yamllint with `.yamllint.yaml`; Helm `templates/` are excluded. |
| `make lint-markdown` | markdownlint-cli2 with `.markdownlint-cli2.yaml`. |
| `make lint-links` | lychee link check of every link in the Markdown files (uses the network). |
| `make lint-links-offline` | lychee check of the local links and anchors in the Markdown files; no network. |
| `make lint-shell` | shellcheck and shfmt on every tracked shell script. |
| `make lint-workflows` | actionlint and zizmor on the GitHub workflows and composite actions. zizmor runs offline unless `GH_TOKEN` is set. |
| `make lint-dockerfiles` | hadolint on every tracked Dockerfile. |
| `make lint-catalog` | Validates `catalog-info.yaml` with the Backstage entity validator pinned by `hack/catalog/package-lock.json` (installed once with `npm ci --ignore-scripts` under `_out/.cache`), and checks that every `$text` definition exists and an OpenAPI definition parses. Needs Node.js 22 or later. |
| `make lint-commits BASE=<commit>` | Checks that the commit subjects in `BASE..HEAD` follow Conventional Commits. |
| `make test-lib` | Self-test of `scripts/lib/common.sh`. |
| `make promotion-engine-test` | Test of `hack/promotion-engine.sh`, which decides whether the workflows or Kargo write the environment files, against the fixture cluster files in `tests/promotion-engine/fixtures`. Needs yq v4. |

## Security

| Target | What it does |
| --- | --- |
| `make secrets` | gitleaks on the committed tree and the working-copy changes, then a check that fails on a committed Kubernetes `kind: Secret` with `data` or `stringData` in any YAML file outside Helm `templates/` directories and `*.example.yaml` files (`hack/secrets.sh`). |
| `make secrets-range BASE=<commit>` | gitleaks on the commits in `BASE..HEAD`. |
| `make secrets-history` | gitleaks on the full history with the credential rules only (`.github/gitleaks-history.toml`). |
| `make secrets-test` | Self-test of the gitleaks rules with generated fixtures (`hack/secrets-test.sh`). |
| `make trivy-config` | Runs `make render`, then a Trivy misconfiguration scan of the rendered manifests with the exceptions in `.github/trivy-ignore.yaml`. Writes `trivy-config.json` and `trivy-config.sarif` to `OUT_DIR` and fails on a HIGH or CRITICAL finding. `TRIVY` selects the binary. |

## Validate

These targets need no cluster. `make validate` runs `validate-config`, `helm`, `argocd-bootstrap` and `policy-test`. `kubeconform`, `argocd-bootstrap`, `policy-test`, `support-matrix` and `support-matrix-check` run `make render` first.

| Target | What it does | Script |
| --- | --- | --- |
| `make validate` | `validate-config`, `helm`, `argocd-bootstrap` and `policy-test`. | Makefile |
| `make validate-config` | Validates every `clusters/*/cluster.yaml` against `clusters/schema.json` and every `tenants/*.yaml` against `tenants/schema.json`, and runs the consistency checks. With `CLUSTER=<name>` on the command line or in the environment, it validates only `clusters/<name>/cluster.yaml`. Reports placeholders as warnings; with `STRICT=1` it fails on them, and on an `example.com` domain in the `reference` profile. The shipped `lab` file and `tenants/team-a.yaml` keep placeholders, so use `STRICT=1 CLUSTER=<name>` for the cluster you install. See [configuration](configuration.md#validation). | `hack/validate-config.sh` |
| `make helm` | `helm-lint`, `helm-unittest` and `argocd-bootstrap-unittest`. | Makefile |
| `make helm-lint` | `helm dependency build` and `helm lint --strict` of every chart. | `hack/render.sh --lint-only` |
| `make helm-unittest` | Runs `make helm-plugins`, then `helm unittest --strict` for every chart under `helmcharts/` with a `tests/*_test.yaml` suite, including `helm-common`; builds the chart dependencies first where `Chart.yaml` declares any. | Makefile |
| `make argocd-bootstrap-unittest` | Runs `make helm-plugins`, then `helm unittest --strict` with every `argocd-bootstrap/tests/*_test.yaml` suite. `previews_test.yaml` holds the render tests of the pull request preview AppProjects and ApplicationSets; `signing_test.yaml` those of the image signing identity derived from `git.repoURL`; `kargo_test.yaml` those of the Kargo toolchain and its pipelines; `monitoring_test.yaml` those of app scraping when the monitoring toolchain is on. | Makefile |
| `make render` | Renders `argocd-bootstrap` and every chart for each cluster profile into `OUT_DIR` (gitignored). `RENDER_ARGS` passes extra options to the script. | `hack/render.sh` |
| `make render-all` | Alias for `make render`. | `hack/render.sh` |
| `make kubeconform` | Validates the rendered manifests against the Kubernetes schemas for `cluster.kubernetesMinor`, again for every version in `KUBECONFORM_EXTRA_VERSIONS` (default `1.35.0`, the other supported minor), and against the CRD schemas. | `hack/kubeconform.sh` |
| `make argocd-bootstrap` | Emulates the app of apps: runs `make kubeconform` (render with `--skip-lint`, then schema validation), then `check-projects.sh --deep`, which checks the Applications and the AppProject permissions of every rendered object. | `argocd-bootstrap/tests/check-projects.sh` |
| `make policy-test` | `kyverno test` on the policy test cases, and `kyverno apply` of the rendered policies to every rendered app and environment. | `hack/policy-test.sh` |
| `make policy-test-attestations` | `kyverno test` of the vulnerability attestation gate of the image verification policy: images in a throwaway local registry, signed and attested with an ephemeral cosign key, must be admitted or denied with the expected reason. Needs Docker and cosign; not part of `make ci`. See [the test README](../../helmcharts/system-charts/kyverno-policies/tests/vuln-attestation/README.md). | `helmcharts/system-charts/kyverno-policies/tests/vuln-attestation/run.sh` |
| `make support-matrix` | Regenerates `docs/reference/support-matrix.md` from the rendered manifests. | `hack/support-matrix.sh` |
| `make support-matrix-check` | Fails when the committed support matrix differs from a fresh render. | `hack/support-matrix.sh` |

## Containers

| Target | What it does | Script |
| --- | --- | --- |
| `make image-smoke` | Builds each sample service image and smoke tests it: the container starts read-only as non-root and answers on `/readyz` and `/metrics`. Needs Docker. | `hack/image-smoke.sh` |

## Release

| Target | Variables | What it does | Script |
| --- | --- | --- | --- |
| `make publish-chart` | `PUSH=1`; optional `CHART=<chart directory>` (default `helmcharts/helm-common`) and `HELM_OCI_REPO=oci://<registry>/<path>` (default `oci://ghcr.io/your-org/charts`) | Runs `helm lint --strict` on the chart and packages it with `helm package` into a temporary directory. Without `PUSH=1` it is a dry run: it prints the `helm push` command and pushes nothing; the `your-org` placeholder in `HELM_OCI_REPO` only gives a warning. With `PUSH=1` it fails while `HELM_OCI_REPO` still holds the placeholder, fails when that chart version already exists in the repository, and otherwise runs `helm push`. `HELM_OCI_REPO` must start with `oci://`. Log in first with `helm registry login`, and bump `version` in `Chart.yaml` before a push, because published versions are immutable. | `hack/publish-chart.sh` |

## Ansible

These targets run Ansible against the hosts in the inventory of `CLUSTER`. See [production setup](../getting-started/production-setup.md).

| Target | What it does | Playbook |
| --- | --- | --- |
| `make ansible-deps` | Installs the pinned Ansible collections from `ansible/collections/requirements.yml`. | |
| `make ansible-lint` | Runs `make ansible-deps`, then ansible-lint with the production profile (`ansible/.ansible-lint`). | |
| `make ansible-syntax` | Runs `make ansible-deps`, then `ansible-playbook --syntax-check` of every playbook and an `ansible-inventory --list` parse check of every `inventories/*/hosts.yml.example`. | `ansible/playbooks/*.yml` |
| `make molecule` | Runs `make ansible-deps`, then every Molecule scenario of the roles (Docker driver). | `ansible/roles/*/molecule/` |
| `make preflight CLUSTER=<name>` | Checks the hosts before an install: supported operating system, swap, kernel modules, sysctl settings, placeholders. | `ansible/playbooks/preflight.yml` |
| `make bootstrap-k8s CLUSTER=<name>` | Installs or updates RKE2: servers one at a time, then agents, then fetches the kubeconfig to `ansible/data/` with mode 0600. Also the entry point for RKE2 upgrades; see [upgrade RKE2](../operations/upgrade-rke2.md). | `ansible/playbooks/site.yml` |
| `make rke2-uninstall CONFIRM=yes CLUSTER=<name>` | Destructive. Removes RKE2 and its data, etcd included, from every host in the inventory. Refuses to run without `CONFIRM=yes`. | `ansible/playbooks/rke2_uninstall.yml` |
| `make install-jenkins CLUSTER=<name>` | Optional. Installs the Jenkins on-premises CI adapter. | `ansible/playbooks/jenkins_setup.yml` |
| `make jenkins-lint` | Static checks of the Jenkins adapter, then the declarative linter on the pipelines in a local Jenkins controller (Docker). `JENKINS_LINT_ARGS=--static-only` or `make jenkins-lint-static` (see [CI](#ci)) runs only the static checks. | `hack/jenkins-lint.sh` |

The inventory files are gitignored and copied from `hosts.yml.example`. [`ansible/README.md`](../../ansible/README.md) describes the roles and the vault, and [`ansible/inventories/README.md`](../../ansible/inventories/README.md) the inventories.

Recommendation: take an etcd snapshot and copy it off the nodes before `make rke2-uninstall`. [Backup and restore](../operations/backup-and-restore.md) covers it.

## Infrastructure

| Target | What it does |
| --- | --- |
| `make tofu-validate` | `tofu fmt -check`, then `tofu init -backend=false` and `tofu validate` of every module under `infra/`, and `tofu test` where a module has a `tests/` directory. The tests mock the cloud provider, so they need no token and create nothing. See [`infra/README.md`](../../infra/README.md). |

## GitOps

These targets run against the cluster in the current kubeconfig. `make bootstrap-gitops` is the one entry point from an empty cluster to GitOps; it is idempotent, and running it again applies a change to the root Application.

| Target | Variables | What it does | Script |
| --- | --- | --- | --- |
| `make bootstrap-gitops` | `CLUSTER=<name>`; optional `REPO_URL`, `TARGET_REVISION`, `REPO_SECRET_FILE`, `HUB_MODE=1`, and the script variables `SKIP_ARGOCD_INSTALL=1`, `WAIT=0`, `WAIT_TIMEOUT` (default 600s), `RENDER_ONLY=1`, `DRY_RUN=1` | Validates `clusters/<name>/cluster.yaml`; installs Argo CD with `hack/argocd-install.sh` unless `SKIP_ARGOCD_INSTALL=1`; applies the repository Secret from `REPO_SECRET_FILE` (a file outside the repository, or a SOPS-encrypted `*.sops.yaml`); applies the AppProjects rendered by `argocd-bootstrap` and the root Application rendered by the `bootstrap/` chart; waits until the root Application is Synced. `REPO_URL` and `TARGET_REVISION` land in the root Application's `valuesObject.git`, so every child follows them. `HUB_MODE=1` adds the ApplicationSet for remote clusters. See [GitOps](../architecture/gitops.md#bootstrap). | `hack/bootstrap-gitops.sh` |
| `make install-argocd` | `PROFILE=lab` or `PROFILE=reference` | Installs or upgrades Argo CD alone from the wrapper chart `helmcharts/system-charts/argo-cd` with the profile's values, as Helm release `argocd` in namespace `argocd`. Not a required step before `make bootstrap-gitops`, which runs the same script. Once the `argo-cd` Application manages Argo CD, the script leaves Helm alone. | `hack/argocd-install.sh` |

## Demo and end-to-end

These targets need Docker. See [quick start](../getting-started/quick-start.md).

| Target | What it does | Script |
| --- | --- | --- |
| `make demo` | Brings up the `lab` profile on a local kind cluster and prints the URLs. | `hack/demo/up.sh` |
| `make demo-down` | Deletes the demo kind cluster. | `hack/demo/down.sh` |
| `make e2e` | Runs the end-to-end test on kind: brings up the demo, runs the assertions of the CI job `e2e-kind`, and deletes the cluster at the end. `SKIP_UP=1` reuses a running demo cluster; `KEEP=1` keeps the cluster. | `hack/e2e/run.sh` |
| `make dr-drill` | Backup and restore drill against the current kube context: backs up, deletes and restores a namespace and a SealedSecret, and checks the result. Needs Velero already installed, because the target does not pass `--install`; run the script with `--install` on a cluster without it. See [backup and restore](../operations/backup-and-restore.md#run-the-restore-drill). | `hack/dr/restore-drill.sh` |

## CI

| Target | What it does |
| --- | --- |
| `make ci` | Runs locally the static CI checks: `lint`, `test-lib`, `promotion-engine-test`, `secrets`, `secrets-test`, `validate-config`, `helm`, `argocd-bootstrap`, `policy-test`, `trivy-config`, `support-matrix-check`, `ansible-lint`, `ansible-syntax`, `tofu-validate` and `jenkins-lint-static`. It needs no Docker. It needs the network for the helm-unittest plugin, chart dependencies, Ansible collections, OpenTofu providers and the end-of-life data of the support matrix. |
| `make jenkins-lint-static` | `make jenkins-lint` with `JENKINS_LINT_ARGS=--static-only`: the static checks of the Jenkins adapter (`hack/jenkins-lint.sh`), without Docker. |

[CI and CD](../architecture/ci-cd.md) maps the targets to the CI jobs.

## Documentation site, previews, tracing and Kargo

The documentation site is built with MkDocs from `mkdocs.yml`. MkDocs and its plugins run from a virtual environment under `OUT_DIR` that uv creates from `requirements-docs.txt`, where every package is pinned with hashes. uv downloads Python 3.13 when the machine does not have it.

| Target | What it does | Script |
| --- | --- | --- |
| `make docs-venv` | Creates or updates the virtual environment `OUT_DIR/.venv-docs` (`uv venv`) and installs exactly the packages of `requirements-docs.txt` with `uv pip sync --require-hashes`. | Makefile |
| `make docs-build` | Runs `make docs-venv`, then `mkdocs build --strict --clean` into `OUT_DIR/site`. A broken link or a warning fails the build. The Docs workflow runs the same target. | Makefile |
| `make docs-serve` | Runs `make docs-venv`, then `mkdocs serve --strict` with live reload on `DOCS_ADDR` (default `127.0.0.1:8000`). | Makefile |
| `make docs-lock` | Rewrites `requirements-docs.txt`: keeps its header, reads the direct pins listed in the header and resolves the full set again with `uv pip compile --generate-hashes --universal` for Python 3.13. Needs the network. Run it after changing a direct pin. | Makefile |
| `make previews-test` | Runs `make helm-plugins`, then only the preview suite `argocd-bootstrap/tests/previews_test.yaml` with `helm unittest --strict`. `make argocd-bootstrap-unittest` and `make helm` run it as well. | Makefile |
| `make integration-tracing` | Tracing integration test: in a throwaway kind cluster, a request to `hello-api` with `otel.enabled` must produce a trace in Tempo from the `tracing` chart. Needs Docker. The script reads `KEEP_CLUSTER=1` (keep the cluster) and `TIMEOUT` (Helm and rollout timeout, default `5m`). See [`tests/integration/tracing/README.md`](../../tests/integration/tracing/README.md). | `tests/integration/tracing/run.sh` |
| `make integration-kargo` | Kargo integration test: in a throwaway single-node kind cluster with a local registry and the demo Git server, the Warehouse discovers two hello-api releases, `dev` auto-promotes and verifies, `stage` waits for a manual promotion, and `prod` waits for its pull request to be merged. Needs Docker and about 5 GiB free in its VM. The script reads `KEEP_CLUSTER`, `MIN_FREE_GIB`, `MEMORY_WAIT` and `PHASE_TIMEOUT`. See [`tests/integration/kargo/README.md`](../../tests/integration/kargo/README.md). | `tests/integration/kargo/run.sh` |

## Scripts

Make targets are the entry points. The scripts behind them live in two places:

- `hack/` holds the scripts that Make targets and CI jobs call: the ones in the tables above, plus `hack/secrets-test.sh`, `hack/image-smoke.sh` (starts the `hello-api` image and checks `/readyz` and `/metrics` for the `dockerfile-lint` job) and `hack/jenkins-lint.sh` (the `jenkins-lint` job). Operators also run `hack/seal.sh` directly, for offline sealing in the `lab` profile (see [secrets handling](../security/secrets-handling.md#lab-sealed-secrets-with-offline-sealing)).
- `scripts/` holds the shared library `scripts/lib/common.sh` and the remaining helper scripts that are not Make entry points.

Every script sources `scripts/lib/common.sh`, which provides:

- strict mode (`errexit`, `nounset`, `pipefail`, `errtrace`) and an error trap that reports file, line and exit code;
- logging to stderr (`log_info`, `log_warn`, `log_error`, `die`), so standard output stays usable for data;
- precondition checks (`require_cmd`, `require_env`) and temporary files that are removed on exit;
- placeholder checks: `is_placeholder` and `config_get`, which reads a key from a cluster file with yq and fails on a missing value, `CHANGE_ME` or `YOUR_` placeholders;
- a confirmation prompt for destructive steps, skipped with `CONFIRM=yes`.

The library reads `LOG_LEVEL` (`debug`, `info`, `warn`, `error`), `NO_COLOR` and `DRY_RUN=1`. The CI job `shell-lint` runs shellcheck and shfmt on every script.
