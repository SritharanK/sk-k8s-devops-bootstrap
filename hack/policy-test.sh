#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the Kyverno policies of the platform in two parts.
#
# Part 1, unit tests: runs the Kyverno CLI test suite of the policy chart,
# every kyverno-test.yaml under helmcharts/system-charts/kyverno-policies/tests,
# after the suite's own render.sh --check (when present) has confirmed that the
# committed test renders match the chart.
#
# Part 2, admission dry run: for each rendered profile, evaluates the rendered
# policies against the rendered manifests of the applications with
# `kyverno apply`, offline, the way the admission controller would evaluate
# them on create.
#   Policies    Documents of kind ClusterPolicy, Policy, ValidatingPolicy,
#               NamespacedValidatingPolicy, MutatingPolicy,
#               NamespacedMutatingPolicy, GeneratingPolicy,
#               NamespacedGeneratingPolicy, DeletingPolicy,
#               NamespacedDeletingPolicy, ValidatingAdmissionPolicy,
#               MutatingAdmissionPolicy and their bindings, from the index
#               rows whose chart list contains
#               helmcharts/system-charts/kyverno-policies (application rows
#               when there are any, otherwise rows of any type).
#   Excluded    Image verification: ImageValidatingPolicy and
#               NamespacedImageValidatingPolicy documents, and verifyImages
#               rules of ClusterPolicy and Policy (a policy left without
#               rules is dropped). They need registry and transparency log
#               access and are covered by the end-to-end test.
#   Exceptions  Every PolicyException document in the profile's render,
#               passed with --exception.
#   Resources   Every document of the application rows whose destination
#               namespace is the namespace of one of the profile's
#               environments (cluster.environments, default dev, stage,
#               prod; namespace namespaces.<env>, default <env>). A
#               namespaced document without metadata.namespace gets the
#               destination namespace, as Argo CD would apply it.
#   Namespaces  A Namespace object per environment namespace, labelled
#               kubernetes.io/metadata.name plus the labels of a rendered
#               Namespace of that name, is passed as CLI values so that
#               namespaceSelector matches as in the cluster.
# --audit-warn is not passed: an Audit violation (for example in dev) fails
# like an Enforce violation, because the applications must be compliant in
# every environment.
#
# Usage:
#   hack/policy-test.sh [--profile NAME]... [--out DIR] [--repo DIR]
#                       [--tests-only | --apply-only] [--verbose]
#
# Options:
#   --profile NAME  Profile to dry-run; repeat for several. Default: every
#                   directory under the render output that has an index.tsv.
#   --out DIR       Render output of hack/render.sh.
#                   Default: ${OUT_DIR:-<repository root>/_out}.
#   --repo DIR      Repository that holds the test suite and the cluster
#                   definitions. Default: the repository of this script.
#   --tests-only    Run part 1 only.
#   --apply-only    Run part 2 only.
#   --verbose       Also print passing unit tests and passing results.
#   -h, --help      Show this help.
#
# Inputs:
#   <repo>/helmcharts/system-charts/kyverno-policies/tests/**/kyverno-test.yaml
#   <out>/<profile>/index.tsv (file, type, name, chart, namespace, project;
#     "-" for an empty field) and the rendered files it lists; other files
#     under <out> are ignored.
#   <repo>/clusters/<profile>/cluster.yaml (cluster.environments, namespaces)
#
# Outputs:
#   stdout  Unit test summary; per profile one line with the pass, fail,
#           warn, error and skip counts, then one line per failing or
#           erroring policy, rule and resource (warnings are listed too).
#   stderr  Progress and diagnostics.
#   Exit status 0 when everything passes, 1 on a failed unit test, a policy
#   violation or an evaluation error, 2 on a usage error.
#
# Requirements: kyverno CLI 1.20.0 or later, yq v4 (mikefarah), jq. Part 1
# needs network access when the suite contains image verification cases.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

KYVERNO_MIN="1.20.0"
POLICY_CHART="helmcharts/system-charts/kyverno-policies"
INDEX_HEADER=$'file\ttype\tname\tchart\tnamespace\tproject'

POLICY_KINDS="ClusterPolicy Policy ValidatingPolicy NamespacedValidatingPolicy
MutatingPolicy NamespacedMutatingPolicy GeneratingPolicy NamespacedGeneratingPolicy
DeletingPolicy NamespacedDeletingPolicy ValidatingAdmissionPolicy
ValidatingAdmissionPolicyBinding MutatingAdmissionPolicy MutatingAdmissionPolicyBinding"
IMAGE_POLICY_KINDS="ImageValidatingPolicy NamespacedImageValidatingPolicy"
# Kinds that never get a default namespace. A cluster-scoped kind missing
# here only receives an unused metadata.namespace in the dry run.
CLUSTER_KINDS="Namespace Node PersistentVolume StorageClass CSIDriver CSINode
VolumeAttachment IngressClass RuntimeClass PriorityClass ClusterRole
ClusterRoleBinding CustomResourceDefinition APIService
MutatingWebhookConfiguration ValidatingWebhookConfiguration
ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding
MutatingAdmissionPolicy MutatingAdmissionPolicyBinding GatewayClass
ClusterIssuer ClusterSecretStore ClusterExternalSecret ClusterPolicy
ClusterCleanupPolicy ValidatingPolicy MutatingPolicy GeneratingPolicy
DeletingPolicy ImageValidatingPolicy ClusterAnalysisTemplate"

usage() {
  sed -n '/^# Usage:/,/^# Requirements:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

REPO="$REPO_ROOT"
OUT="${OUT_DIR:-$REPO_ROOT/_out}"
PROFILES=()
RUN_TESTS=1
RUN_APPLY=1
VERBOSE=0

while (($# > 0)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 && -n "$2" ]] || die "--profile needs a value" 2
      PROFILES+=("$2")
      shift 2
      ;;
    --out)
      [[ $# -ge 2 && -n "$2" ]] || die "--out needs a value" 2
      OUT="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || die "--repo needs a value" 2
      REPO="$2"
      shift 2
      ;;
    --tests-only)
      RUN_APPLY=0
      shift
      ;;
    --apply-only)
      RUN_TESTS=0
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1" 2
      ;;
  esac
done

((RUN_TESTS + RUN_APPLY > 0)) || die "--tests-only and --apply-only exclude each other" 2
[[ -d "$REPO" ]] || die "repository not found: $REPO" 2
REPO="$(cd "$REPO" && pwd -P)"

require_cmd kyverno yq jq
[[ "$(yq --version 2>/dev/null)" == *mikefarah* ]] || die "yq must be mikefarah/yq v4 (see mise.toml)"
KYVERNO_VERSION="$(kyverno version 2>/dev/null | awk '/^Version:/ {v = $2} END {print v}')"
if [[ -z "$KYVERNO_VERSION" ]]; then
  log_warn "could not read the kyverno CLI version; ${KYVERNO_MIN} or later is expected"
elif ! version_ge "$KYVERNO_VERSION" "$KYVERNO_MIN"; then
  die "kyverno CLI ${KYVERNO_VERSION} is older than ${KYVERNO_MIN} (see mise.toml)"
fi

make_temp_dir WORK policy-test
FAILED=0

# yq_kind_match KIND...: prints a yq condition that is true for these kinds.
yq_kind_match() {
  local expr="" kind
  for kind in "$@"; do
    expr="${expr:+$expr or }(.kind == \"$kind\")"
  done
  printf '(%s)' "$expr"
}

# count_docs FILE: number of YAML documents with a kind in FILE.
count_docs() {
  if [[ ! -s "$1" ]]; then
    echo 0
    return 0
  fi
  yq -N 'select(tag == "!!map" and has("kind")) | .kind' "$1" | grep -c . || true
}

# ---------------------------------------------------------------------------
# Part 1: unit tests
# ---------------------------------------------------------------------------
run_unit_tests() {
  local dir="${REPO}/${POLICY_CHART}/tests" log="${WORK}/unit-tests.log" rc=0
  local suites
  if [[ -d "$dir" ]]; then
    suites="$(find "$dir" -name kyverno-test.yaml -type f | wc -l | tr -d ' ')"
  else
    suites=0
  fi
  if [[ "$suites" == "0" ]]; then
    die "policy unit test suite missing: ${dir#"$REPO"/} has no kyverno-test.yaml. The policy chart must ship Kyverno CLI tests; run with --apply-only to skip part 1."
  fi

  # kyverno test reads committed renders of the policy chart. The chart's own
  # tests/render.sh --check fails when they no longer match the templates.
  if [[ -f "${dir}/render.sh" ]]; then
    log_info "part 1: ${dir#"$REPO"/}/render.sh --check"
    if ! bash "${dir}/render.sh" --check >"${WORK}/render-check.log" 2>&1; then
      sed 's/^/  /' "${WORK}/render-check.log"
      echo "  FAILED: the rendered test policies differ from the chart; run ${dir#"$REPO"/}/render.sh"
      FAILED=1
    fi
  fi

  log_info "part 1: kyverno test ${dir#"$REPO"/} (kyverno-test.yaml files: ${suites})"
  local args=(test "$dir" --require-tests --remove-color)
  if ((VERBOSE)); then
    args+=(--detailed-results)
  else
    args+=(--fail-only)
  fi
  kyverno "${args[@]}" >"$log" 2>&1 || rc=$?

  echo "Part 1: unit tests (${dir#"$REPO"/}, kyverno-test.yaml files: ${suites})"
  if ((rc != 0 || VERBOSE)); then
    sed 's/^/  /' "$log"
  else
    grep -E '^Test Summary:' "$log" | sed 's/^/  /' || true
  fi
  if ((rc != 0)); then
    echo "  FAILED: kyverno test exited with status ${rc}"
    FAILED=1
  fi
}

# ---------------------------------------------------------------------------
# Part 2: admission dry run
# ---------------------------------------------------------------------------

# check_index PROFILE: fails unless the profile has an index.tsv with the
# header of the render contract.
check_index() {
  local idx="${OUT}/$1/index.tsv" header
  [[ -f "$idx" ]] || die "no render for profile $1: ${idx} not found (run hack/render.sh)"
  header="$(head -n 1 "$idx" | tr -d '\r')"
  [[ "$header" == "$INDEX_HEADER" ]] ||
    die "unexpected header in ${idx}: expected the columns ${INDEX_HEADER//$'\t'/, }"
}

# index_rows PROFILE: prints the data rows of index.tsv with the fields
# separated by \037 instead of tabs, so that `read` keeps empty fields.
index_rows() {
  tail -n +2 "${OUT}/$1/index.tsv" | tr -d '\r' | tr '\t' '\037'
}

# chart_list CHART: normalises the chart column, a comma-separated list of
# repository-relative chart paths, to paths without "./" or a trailing "/".
chart_list() {
  printf '%s\n' "$1" | tr ',' '\n' | sed -e 's#^\./##' -e 's#/$##' | paste -s -d , -
}

# env_namespaces PROFILE: prints one namespace per environment of PROFILE.
env_namespaces() {
  local cluster="${REPO}/clusters/$1/cluster.yaml"
  if [[ ! -f "$cluster" ]]; then
    log_warn "profile $1: ${cluster#"$REPO"/} not found; using environments dev, stage, prod"
    printf '%s\n' dev stage prod
    return 0
  fi
  # shellcheck disable=SC2016  # $c and $e are yq variables
  yq -N '. as $c | ($c.cluster.environments // ["dev", "stage", "prod"])[] | . as $e | ($c.namespaces[$e] // $e)' "$cluster"
}

dry_run_profile() {
  local profile="$1"
  local dir="${WORK}/${profile}"
  mkdir -p "$dir"
  local policy_list="${dir}/policy-files" all_list="${dir}/all-files" resource_list="${dir}/resource-files"
  : >"$policy_list"
  : >"$all_list"
  : >"$resource_list"

  local namespaces
  namespaces=" $(env_namespaces "$profile" | tr '\n' ' ')"

  local file type chart namespace path policy_rows_app=0
  while IFS=$'\037' read -r file type _ chart namespace _; do
    # "-" marks an empty field; remote rows have no rendered file.
    [[ -n "$file" && "$file" != "-" ]] || continue
    [[ "$namespace" != "-" ]] || namespace=""
    path="${OUT}/${file}"
    [[ -f "$path" ]] || die "profile ${profile}: index.tsv lists ${file}, which does not exist under ${OUT}"
    printf '%s\n' "$path" >>"$all_list"
    if [[ ",$(chart_list "$chart")," == *",${POLICY_CHART},"* ]]; then
      printf '%s\t%s\n' "$type" "$path" >>"$policy_list"
      if [[ "$type" == "application" ]]; then
        policy_rows_app=1
      fi
    fi
    if [[ "$type" == "application" && -n "$namespace" && "$namespaces" == *" ${namespace} "* ]]; then
      printf '%s\t%s\n' "$namespace" "$path" >>"$resource_list"
    fi
  done < <(index_rows "$profile")

  # Policy files: the application rows of the policy chart when there are
  # any, so that a standalone chart render does not duplicate them.
  local policy_files=()
  while IFS=$'\t' read -r type path; do
    if ((policy_rows_app == 0)) || [[ "$type" == "application" ]]; then
      policy_files+=("$path")
    fi
  done <"$policy_list"

  echo "Profile ${profile} (environment namespaces:${namespaces% })"
  if ((${#policy_files[@]} == 0)); then
    echo "  ERROR: no rendered document from ${POLICY_CHART} in ${OUT}/${profile}/index.tsv"
    FAILED=1
    return 0
  fi

  # Policies, without image verification.
  local policies="${dir}/policies.yaml" excluded_docs excluded_rules
  # shellcheck disable=SC2086  # word splitting of the kind lists is intended
  {
    excluded_docs="$(yq -N "select(tag == \"!!map\") | select($(yq_kind_match $IMAGE_POLICY_KINDS)) | .kind" \
      "${policy_files[@]}" | grep -c . || true)"
    excluded_rules="$(yq -N 'select(tag == "!!map") | select((.kind == "ClusterPolicy") or (.kind == "Policy")) | .spec.rules[]? | select(has("verifyImages")) | .name' \
      "${policy_files[@]}" | grep -c . || true)"
    yq "select(tag == \"!!map\") | select($(yq_kind_match $POLICY_KINDS))
      | (select((.kind == \"ClusterPolicy\") or (.kind == \"Policy\")) | .spec.rules) |= ((. // []) | map(select(has(\"verifyImages\") | not)))
      | select(((.kind != \"ClusterPolicy\") and (.kind != \"Policy\")) or ((.spec.rules | length) > 0))" \
      "${policy_files[@]}" >"$policies"
  }
  local n_policies
  n_policies="$(count_docs "$policies")"
  if ((excluded_docs + excluded_rules > 0)); then
    log_info "profile ${profile}: image verification excluded (policies: ${excluded_docs}, verifyImages rules: ${excluded_rules})"
  fi
  if ((n_policies == 0)); then
    echo "  ERROR: ${POLICY_CHART} rendered no policy that the dry run can evaluate"
    FAILED=1
    return 0
  fi

  # Exceptions from the whole render of the profile.
  local all_files=()
  while IFS= read -r path; do
    all_files+=("$path")
  done <"$all_list"
  local exceptions="${dir}/exceptions.yaml" n_exceptions
  yq 'select(tag == "!!map") | select(.kind == "PolicyException")' "${all_files[@]}" >"$exceptions"
  n_exceptions="$(count_docs "$exceptions")"

  # Resources of the environment namespaces, without policies and
  # exceptions: one file per index row, files without documents left out
  # (the CLI rejects an empty document).
  local resource_args=() n_resources=0 n=0 out count
  # shellcheck disable=SC2086  # word splitting of the kind lists is intended
  while IFS=$'\t' read -r namespace path; do
    n=$((n + 1))
    out="${dir}/resources-${n}.yaml"
    NS="$namespace" yq "select(tag == \"!!map\" and has(\"kind\"))
      | select(($(yq_kind_match $POLICY_KINDS $IMAGE_POLICY_KINDS PolicyException)) | not)
      | (select(((.metadata.namespace // \"\") == \"\") and (($(yq_kind_match $CLUSTER_KINDS)) | not)) | .metadata.namespace) = strenv(NS)" \
      "$path" >"$out"
    count="$(count_docs "$out")"
    if ((count > 0)); then
      resource_args+=(--resource "$out")
      n_resources=$((n_resources + count))
    fi
  done <"$resource_list"
  if ((n_resources == 0)); then
    log_warn "profile ${profile}: no application manifests in the environment namespaces; nothing to evaluate"
    echo "  pass 0  fail 0  warn 0  error 0  skip 0  (no application manifests in the environment namespaces)"
    return 0
  fi

  # Namespace objects for namespaceSelector matching.
  local values="${dir}/values.json"
  yq ea -o json -I0 '[select(tag == "!!map") | select(.kind == "Namespace") | {"name": .metadata.name, "labels": (.metadata.labels // {})}]' \
    "${all_files[@]}" |
    jq --arg namespaces "$namespaces" '
      . as $rendered
      | {
          apiVersion: "cli.kyverno.io/v1alpha1",
          kind: "Value",
          metadata: {name: "values"},
          namespaces: [
            $namespaces | split(" ")[] | select(length > 0) | . as $ns
            | {
                apiVersion: "v1",
                kind: "Namespace",
                metadata: {
                  name: $ns,
                  labels: ((([$rendered[] | select(.name == $ns) | .labels] | add) // {})
                    + {"kubernetes.io/metadata.name": $ns})
                }
              }
          ]
        }' >"$values"

  local args=(apply "$policies" ${resource_args[@]+"${resource_args[@]}"} --values-file "$values"
    --policy-report --output-format json --remove-color)
  if ((n_exceptions > 0)); then
    args+=(--exception "$exceptions")
  fi
  local report="${dir}/report.json" errlog="${dir}/kyverno.log" rc=0
  kyverno "${args[@]}" >"$report" 2>"$errlog" || rc=$?

  if ! jq -e '.results | type == "array"' "$report" >/dev/null 2>&1; then
    echo "  ERROR: kyverno apply exited with status ${rc} and produced no report:"
    sed -e '/^[[:space:]]*$/d' -e 's/^/    /' "$errlog"
    FAILED=1
    return 0
  fi

  local counts
  counts="$(jq -r '
    reduce (.results[]?.result) as $r ({pass: 0, fail: 0, warn: 0, error: 0, skip: 0}; .[$r] += 1)
    | "\(.pass) \(.fail) \(.warn) \(.error) \(.skip)"' "$report")"
  local pass fail warn error skip
  read -r pass fail warn error skip <<<"$counts"
  printf '  pass %s  fail %s  warn %s  error %s  skip %s  (policies %s, resources %s, exceptions %s)\n' \
    "$pass" "$fail" "$warn" "$error" "$skip" "$n_policies" "$n_resources" "$n_exceptions"

  local show='["fail", "error", "warn"]'
  if ((VERBOSE)); then
    show='["fail", "error", "warn", "skip", "pass"]'
  fi
  jq -r --argjson show "$show" '
    .results[]? | select(.result as $r | $show | index($r))
    | . as $x | (.resources // [{}])[]
    | [($x.result | ascii_upcase),
       "\($x.policy)/\($x.rule // "")",
       "\(.kind // "?") \(if (.namespace // "") != "" then "\(.namespace)/" else "" end)\(.name // "?")",
       ($x.message // "" | gsub("\\s+"; " "))]
    | @tsv' "$report" |
    LC_ALL=C sort -u |
    awk -F'\t' '{ printf "    %-5s %s  %s: %s\n", $1, $2, $3, $4 }'

  if ((fail + error > 0)); then
    FAILED=1
  elif ((rc != 0)); then
    echo "  ERROR: kyverno apply exited with status ${rc} without failing results:"
    sed -e '/^[[:space:]]*$/d' -e 's/^/    /' "$errlog"
    FAILED=1
  fi
}

# resolve_profiles: fills PROFILES when no --profile was given and checks
# every profile before any test runs.
resolve_profiles() {
  [[ -d "$OUT" ]] || die "render output not found: ${OUT} (run hack/render.sh first)"
  OUT="$(cd "$OUT" && pwd -P)"
  if ((${#PROFILES[@]} == 0)); then
    local d
    for d in "$OUT"/*/; do
      if [[ -f "${d}index.tsv" ]]; then
        PROFILES+=("$(basename "$d")")
      fi
    done
  fi
  ((${#PROFILES[@]} > 0)) || die "no rendered profile under ${OUT} (run hack/render.sh first)"
  local profile
  for profile in "${PROFILES[@]}"; do
    check_index "$profile"
  done
}

run_dry_run() {
  log_info "part 2: admission dry run for ${PROFILES[*]} (render output ${OUT})"
  echo "Part 2: admission dry run (kyverno apply, render output ${OUT})"
  local profile
  for profile in "${PROFILES[@]}"; do
    dry_run_profile "$profile"
  done
}

if ((RUN_APPLY)); then
  resolve_profiles
fi
if ((RUN_TESTS)); then
  run_unit_tests
fi
if ((RUN_APPLY)); then
  run_dry_run
fi

if ((FAILED)); then
  die "policy tests failed"
fi
log_info "policy tests passed"
