#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Verifies the sync-wave order of the child Applications of the root
# Application (those carrying the argocd.argoproj.io/tracking-id annotation):
# for every pair A, B with wave(A) < wave(B), B must have been created at or
# after the first "-> Healthy" event Argo CD recorded for A. Times are compared
# in epoch seconds. Missing annotation means wave 0, as in Argo CD.
#
# Events live for the kube-apiserver --event-ttl (1h by default), so the check is
# only meaningful within that window after the bootstrap. An Application in a
# lower wave without a Healthy event fails the check instead of passing it.
#
# Settings:
#   ARGOCD_NAMESPACE        namespace of the Applications (default: argocd)
#   SYNC_WAVE_SKEW_SECONDS  tolerated difference in seconds (default: 0)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

skew="${SYNC_WAVE_SKEW_SECONDS:-0}"

# Reduce both lists to the fields needed, so the jq arguments stay small.
apps="$(
  kubectl get applications.argoproj.io -n "${ARGOCD_NAMESPACE}" -o json |
    jq -c '
      def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [.items[]
       | select(.metadata.annotations["argocd.argoproj.io/tracking-id"] != null)
       | {name: .metadata.name,
          uid: .metadata.uid,
          wave: ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0") | tonumber),
          created: (.metadata.creationTimestamp | ts)}]'
)"
events="$(
  kubectl get events -n "${ARGOCD_NAMESPACE}" --field-selector involvedObject.kind=Application -o json |
    jq -c '
      def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [.items[]
       | select((.message // "") | test("-> Healthy"))
       | {name: .involvedObject.name,
          uid: (.involvedObject.uid // ""),
          t: ([.firstTimestamp, .eventTime, .metadata.creationTimestamp]
              | map(select(. != null) | ts) | min)}]'
)"

analysis="$(
  jq -n --argjson apps "${apps}" --argjson events "${events}" --argjson skew "${skew}" '
    ($apps
     | map(. as $a
           | . + {healthy: ([$events[]
                             | select(.name == $a.name and (.uid == "" or .uid == $a.uid))
                             | .t] | min)})) as $rows
    | ($rows | map(.wave) | unique) as $waves
    | ($waves | max) as $top
    | {rows: ($rows | sort_by(.wave, .name)),
       waves: ($waves | length),
       missing: [$rows[] | select(.wave < $top and .healthy == null)],
       violations: [$rows[] as $a | $rows[] as $b
                    | select($a.wave < $b.wave and $a.healthy != null
                             and ($b.created + $skew) < $a.healthy)
                    | {lower: $a, higher: $b, early: ($a.healthy - $b.created)}]}'
)"

log "Child Applications in ${ARGOCD_NAMESPACE} by sync wave:"
{
  printf 'WAVE\tAPPLICATION\tCREATED\tFIRST_HEALTHY\n'
  jq -r '.rows[]
    | [(.wave | tostring), .name, (.created | todate),
       (if .healthy == null then "-" else (.healthy | todate) end)]
    | @tsv' <<<"${analysis}"
} | awk -F '\t' '{ printf "%-5s %-30s %-21s %s\n", $1, $2, $3, $4 }'

rc=0
count="$(jq '.rows | length' <<<"${analysis}")"
if ((count == 0)); then
  fail "no child Application with annotation argocd.argoproj.io/tracking-id in ${ARGOCD_NAMESPACE}"
fi
if (($(jq '.waves' <<<"${analysis}") < 2)); then
  fail "all child Applications share one sync wave; the wave contract (0, 1, 2, 3, 4, 10) is not applied"
fi

if (($(jq '.missing | length' <<<"${analysis}") > 0)); then
  printf '\nNo "-> Healthy" event for these lower-wave Applications:\n' >&2
  jq -r '.missing[] | "  wave \(.wave) \(.name)"' <<<"${analysis}" >&2
  printf '%s\n' "Their events have most likely expired (kube-apiserver --event-ttl, 1h by default)," \
    "so the order cannot be proven. Run the suite within the event TTL of the bootstrap." >&2
  rc=1
fi

if (($(jq '.violations | length' <<<"${analysis}") > 0)); then
  printf '\nSync-wave order violated:\n' >&2
  jq -r '.violations[]
    | "  wave \(.higher.wave) \(.higher.name) created \(.higher.created | todate),"
      + " \(.early)s before wave \(.lower.wave) \(.lower.name) was first Healthy (\(.lower.healthy | todate))"' \
    <<<"${analysis}" >&2
  rc=1
fi

if ((rc != 0)); then
  fail "sync-wave check failed"
fi
log "Sync-wave order holds for ${count} child Applications."
