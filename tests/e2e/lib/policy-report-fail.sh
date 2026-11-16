#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Usage: policy-report-fail.sh NAMESPACE KIND NAME
#
# Waits until a policy report in NAMESPACE shows at least one failed result for
# the resource KIND/NAME, and prints the failed results. Accepts both report
# APIs: wgpolicyk8s.io/v1alpha2 PolicyReport and openreports.io/v1alpha1 Report.
# A report matches when its scope points at the resource (per-resource
# reports) or when a failed result lists the resource (older layout).
#
# Settings:
#   REPORT_TIMEOUT_SECONDS  how long to wait (default: 180)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

ns="${1:?usage: policy-report-fail.sh NAMESPACE KIND NAME}"
kind="${2:?usage: policy-report-fail.sh NAMESPACE KIND NAME}"
name="${3:?usage: policy-report-fail.sh NAMESPACE KIND NAME}"
timeout="${REPORT_TIMEOUT_SECONDS:-180}"

# kubectl api-resources exits non-zero when one aggregated API is unavailable
# while still listing the others, so its status is ignored.
served="$(kubectl api-resources -o name 2>/dev/null || true)"
resources=""
for r in policyreports.wgpolicyk8s.io reports.openreports.io; do
  case $'\n'"${served}"$'\n' in
    *$'\n'"${r}"$'\n'*) resources="${resources} ${r}" ;;
  esac
done
[[ -n "${resources}" ]] || fail "no policy report API is served (policyreports.wgpolicyk8s.io or reports.openreports.io)"
log "report APIs:${resources}"

failed_results() {
  local r
  for r in ${resources}; do
    kubectl get "${r}" -n "${ns}" -o json |
      jq -r --arg kind "${kind}" --arg name "${name}" --arg api "${r}" '
        .items[]
        | . as $report
        | ((.scope.kind // "") == $kind and (.scope.name // "") == $name) as $scoped
        | .results[]?
        | select(.result == "fail")
        | select($scoped or any(.resources[]?; .kind == $kind and .name == $name))
        | "\($api) \($report.metadata.name): \(.policy)/\(.rule // "-"): \(.message // "")"'
  done
}

deadline=$((SECONDS + timeout))
while :; do
  # A transient API error is retried until the deadline.
  results="$(failed_results || true)"
  if [[ -n "${results}" ]]; then
    log "Failed policy results for ${kind} ${ns}/${name}:"
    log "${results}"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    break
  fi
  sleep 10
done

log "Reports in ${ns} that reference ${kind}/${name}:"
for r in ${resources}; do
  kubectl get "${r}" -n "${ns}" -o json |
    jq -r --arg kind "${kind}" --arg name "${name}" '
      .items[]
      | select((.scope.kind // "") == $kind and (.scope.name // "") == $name)
      | "\(.metadata.name) summary=\(.summary | tostring)"'
done
fail "no failed policy result for ${kind} ${ns}/${name} after ${timeout}s"
