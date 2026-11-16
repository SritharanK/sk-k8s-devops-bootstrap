#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Renders what Argo CD would deploy for each cluster profile and fails where
# Argo CD would refuse to sync.
#
# Usage:
#   hack/render.sh [--profile NAME]... [--repo DIR] [--out DIR]
#                  [--skip-lint] [--lint-only] [--list]
#
# Options:
#   --profile NAME  Profile to process; repeat for several. Default: every
#                   clusters/<name>/cluster.yaml, profile name = <name>.
#                   Without a clusters/ directory there is
#                   one profile, "default", rendered from
#                   argocd-bootstrap/values.yaml alone.
#   --repo DIR      Repository to render. Default: this repository.
#   --out DIR       Output directory. Default: $OUT_DIR, else <this repo>/_out.
#   --skip-lint     Skip helm lint.
#   --lint-only     helm dependency build and helm lint --strict of every
#                   chart, per profile. No templates, no Application
#                   emulation, nothing written to --out. Pre-commit fast path.
#   --list          Print the plan per profile (Applications and charts)
#                   without rendering them. argocd-bootstrap is rendered to a
#                   temporary file to discover the Applications.
#   -h, --help      Show this help.
#
# Per profile:
#   1. Renders argocd-bootstrap with argocd-bootstrap/values.yaml and the
#      cluster file, as the root Application does; again with
#      applicationSet.enabled=true when the values define that switch; and
#      the bootstrap/ chart with its values and the cluster file, when the
#      repository has one.
#   2. Emulates the Argo CD repo server for every Application of the static
#      render (sorted by name) whose sources point into the repository: value
#      files ($<ref>/ and chart relative), valuesObject or values, parameters,
#      releaseName, destination namespace, skipCrds, skipTests. Runs helm
#      dependency build, helm lint --strict and helm template --include-crds.
#      Sources with chart: (remote charts) are listed in the index as type
#      remote and not rendered.
#   3. Lints and renders every other chart under helmcharts/ with values.yaml
#      and values-<profile>.yaml (release and namespace = directory name).
#      Library charts and charts used as a file:// dependency are linted only.
#   4. Renders the Applications and charts a second time with --api-versions
#      for every served version of every CRD in the profile's output, so
#      .Capabilities.APIVersions.Has guards see the platform CRDs.
#   5. Checks that rendering itself needs, reported together at the end:
#      Application names are unique (static and ApplicationSet mode), every
#      in-repo source path exists and holds a Chart.yaml, every value file
#      exists unless ignoreMissingValueFiles is set, and dependency builds,
#      lints and templates succeed. AppProject permissions, destinations and
#      manifest-generate-paths are checked by
#      argocd-bootstrap/tests/check-projects.sh, not here.
#   The Kubernetes version is cluster.kubernetesMinor plus ".0" (1.36.0 when
#   absent), passed to helm as --kube-version.
#
# Outputs, under <out>/<profile>/:
#   bootstrap/argocd-bootstrap.yaml         static render of argocd-bootstrap
#   bootstrap/argocd-bootstrap-appset.yaml  ApplicationSet mode, if defined
#   bootstrap/bootstrap.yaml                bootstrap/ chart, if present
#   apps/<application>.yaml                 one file per rendered Application
#   charts/<path, / replaced by __>.yaml    charts no Application references
#   index.tsv    tab separated: file, type, name, chart, namespace, project.
#                file is relative to <out>; type is bootstrap, application,
#                chart or remote; "-" marks an empty field (remote rows have
#                no file).
#   profile.env  PROFILE= and KUBERNETES_VERSION=
# Files are overwritten on every run and never removed. Consumers read only
# the files listed in index.tsv, so files left by an older run are harmless.
#
# The repository is never written: charts are copied to a temporary
# directory before helm dependency build. The http(s) chart repositories of
# dependencies are registered in a temporary Helm repository configuration,
# as Argo CD does; the user's Helm repositories are not used or changed.
#
# Requirements: helm 3.14+ or 4, yq v4 (mikefarah), jq 1.7+, and network
# access for helm dependency build of remote chart dependencies.
#
# Exit status: 0 when every render, lint and check passes, 1 otherwise,
# 2 for usage errors.

# jq programs below use jq variables ($name) inside single quotes.
# shellcheck disable=SC2016
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

readonly DEFAULT_KUBERNETES_VERSION=1.36.0
# Field separator for internal records: never part of a name, path or URL.
readonly US=$'\037'

PROFILES=()
REPO="$REPO_ROOT"
OUT="${OUT_DIR:-$REPO_ROOT/_out}"
SKIP_LINT=0
MODE=render

usage() {
  awk 'NR > 2 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"
}

usage_error() {
  log_error "$1 (see --help)"
  exit 2
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --profile)
        (($# >= 2)) || usage_error "--profile needs a value"
        PROFILES+=("$2")
        shift 2
        ;;
      --profile=*)
        PROFILES+=("${1#*=}")
        shift
        ;;
      --repo)
        (($# >= 2)) || usage_error "--repo needs a value"
        REPO="$2"
        shift 2
        ;;
      --repo=*)
        REPO="${1#*=}"
        shift
        ;;
      --out)
        (($# >= 2)) || usage_error "--out needs a value"
        OUT="$2"
        shift 2
        ;;
      --out=*)
        OUT="${1#*=}"
        shift
        ;;
      --skip-lint)
        SKIP_LINT=1
        shift
        ;;
      --lint-only)
        [[ "$MODE" == render ]] || usage_error "--lint-only and --list exclude each other"
        MODE=lint
        shift
        ;;
      --list)
        [[ "$MODE" == render ]] || usage_error "--lint-only and --list exclude each other"
        MODE=list
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# norm_path PATH
# Normalises a repository-relative path without touching the file system:
# drops empty and "." segments and resolves "..". Prints "." for the root; a
# result that starts with ".." lies outside the repository.
norm_path() {
  local IFS=/ part n
  local -a parts=() segs=()
  read -r -a parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..)
        n=${#segs[@]}
        if ((n > 0)) && [[ "${segs[n - 1]}" != .. ]]; then
          unset "segs[n - 1]"
          segs=(${segs[@]+"${segs[@]}"})
        else
          segs+=(..)
        fi
        ;;
      *) segs+=("$part") ;;
    esac
  done
  if ((${#segs[@]} == 0)); then
    printf '.\n'
  else
    printf '%s\n' "${segs[*]}"
  fi
}

outside_repo() {
  [[ "$1" == .. || "$1" == ../* ]]
}

# path_key PATH: file name for a repository path ("/" replaced by "__").
path_key() {
  printf '%s\n' "${1//\//__}"
}

# dns_name NAME: a valid Helm release name (lower case, [a-z0-9-], at most 53
# characters) derived from a directory name.
dns_name() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  s="${s:0:53}"
  while [[ "$s" == -* ]]; do s="${s#-}"; done
  while [[ "$s" == *- ]]; do s="${s%-}"; done
  printf '%s\n' "${s:-chart}"
}

# show_log FILE: prints a captured helm log, indented, with the staging
# directory removed from paths.
show_log() {
  local line prefix="$STAGE/"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '    %s\n' "${line//"$prefix"/}" >&2
  done <"$1"
}

# record_failure CATEGORY PROFILE SUBJECT MESSAGE
record_failure() {
  local msg="$4"
  msg="${msg//$'\t'/ }"
  msg="${msg//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$msg" >>"$FAILURES"
}

# to_jsonl FILE: one compact JSON object per Kubernetes object of a
# multi-document YAML file, with List kinds flattened, written to FILE.jsonl.
to_jsonl() {
  yq -o=json -I=0 '.' "$1" |
    jq -c 'select(type == "object")
      | if ((.kind // "") | endswith("List")) and ((.items | type) == "array")
        then .items[] | select(type == "object") else . end' >"$1.jsonl"
}

# add_index_row FILE TYPE NAME CHART NAMESPACE PROJECT ("-" for empty)
add_index_row() {
  local f cols=()
  for f in "$@"; do cols+=("${f:--}"); done
  local IFS=$'\t'
  printf '%s\n' "${cols[*]}" >>"$P_WORK/index.rows"
}

write_jq_library() {
  cat >"$WORK/apps.jq" <<'JQ'
def project_name: (.spec.project // "") | if . == "" then "default" else . end;

def app_sources: [(.spec.sources // [.spec.source])[] | select(. != null)];

def re_escape: gsub("(?<c>[.+*?^$()\\[\\]{}|\\\\])"; "\\\(.c)");

def subst($el):
  reduce ($el | to_entries[]) as $kv (.;
    gsub("\\{\\{\\s*\\.?" + ($kv.key | re_escape) + "\\s*\\}\\}"; $kv.value | tostring));

# Application objects of a render, with list generator ApplicationSets
# expanded (goTemplate {{ .key }} and fasttemplate {{key}} placeholders).
# Other generators are reported by the caller.
def applications($origin):
  if .kind == "Application" then . + {_origin: $origin}
  elif .kind == "ApplicationSet" then
    . as $as
    | ($as.spec.generators // [])[] | (.list.elements // [])[] as $el
    | $as.spec.template
    | walk(if type == "string" then subst($el) else . end)
    | . + {apiVersion: "argoproj.io/v1alpha1", kind: "Application",
           _origin: "\($origin) ApplicationSet/\($as.metadata.name)"}
    | .metadata.namespace = (.metadata.namespace // $as.metadata.namespace)
  else empty end;
JQ
}

# jqp ARGS...: jq with the Application helpers (include "apps") available.
jqp() {
  jq -L "$WORK" "$@"
}

# ---------------------------------------------------------------------------
# Profiles and charts
# ---------------------------------------------------------------------------

discover_profiles() {
  local f d p
  ALL_PROFILES=()
  if [[ -d "$REPO/clusters" ]]; then
    for f in "$REPO"/clusters/*/cluster.yaml; do
      [[ -f "$f" ]] || continue
      d="${f%/cluster.yaml}"
      ALL_PROFILES+=("${d##*/}")
    done
    ((${#ALL_PROFILES[@]} > 0)) || die "$REPO/clusters holds no <name>/cluster.yaml"
  else
    ALL_PROFILES=(default)
  fi
  if ((${#PROFILES[@]} == 0)); then
    PROFILES=("${ALL_PROFILES[@]}")
    return 0
  fi
  for p in "${PROFILES[@]}"; do
    case " ${ALL_PROFILES[*]} " in
      *" $p "*) ;;
      *) die "unknown profile: $p (available: ${ALL_PROFILES[*]})" 2 ;;
    esac
  done
}

# Writes the chart directories under helmcharts/ to $WORK/charts.list, sorted,
# without the charts/ directory of any chart (vendored dependencies). Library
# charts and charts that another chart uses as a file:// dependency go to
# $WORK/libraries.list instead: they are linted, never rendered on their own.
discover_charts() {
  local f d check parent skip rel dep deps=$'\n'
  local -a files=()
  : >"$WORK/charts.list"
  : >"$WORK/libraries.list"
  [[ -d "$REPO/helmcharts" ]] || return 0
  while IFS= read -r f; do files+=("$f"); done < <(find "$REPO/helmcharts" -name Chart.yaml -type f)
  while IFS=$'\t' read -r f dep; do
    d="${f%/Chart.yaml}"
    deps+="$(norm_path "${d#"$REPO"/}/$dep")"$'\n'
  done < <(yq -N '.dependencies[]? | select(.repository // "" | test("^file://"))
    | filename + "\t" + (.repository | sub("^file://"; ""))' ${files[@]+"${files[@]}"})
  while IFS= read -r f; do
    d="${f%/Chart.yaml}"
    check="$d"
    skip=0
    while [[ "$check" == "$REPO"/helmcharts/* ]]; do
      parent="${check%/*}"
      if [[ "${check##*/}" == charts && -f "$parent/Chart.yaml" ]]; then
        skip=1
        break
      fi
      check="$parent"
    done
    ((skip == 0)) || continue
    rel="${d#"$REPO"/}"
    if [[ "$deps" == *$'\n'"$rel"$'\n'* || "$(yq '.type // ""' "$f")" == library ]]; then
      printf '%s\n' "$rel" >>"$WORK/libraries.list"
    else
      printf '%s\n' "$rel" >>"$WORK/charts.list"
    fi
  done < <(find "$REPO/helmcharts" -name Chart.yaml -type f | LC_ALL=C sort)
}

# profile_value EXPR: first non-empty value of EXPR in the cluster file, then
# in argocd-bootstrap/values.yaml.
profile_value() {
  local expr="$1" f v
  for f in ${P_CLUSTER:+"$P_CLUSTER"} "$REPO/argocd-bootstrap/values.yaml"; do
    v="$(yq "($expr) // \"\"" "$f")"
    if [[ -n "$v" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  done
}

setup_profile() {
  local minor
  P="$1"
  P_WORK="$WORK/profiles/$P"
  mkdir -p "$P_WORK/render/bootstrap" "$P_WORK/render/apps" "$P_WORK/render/charts" \
    "$P_WORK/plan" "$P_WORK/apps/static" "$P_WORK/apps/appset" "$P_WORK/failed"
  : >"$P_WORK/index.rows"
  P_CLUSTER=""
  if [[ -d "$REPO/clusters" ]]; then
    P_CLUSTER="$REPO/clusters/$P/cluster.yaml"
  fi
  BS_VALUES=(-f "$REPO/argocd-bootstrap/values.yaml")
  if [[ -n "$P_CLUSTER" ]]; then
    BS_VALUES+=(-f "$P_CLUSTER")
  fi
  minor="$(profile_value .cluster.kubernetesMinor)"
  if [[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]]; then
    P_KV="$minor.0"
  elif [[ "$minor" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    P_KV="$minor"
  else
    if [[ -n "$minor" ]]; then
      log_warn "[$P] cluster.kubernetesMinor \"$minor\" is not a version; using $DEFAULT_KUBERNETES_VERSION"
    fi
    P_KV="$DEFAULT_KUBERNETES_VERSION"
  fi
  P_ARGOCD_NS="$(profile_value .namespaces.argocd)"
  P_ARGOCD_NS="${P_ARGOCD_NS:-argocd}"
  P_API_ARGS=()
  P_API_COUNT=0
}

# ---------------------------------------------------------------------------
# Charts: staging, dependencies, lint, template
# ---------------------------------------------------------------------------

# stage_chart REL: copies the chart at REL to the staging directory once,
# together with its file:// dependencies, so that helm dependency build never
# writes into the repository.
stage_chart() {
  local rel="$1" dst="$STAGE/$1" dep deprel
  [[ -f "$dst/Chart.yaml" ]] && return 0
  [[ -f "$REPO/$rel/Chart.yaml" ]] || return 1
  mkdir -p "$dst"
  cp -R "$REPO/$rel/." "$dst/"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    deprel="$(norm_path "$rel/$dep")"
    if ! outside_repo "$deprel"; then
      stage_chart "$deprel" || true
    fi
  done < <(yq '.dependencies[]? | select(.repository // "" | test("^file://")) | .repository | sub("^file://"; "")' "$REPO/$rel/Chart.yaml")
}

# add_dependency_repos REL: registers the http(s) chart repositories that the
# dependencies of REL use, as Argo CD does before helm dependency build. They
# go to the private Helm repository configuration of this run
# (HELM_REPOSITORY_CONFIG), never to the user's.
add_dependency_repos() {
  local rel="$1" url log="$WORK/log/repo-add.log"
  while IFS= read -r url; do
    case "$url" in http://* | https://*) ;; *) continue ;; esac
    url="${url%/}"
    [[ "$HELM_REPOS_ADDED" != *$'\n'"$url"$'\n'* ]] || continue
    HELM_REPO_COUNT=$((HELM_REPO_COUNT + 1))
    if ! helm repo add "dependency-$HELM_REPO_COUNT" "$url" >"$log" 2>&1; then
      log_error "helm repo add $url failed (dependency of $rel):"
      show_log "$log"
      record_failure dependencies all "$rel" "chart repository $url is unavailable"
      return 1
    fi
    HELM_REPOS_ADDED+="$url"$'\n'
  done < <(yq '.dependencies[]?.repository // ""' "$STAGE/$rel/Chart.yaml")
}

# prepare_chart REL: stages the chart and builds its dependencies, once per
# run. Returns non-zero when the chart cannot be rendered.
prepare_chart() {
  local rel="$1" key marker chart log ndeps
  key="$(path_key "$rel")"
  marker="$WORK/deps/$key"
  if [[ -f "$marker" ]]; then
    if [[ "$(<"$marker")" == ok ]]; then return 0; fi
    return 1
  fi
  echo fail >"$marker"
  if ! stage_chart "$rel"; then
    record_failure render all "$rel" "no Chart.yaml in $rel"
    return 1
  fi
  chart="$STAGE/$rel"
  ndeps="$(yq '.dependencies // [] | length' "$chart/Chart.yaml")"
  if ((ndeps > 0)); then
    log="$WORK/log/deps-$key.log"
    add_dependency_repos "$rel" || return 1
    if [[ -f "$chart/Chart.lock" ]]; then
      log_info "dependency build $rel"
      if ! helm dependency build "$chart" >"$log" 2>&1; then
        log_error "helm dependency build failed for $rel:"
        show_log "$log"
        record_failure dependencies all "$rel" "helm dependency build failed: Chart.lock does not match Chart.yaml, or a dependency is unavailable"
        return 1
      fi
    else
      record_failure dependencies all "$rel" "Chart.yaml declares dependencies but Chart.lock is missing; run helm dependency update $rel and commit Chart.lock"
      log_warn "dependency update $rel (no Chart.lock; resolved in the staging copy only to continue)"
      if ! helm dependency update "$chart" >"$log" 2>&1; then
        log_error "helm dependency update failed for $rel:"
        show_log "$log"
        record_failure dependencies all "$rel" "helm dependency update failed"
        return 1
      fi
    fi
  fi
  echo ok >"$marker"
}

# lint_chart SUBJECT REL NAMESPACE [HELM ARGS...]
lint_chart() {
  local subject="$1" rel="$2" ns="$3" log="$WORK/log/lint.log"
  shift 3
  local cmd=(helm lint --strict "$STAGE/$rel" --kube-version "$P_KV")
  if [[ -n "$ns" ]]; then cmd+=(--namespace "$ns"); fi
  log_info "[$P] lint $subject ($rel)"
  if "${cmd[@]}" "$@" >"$log" 2>&1; then
    return 0
  fi
  log_error "[$P] helm lint --strict failed for $subject ($rel):"
  show_log "$log"
  record_failure lint "$P" "$subject" "helm lint --strict failed for $rel"
  return 1
}

# template_chart OUTFILE SUBJECT REL RELEASE NAMESPACE [HELM ARGS...]
template_chart() {
  local out="$1" subject="$2" rel="$3" release="$4" ns="$5" log="$WORK/log/template.log"
  shift 5
  local cmd=(helm template "$release" "$STAGE/$rel" --kube-version "$P_KV")
  if [[ -n "$ns" ]]; then cmd+=(--namespace "$ns"); fi
  cmd+=(${P_API_ARGS[@]+"${P_API_ARGS[@]}"})
  if "${cmd[@]}" "$@" >"$out.tmp" 2>"$log"; then
    mv -f "$out.tmp" "$out"
    if [[ "${LOG_LEVEL:-info}" == debug && -s "$log" ]]; then show_log "$log"; fi
    return 0
  fi
  log_error "[$P] helm template failed for $subject ($rel):"
  show_log "$log"
  return 1
}

pass_note() {
  if ((P_API_COUNT > 0)); then printf ' (pass 2, %s API versions)' "$P_API_COUNT"; fi
}

# ---------------------------------------------------------------------------
# Bootstrap renders and Applications
# ---------------------------------------------------------------------------

appset_switch_defined() {
  local f
  for f in ${P_CLUSTER:+"$P_CLUSTER"} "$REPO/argocd-bootstrap/values.yaml"; do
    if [[ "$(yq '(.applicationSet.enabled) != null' "$f")" == true ]]; then return 0; fi
  done
  return 1
}

# render_bootstrap LINT(0|1): renders argocd-bootstrap (static and
# ApplicationSet mode) and the bootstrap/ chart into $P_WORK/render/bootstrap.
render_bootstrap() {
  local lint="$1" dir="$P_WORK/render/bootstrap" bvalues=()
  if prepare_chart argocd-bootstrap; then
    if ((lint)); then
      lint_chart argocd-bootstrap argocd-bootstrap "$P_ARGOCD_NS" "${BS_VALUES[@]}" || true
    fi
    log_info "[$P] template bootstrap argocd-bootstrap"
    if template_chart "$dir/argocd-bootstrap.yaml" argocd-bootstrap argocd-bootstrap \
      argocd-bootstrap "$P_ARGOCD_NS" "${BS_VALUES[@]}"; then
      add_index_row "$P/bootstrap/argocd-bootstrap.yaml" bootstrap argocd-bootstrap \
        argocd-bootstrap "$P_ARGOCD_NS" -
    elif [[ -z "$P_CLUSTER" ]]; then
      record_failure render "$P" argocd-bootstrap "argocd-bootstrap does not render from argocd-bootstrap/values.yaml alone (no clusters/ directory): a required value is missing; see the helm error above"
    else
      record_failure render "$P" argocd-bootstrap "helm template failed"
    fi
    if appset_switch_defined; then
      log_info "[$P] template bootstrap argocd-bootstrap (applicationSet.enabled=true)"
      if template_chart "$dir/argocd-bootstrap-appset.yaml" "argocd-bootstrap (ApplicationSet mode)" \
        argocd-bootstrap argocd-bootstrap "$P_ARGOCD_NS" "${BS_VALUES[@]}" \
        --set applicationSet.enabled=true; then
        add_index_row "$P/bootstrap/argocd-bootstrap-appset.yaml" bootstrap \
          argocd-bootstrap-appset argocd-bootstrap "$P_ARGOCD_NS" -
      else
        record_failure render "$P" "argocd-bootstrap (ApplicationSet mode)" "helm template failed"
      fi
    fi
  fi
  if [[ -f "$REPO/bootstrap/Chart.yaml" ]] && prepare_chart bootstrap; then
    if [[ -f "$REPO/bootstrap/values.yaml" ]]; then bvalues+=(-f "$REPO/bootstrap/values.yaml"); fi
    if [[ -n "$P_CLUSTER" ]]; then bvalues+=(-f "$P_CLUSTER"); fi
    if ((lint)); then
      lint_chart bootstrap bootstrap "$P_ARGOCD_NS" ${bvalues[@]+"${bvalues[@]}"} || true
    fi
    log_info "[$P] template bootstrap bootstrap"
    if template_chart "$dir/bootstrap.yaml" bootstrap bootstrap bootstrap "$P_ARGOCD_NS" \
      ${bvalues[@]+"${bvalues[@]}"}; then
      add_index_row "$P/bootstrap/bootstrap.yaml" bootstrap bootstrap bootstrap "$P_ARGOCD_NS" -
    else
      record_failure render "$P" bootstrap "helm template failed"
    fi
  fi
}

# collect_apps OUTFILE FILE...: the Applications of the given renders, list
# generator ApplicationSets expanded, sorted by name, one JSON per line.
collect_apps() {
  local outfile="$1" f n g tmp="$P_WORK/apps.tmp"
  shift
  : >"$tmp"
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    to_jsonl "$f"
    jqp -c --arg origin "${f##*/}" 'include "apps"; applications($origin)' "$f.jsonl" >>"$tmp"
    while IFS="$US" read -r n g; do
      log_warn "[$P] ApplicationSet $n in ${f##*/}: $g is not emulated; its Applications are not checked"
    done < <(jq -r 'select(.kind == "ApplicationSet") | .metadata.name as $n
      | ((.spec.generators // [])[] | keys[] | select(. != "list") | "\($n)\u001f\(.) generator"),
        (if .spec.templatePatch then "\($n)\u001ftemplatePatch" else empty end)' "$f.jsonl")
  done
  jq -s -c 'sort_by(.metadata.name)[]' "$tmp" >"$outfile"
  while IFS= read -r n; do
    log_warn "[$P] Application $n still holds template expressions after ApplicationSet expansion"
  done < <(jq -r 'select((._origin | contains("ApplicationSet/")) and (del(._origin) | tojson | test("\\{\\{"))) | .metadata.name' "$outfile")
}

# value_file_args SUBJECT CHART_REL REFS IGNORE REMOTE FILE
# Resolves the value files listed in FILE (one per line, after a first line
# that is skipped) as Argo CD does and sets VF_ARGS to the -f arguments of
# those that exist. "$<ref>/x" is repository relative when a source has ref
# <ref>, "/x" is repository relative, anything else is chart relative. With
# REMOTE=1 (remote chart source) only repository files are checked.
value_file_args() {
  local subj="$1" rel="$2" refs="$3" ignore="$4" remote="$5" vf vrel refname
  VF_ARGS=()
  {
    read -r _
    while IFS= read -r vf; do
      [[ -n "$vf" ]] || continue
      case "$vf" in
        http://* | https://*)
          if ((remote == 0)); then
            log_warn "[$P] $subj: value file $vf is passed to helm as a URL"
            VF_ARGS+=(-f "$vf")
          fi
          continue
          ;;
        '$'*/*)
          refname="${vf%%/*}"
          refname="${refname#\$}"
          if [[ "$refs" == *" $refname "* ]]; then
            vrel="$(norm_path "${vf#*/}")"
          elif ((remote)); then
            continue
          else
            vrel="$(norm_path "$rel/$vf")"
          fi
          ;;
        /*) vrel="$(norm_path "$vf")" ;;
        *)
          if ((remote)); then continue; fi
          vrel="$(norm_path "$rel/$vf")"
          ;;
      esac
      if outside_repo "$vrel"; then
        record_failure valuefile "$P" "$subj" "value file $vf resolves outside the repository"
      elif [[ -f "$REPO/$vrel" ]]; then
        VF_ARGS+=(-f "$REPO/$vrel")
      elif [[ "$ignore" == true ]]; then
        log_debug "[$P] $subj: missing value file $vf ignored (ignoreMissingValueFiles)"
      else
        record_failure valuefile "$P" "$subj" "value file $vf ($vrel) does not exist"
      fi
    done
  } <"$6"
}

# plan_app MODE NAME
# Resolves the sources of one Application and records source and value file
# failures. In static mode writes the render plan to
# $P_WORK/plan/<name>/<n>.meta and <n>.args (one pair per in-repo source)
# and adds index rows for remote sources.
plan_app() {
  local mode="$1" name="$2" appfile="$P_WORK/apps/$1/$2.json" subj="$2"
  local srcfile="$P_WORK/source.txt" plandir="$P_WORK/plan/$2" rel p i
  local dest_ns project refs nsrc
  local path chart repo rev ref release ignore skipcrds skiptests skipschema
  local -a args=()
  if [[ "$mode" == appset ]]; then subj="$name (ApplicationSet mode)"; fi
  IFS="$US" read -r dest_ns project nsrc refs < <(
    jqp -r 'include "apps";
      [.spec.destination.namespace // "", project_name, (app_sources | length | tostring),
       ([app_sources[] | .ref // empty] | join(" "))] | join("\u001f")' "$appfile"
  )
  refs=" $refs "
  if ((nsrc == 0)); then
    record_failure source "$P" "$subj" "Application has no source"
    return 0
  fi
  for ((i = 0; i < nsrc; i++)); do
    # First line: the source fields; then one value file per line.
    jqp -r --argjson i "$i" --arg d "$name" 'include "apps"; app_sources[$i]
      | ([.path // "", .chart // "", .repoURL // "", .targetRevision // "", .ref // "",
          .helm.releaseName // $d, (.helm.ignoreMissingValueFiles // false | tostring),
          (.helm.skipCrds // false | tostring), (.helm.skipTests // false | tostring),
          (.helm.skipSchemaValidation // false | tostring)] | join("\u001f")),
        (.helm.valueFiles // [])[]' "$appfile" >"$srcfile"
    IFS="$US" read -r path chart repo rev ref release ignore skipcrds skiptests skipschema <"$srcfile"
    if [[ -n "$chart" ]]; then
      if [[ "$mode" == static ]]; then
        log_warn "[$P] $name: remote chart $chart from $repo ($rev) is not rendered"
        add_index_row - remote "$name" "${repo%/}/$chart:$rev" "$dest_ns" "$project"
      fi
      value_file_args "$subj" "" "$refs" "$ignore" 1 "$srcfile"
      continue
    fi
    if [[ -z "$path" ]]; then
      if [[ -z "$ref" ]]; then
        log_warn "[$P] $subj: source $i has neither path nor chart; not rendered"
      fi
      continue
    fi
    rel="$(norm_path "$path")"
    if outside_repo "$rel"; then
      record_failure source "$P" "$subj" "source path $path lies outside the repository"
      continue
    elif [[ ! -d "$REPO/$rel" ]]; then
      record_failure source "$P" "$subj" "source path $path does not exist"
      continue
    elif [[ ! -f "$REPO/$rel/Chart.yaml" ]]; then
      record_failure source "$P" "$subj" "source path $path has no Chart.yaml (only Helm sources are rendered)"
      continue
    fi
    value_file_args "$subj" "$rel" "$refs" "$ignore" 0 "$srcfile"
    [[ "$mode" == static ]] || continue

    mkdir -p "$plandir"
    args=(${VF_ARGS[@]+"${VF_ARGS[@]}"})
    # valuesObject, else the Argo CD values string, after the value files.
    jqp -r --argjson i "$i" 'include "apps"; app_sources[$i].helm // {}
      | if .valuesObject != null then (.valuesObject | tojson)
        elif (.values // "") != "" then .values else empty end' "$appfile" >"$plandir/$i.values.yaml"
    if [[ -s "$plandir/$i.values.yaml" ]]; then
      args+=(-f "$plandir/$i.values.yaml")
    fi
    # Parameters last, as Argo CD passes them; commas are escaped unless the
    # value is a {a,b} list. fileParameters are relative to the source path.
    while IFS= read -r -d '' p; do
      args+=("$p")
    done < <(jqp --raw-output0 --argjson i "$i" --arg base "$REPO/$rel" 'include "apps";
      app_sources[$i].helm // {}
      | ((.parameters // [])[]
          | (if .forceString then "--set-string" else "--set" end),
            "\(.name)=\((.value // "") | if test("^\\{.*\\}$"; "s") then . else gsub("(?<!\\\\),"; "\\,") end)"),
        ((.fileParameters // [])[] | "--set-file", "\(.name)=\($base)/\(.path)")' "$appfile")

    printf '%s\n' "$rel" "$release" "$dest_ns" "$skipcrds" "$skiptests" "$skipschema" >"$plandir/$i.meta"
    if ((${#args[@]} > 0)); then
      printf '%s\0' "${args[@]}" >"$plandir/$i.args"
    else
      : >"$plandir/$i.args"
    fi
  done
}

# render_app PASS NAME: lints (pass 1) and renders every planned source of an
# Application into $P_WORK/render/apps/<name>.yaml.
render_app() {
  local pass="$1" name="$2" plandir="$P_WORK/plan/$2" out="$P_WORK/render/apps/$2.yaml"
  local meta rel release ns skipcrds skiptests skipschema a ok=1 part="$P_WORK/part.yaml"
  local -a args=() targs=() largs=()
  [[ -d "$plandir" ]] || return 0
  [[ -f "$P_WORK/failed/app-$name" ]] && return 0
  : >"$out.next"
  for meta in "$plandir"/*.meta; do
    [[ -f "$meta" ]] || continue
    {
      read -r rel
      read -r release
      read -r ns
      read -r skipcrds
      read -r skiptests
      read -r skipschema
    } <"$meta"
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done <"${meta%.meta}.args"
    if ! prepare_chart "$rel"; then
      record_failure render "$P" "$name" "chart $rel cannot be prepared (see the dependency failure)"
      ok=0
      continue
    fi
    largs=()
    if [[ "$skipschema" == true ]]; then largs+=(--skip-schema-validation); fi
    if ((pass == 1 && SKIP_LINT == 0)); then
      lint_chart "application $name" "$rel" "$ns" ${args[@]+"${args[@]}"} ${largs[@]+"${largs[@]}"} || true
    fi
    targs=(${largs[@]+"${largs[@]}"})
    if [[ "$skipcrds" != true ]]; then targs+=(--include-crds); fi
    if [[ "$skiptests" == true ]]; then targs+=(--skip-tests); fi
    log_info "[$P] template application $name: $rel -> ${ns:-default}$(pass_note)"
    if template_chart "$part" "application $name" "$rel" "$release" "$ns" \
      ${targs[@]+"${targs[@]}"} ${args[@]+"${args[@]}"}; then
      cat "$part" >>"$out.next"
    else
      record_failure render "$P" "$name" "helm template failed for $rel$(pass_note)"
      ok=0
    fi
  done
  if ((ok)); then
    mv -f "$out.next" "$out"
  else
    touch "$P_WORK/failed/app-$name"
    if [[ -f "$out" ]]; then mv -f "$out" "$out.failed"; fi
  fi
}

# chart_values REL: sets CHART_ARGS to values.yaml and values-<profile>.yaml.
chart_values() {
  local rel="$1"
  CHART_ARGS=()
  if [[ -f "$REPO/$rel/values.yaml" ]]; then CHART_ARGS+=(-f "$REPO/$rel/values.yaml"); fi
  if [[ -f "$REPO/$rel/values-$P.yaml" ]]; then CHART_ARGS+=(-f "$REPO/$rel/values-$P.yaml"); fi
}

# render_chart PASS REL: a chart no Application of the profile references.
render_chart() {
  local pass="$1" rel="$2" key release out
  key="$(path_key "$rel")"
  out="$P_WORK/render/charts/$key.yaml"
  release="$(dns_name "${rel##*/}")"
  [[ -f "$P_WORK/failed/chart-$key" ]] && return 0
  if ! prepare_chart "$rel"; then
    touch "$P_WORK/failed/chart-$key"
    return 0
  fi
  chart_values "$rel"
  if ((pass == 1 && SKIP_LINT == 0)); then
    lint_chart "chart" "$rel" "$release" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} || true
  fi
  log_info "[$P] template chart $rel -> $release$(pass_note)"
  if ! template_chart "$out" "chart $rel" "$rel" "$release" "$release" --include-crds \
    ${CHART_ARGS[@]+"${CHART_ARGS[@]}"}; then
    record_failure render "$P" "$rel" "helm template failed$(pass_note)"
    touch "$P_WORK/failed/chart-$key"
    if [[ -f "$out" ]]; then mv -f "$out" "$out.failed"; fi
  fi
}

# lint_library REL: library charts and file:// dependency charts are linted
# once per run.
lint_library() {
  local rel="$1" marker
  marker="$WORK/deps/lint-$(path_key "$rel")"
  [[ -f "$marker" ]] && return 0
  touch "$marker"
  if prepare_chart "$rel"; then
    lint_chart "library or dependency chart" "$rel" "" || true
  fi
}

render_pass() {
  local pass="$1" name rel
  while IFS= read -r name <&3; do
    render_app "$pass" "$name"
  done 3<"$P_WORK/static.names"
  while IFS= read -r rel <&3; do
    render_chart "$pass" "$rel"
  done 3<"$P_WORK/charts.todo"
}

# rendered_files: the current renders of the profile (bootstrap, apps, charts).
rendered_files() {
  local f
  for f in "$P_WORK"/render/bootstrap/*.yaml "$P_WORK"/render/apps/*.yaml "$P_WORK"/render/charts/*.yaml; do
    if [[ -f "$f" ]]; then printf '%s\n' "$f"; fi
  done
}

refresh_jsonl() {
  local f
  while IFS= read -r f; do
    to_jsonl "$f"
  done < <(rendered_files)
}

# all_jsonl: concatenated JSON of every current render of the profile.
all_jsonl() {
  local f
  while IFS= read -r f; do
    cat "$f.jsonl"
  done < <(rendered_files)
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_unique_names() {
  local mode="$1" file="$2" n c origins
  while IFS="$US" read -r n c origins; do
    record_failure names "$P" "$n" "Application name defined $c times in $mode mode ($origins)"
  done < <(jq -s -r 'group_by(.metadata.name)[] | select(length > 1)
    | "\(.[0].metadata.name)\u001f\(length)\u001f\(map(._origin) | join(", "))"' "$file")
}

run_checks() {
  check_unique_names static "$P_WORK/static.jsonl"
  if [[ -f "$P_WORK/render/bootstrap/argocd-bootstrap-appset.yaml" ]]; then
    check_unique_names "ApplicationSet" "$P_WORK/appset.jsonl"
  fi
}

# ---------------------------------------------------------------------------
# Application inventory of a profile
# ---------------------------------------------------------------------------

# split_apps MODE JSONL: writes one file per Application to
# $P_WORK/apps/<MODE>/<name>.json, "<name><US><namespace><US><project>" lines
# to $P_WORK/<MODE>.meta and the sorted names to $P_WORK/<MODE>.names. In
# ApplicationSet mode only Applications that differ from the static mode are
# kept (the others are checked in static mode).
split_apps() {
  local mode="$1" jsonl="$2" name ns project norm full static
  : >"$P_WORK/$mode.meta"
  while IFS="$US" read -r name ns project norm full <&3; do
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
      record_failure names "$P" "${name:-<empty>}" "invalid Application name in $mode mode"
      continue
    fi
    if [[ "$mode" == appset ]]; then
      static="$P_WORK/apps/static/$name.norm"
      if [[ -f "$static" && "$(<"$static")" == "$norm" ]]; then continue; fi
    fi
    printf '%s\n' "$full" >"$P_WORK/apps/$mode/$name.json"
    printf '%s\n' "$norm" >"$P_WORK/apps/$mode/$name.norm"
    printf '%s\n' "$name$US$ns$US$project" >>"$P_WORK/$mode.meta"
  done 3< <(jqp -r 'include "apps";
    def sortkeys: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end);
    [.metadata.name // "", .spec.destination.namespace // "", project_name,
     (del(._origin) | sortkeys | tojson), tojson] | join("\u001f")' "$jsonl")
  cut -d "$US" -f 1 "$P_WORK/$mode.meta" | LC_ALL=C sort -u >"$P_WORK/$mode.names"
}

# inventory: Applications of both modes and the charts no Application
# references ($P_WORK/charts.todo).
inventory() {
  local bs="$P_WORK/render/bootstrap" rel path referenced
  collect_apps "$P_WORK/static.jsonl" "$bs/argocd-bootstrap.yaml" "$bs/bootstrap.yaml"
  split_apps static "$P_WORK/static.jsonl"
  if [[ -f "$bs/argocd-bootstrap-appset.yaml" ]]; then
    collect_apps "$P_WORK/appset.jsonl" "$bs/argocd-bootstrap-appset.yaml" "$bs/bootstrap.yaml"
    split_apps appset "$P_WORK/appset.jsonl"
    if ! cmp -s <(jq -r '.metadata.name' "$P_WORK/static.jsonl" | LC_ALL=C sort -u) \
      <(jq -r '.metadata.name' "$P_WORK/appset.jsonl" | LC_ALL=C sort -u); then
      log_warn "[$P] static and ApplicationSet mode produce different Application names; switching modes would replace Applications"
    fi
  fi
  # Chart directories the static Applications reference.
  referenced=$'\n'
  while IFS= read -r path; do
    referenced+="$(norm_path "$path")"$'\n'
  done < <(jqp -r 'include "apps"; app_sources[] | select(.chart == null and .path != null) | .path' \
    "$P_WORK/static.jsonl")
  : >"$P_WORK/charts.todo"
  while IFS= read -r rel; do
    if [[ "$referenced" != *$'\n'"$rel"$'\n'* ]]; then
      printf '%s\n' "$rel" >>"$P_WORK/charts.todo"
    fi
  done <"$WORK/charts.list"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

publish_profile() {
  local name rel key chart line ns project file f pdir="$OUT/$P" apps=0 charts=0 remote resources
  local -a listed=()
  mkdir -p "$pdir/bootstrap" "$pdir/apps" "$pdir/charts"
  while IFS="$US" read -r name ns project <&3; do
    file="$P_WORK/render/apps/$name.yaml"
    [[ -f "$file" ]] || continue
    chart=""
    for f in "$P_WORK/plan/$name"/*.meta; do
      read -r line <"$f"
      chart="${chart:+$chart,}$line"
    done
    add_index_row "$P/apps/$name.yaml" application "$name" "$chart" "$ns" "$project"
    apps=$((apps + 1))
  done 3< <(LC_ALL=C sort -u "$P_WORK/static.meta")
  while IFS= read -r rel <&3; do
    key="$(path_key "$rel")"
    [[ -f "$P_WORK/render/charts/$key.yaml" ]] || continue
    ns="$(dns_name "${rel##*/}")"
    add_index_row "$P/charts/$key.yaml" chart "${rel##*/}" "$rel" "$ns" -
    charts=$((charts + 1))
  done 3<"$P_WORK/charts.todo"

  # Copy the files the index lists, then the index itself.
  while IFS=$'\t' read -r file _ <&3; do
    [[ "$file" != - ]] || continue
    cp -f "$P_WORK/render/${file#"$P"/}" "$OUT/$file"
    listed+=("$P_WORK/render/${file#"$P"/}.jsonl")
  done 3<"$P_WORK/index.rows"
  resources=0
  if ((${#listed[@]} > 0)); then
    resources="$(cat "${listed[@]}" | wc -l | tr -d ' ')"
  fi
  {
    printf 'file\ttype\tname\tchart\tnamespace\tproject\n'
    cat "$P_WORK/index.rows"
  } >"$P_WORK/index.tsv"
  cp -f "$P_WORK/index.tsv" "$pdir/index.tsv"
  printf 'PROFILE=%s\nKUBERNETES_VERSION=%s\n' "$P" "$P_KV" >"$pdir/profile.env"
  remote="$(awk -F'\t' '$2 == "remote"' "$P_WORK/index.rows" | wc -l | tr -d ' ')"
  log_info "[$P] wrote $pdir: $apps Application(s), $remote remote source(s), $charts chart(s), $resources resource(s), Kubernetes $P_KV, $P_API_COUNT API version(s) from CRDs"
}

render_profile() {
  local api="$WORK/api.txt" a rel name
  setup_profile "$1"
  log_info "[$P] profile $P: Kubernetes $P_KV, Argo CD namespace $P_ARGOCD_NS${P_CLUSTER:+, ${P_CLUSTER#"$REPO"/}}"
  render_bootstrap "$((1 - SKIP_LINT))"
  inventory

  while IFS= read -r name <&3; do
    plan_app static "$name"
  done 3<"$P_WORK/static.names"
  if [[ -f "$P_WORK/appset.names" ]]; then
    while IFS= read -r name <&3; do
      plan_app appset "$name"
    done 3<"$P_WORK/appset.names"
  fi
  if ((SKIP_LINT == 0)); then
    while IFS= read -r rel <&3; do
      lint_library "$rel"
    done 3<"$WORK/libraries.list"
  fi

  render_pass 1
  refresh_jsonl
  all_jsonl | jq -r 'select(.kind == "CustomResourceDefinition") | .spec.group as $g
    | .spec.names.kind as $k | (.spec.versions // [])[] | select(.served != false)
    | "\($g)/\(.name)", "\($g)/\(.name)/\($k)"' | LC_ALL=C sort -u >"$api"
  if [[ -s "$api" ]]; then
    while IFS= read -r a; do
      P_API_ARGS+=(--api-versions "$a")
      P_API_COUNT=$((P_API_COUNT + 1))
    done <"$api"
    render_pass 2
    refresh_jsonl
  fi
  run_checks
  publish_profile
}

lint_profile() {
  local rel key bvalues=()
  setup_profile "$1"
  log_info "[$P] lint profile $P: Kubernetes $P_KV"
  if prepare_chart argocd-bootstrap; then
    lint_chart argocd-bootstrap argocd-bootstrap "$P_ARGOCD_NS" "${BS_VALUES[@]}" || true
  fi
  if [[ -f "$REPO/bootstrap/Chart.yaml" ]] && prepare_chart bootstrap; then
    if [[ -f "$REPO/bootstrap/values.yaml" ]]; then bvalues+=(-f "$REPO/bootstrap/values.yaml"); fi
    if [[ -n "$P_CLUSTER" ]]; then bvalues+=(-f "$P_CLUSTER"); fi
    lint_chart bootstrap bootstrap "$P_ARGOCD_NS" ${bvalues[@]+"${bvalues[@]}"} || true
  fi
  while IFS= read -r rel <&3; do
    lint_library "$rel"
  done 3<"$WORK/libraries.list"
  while IFS= read -r rel <&3; do
    key="$WORK/deps/lint-$(path_key "$rel")"
    # Charts without a profile values file give the same result everywhere.
    if [[ ! -f "$REPO/$rel/values-$P.yaml" ]]; then
      [[ -f "$key" ]] && continue
      touch "$key"
    fi
    prepare_chart "$rel" || continue
    chart_values "$rel"
    lint_chart chart "$rel" "$(dns_name "${rel##*/}")" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} || true
  done 3<"$WORK/charts.list"
}

list_profile() {
  local rel bs
  setup_profile "$1"
  bs="$P_WORK/render/bootstrap"
  render_bootstrap 0 2>/dev/null || true
  inventory
  printf 'profile %s  kubernetes %s  argocd namespace %s  values argocd-bootstrap/values.yaml%s\n' \
    "$P" "$P_KV" "$P_ARGOCD_NS" "${P_CLUSTER:+ ${P_CLUSTER#"$REPO"/}}"
  if [[ ! -f "$bs/argocd-bootstrap.yaml" ]]; then
    printf '  argocd-bootstrap does not render for this profile; run without --list for the error\n'
  fi
  jqp -r 'include "apps"; . as $a | app_sources[] | select(.ref == null or .path != null or .chart != null)
    | "  " + (if .chart then "remote     " else "application" end)
      + "  " + $a.metadata.name + "  " + (if .chart then "\(.repoURL)/\(.chart):\(.targetRevision)" else (.path // "") end)
      + "  namespace=" + ($a.spec.destination.namespace // "") + "  project=" + ($a | project_name)' \
    "$P_WORK/static.jsonl"
  if [[ -f "$P_WORK/appset.names" ]]; then
    printf '  ApplicationSet mode: %s Application(s) differ from the static mode\n' \
      "$(wc -l <"$P_WORK/appset.names" | tr -d ' ')"
  fi
  while IFS= read -r rel; do
    printf '  chart        %s  (no Application references it)\n' "$rel"
  done <"$P_WORK/charts.todo"
  while IFS= read -r rel; do
    printf '  lint only    %s  (library or file:// dependency)\n' "$rel"
  done <"$WORK/libraries.list"
}

report() {
  local count
  count="$(wc -l <"$FAILURES" | tr -d ' ')"
  if ((count == 0)); then
    log_info "all checks passed (${SECONDS}s)"
    return 0
  fi
  log_error "$count check(s) failed (${SECONDS}s):"
  LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 "$FAILURES" | awk -F'\t' '
    { if ($1 != cat) { cat = $1; printf "  %s\n", cat } printf "    [%s] %s: %s\n", $2, $3, $4 }' >&2
  awk -F'\t' '{ n[$1]++ } END { for (c in n) printf "%s=%d\n", c, n[c] }' "$FAILURES" |
    LC_ALL=C sort | paste -s -d ' ' - | while IFS= read -r count; do log_error "by category: $count"; done
  return 1
}

main() {
  local p
  parse_args "$@"
  require_cmd helm yq jq awk
  if ! yq --version 2>/dev/null | grep -q mikefarah; then
    die "yq must be the Go implementation (mikefarah/yq v4); see mise.toml"
  fi
  [[ -d "$REPO" ]] || die "repository not found: $REPO" 2
  REPO="$(cd "$REPO" && pwd -P)"
  [[ -f "$REPO/argocd-bootstrap/Chart.yaml" ]] || die "$REPO has no argocd-bootstrap/Chart.yaml" 2
  discover_profiles

  make_temp_dir WORK render
  STAGE="$WORK/stage"
  # Private Helm repository configuration: chart dependencies resolve the same
  # way on every machine, and the user's Helm setup is neither used nor changed.
  export HELM_REPOSITORY_CONFIG="$WORK/helm/repositories.yaml"
  export HELM_REPOSITORY_CACHE="$WORK/helm/cache"
  HELM_REPOS_ADDED=$'\n'
  HELM_REPO_COUNT=0
  FAILURES="$WORK/failures.tsv"
  mkdir -p "$STAGE" "$WORK/deps" "$WORK/log" "$WORK/profiles" "$WORK/helm/cache"
  : >"$FAILURES"
  write_jq_library
  discover_charts

  case "$MODE" in
    list)
      for p in "${PROFILES[@]}"; do list_profile "$p"; done
      return 0
      ;;
    lint)
      for p in "${PROFILES[@]}"; do lint_profile "$p"; done
      ;;
    render)
      mkdir -p "$OUT"
      OUT="$(cd "$OUT" && pwd -P)"
      log_info "rendering ${#PROFILES[@]} profile(s) of $REPO into $OUT"
      for p in "${PROFILES[@]}"; do render_profile "$p"; done
      ;;
  esac
  if ! report; then
    exit 1
  fi
}

main "$@"
