#!/usr/bin/env bash
# Render the policies under test from the chart into each test directory, so
# that `kyverno test` runs on plain manifests.
#
# Usage:
#   render.sh           write policies.yaml (and exceptions.yaml) per test
#   render.sh --check   exit 1 if a committed file differs from a fresh render
#
# Requires helm. Run from any directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="$(dirname "$here")"
mode="${1:-write}"
case "$mode" in
  write | --check) ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

command -v helm >/dev/null 2>&1 || {
  echo "helm is required" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

drift=0

# render <output file> <template> [helm args...]
render() {
  local out="$1" template="$2"
  shift 2
  local rendered="$tmp/rendered.yaml"
  {
    echo "# yamllint disable-file"
    echo "# Rendered by tests/render.sh from the chart templates. Do not edit; re-run the script."
    helm template kyverno-policies "$chart" --namespace kyverno \
      --show-only "$template" "$@"
  } >"$rendered"
  if [[ "$mode" == "--check" ]]; then
    if ! diff -u "$out" "$rendered" >"$tmp/diff" 2>&1; then
      echo "out of date: ${out#"$chart"/}" >&2
      cat "$tmp/diff" >&2
      drift=1
    fi
  else
    cp "$rendered" "$out"
  fi
}

render "$here/workload-policies/policies.yaml" templates/validatingpolicies.yaml \
  --show-only templates/networkpolicy-audit.yaml
render "$here/workload-policies/exceptions.yaml" templates/policyexceptions.yaml

for dir in "$here"/image-verification/*/; do
  dir="${dir%/}"
  render "$dir/policies.yaml" templates/imagevalidatingpolicy.yaml \
    --values "$dir/chart-values.yaml"
done

if [[ "$drift" -ne 0 ]]; then
  echo "rendered policies are out of date: run $0 and commit the result" >&2
  exit 1
fi
