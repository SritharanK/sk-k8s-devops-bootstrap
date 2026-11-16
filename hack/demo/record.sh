#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Records the lab demo for the README: renders hack/demo/demo.tape with vhs
# (https://github.com/charmbracelet/vhs) to
#   _out/demo/recording/demo.gif
#   _out/demo/recording/demo.mp4
# _out/ is build output; never commit the recordings from there.
#
# Usage: hack/demo/record.sh
#
# Requirements:
#   - vhs at VHS_VERSION below, with ttyd and ffmpeg on PATH. The script checks
#     them and prints install instructions; it never installs anything.
#   - Everything hack/demo/up.sh needs. When the pinned tools from
#     hack/e2e/install-tools.sh exist (TOOLS_BIN_DIR, default _out/tools/bin),
#     they are put first on PATH for the recording.
#   - DEMO_HTTPS_PORT=443 and DEMO_DOMAIN=localtest.me (the defaults), because
#     the tape calls https://hello-api.dev.localtest.me/ literally.
#
# The tape runs hack/demo/up.sh, so recording creates the kind cluster
# DEMO_CLUSTER (default demo), or converges an existing one, and leaves it
# running; hack/demo/down.sh removes it.
#
# Duration: the recording is about one minute long. Rendering takes as long as
# hack/demo/up.sh plus one to two minutes; see the header of demo.tape.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Latest release on 2026-11-16: https://github.com/charmbracelet/vhs/releases/tag/v0.12.1
VHS_VERSION="v0.12.1"

TAPE="${REPO_ROOT}/hack/demo/demo.tape"
# Must match the Output lines in demo.tape (relative to REPO_ROOT).
RECORDING_DIR="${REPO_ROOT}/_out/demo/recording"

vhs_install_hint() {
  cat >&2 <<EOF

Recording needs vhs ${VHS_VERSION} with ttyd and ffmpeg on PATH:
  vhs     go install github.com/charmbracelet/vhs@${VHS_VERSION}
          or a release archive from
          https://github.com/charmbracelet/vhs/releases/tag/${VHS_VERSION}
  ttyd    1.7.2 or later, https://github.com/tsl0922/ttyd/releases
  ffmpeg  from the system package manager

EOF
}

check_vhs() {
  local have cmd absent=""
  if ! command -v vhs >/dev/null 2>&1; then
    vhs_install_hint
    die "vhs not found on PATH"
  fi
  # vhs version v0.12.1 (abc1234); some package builds omit the leading "v".
  have="$(vhs --version 2>/dev/null | awk '{print $3}')" || have=""
  if [[ -z "${have}" || "${have#v}" != "${VHS_VERSION#v}" ]]; then
    vhs_install_hint
    die "found vhs ${have:-of unknown version} at $(command -v vhs), need ${VHS_VERSION}"
  fi
  for cmd in ttyd ffmpeg; do
    command -v "${cmd}" >/dev/null 2>&1 || absent="${absent} ${cmd}"
  done
  if [[ -n "${absent}" ]]; then
    vhs_install_hint
    die "vhs needs these commands on PATH:${absent}"
  fi
}

main() {
  local tools_bin="${TOOLS_BIN_DIR:-${REPO_ROOT}/_out/tools/bin}" f
  (($# == 0)) || die "usage: hack/demo/record.sh (settings come from DEMO_* environment variables)"

  [[ "${DEMO_HTTPS_PORT}" == "443" ]] ||
    die "the tape calls https://hello-api.dev.localtest.me/ without a port; unset DEMO_HTTPS_PORT (now ${DEMO_HTTPS_PORT})"
  [[ "${DEMO_DOMAIN}" == "localtest.me" ]] ||
    die "the tape calls https://hello-api.dev.localtest.me/; unset DEMO_DOMAIN (now ${DEMO_DOMAIN})"

  if [[ -d "${tools_bin}" ]]; then
    PATH="${tools_bin}:${PATH}"
    export PATH
    log_info "using pinned tools from ${tools_bin}"
  fi

  check_vhs
  require_cmd docker kind kubectl curl

  if demo_cluster_exists; then
    log_warn "kind cluster ${DEMO_CLUSTER} already exists; the recording shows hack/demo/up.sh against it"
  fi

  # The recorded shell inherits this environment: kubectl targets the demo
  # cluster and the tape's curl reads the lab CA from DEMO_CA_FILE.
  export KUBECONFIG="${DEMO_KUBECONFIG}"
  export DEMO_CA_FILE

  mkdir -p "${RECORDING_DIR}"
  cd "${REPO_ROOT}"
  log_info "rendering hack/demo/demo.tape with vhs ${VHS_VERSION} (cluster ${DEMO_CLUSTER}); this takes as long as hack/demo/up.sh plus one to two minutes"
  vhs "${TAPE}"

  for f in demo.gif demo.mp4; do
    [[ -s "${RECORDING_DIR}/${f}" ]] || die "vhs finished but ${RECORDING_DIR}/${f} is missing or empty"
  done
  log_info "recording written to ${RECORDING_DIR}/demo.gif and ${RECORDING_DIR}/demo.mp4"
}

main "$@"
