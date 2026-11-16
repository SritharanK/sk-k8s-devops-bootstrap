#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Usage: redis-auth.sh CLIENT_POD
#
# Argo CD Redis has two independent protections; both are asserted.
# 1. Network: the default-deny NetworkPolicy in the Argo CD namespace admits
#    only argocd-server, argocd-repo-server and argocd-application-controller.
#    From CLIENT_POD (container "redis" in the test namespace NAMESPACE) an
#    unauthenticated PING to every Service exposing port 6379 must time out.
#    PONG fails (open), NOAUTH fails too (reachable: only the password
#    protects), and so does a DNS failure or a refused connection, which prove
#    nothing about the NetworkPolicy.
# 2. Password: inside a Redis pod selected by such a Service, an
#    unauthenticated "redis-cli ping" must answer NOAUTH (--requirepass).
#
# Settings:
#   REDIS_TIMEOUT_SECONDS  limit for one redis-cli call (default: 10)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

pod="${1:?usage: redis-auth.sh CLIENT_POD}"
ns="${NAMESPACE:?NAMESPACE is not set}"
limit="${REDIS_TIMEOUT_SECONDS:-10}"

services_json="$(kubectl get services -n "${ARGOCD_NAMESPACE}" -o json |
  jq -c '[.items[] | select(any((.spec.ports // [])[]; .port == 6379))]')"
services="$(jq -r '.[].metadata.name' <<<"${services_json}")"
[[ -n "${services}" ]] || fail "no Service exposing port 6379 in ${ARGOCD_NAMESPACE}"

failed=0

# 1. Network layer, from the test namespace.
for svc in ${services}; do
  host="${svc}.${ARGOCD_NAMESPACE}"
  rc=0
  # timeout is the busybox applet of the client image: redis-cli would
  # otherwise wait for the kernel TCP connect timeout when packets are dropped.
  # busybox reports the killed child (143), coreutils reports 124.
  out="$(kubectl exec -n "${ns}" "${pod}" -c redis -- \
    timeout "${limit}" redis-cli -h "${host}" -p 6379 ping 2>&1)" || rc=$?
  case "${out}" in
    *PONG*)
      log "FAIL network  ${host}:6379 answered PONG to an unauthenticated client from ${ns}"
      failed=1
      ;;
    *NOAUTH*)
      log "FAIL network  ${host}:6379 reachable from ${ns} (NOAUTH); the NetworkPolicy does not isolate Redis"
      failed=1
      ;;
    *"does not resolve"* | *"not known"* | *"name resolution"*)
      log "FAIL network  ${host}:6379 inconclusive, name resolution failed: ${out}"
      failed=1
      ;;
    *)
      if ((rc == 124 || rc == 137 || rc == 143)); then
        log "OK   network  ${host}:6379 connection from ${ns} timed out after ${limit}s (NetworkPolicy drop)"
      else
        log "FAIL network  ${host}:6379 expected a connection timeout, got exit ${rc}: ${out}"
        failed=1
      fi
      ;;
  esac
done

# 2. Password layer, inside a Redis pod. HAProxy pods of the HA setup also
# serve 6379, so only containers whose image names redis are used.
target=""
for svc in ${services}; do
  selector="$(jq -r --arg s "${svc}" '
    .[] | select(.metadata.name == $s) | .spec.selector // {}
    | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"${services_json}")"
  [[ -n "${selector}" ]] || continue
  target="$(kubectl get pods -n "${ARGOCD_NAMESPACE}" -l "${selector}" -o json |
    jq -r '[.items[] | select(.status.phase == "Running") | . as $p
            | .spec.containers[]
            | select(any(.ports[]?; .containerPort == 6379) and (.image | test("redis")))
            | "\($p.metadata.name) \(.name)"] | .[0] // empty')"
  [[ -z "${target}" ]] || break
done
if [[ -z "${target}" ]]; then
  log "FAIL password no running Redis container behind the 6379 Services in ${ARGOCD_NAMESPACE}"
  failed=1
else
  redis_pod="${target%% *}"
  redis_container="${target##* }"
  rc=0
  out="$(kubectl exec -n "${ARGOCD_NAMESPACE}" "${redis_pod}" -c "${redis_container}" -- \
    redis-cli -p 6379 ping 2>&1)" || rc=$?
  case "${out}" in
    *NOAUTH*)
      log "OK   password ${ARGOCD_NAMESPACE}/${redis_pod}: unauthenticated PING answered NOAUTH (requirepass)"
      ;;
    *PONG*)
      log "FAIL password ${ARGOCD_NAMESPACE}/${redis_pod}: unauthenticated PING answered PONG; no password is set"
      failed=1
      ;;
    *)
      log "FAIL password ${ARGOCD_NAMESPACE}/${redis_pod}: expected NOAUTH, got exit ${rc}: ${out}"
      failed=1
      ;;
  esac
fi

((failed == 0)) || fail "Argo CD Redis protections incomplete (network isolation and password are both required)"
log "Argo CD Redis: NetworkPolicy isolation and password authentication both apply."
