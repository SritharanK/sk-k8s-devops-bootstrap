#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# When Prometheus runs in the cluster, requires an active hello-api scrape
# target with health "up". Without Prometheus the check is skipped and passes.
#
# The platform Prometheus is Service monitoring-prometheus in "monitoring",
# port 9090 (monitoring is off in the lab profile by default). Other installs
# are found without assuming names. Candidates, in this order: that Service,
# Services in "monitoring" with port 9090, Services labelled
# app.kubernetes.io/name=prometheus, Services in "monitoring" with a port named
# http-web. A candidate counts only when /api/v1/status/buildinfo answers
# through the API server service proxy (Alertmanager and Grafana also use the
# port name http-web).
#
# A hello-api target is one whose service label is hello-api (the platform
# ServiceMonitor contract), or whose scrape pool or job names hello-api.
#
# Settings:
#   MONITORING_NAMESPACE     (default: monitoring)
#   PROMETHEUS_SERVICE       (default: monitoring-prometheus)
#   METRICS_TIMEOUT_SECONDS  how long to wait for the target (default: 180)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

mon_ns="${MONITORING_NAMESPACE:-monitoring}"
prom_svc="${PROMETHEUS_SERVICE:-monitoring-prometheus}"
timeout="${METRICS_TIMEOUT_SECONDS:-180}"

candidates() {
  kubectl get services -n "${mon_ns}" -o json |
    jq -r --arg name "${prom_svc}" '.items[] | select(.metadata.name == $name) | . as $s
      | .spec.ports[] | select(.port == 9090)
      | "\($s.metadata.namespace) \($s.metadata.name) \(.port)"'
  kubectl get services -n "${mon_ns}" -o json |
    jq -r '.items[] | . as $s | .spec.ports[] | select(.port == 9090)
      | "\($s.metadata.namespace) \($s.metadata.name) \(.port)"'
  kubectl get services -A -l app.kubernetes.io/name=prometheus -o json |
    jq -r '.items[]
      | "\(.metadata.namespace) \(.metadata.name) \(([.spec.ports[] | select(.port == 9090 or .name == "http-web")] + .spec.ports)[0].port)"'
  kubectl get services -n "${mon_ns}" -o json |
    jq -r '.items[] | . as $s | .spec.ports[] | select(.name == "http-web")
      | "\($s.metadata.namespace) \($s.metadata.name) \(.port)"'
}

list="$(candidates)"
if [[ -z "${list}" ]]; then
  log "monitoring not enabled in this profile; skipped"
  exit 0
fi

proxy=""
deadline=$((SECONDS + 60))
while [[ -z "${proxy}" ]]; do
  while read -r c_ns c_svc c_port; do
    [[ -n "${c_svc}" ]] || continue
    base="/api/v1/namespaces/${c_ns}/services/${c_svc}:${c_port}/proxy"
    if kubectl get --raw "${base}/api/v1/status/buildinfo" 2>/dev/null |
      jq -e '.status == "success"' >/dev/null 2>&1; then
      proxy="${base}"
      log "Prometheus: service ${c_ns}/${c_svc} port ${c_port}"
      break
    fi
  done <<<"${list}"
  if [[ -z "${proxy}" ]]; then
    if ((SECONDS >= deadline)); then
      log "candidates:"
      log "${list}"
      fail "Prometheus Services exist but none answered /api/v1/status/buildinfo within 60s"
    fi
    sleep 5
  fi
done

deadline=$((SECONDS + timeout))
while :; do
  targets="$(kubectl get --raw "${proxy}/api/v1/targets" |
    jq -r '.data.activeTargets[]
      | select((.labels.service // "") == "hello-api"
               or ([.scrapePool, .labels.job] | map(. // "") | join(" ") | test("hello-api")))
      | "\(.health) \(.labels.namespace // "-") \(.scrapeUrl) \(.lastError // "")"' || true)"
  case $'\n'"${targets}" in
    *$'\n'"up "*)
      log "hello-api scrape targets (health namespace url error):"
      log "${targets}"
      exit 0
      ;;
  esac
  if ((SECONDS >= deadline)); then
    break
  fi
  sleep 10
done

log "hello-api scrape targets (health namespace url error):"
log "${targets:-none}"
fail "no hello-api target with health up in Prometheus after ${timeout}s"
