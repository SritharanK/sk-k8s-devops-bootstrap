# End-to-end tests (Chainsaw)

Chainsaw v0.2.15 suite for the lab profile on kind: Argo CD app-of-apps,
Envoy Gateway, cert-manager, Kyverno, Sealed Secrets and the hello-api sample
service in `dev`, `stage` and `prod`.

## Run

```bash
make e2e                 # or: hack/e2e/run.sh
KEEP=1 make e2e          # keep the kind cluster afterwards
```

`hack/e2e/run.sh` creates the cluster, exports the environment below and runs:

```bash
chainsaw test --config tests/e2e/.chainsaw.yaml --test-dir tests/e2e \
  --report-path "${E2E_REPORT_DIR}"
```

Chainsaw does not expand environment variables in `.chainsaw.yaml`, so the
report directory is passed with `--report-path` (it must exist). The JUnit
report is `${E2E_REPORT_DIR}/chainsaw-report.xml`. To run one test against a
running cluster, export the same variables and add
`--include-test-regex '<test name>'`.

Tests run one at a time in directory order and never stop the suite on the
first failure. Each test gets an ephemeral namespace with the restricted Pod
Security level; Chainsaw deletes it and every resource it created.

## Environment

| Variable | Meaning |
| --- | --- |
| `KUBECONFIG` | kind cluster. Chainsaw hands scripts a temporary copy without a namespace, so scripts always pass `-n`. |
| `REPO_ROOT` | absolute repository root |
| `DEMO_CLUSTER` | kind cluster name (used by `kind load` in tests 05 and 10) |
| `DEMO_STATE_DIR` | kubeconfig, CA and downloads of the cluster |
| `DEMO_CA_FILE` | PEM of the lab CA, written by the runner |
| `DEMO_HTTPS_PORT` | host port mapped to the Gateway `https` listener |
| `DEMO_DOMAIN` | base domain of the routes (`localtest.me`) |
| `DEMO_GIT_NAMESPACE`, `DEMO_GIT_URL` | in-cluster Git server used by the commit helpers |
| `E2E_REPORT_DIR` | report directory; test 04 also appends `policy-denial-layers.txt` there |

Scripts in `lib/` also read optional settings, documented in each script
header (for example `SYNC_WAVE_SKEW_SECONDS`, `REPORT_TIMEOUT_SECONDS`,
`METRICS_TIMEOUT_SECONDS`, `ROLLOUT_TIMEOUT_SECONDS`).

Host tools: `chainsaw`, `kubectl`, `jq`, `curl`, `yq` (v4), `awk`, `sed`,
`base64`, plus `docker` and `kind` for the probe image of test 05 and for the
new image tag of test 10 (`hack/e2e/values-commit.sh`).

## Tests

| Test | Asserts |
| --- | --- |
| `01-applications-healthy` | No Application in `argocd` is out of sync or unhealthy; cert-manager, kyverno, kyverno-policies, envoy-gateway, misc and network-policies exist; every configured environment (dev always, stage and prod when `apps-<env>` or the namespace exists) has a hello-api Application. |
| `02-sync-waves` | For child Applications A, B with wave(A) < wave(B), B was created at or after the first `-> Healthy` event of A. Fails when such an event is missing (events expire after the API server event TTL, 1h by default). |
| `03-policy-audit-dev-enforce-stage` | A pod whose only violation is a `:latest` tag is admitted in `dev` and gets a failed result in its policy report (`wgpolicyk8s.io` or `openreports.io`); in `stage` it is denied by an admission policy, not by Pod Security Admission. |
| `04-policy-threat-model` | Privileged, root and `:latest` pods are denied in `stage` and `prod`; the denying layer and message of each case are printed as evidence. The test fails when a case is denied by anything other than Pod Security Admission or the policy engine, and when `:latest` is not denied by the policy engine. In `stage` and `prod`, Pod Security Admission (`restricted`) rejects the privileged and root pods before Kyverno sees them; the Kyverno rules for those cases are covered by `make policy-test`. |
| `05-network-policy-default-deny` | A client in the test namespace (positive control: API server) and a client in `stage` (positive control: DNS of the dev Service) both hit a TCP connect timeout to hello-api in `dev`. |
| `06-gateway-hello-api` | From the host, `https://hello-api.<env>.<domain>/readyz` returns 200 through the Gateway with the lab CA, for dev and for stage and prod when deployed; `https://argocd.<domain>/healthz` returns 200 when an HTTPRoute for it exists. |
| `07-metrics-scrape` | Skipped unless Prometheus runs; then a hello-api target is `up` within 3 minutes. |
| `08-argocd-redis-auth` | From the test namespace, Redis on 6379 in `argocd` times out (NetworkPolicy); inside the Redis pod an unauthenticated PING answers `NOAUTH`. |
| `09-namespaces-pss` | `dev`, `stage`, `prod` enforce a Pod Security level (dev baseline or restricted, stage and prod restricted) with a pinned `enforce-version`, and carry `Prune=false` and `Delete=false` in `argocd.argoproj.io/sync-options`. |
| `10-values-commit-rollout` | A hello-api tag committed to the dev values (normal refresh, no hard refresh) is running and rolled out within 4 minutes. |
| `11-toggle-keeps-namespaces` | Disabling the misc toolchain removes its Application while `dev`, `stage`, `prod` keep their uid and phase Active and the dev hello-api Deployment remains; misc is always re-enabled and must be Synced and Healthy again. |

Tests 10 and 11 change the cluster: dev keeps the new image tag, and the misc
Application is recreated. Test 02 is therefore only meaningful on a fresh
bootstrap, before test 11 has run.

## Images

Test pods use images pinned by tag and multi-arch index digest:

- `docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93`
  (test 05 client, and the base of `probe/Dockerfile`)
- `docker.io/library/redis:8.2.11-alpine@sha256:da23c2478319ceb4903857d77a2fd7aa5137d9e9d4c8165dafbacedac6403e95`
  (test 08 client)

`lib/netprobe-image.sh` tags the curl image as
`<registry of the dev hello-api image>/e2e-netprobe:<curl version>` (in lab
`ghcr.io/your-org/e2e-netprobe:8.23.0`) and loads it into kind, only so that
the probe pod in `stage` passes the registry allowlist. It is never pushed.
The policy probe pods of tests 03 and 04 reuse the hello-api repository with
`imagePullPolicy: Never`; nothing is pulled for them.
