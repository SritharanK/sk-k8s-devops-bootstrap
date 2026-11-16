#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Secret and environment-data scanning with gitleaks.
#
# Usage:
#   hack/secrets.sh tree            committed tree at HEAD plus staged and
#                                   unstaged changes (make secrets)
#   hack/secrets.sh range BASE      every commit in BASE..HEAD, as a pull
#                                   request or push introduces them
#   hack/secrets.sh history         full Git history with the credential rules
#                                   only (.github/gitleaks-history.toml)
#
# The tree mode scans a `git archive` of HEAD, so untracked and ignored files
# (local kubeconfigs, vault files, .env) are never read, and the working-copy
# changes through `gitleaks git --pre-commit`. It also fails on a committed
# Kubernetes Secret with data or stringData outside Helm templates. Findings are redacted. Accepted
# findings are fingerprinted in .gitleaksignore.
#
# Requirements: gitleaks >= 8.25.0, git, tar, yq (v4).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

GITLEAKS_MIN="8.25.0"
CONFIG="${REPO_ROOT}/.gitleaks.toml"
HISTORY_CONFIG="${REPO_ROOT}/.github/gitleaks-history.toml"
IGNORE="${REPO_ROOT}/.gitleaksignore"

usage() {
  sed -n '4,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_cmd gitleaks git tar yq
have="$(gitleaks version)"
version_ge "$have" "$GITLEAKS_MIN" || die "gitleaks ${have} is older than ${GITLEAKS_MIN} (see mise.toml)"

COMMON_ARGS=(--no-banner --redact --log-level warn --exit-code 1)

cd "$REPO_ROOT" || die "cannot enter ${REPO_ROOT}"

mode="${1:-}"
case "$mode" in
  tree)
    make_temp_dir TREE gitleaks-tree
    git archive --format=tar HEAD | tar -x -C "$TREE"
    log_info "gitleaks: committed tree at $(git rev-parse --short HEAD)"
    # Run from the extracted tree so finding paths and fingerprints are
    # repository-relative, as in .gitleaksignore.
    (cd "$TREE" && gitleaks dir . "${COMMON_ARGS[@]}" -c "$CONFIG" --gitleaks-ignore-path "$IGNORE")
    # Kubernetes Secrets with data never go into the repository: they come
    # from SealedSecrets, ExternalSecrets or example files (*.example.yaml). Helm templates
    # are not plain YAML and render no Secret data from the repository.
    log_info "committed Secret manifests with data or stringData"
    secret_files="$(
      cd "$TREE" &&
        find . \( -name '*.yaml' -o -name '*.yml' \) -not -name '*.example.y*ml' -not -path '*/templates/*' -print0 |
        while IFS= read -r -d '' f; do
          if yq -e 'select(.kind == "Secret" and (((.data // {}) | length) > 0 or ((.stringData // {}) | length) > 0)) | .kind' "$f" >/dev/null 2>&1; then
            printf '%s\n' "${f#./}"
          fi
        done
    )"
    if [[ -n "$secret_files" ]]; then
      while IFS= read -r f; do
        log_error "${f}: Secret with data; commit a SealedSecret, an ExternalSecret or a *.example file instead"
      done <<<"$secret_files"
      die "Secret manifests with data are committed"
    fi
    log_info "gitleaks: staged changes"
    gitleaks git . "${COMMON_ARGS[@]}" -c "$CONFIG" --pre-commit --staged
    log_info "gitleaks: unstaged changes"
    gitleaks git . "${COMMON_ARGS[@]}" -c "$CONFIG" --pre-commit
    ;;
  range)
    base="${2:-}"
    [[ -n "$base" ]] || die "usage: hack/secrets.sh range BASE"
    git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || die "unknown commit: ${base}"
    if [[ "$(git rev-list --count "${base}..HEAD")" == "0" ]]; then
      log_info "gitleaks: no commits in ${base}..HEAD"
      exit 0
    fi
    log_info "gitleaks: commits ${base}..HEAD"
    gitleaks git . "${COMMON_ARGS[@]}" -c "$CONFIG" --log-opts="--no-merges ${base}..HEAD"
    ;;
  history)
    log_info "gitleaks: full history, credential rules"
    gitleaks git . "${COMMON_ARGS[@]}" -c "$HISTORY_CONFIG"
    ;;
  -h | --help | "")
    usage
    [[ -n "$mode" ]] || exit 2
    ;;
  *)
    usage >&2
    die "unknown mode: ${mode}" 2
    ;;
esac
