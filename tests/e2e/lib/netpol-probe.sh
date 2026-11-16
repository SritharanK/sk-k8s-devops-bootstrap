#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Usage: netpol-probe.sh CLIENT_NAMESPACE CLIENT_POD CONTROL
#
# From CLIENT_POD (its first container needs curl and nslookup):
# 1. Positive control, so that a blocked connection proves something:
#    apiserver  the pod reaches the kube-apiserver (any HTTP status) or, failing
#               that, resolves kubernetes.default (client in an unrestricted
#               namespace, such as the Chainsaw test namespace);
#    dns        the pod resolves the target Service name to its ClusterIP
#               (client in an app namespace, where egress allows DNS only).
# 2. The hello-api Service in the target namespace, which has ready endpoints,
#    must not accept a TCP connection: curl must hit the connect timeout
#    (exit 28 with no completed TCP handshake), not an HTTP error.
#
# Settings:
#   NETPOL_TARGET_NAMESPACE  namespace of the hello-api Service (default: dev)
#   CONNECT_TIMEOUT_SECONDS  curl connect timeout (default: 5)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

usage="usage: netpol-probe.sh CLIENT_NAMESPACE CLIENT_POD apiserver|dns"
ns="${1:?${usage}}"
pod="${2:?${usage}}"
control="${3:?${usage}}"
target_ns="${NETPOL_TARGET_NAMESPACE:-dev}"
connect_timeout="${CONNECT_TIMEOUT_SECONDS:-5}"

in_client() {
  kubectl exec -n "${ns}" "${pod}" -- "$@"
}

# Target: the hello-api Service in the target namespace, with ready endpoints.
deployment="$(hello_api_deployment "${target_ns}")"
[[ -n "${deployment}" ]] || fail "no hello-api Deployment in ${target_ns}"
service="$(service_for_deployment "${target_ns}" "${deployment}")"
[[ -n "${service}" ]] || fail "no Service selects the pods of ${target_ns}/${deployment}"
svc="${service%% *}"
port="${service##* }"
fqdn="${svc}.${target_ns}.svc.cluster.local"

ready="$(kubectl get endpointslices.discovery.k8s.io -n "${target_ns}" \
  -l "kubernetes.io/service-name=${svc}" -o json |
  jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')"
((ready > 0)) || fail "Service ${target_ns}/${svc} has no ready endpoints; a timeout would not prove the NetworkPolicy"

# 1. Positive control.
case "${control}" in
  apiserver)
    # -k only skips verification of the apiserver certificate for a
    # reachability probe that sends no credentials.
    rc=0
    code="$(in_client curl -sk -o /dev/null -w '%{http_code}' \
      --connect-timeout "${connect_timeout}" --max-time 10 \
      https://kubernetes.default.svc/readyz)" || rc=$?
    if ((rc == 0)) && [[ "${code}" != 000 ]]; then
      log "positive control: kube-apiserver answered HTTP ${code} from ${ns}/${pod}"
    elif in_client nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
      log "positive control: DNS resolution works from ${ns}/${pod} (apiserver probe: curl exit ${rc})"
    else
      fail "positive control failed: ${ns}/${pod} can neither reach the kube-apiserver nor resolve DNS"
    fi
    ;;
  dns)
    cluster_ip="$(kubectl get service "${svc}" -n "${target_ns}" -o json | jq -r '.spec.clusterIP')"
    rc=0
    answer="$(in_client nslookup "${fqdn}" 2>&1)" || rc=$?
    case "${answer}" in
      *"${cluster_ip}"*)
        log "positive control: ${ns}/${pod} resolves ${fqdn} to ${cluster_ip} (DNS egress allowed)"
        ;;
      *)
        fail "positive control failed: ${ns}/${pod} cannot resolve ${fqdn} to ${cluster_ip} (exit ${rc}): ${answer}"
        ;;
    esac
    ;;
  *)
    fail "${usage}"
    ;;
esac

# 2. The connection itself.
url="http://${fqdn}:${port}/readyz"
log "probing ${url} (${ready} ready endpoints) from ${ns}/${pod}"
rc=0
out="$(in_client curl -sS -o /dev/null -w '%{http_code} %{time_connect}' \
  --connect-timeout "${connect_timeout}" --max-time $((connect_timeout + 5)) \
  "${url}")" || rc=$?
http_code="${out%% *}"
time_connect="${out##* }"

case "${rc}" in
  28)
    if awk -v t="${time_connect}" 'BEGIN { exit !(t + 0 == 0) }'; then
      log "default-deny holds: TCP connect to ${url} timed out after ${connect_timeout}s"
    else
      fail "TCP connect to ${url} succeeded (time_connect ${time_connect}s) and only the request timed out; the NetworkPolicy does not block it"
    fi
    ;;
  0)
    fail "${url} answered HTTP ${http_code} from ${ns}; the NetworkPolicies do not isolate hello-api"
    ;;
  *)
    fail "unexpected curl exit ${rc} for ${url} (expected 28, connect timeout); write-out: ${out:-none}"
    ;;
esac
