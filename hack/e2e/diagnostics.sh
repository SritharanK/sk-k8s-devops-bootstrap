#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Collects cluster state and logs after a failed demo or e2e run.
#
#   hack/e2e/diagnostics.sh OUTPUT_DIR
#
# Best effort by design: every collector may fail (for example when the
# cluster never came up) and the script still collects the rest. It never
# changes the cluster.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../demo/lib.sh"

out="${1:-${REPO_ROOT}/_out/e2e/${DEMO_CLUSTER}/diagnostics}"
mkdir -p "${out}/logs"

# collect FILE COMMAND...: runs COMMAND, writes stdout and stderr to FILE.
collect() {
  local file="$1"
  shift
  "$@" >"${out}/${file}" 2>&1 || printf '\n(command failed: %s)\n' "$*" >>"${out}/${file}"
}

if ! demo_cluster_exists; then
  log_warn "kind cluster ${DEMO_CLUSTER} does not exist; nothing to collect"
  exit 0
fi
demo_use_kubeconfig

log_info "collecting diagnostics into ${out}"
collect versions.txt kubectl version
collect nodes.txt kubectl get nodes -o wide --show-labels
collect nodes-describe.txt kubectl describe nodes
collect pods.txt kubectl get pods -A -o wide
collect events.txt kubectl get events -A --sort-by=.lastTimestamp
collect namespaces.yaml kubectl get namespaces -o yaml
collect applications.yaml kubectl -n argocd get applications.argoproj.io -o yaml
collect appprojects.yaml kubectl -n argocd get appprojects.argoproj.io -o yaml
collect gateway-api.txt kubectl get gatewayclasses,gateways,httproutes -A -o wide
collect gateway-api.yaml kubectl get gateways,httproutes -A -o yaml
collect certificates.txt kubectl get clusterissuers,issuers,certificates,certificaterequests -A
collect networkpolicies.yaml kubectl get networkpolicies -A -o yaml
collect policies.txt kubectl get clusterpolicies,policies,validatingpolicies,policyexceptions -A
collect policyreports.txt kubectl get policyreports -A
collect services.txt kubectl get services,endpointslices -A -o wide
collect argocd-cm.yaml kubectl -n argocd get configmap argocd-cm -o yaml

# Logs of every pod that is not Running and Ready, or has restarted.
kubectl get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase != "Succeeded")
  | select(
      .status.phase != "Running"
      or ([.status.containerStatuses[]? | select(.ready != true or .restartCount > 0)] | length > 0))
  | "\(.metadata.namespace) \(.metadata.name)"' |
  while read -r ns pod; do
    collect "logs/${ns}_${pod}.log" kubectl -n "${ns}" logs "${pod}" --all-containers --prefix --tail=500
    collect "logs/${ns}_${pod}.previous.log" kubectl -n "${ns}" logs "${pod}" --all-containers --prefix --tail=500 --previous
    collect "logs/${ns}_${pod}.describe.txt" kubectl -n "${ns}" describe pod "${pod}"
  done

# Controllers whose logs explain most convergence failures.
for target in \
  "argocd statefulset/argocd-application-controller" \
  "argocd deployment/argocd-repo-server" \
  "argocd deployment/argocd-server" \
  "kyverno deployment/kyverno-admission-controller" \
  "envoy-gateway-system deployment/envoy-gateway" \
  "cert-manager deployment/cert-manager" \
  "demo-git deployment/gitea"; do
  ns="${target%% *}"
  workload="${target#* }"
  collect "logs/${ns}_${workload//\//_}.log" kubectl -n "${ns}" logs "${workload}" --all-containers --prefix --tail=1000
done

# Node level logs (kubelet, containerd), as kind collects them.
collect kind-export-logs.txt kind export logs "${out}/kind" --name "${DEMO_CLUSTER}"

log_info "diagnostics written to ${out}"
