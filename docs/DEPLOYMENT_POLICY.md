# Deployment policy

- **No `:latest` in production** — Use explicit tags (e.g. `1.2.3`, `prod-<gitsha>`). CD updates image tags in values via PR.
- **Tag format** — Prefer `1.2.3+<gitsha>` or `prod-<gitsha>` so each tag points to an exact commit. Document in your CI (e.g. Jenkins) how the tag is set.
- **CD updates values via PR** — The CD pipeline (or a human) updates the image tag in the app’s `values-<env>.yaml` and pushes to the GitOps repo; Argo CD syncs. No ad-hoc `kubectl set image`.
- **Traceability** — Tag → commit → build. Ensure your registry and Git history allow tracing a running image back to source.

Reference this policy in README and in CI/CD documentation.
