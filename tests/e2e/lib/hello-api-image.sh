#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Usage: hello-api-image.sh NAMESPACE
#
# Prints one JSON object describing the hello-api image in NAMESPACE, for use
# as a Chainsaw output binding (json_parse($stdout)):
#   {"deployment": ..., "image": ..., "repository": ..., "latest": "<repository>:latest"}
# Diagnostics go to stderr so stdout stays valid JSON.
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

ns="${1:?usage: hello-api-image.sh NAMESPACE}"

deployment="$(hello_api_deployment "${ns}")"
[[ -n "${deployment}" ]] || fail "no hello-api Deployment found in namespace ${ns}"
image="$(hello_api_image "${ns}" "${deployment}")"
[[ -n "${image}" ]] || fail "Deployment ${ns}/${deployment} has no container image"
repository="$(image_repository "${image}")"

printf 'hello-api in %s: deployment %s, image %s\n' "${ns}" "${deployment}" "${image}" >&2
jq -cn --arg d "${deployment}" --arg i "${image}" --arg r "${repository}" \
  '{deployment: $d, image: $i, repository: $r, latest: ($r + ":latest")}'
