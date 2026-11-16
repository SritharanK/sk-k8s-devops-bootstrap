#!/usr/bin/env bash
# Regenerate the Prometheus rules in rules/ from the Sloth specs in slos/.
#
# Usage:
#   ./generate.sh          write rules/<name>.yaml for every slos/<name>.yaml
#   ./generate.sh --check  generate into a temporary directory and exit 1 if the
#                          committed rules differ from the output (for CI)
#
# Sloth runs with `go run` at the pinned version below, which needs Go and access
# to the Go module proxy; the checksum database verifies the source. Set SLOTH to
# the path of an installed sloth binary to use that instead. It must be the same
# version, or the generated header and possibly the rules differ.
set -euo pipefail

readonly SLOTH_VERSION=v0.16.0
readonly SLO_PERIOD=30d

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly chart_dir
readonly spec_dir=$chart_dir/slos
readonly rules_dir=$chart_dir/rules

sloth() {
  if [[ -n "${SLOTH:-}" ]]; then
    "$SLOTH" "$@"
  elif command -v go >/dev/null 2>&1; then
    # Set the version the way the upstream release build does, so the header in
    # the generated files matches the output of a release binary.
    go run -ldflags "-X github.com/slok/sloth/internal/info.Version=${SLOTH_VERSION}" \
      "github.com/slok/sloth/cmd/sloth@${SLOTH_VERSION}" "$@"
  else
    echo "error: neither SLOTH nor go is available" >&2
    return 1
  fi
}

# generate <output directory>: one rules file per spec, same file name.
generate() {
  local out=$1 spec
  local specs=()
  shopt -s nullglob
  specs=("$spec_dir"/*.yaml)
  shopt -u nullglob
  if ((${#specs[@]} == 0)); then
    echo "error: no specs found in $spec_dir" >&2
    return 1
  fi
  for spec in "${specs[@]}"; do
    sloth generate --no-log --default-slo-period="$SLO_PERIOD" \
      -i "$spec" -o "$out/$(basename "$spec")"
  done
}

case "${1:-}" in
  "")
    generate "$rules_dir"
    echo "rules regenerated in $rules_dir"
    ;;
  --check)
    # The temporary directory is kept so a failed check can be inspected;
    # CI runners discard it with the workspace.
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/slo-rules.XXXXXX")
    generate "$tmp"
    if ! diff -r "$rules_dir" "$tmp"; then
      echo "error: rules/ is out of date, run ./generate.sh and commit the result (fresh output in $tmp)" >&2
      exit 1
    fi
    echo "rules/ is up to date"
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
