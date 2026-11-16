#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Proves that a values commit rolls out without a hard refresh.
#
#   hack/e2e/values-commit.sh ENV
#
# 1. Tags the hello-api image of the demo with a new tag and loads it into kind
#    (same layers, so the new pods start immediately).
# 2. Commits the new image.tag to envs/ENV/hello-api/values.yaml on the
#    in-cluster Git server, the same change a promotion makes.
# 3. Requests a normal refresh of the Application. A normal refresh resolves
#    the new revision but reuses cached manifests when no changed file matches
#    the manifest-generate-paths annotation, so the rollout only happens when
#    that annotation covers envs/ENV/hello-api.
#
# Prints the new image reference on stdout; the caller waits for the rollout.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../demo/lib.sh"

env="${1:-}"
[[ -n "${env}" ]] || die "usage: $0 ENV"
require_cmd docker kind kubectl git yq jq
[[ -f "${DEMO_STATE_DIR}/hello-api-image" ]] || die "no demo image recorded; run hack/demo/up.sh first"
demo_use_kubeconfig

base_ref="$(cat "${DEMO_STATE_DIR}/hello-api-image")"
repository="${base_ref%:*}"
new_tag="${base_ref##*:}-r$(date +%s)"
new_ref="${repository}:${new_tag}"

log_info "loading ${new_ref} into kind"
docker tag "${base_ref}" "${new_ref}"
kind load docker-image --name "${DEMO_CLUSTER}" "${new_ref}" >&2

work="${DEMO_STATE_DIR}/git-e2e"
git_server_checkout "${work}"
values="${work}/envs/${env}/hello-api/values.yaml"
[[ -f "${values}" ]] || die "envs/${env}/hello-api/values.yaml not found on the Git server"
NEW_TAG="${new_tag}" yq -i '.image.tag = strenv(NEW_TAG) | .image.digest = ""' "${values}"
ensure_commit_identity "${work}"
git -C "${work}" add "envs/${env}/hello-api/values.yaml"
git -C "${work}" -c commit.gpgsign=false commit --quiet --no-verify \
  -m "chore(e2e): set hello-api ${env} image tag to ${new_tag}"
git_server_push "${work}" HEAD
log_info "pushed $(git -C "${work}" rev-parse --short=12 HEAD) with image.tag ${new_tag} for ${env}"

app="$(hello_api_application "${env}")"
[[ -n "${app}" ]] || die "no hello-api Application for namespace ${env}"
kubectl -n argocd annotate application.argoproj.io "${app}" argocd.argoproj.io/refresh=normal --overwrite >&2
log_info "requested a normal refresh of Application ${app}"

printf '%s\n' "${new_ref}"
