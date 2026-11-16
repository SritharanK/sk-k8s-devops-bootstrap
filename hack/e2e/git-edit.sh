#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Commits one yq edit to the repository on the in-cluster Git server and asks
# Argo CD for a normal refresh of the given Applications. Used by the e2e suite
# to exercise GitOps changes (toggles, values) the way an operator would.
#
#   hack/e2e/git-edit.sh FILE YQ_EXPRESSION MESSAGE [APPLICATION...]
#
# FILE is relative to the repository root. Prints the new commit SHA on stdout.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../demo/lib.sh"

(($# >= 3)) || die "usage: $0 FILE YQ_EXPRESSION MESSAGE [APPLICATION...]"
file="$1"
expression="$2"
message="$3"
shift 3
require_cmd kubectl git yq
demo_use_kubeconfig

work="${DEMO_STATE_DIR}/git-e2e"
git_server_checkout "${work}"
[[ -f "${work}/${file}" ]] || die "${file} not found on the Git server"
yq -i "${expression}" "${work}/${file}"
if [[ -z "$(git -C "${work}" status --porcelain)" ]]; then
  log_info "${file} already matches; nothing to commit"
else
  ensure_commit_identity "${work}"
  git -C "${work}" add "${file}"
  git -C "${work}" -c commit.gpgsign=false commit --quiet --no-verify -m "${message}"
  git_server_push "${work}" HEAD
  log_info "pushed $(git -C "${work}" rev-parse --short=12 HEAD): ${message}"
fi

for app in "$@"; do
  kubectl -n argocd annotate application.argoproj.io "${app}" argocd.argoproj.io/refresh=normal --overwrite >&2
done
git -C "${work}" rev-parse HEAD
