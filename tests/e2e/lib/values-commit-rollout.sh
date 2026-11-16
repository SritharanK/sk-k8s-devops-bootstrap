#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Commits a new hello-api image tag for dev through hack/e2e/values-commit.sh
# (normal Argo CD refresh, no hard refresh) and waits until the dev hello-api
# Deployment runs exactly that image and its rollout is complete.
#
# Settings:
#   ROLLOUT_TIMEOUT_SECONDS  wait after the commit (default: 240)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

env=dev
timeout="${ROLLOUT_TIMEOUT_SECONDS:-240}"
commit_script="${REPO_ROOT:?REPO_ROOT is not set}/hack/e2e/values-commit.sh"
[[ -x "${commit_script}" ]] || fail "${commit_script} is missing or not executable"

deployment="$(hello_api_deployment "${env}")"
[[ -n "${deployment}" ]] || fail "no hello-api Deployment in ${env}"
log "before: ${env}/${deployment} runs $(hello_api_image "${env}" "${deployment}")"

# The last non-empty line of stdout is the new image reference.
output="$("${commit_script}" "${env}")"
want="$(printf '%s\n' "${output}" | awk 'NF { line = $0 } END { print line }')"
[[ -n "${want}" ]] || fail "values-commit.sh printed no image reference"
log "committed: ${want}"

start="${SECONDS}"
deadline=$((SECONDS + timeout))
while :; do
  have="$(hello_api_image "${env}" "${deployment}" || true)"
  if [[ "${have}" == "${want}" ]]; then
    break
  fi
  if ((SECONDS >= deadline)); then
    fail "${env}/${deployment} still runs ${have} after ${timeout}s, expected ${want}"
  fi
  sleep 5
done
log "Deployment spec updated after $((SECONDS - start))s"

remaining=$((deadline - SECONDS))
((remaining > 10)) || remaining=10
kubectl rollout status "deployment.apps/${deployment}" -n "${env}" --timeout="${remaining}s"
log "rolled out ${want} in $((SECONDS - start))s after the commit, with a normal refresh"
