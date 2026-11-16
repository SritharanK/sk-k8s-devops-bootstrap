#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Deletes the kind cluster of the demo (`make demo-down`). Only the cluster
# named by DEMO_CLUSTER (default: demo) is touched. Files under _out/demo stay
# in place; the next `make demo` overwrites them.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kind
if demo_cluster_exists; then
  log_info "deleting kind cluster ${DEMO_CLUSTER}"
  kind delete cluster --name "${DEMO_CLUSTER}" --kubeconfig "${DEMO_KUBECONFIG}"
else
  log_info "kind cluster ${DEMO_CLUSTER} does not exist; nothing to do"
fi
