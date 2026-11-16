#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# From the host, through the kind port mapping of the Gateway https listener:
# - hello-api /readyz returns 200 in dev, and in stage and prod when their
#   hello-api Application exists, verified with the lab CA;
# - https://argocd.<domain>/healthz returns 200 when an HTTPRoute for that host
#   exists (skipped otherwise).
#
# Settings (from the runner): REPO_ROOT, DEMO_CA_FILE, DEMO_HTTPS_PORT, DEMO_DOMAIN.
#   GATEWAY_TIMEOUT_SECONDS  how long to retry each URL (default: 60)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

# hack/demo/lib.sh derives DEMO_CA_FILE from DEMO_STATE_DIR; keep the file the
# runner exported when it set one.
runner_ca_file="${DEMO_CA_FILE:-}"
# shellcheck source=/dev/null
source "${REPO_ROOT:?REPO_ROOT is not set}/hack/demo/lib.sh"
if [[ -n "${runner_ca_file}" ]]; then
  DEMO_CA_FILE="${runner_ca_file}"
fi
# The runner writes the CA before the suite. Otherwise fetch it the same way:
# fetch_lab_ca follows the certificateRefs of the https listener, so no Secret
# name is assumed here.
if [[ ! -s "${DEMO_CA_FILE}" ]]; then
  fetch_lab_ca || fail "lab CA file ${DEMO_CA_FILE} is missing and cannot be read from the https listener certificate"
fi

timeout="${GATEWAY_TIMEOUT_SECONDS:-60}"

# expect_200 HOST PATH: retries until HOST PATH answers 200 or the timeout ends.
expect_200() {
  local host="$1" path="$2" code deadline
  deadline=$((SECONDS + timeout))
  while :; do
    code="$(curl_gateway "${host}" "${path}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    if [[ "${code}" == 200 ]]; then
      log "OK   https://${host}${path} -> 200 (127.0.0.1:${DEMO_HTTPS_PORT}, lab CA)"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      log "last attempt for https://${host}${path}:"
      curl_gateway "${host}" "${path}" -o /dev/null -w 'HTTP %{http_code}\n' || true
      fail "https://${host}${path} did not return 200 within ${timeout}s (last: ${code:-none})"
    fi
    sleep 5
  done
}

for env in ${E2E_ENVS}; do
  if [[ "${env}" != dev && -z "$(hello_api_apps "${env}")" ]]; then
    log "SKIP hello-api in ${env}: no hello-api Application"
    continue
  fi
  expect_200 "$(app_host "${env}")" /readyz
done

argocd_host="argocd.${DEMO_DOMAIN}"
routes="$(kubectl get httproutes.gateway.networking.k8s.io -A -o json |
  jq -r --arg h "${argocd_host}" '
    .items[] | select(any(.spec.hostnames[]?; . == $h))
    | "\(.metadata.namespace)/\(.metadata.name)"')"
if [[ -z "${routes}" ]]; then
  log "SKIP ${argocd_host}: no HTTPRoute for this host"
else
  log "HTTPRoute for ${argocd_host}: ${routes}"
  expect_200 "${argocd_host}" /healthz
fi
