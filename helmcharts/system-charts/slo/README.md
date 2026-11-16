# slo

Service level objectives for the platform and the hello-api sample service, as Prometheus recording rules and multi-window, multi-burn-rate alerts. The rules are generated with Sloth from the specs in `slos/` and installed as `PrometheusRule` objects that the monitoring Prometheus picks up.

| Item | Value |
| --- | --- |
| Upstream chart | None. Local chart without dependencies. |
| Upstream app version | None in the cluster. Rules generated with Sloth v0.16.0 at development time (see Decision). |
| Upstream source | <https://github.com/slok/sloth> |
| Namespace | monitoring (Pod Security: privileged, set by the monitoring chart; this chart creates no pods) |
| Enabled by default | No. Switch on with `toolchains.slo.enabled: true` in `clusters/<cluster>/cluster.yaml`. |

## Decision

SLOs are written as Sloth specs (`version: prometheus/v1`) and turned into Prometheus rules with the Sloth CLI v0.16.0 at development time. The generated rules are committed. No SLO controller runs in the cluster.

Reason: every recording rule and alert is reviewable in Git before it reaches Prometheus, and the platform runs no extra operator or CRD for SLOs. The cost is a manual step: a spec change needs `./generate.sh` and a commit of the regenerated rules. No CI job or pre-commit hook runs `./generate.sh --check`; run it yourself before you commit a rule change.

## Layout

| Path | Content | Packaged |
| --- | --- | --- |
| `slos/<name>.yaml` | Sloth specs, one file per service | No (`.helmignore`) |
| `rules/<name>.yaml` | Prometheus rule groups, unedited Sloth output | Yes |
| `generate.sh` | Regenerates `rules/` from `slos/`; `--check` fails when `rules/` is stale | No (`.helmignore`) |
| `templates/prometheusrules.yaml` | One `PrometheusRule` per `rules/*.yaml`, named `slo-<name>` | Yes |

The chart has no dependencies, so `helm dependency build` has nothing to resolve and there is no `Chart.lock`.

## SLOs

All SLOs use a 30-day rolling window.

| Service and SLO | Objective | Bad events | Total events | Alert |
| --- | --- | --- | --- | --- |
| `hello-api` / `requests-availability` | 99.5% | `http_requests_total` with `code=~"5.."` | `http_requests_total` | `HelloApiAvailabilityBudgetBurn` |
| `hello-api` / `requests-latency` | 99% under 250 ms | `http_request_duration_seconds_count` minus `_bucket{le="0.25"}` | `http_request_duration_seconds_count` | `HelloApiLatencyBudgetBurn` |
| `argocd` / `sync-success` | 99% | `argocd_app_sync_total` with `phase=~"Error\|Failed"` | `argocd_app_sync_total` | `ArgoCDSyncSuccessBudgetBurn` |
| `kyverno` / `admission-latency` | 99% under 1 s | `kyverno_admission_review_duration_seconds_count` minus `_bucket{le=~"1(\\.0)?"}` | `kyverno_admission_review_duration_seconds_count` | `KyvernoAdmissionLatencyBudgetBurn` |

Scope of the selectors:

- hello-api: `namespace="prod"`, `service="hello-api"`, and `handler!~"/healthz|/readyz|/metrics"` so probes and scrapes do not count as traffic.
- Argo CD: dry-run syncs (`dry_run="true"`) are excluded.
- Kyverno: Prometheus 3 stores classic histogram bucket labels in float form (`le="1.0"`), Prometheus 2 stored `le="1"`. The regex accepts both.

Every alert exists twice with the same name: a page alert (`severity: critical`, `sloth_severity: page`) and a ticket alert (`severity: warning`, `sloth_severity: ticket`). Both carry a `summary` and a `runbook_url` annotation pointing to `docs/operations/troubleshooting.md`.

| Alert | Windows | Burn rate | Budget spent when it fires |
| --- | --- | --- | --- |
| page | 5m and 1h | 14.4 | 2% in 1 hour |
| page | 30m and 6h | 6 | 5% in 6 hours |
| ticket | 2h and 1d | 3 | 10% in 1 day |
| ticket | 6h and 3d | 1 | 10% in 3 days |

Certificate expiry is an alert, not an SLO. The monitoring chart owns it.

## Recording rules

Sloth writes the same rule names for every SLO and tells them apart with the labels `sloth_service`, `sloth_slo` and `sloth_id` (`<service>-<slo>`). Every rule also carries `owner: platform`.

| Rule | Meaning |
| --- | --- |
| `slo:sli_error:ratio_rate5m`, `_rate30m`, `_rate1h`, `_rate2h`, `_rate6h`, `_rate1d`, `_rate3d` | Error ratio over the window (label `sloth_window`) |
| `slo:sli_error:ratio_rate30d` | Mean of the 5m error ratio over 30 days |
| `slo:objective:ratio` | Objective, for example 0.995 |
| `slo:error_budget:ratio` | 1 minus the objective |
| `slo:time_period:days` | 30 |
| `slo:current_burn_rate:ratio` | 5m error ratio divided by the error budget |
| `slo:period_burn_rate:ratio` | 30d error ratio divided by the error budget |
| `slo:period_error_budget_remaining:ratio` | 1 minus the period burn rate; below 0 the budget is spent |
| `sloth_slo_info` | Metadata: objective, Sloth version, spec version |

The Argo CD and hello-api dashboards in the monitoring chart read `slo:period_error_budget_remaining:ratio`, `slo:sli_error:ratio_rate30d`, `slo:current_burn_rate:ratio`, `slo:sli_error:ratio_rate1h`, `slo:sli_error:ratio_rate6h` and `slo:error_budget:ratio`. Renaming an SLO or a service in a spec breaks their selectors.

## Change or add an SLO

1. Edit or add a spec in `slos/`. A new file becomes a new `PrometheusRule` automatically.
2. Run `./generate.sh` from this directory. It uses `go run github.com/slok/sloth/cmd/sloth@v0.16.0` (Go and access to the Go module proxy are needed; the checksum database verifies the source). To use an installed Sloth binary of the same version instead, set `SLOTH=/path/to/sloth`.
3. Review and commit the spec and the regenerated file in `rules/` together. Never edit `rules/` by hand.

```bash
./generate.sh           # regenerate rules/
./generate.sh --check   # before committing: exit 1 when rules/ differs from fresh output
```

## Argo CD sync volume

Syncs happen on Git changes, on manual syncs and on self-heal, so volume is low and many 5-minute windows have none. Windows without syncs produce no sample (the `> 0` guard on the total query) and do not count. The page threshold for a 99% objective is an error ratio of 14.4% in both the 5m and the 1h window. In an hour with six syncs or fewer, one failed sync lifts the 1h ratio above 14.4%, and the 5m ratio is usually above it too while the failure is recent, so a single failure can page. Burn-rate alerts on this SLO can be noisy.

Options to reduce noise, in the spec `slos/argocd.yaml`, each followed by `./generate.sh`:

- Disable the page alert and keep the ticket alert: `alerting.page_alert.disable: true`.
- Require a minimum volume per window, so sparse windows produce no sample: `total_query: sum(rate(argocd_app_sync_total{dry_run!="true"}[{{.window}}])) and on() sum(increase(argocd_app_sync_total{dry_run!="true"}[{{.window}}])) >= 10`. At low volume this also stops the short windows (5m, 30m) from producing samples, so the page alert stops firing altogether, and the 30-day values, which Sloth derives from the 5m ratio, lose most of their samples.
- Lower the objective, for example to 95%, which raises every alert threshold.

## Profiles

| Profile | Delta |
| --- | --- |
| lab | All SLOs installed. hello-api reports no data until the prod namespace gets traffic. |
| reference | All SLOs installed. Set `disabledRuleFiles: [hello-api]` when the sample service is not deployed. |

`disabledRuleFiles` takes file names from `rules/` without the extension. An unknown name fails the render.

## Secrets

None.

## Dependencies

| Toolchain | Why |
| --- | --- |
| monitoring | `PrometheusRule` CRD and the Prometheus rule selector `release: monitoring`. Both Applications are in sync wave 4; this one skips the dry run for missing CRDs and retries until the CRD exists. |
| hello-api, Argo CD, Kyverno | Source metrics, scraped by the monitoring Prometheus through ServiceMonitors labelled `release: monitoring`: hello-api (Service `hello-api`), the Argo CD application controller, and the Kyverno admission controller. Without them the SLOs report no data and no alert fires. |

## Upgrade

1. Read the Sloth changelog: <https://github.com/slok/sloth/blob/main/CHANGELOG.md>
2. Change `SLOTH_VERSION` in `generate.sh`, run `./generate.sh`, and review the diff in `rules/`. Rule names or labels may change between releases; check the dashboards in the monitoring chart against them.
3. Bump `version` in `Chart.yaml`.

## Known limitations

- `slo:sli_error:ratio_rate30d` is Sloth's mean of the 5m ratios, not a ratio of 30-day event counts. Each 5-minute window with traffic weighs the same, whatever its volume. For low-volume SLIs (Argo CD syncs) a single bad window moves the 30-day value more than its share of events.
- The 30d rules need at least 30 days of Prometheus retention (`prometheus.prometheusSpec.retention` in the monitoring chart). With shorter retention they cover only the retained data, and the error budget looks larger than it is after an incident ages out.
- Alerts have no `for` duration (Sloth does not set one). The multi-window conditions provide the debounce.
