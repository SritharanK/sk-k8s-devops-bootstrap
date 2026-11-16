#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Validates the Backstage catalog descriptors with the pinned entity validator
# (@roadiehq/backstage-entity-validator).
#
# The validator and every transitive dependency are pinned by
# hack/catalog/package-lock.json and installed with `npm ci --ignore-scripts`
# into a cache under the render output directory, so the repository stays
# free of node_modules and no package install script runs. The overrides in
# hack/catalog/package.json lift undici and glob (with it minimatch) to
# releases with security fixes that the validator's own version ranges do not
# reach; remove them once the validator depends on fixed releases. The validator
# replaces $text references with dummy text, so this script also checks that
# every relative $text target exists and that an OpenAPI definition parses
# and declares its version.
#
# Usage:
#   hack/lint-catalog.sh [FILE...]    default: catalog-info.yaml
#
# Environment:
#   OUT_DIR   cache root (default: <repository root>/_out)
#
# Requirements: node 22 or later, npm, yq v4 (mikefarah).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

require_cmd node npm yq

LOCK_DIR="${REPO_ROOT}/hack/catalog"
CACHE="${OUT_DIR:-${REPO_ROOT}/_out}/.cache/catalog-lint"
FILES=("$@")
if ((${#FILES[@]} == 0)); then
  FILES=("${REPO_ROOT}/catalog-info.yaml")
fi

node_major="$(node -p 'process.versions.node.split(".")[0]')"
((node_major >= 22)) || die "node 22 or later is required, found $(node --version)"

# Reinstall only when the lockfile changed.
if ! cmp -s "${LOCK_DIR}/package-lock.json" "${CACHE}/package-lock.json" ||
  [[ ! -x "${CACHE}/node_modules/.bin/validate-entity" ]]; then
  log_info "installing the catalog validator from ${LOCK_DIR#"$REPO_ROOT"/}/package-lock.json"
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
  cp "${LOCK_DIR}/package.json" "${LOCK_DIR}/package-lock.json" "$CACHE/"
  (cd "$CACHE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error >/dev/null)
fi

# kind, name, spec.type and the $text reference of every entity.
# shellcheck disable=SC2016 # $text is a literal key name for yq
QUERY='[.kind, .metadata.name, (.spec.type // ""), (.spec.definition."$text" // "")] | @tsv'

failed=0
for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || die "catalog file not found: ${file}"
  rel="${file#"$REPO_ROOT"/}"
  if "${CACHE}/node_modules/.bin/validate-entity" "$file" >"${CACHE}/last.log" 2>&1; then
    log_info "${rel}: $(grep -c '^Validated entity kind' "${CACHE}/last.log") entities valid"
  else
    sed 's/^/  /' "${CACHE}/last.log" >&2
    log_error "${rel}: entity validation failed"
    failed=1
  fi

  # Relative $text references, resolved against the descriptor's directory.
  base="$(cd "$(dirname "$file")" && pwd -P)"
  while IFS=$'\t' read -r kind name type target; do
    [[ -n "$target" ]] || continue
    case "$target" in
      ./* | ../*) ;;
      *) continue ;;
    esac
    path="${base}/${target}"
    if [[ ! -f "$path" ]]; then
      log_error "${rel}: ${kind} ${name}: \$text target ${target} does not exist"
      failed=1
      continue
    fi
    if ! yq -e 'tag == "!!map"' "$path" >/dev/null 2>&1; then
      log_error "${rel}: ${kind} ${name}: ${target} is not a YAML or JSON document"
      failed=1
    elif [[ "$type" == openapi && ! "$(yq -r '.openapi // ""' "$path")" =~ ^3\.[01]\.[0-9]+$ ]]; then
      log_error "${rel}: ${kind} ${name}: ${target} does not declare openapi 3.0.x or 3.1.x"
      failed=1
    else
      log_info "${rel}: ${kind} ${name}: ${target} parses"
    fi
  done < <(yq -N "$QUERY" "$file")
done

((failed == 0)) || die "catalog validation failed"
log_info "catalog valid"
