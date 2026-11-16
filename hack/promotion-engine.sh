#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Print the promotion engine that writes image.tag and image.digest in
# envs/<env>/<app>/values.yaml: "workflows" (build-image.yml and promote.yml)
# or "kargo" (docs/adr/0012-kargo-promotion.md). Only one engine writes.
#
# Usage:
#   hack/promotion-engine.sh [CLUSTERS_DIR]
#
#   PROMOTION_ENGINE=workflows|kargo  explicit choice; always wins
#   PROMOTION_ENGINE unset or empty   kargo when any CLUSTERS_DIR/*/cluster.yaml
#                                     enables toolchains.kargo with its
#                                     pipelines (the default), else workflows
#
# CLUSTERS_DIR defaults to clusters. In GitHub Actions (GITHUB_OUTPUT set) the
# script also writes engine=<engine> to GITHUB_OUTPUT and prints the reason as
# a notice. Exit status 2 for an invalid PROMOTION_ENGINE, an unreadable
# cluster file or a missing yq v4.

set -euo pipefail

usage() {
  sed -n '4,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# GitHub Actions annotations on a runner, plain lines elsewhere.
annotate() {
  local level="$1" message="$2"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::%s::%s\n' "$level" "$message" >&2
  else
    printf '%s: %s\n' "$level" "$message" >&2
  fi
}

fail() {
  annotate error "$1"
  exit 2
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac
(($# <= 1)) || fail "promotion-engine: at most one argument (CLUSTERS_DIR)"
clusters_dir="${1:-clusters}"

engine=""
reason=""
explicit="${PROMOTION_ENGINE:-}"
case "$explicit" in
  workflows | kargo)
    engine="$explicit"
    reason="the repository variable PROMOTION_ENGINE is ${explicit}"
    ;;
  "")
    yq --version 2>/dev/null | grep -Eq 'mikefarah/yq.* version v?4\.' ||
      fail "promotion-engine: mikefarah yq v4 is required (yq --version did not report it)"
    [[ -d "$clusters_dir" ]] || fail "promotion-engine: ${clusters_dir} is not a directory"
    enabled_in=()
    shopt -s nullglob
    for f in "$clusters_dir"/*/cluster.yaml; do
      # Same rule as argocd-bootstrap.kargoPipelines: the toolchain is on and
      # its pipelines are not switched off.
      on="$(yq -r '(.toolchains.kargo.enabled == true) and (.toolchains.kargo.pipelines.enabled != false)' "$f" 2>/dev/null)" ||
        fail "promotion-engine: cannot read ${f}"
      if [[ "$on" == "true" ]]; then
        enabled_in+=("$f")
      fi
    done
    shopt -u nullglob
    if ((${#enabled_in[@]} > 0)); then
      engine=kargo
      reason="PROMOTION_ENGINE is unset and toolchains.kargo is enabled in ${enabled_in[*]}"
    else
      engine=workflows
      reason="PROMOTION_ENGINE is unset and no cluster definition enables Kargo pipelines"
    fi
    ;;
  *)
    fail "promotion-engine: PROMOTION_ENGINE is '${explicit}'; use workflows, kargo, or leave it unset"
    ;;
esac

if [[ "$engine" == kargo ]]; then
  annotate notice "Promotion engine: kargo (${reason}). Kargo writes the environment files; the workflows do not. Set PROMOTION_ENGINE=workflows to change that."
else
  annotate notice "Promotion engine: workflows (${reason})."
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "engine=${engine}" >>"$GITHUB_OUTPUT"
fi
echo "$engine"
