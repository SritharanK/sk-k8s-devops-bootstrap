#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks that every configured environment has at least one hello-api
# Application. dev is always required; stage and prod are required when their
# AppProject (apps-<env>) or their namespace exists.
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

missing=""
printf '%-6s %-11s %s\n' ENV CONFIGURED HELLO_API_APPLICATIONS
for env in ${E2E_ENVS}; do
  configured=no
  if [[ "${env}" == dev ]] || env_configured "${env}"; then
    configured=yes
  fi
  apps="$(hello_api_apps "${env}" | awk 'NF { printf "%s%s", sep, $0; sep = "," }')"
  printf '%-6s %-11s %s\n' "${env}" "${configured}" "${apps:--}"
  if [[ "${configured}" == yes && -z "${apps}" ]]; then
    missing="${missing} ${env}"
  fi
done

if [[ -n "${missing}" ]]; then
  fail "no hello-api Application (project apps-<env> or destination namespace <env>, source path containing hello-api) for:${missing}"
fi
