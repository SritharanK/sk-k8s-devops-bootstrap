#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Usage: wait-application.sh NAME
#
# Waits until the Argo CD Application NAME exists and is Synced and Healthy.
# Used where Chainsaw allows no assert operation (finally blocks) and the
# Application may not exist yet.
#
# Settings:
#   WAIT_TIMEOUT_SECONDS  (default: 300)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

name="${1:?usage: wait-application.sh NAME}"
timeout="${WAIT_TIMEOUT_SECONDS:-300}"

deadline=$((SECONDS + timeout))
state=""
while :; do
  state="$(application_state "${name}")"
  if [[ "${state}" == "Synced Healthy" ]]; then
    log "Application ${ARGOCD_NAMESPACE}/${name} is Synced and Healthy after ${SECONDS}s"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    break
  fi
  sleep 5
done
fail "Application ${ARGOCD_NAMESPACE}/${name} not Synced and Healthy after ${timeout}s (sync health: ${state:-absent})"
