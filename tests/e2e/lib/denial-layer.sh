#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Records which admission layer denied each threat-model case. The Chainsaw
# test passes the API server error of every denied request in:
#   TARGET_NAMESPACE, PRIVILEGED_ERROR, ROOT_ERROR, LATEST_ERROR
# Pod Security Admission runs before validating webhooks and
# ValidatingAdmissionPolicies, so a pod that violates both is reported by Pod
# Security Admission. The output is evidence for the threat model; when
# E2E_REPORT_DIR is an existing directory it is also appended to
# policy-denial-layers.txt there.
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

ns="${TARGET_NAMESPACE:?TARGET_NAMESPACE is not set}"

classify() {
  case "$1" in
    "") printf 'not denied' ;;
    *"violates PodSecurity"*) printf 'Pod Security Admission' ;;
    *ValidatingAdmissionPolicy*) printf 'ValidatingAdmissionPolicy' ;;
    *kyverno*) printf 'policy engine (Kyverno webhook)' ;;
    *"admission webhook"*) printf 'admission webhook (not Kyverno)' ;;
    *) printf 'unknown' ;;
  esac
}

report() {
  local case_name="$1" message="$2"
  printf '%-10s %-10s %s\n' "${ns}" "${case_name}" "$(classify "${message}")"
  printf '           message: %s\n' "${message}"
}

output="$(
  printf '%-10s %-10s %s\n' NAMESPACE CASE DENIED_BY
  report privileged "${PRIVILEGED_ERROR:-}"
  report root "${ROOT_ERROR:-}"
  report latest "${LATEST_ERROR:-}"
)"
log "${output}"

if [[ -n "${E2E_REPORT_DIR:-}" && -d "${E2E_REPORT_DIR}" ]]; then
  log "${output}" >>"${E2E_REPORT_DIR}/policy-denial-layers.txt"
fi

# Chainsaw only checks that each request failed. Any API error passes that
# check (a missing namespace, a quota, an unreachable webhook), so the layer
# must be one that enforces the contract. Pod Security Admission does not
# check image tags, so the latest case must be denied by the policy engine.
failed=0
for case_name in privileged root latest; do
  var="$(tr '[:lower:]' '[:upper:]' <<<"${case_name}")_ERROR"
  layer="$(classify "${!var:-}")"
  case "${case_name}:${layer}" in
    latest:"policy engine (Kyverno webhook)" | latest:ValidatingAdmissionPolicy) ;;
    latest:*) failed=1 ;;
    *:"Pod Security Admission" | *:"policy engine (Kyverno webhook)" | *:ValidatingAdmissionPolicy) ;;
    *) failed=1 ;;
  esac
  [[ "${failed}" == 0 ]] || {
    log "${ns}: case ${case_name} was not denied by an enforcing admission layer (${layer})"
    exit 1
  }
done
