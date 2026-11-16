# Build and publish the documentation site

The Markdown under `docs/` is also published as a static site built with MkDocs and the Material theme. This page covers the local build, the checks it enforces, publishing to GitHub Pages and keeping the toolchain current.

## Build and preview locally

Prerequisite: `uv` (pinned in `mise.toml`). The Make targets create a virtual environment under `_out/.venv-docs` from `requirements-docs.txt`, where every package is pinned with a hash; uv downloads Python 3.13 when the machine does not have it.

```bash
make docs-build
```

```bash
make docs-serve
```

`docs-build` writes the site to `_out/site` (gitignored). `docs-serve` serves a live preview on `http://127.0.0.1:8000`; set `DOCS_ADDR` to change the address.

## What the strict build checks

`mkdocs.yml` sets `strict: true` and turns every link validation to a warning, so the build fails on:

- a link to a page or file that does not exist,
- an anchor that does not exist on the target page,
- an absolute link or an unrecognised link inside `docs/`,
- a page listed in the nav that does not exist, or a page that is not in the nav.

Pages are written to be read on the Git host as well, so they link to files outside `docs/` with relative paths (for example `../../ansible/README.md`). MkDocs publishes `docs/` only. The hook `hack/mkdocs_hooks.py` rewrites those links to `<repo_url>/blob/main/<path>` (or `/tree/` for a directory) before MkDocs validates them. A relative link to a file that does not exist is left unchanged, so the strict build still reports it.

## Add a page

1. Create the Markdown file under the matching section of `docs/` (`getting-started`, `architecture`, `operations`, `how-to`, `reference`, `security` or `adr`).
2. Add it to `nav` in `mkdocs.yml`. An entry without a title takes the first heading of the page.
3. Link it from `docs/README.md`, which is the home page of the site and the map of the documentation on the Git host.
4. Run `make docs-build` and `make lint-markdown`.

## Publish to GitHub Pages

The workflow `.github/workflows/docs.yml` runs the strict build on every pull request that changes `docs/`, `mkdocs.yml`, `requirements-docs.txt` or the hook. On `main` it uploads `_out/site` as a Pages artifact and deploys it with `actions/deploy-pages`.

Enabling Pages is a one-time step for a repository administrator: in the repository settings, under Pages, set the source to "GitHub Actions". The deploy job creates the `github-pages` environment on its first run. Until Pages is enabled, the deploy job fails while the build job keeps reporting. Set `site_url` in `mkdocs.yml` to the published address (for example `https://your-org.github.io/sk-k8s-devops-bootstrap/`) so canonical links and the sitemap are correct.

The build job has read access to the repository only. The deploy job alone holds `pages: write` and `id-token: write`, runs only on `main`, and uses no cache.

## Keep the toolchain current

- Renovate updates the pins and hashes in `requirements-docs.txt` and the action SHAs in the workflow.
- After changing one of the three direct pins in the header of `requirements-docs.txt` (`mkdocs`, `mkdocs-material`, `pymdown-extensions`), run `make docs-lock` to resolve the transitive packages again for every platform.
- The Material theme prints an end-of-life notice during the build: its maintainers announced the end of life of Material for MkDocs for 5 May 2027 and name Zensical as the successor that reads an existing `mkdocs.yml`. Plan the migration before that date and verify the hook and the strict checks with the new tool.
