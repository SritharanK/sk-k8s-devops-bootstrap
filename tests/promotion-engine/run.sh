#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test of hack/promotion-engine.sh against the fixture cluster definitions in
# fixtures/<case>/clusters/. No cluster, no network; needs yq v4.
# Usage: tests/promotion-engine/run.sh   (or: make promotion-engine-test)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../hack/promotion-engine.sh"
FIXTURES="${HERE}/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# expect NAME WANT_STATUS WANT_ENGINE PROMOTION_ENGINE CLUSTERS_DIR
expect() {
  local name="$1" want_status="$2" want_engine="$3" value="$4" dir="$5"
  local out status
  out="$(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT PROMOTION_ENGINE="$value" "$SCRIPT" "$dir" 2>"${WORK}/stderr")"
  status=$?
  if [[ "$status" == "$want_status" && "$out" == "$want_engine" ]]; then
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: status %s (want %s), engine "%s" (want "%s")\n' "$name" "$status" "$want_status" "$out" "$want_engine"
    sed 's/^/     /' "${WORK}/stderr"
  fi
}

# Derived from the cluster definitions when PROMOTION_ENGINE is unset.
expect "no kargo toolchain: workflows" 0 workflows "" "${FIXTURES}/none/clusters"
expect "kargo disabled: workflows" 0 workflows "" "${FIXTURES}/kargo-off/clusters"
expect "kargo enabled in one of two clusters: kargo" 0 kargo "" "${FIXTURES}/kargo-on/clusters"
expect "kargo enabled, block style, pipelines tuned: kargo" 0 kargo "" "${FIXTURES}/block-style/clusters"
expect "kargo enabled without pipelines: workflows" 0 workflows "" "${FIXTURES}/pipelines-off/clusters"
mkdir -p "${WORK}/empty"
expect "no cluster definitions: workflows" 0 workflows "" "${WORK}/empty"

# An explicit value always wins.
expect "explicit workflows over an enabled kargo" 0 workflows workflows "${FIXTURES}/kargo-on/clusters"
expect "explicit kargo without a kargo cluster" 0 kargo kargo "${FIXTURES}/none/clusters"

# Errors.
expect "invalid value" 2 "" Kargo "${FIXTURES}/none/clusters"
expect "missing clusters directory" 2 "" "" "${WORK}/missing"
mkdir -p "${WORK}/broken/clusters/lab"
printf 'toolchains: {kargo: [\n' >"${WORK}/broken/clusters/lab/cluster.yaml"
expect "unreadable cluster file" 2 "" "" "${WORK}/broken/clusters"

# GitHub Actions: output and notice.
: >"${WORK}/output"
GITHUB_ACTIONS=true GITHUB_OUTPUT="${WORK}/output" PROMOTION_ENGINE="" \
  "$SCRIPT" "${FIXTURES}/kargo-on/clusters" >/dev/null 2>"${WORK}/annotations"
if grep -qx 'engine=kargo' "${WORK}/output" &&
  grep -q '^::notice::Promotion engine: kargo (PROMOTION_ENGINE is unset and toolchains.kargo is enabled in .*/kargo-on/clusters/reference/cluster.yaml)' "${WORK}/annotations"; then
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "GitHub Actions output and notice"
else
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "GitHub Actions output and notice"
  sed 's/^/     /' "${WORK}/output" "${WORK}/annotations"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
