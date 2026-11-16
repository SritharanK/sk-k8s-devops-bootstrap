#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Records the state that the misc toggle test compares against, as one JSON
# object on stdout (Chainsaw output binding, json_parse($stdout)):
#   {"dev": "<uid>", "stage": "<uid>", "prod": "<uid>", "deployment": "<dev hello-api Deployment>"}
#
# Guard: disabling misc deletes every Namespace that lacks Delete=false in
# argocd.argoproj.io/sync-options, which would destroy the environments. The
# script fails before anything is changed when a Namespace lacks it.
# Diagnostics go to stderr so stdout stays valid JSON.
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

state="{}"
for env in ${E2E_ENVS}; do
  ns_json="$(kubectl get namespace "${env}" -o json)" || fail "namespace ${env} does not exist"
  uid="$(jq -r '.metadata.uid' <<<"${ns_json}")"
  options="$(jq -r '.metadata.annotations["argocd.argoproj.io/sync-options"] // ""' <<<"${ns_json}")"
  printf 'namespace %-6s uid %s sync-options "%s"\n' "${env}" "${uid}" "${options}" >&2
  case ",${options}," in
    *,Delete=false,*) ;;
    *) fail "namespace ${env} lacks Delete=false in argocd.argoproj.io/sync-options; not disabling misc" ;;
  esac
  state="$(jq -c --arg k "${env}" --arg v "${uid}" '.[$k] = $v' <<<"${state}")"
done

deployment="$(hello_api_deployment dev)"
[[ -n "${deployment}" ]] || fail "no hello-api Deployment in dev"
printf 'hello-api Deployment in dev: %s\n' "${deployment}" >&2

jq -c --arg d "${deployment}" '.deployment = $d' <<<"${state}"
