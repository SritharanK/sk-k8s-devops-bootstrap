#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# End-to-end test of the lab profile on kind (`make e2e`, workflow e2e.yml).
#
#   1. hack/demo/up.sh brings the platform up and waits for convergence.
#   2. Chainsaw runs the suite in tests/e2e.
#   3. On failure, hack/e2e/diagnostics.sh collects state and logs.
#   4. The cluster is deleted, unless KEEP=1.
#
# Output (JUnit report, logs, diagnostics): _out/e2e/<cluster>/.
#
# Settings: KEEP=1 keeps the cluster; CHAINSAW_ARGS adds arguments to
# `chainsaw test` (for example "--include-test-regex 06-.*"); SKIP_UP=1 reuses a
# running demo cluster; plus the DEMO_* settings in hack/demo/lib.sh.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../demo/lib.sh"

: "${KEEP:=0}"
: "${SKIP_UP:=0}"
: "${CHAINSAW_ARGS:=}"

out="${REPO_ROOT}/_out/e2e/${DEMO_CLUSTER}"
mkdir -p "${out}"

# Prefer the pinned tools from hack/e2e/install-tools.sh when present.
: "${TOOLS_BIN_DIR:=${REPO_ROOT}/_out/tools/bin}"
if [[ -d "${TOOLS_BIN_DIR}" ]]; then
  PATH="${TOOLS_BIN_DIR}:${PATH}"
fi
# Chainsaw: from PATH, else the pinned release binary through
# install-tools.sh (SHA-256 verified), else `go install` of the same version.
# The upstream container image is not an option: the suite's scripts need
# kubectl, curl, jq, yq, git, docker and kind next to chainsaw.
CHAINSAW_VERSION="$(sed -n 's/^CHAINSAW_VERSION="\(.*\)"$/\1/p' "${REPO_ROOT}/hack/e2e/install-tools.sh")"
if ! command -v chainsaw >/dev/null 2>&1; then
  log_info "chainsaw not found; installing ${CHAINSAW_VERSION} into ${TOOLS_BIN_DIR}"
  if ! INSTALL_TOOLS=chainsaw bash "${REPO_ROOT}/hack/e2e/install-tools.sh" "${TOOLS_BIN_DIR}" >/dev/null; then
    require_cmd go
    log_warn "release download failed; building chainsaw ${CHAINSAW_VERSION} with go install"
    GOBIN="${TOOLS_BIN_DIR}" go install "github.com/kyverno/chainsaw@${CHAINSAW_VERSION}"
  fi
  PATH="${TOOLS_BIN_DIR}:${PATH}"
fi
require_cmd chainsaw kind kubectl jq curl

if [[ "${KEEP}" != "1" ]]; then
  add_cleanup "bash '${REPO_ROOT}/hack/demo/down.sh'"
fi

rc=0
stage="up"
if [[ "${SKIP_UP}" == "1" ]]; then
  log_info "SKIP_UP=1: reusing kind cluster ${DEMO_CLUSTER}"
  demo_cluster_exists || die "kind cluster ${DEMO_CLUSTER} does not exist"
elif ! bash "${REPO_ROOT}/hack/demo/up.sh" 2>&1 | tee "${out}/up.log"; then
  rc=1
fi

if ((rc == 0)); then
  stage="chainsaw"
  demo_use_kubeconfig
  [[ -s "${DEMO_CA_FILE}" ]] || fetch_lab_ca || log_warn "lab CA not available"
  E2E_REPORT_DIR="${out}"
  export KUBECONFIG REPO_ROOT DEMO_CA_FILE DEMO_GIT_URL E2E_REPORT_DIR
  # shellcheck disable=SC2086 # CHAINSAW_ARGS is a list of words by design
  chainsaw test \
    --config "${REPO_ROOT}/tests/e2e/.chainsaw.yaml" \
    --test-dir "${REPO_ROOT}/tests/e2e" \
    --report-format JUNIT-TEST \
    --report-path "${out}" \
    --report-name chainsaw-report \
    ${CHAINSAW_ARGS} 2>&1 | tee "${out}/chainsaw.log" || rc=$?
fi

if ((rc != 0)); then
  log_error "e2e failed during ${stage}; collecting diagnostics"
  bash "${REPO_ROOT}/hack/e2e/diagnostics.sh" "${out}/diagnostics" || log_warn "diagnostics incomplete"
fi

if [[ "${KEEP}" == "1" ]]; then
  log_info "KEEP=1: cluster ${DEMO_CLUSTER} kept; export KUBECONFIG=${DEMO_KUBECONFIG}"
fi
log_info "results in ${out}"
exit "${rc}"
