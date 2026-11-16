#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Validates the manifests that hack/render.sh rendered, with kubeconform in
# strict mode, against the Kubernetes version of each profile.
#
# Usage:
#   hack/kubeconform.sh [--profile NAME]... [--out DIR]
#
# Options:
#   --profile NAME  Profile to validate; repeat for several. Default: every
#                   profile with an <out>/<profile>/index.tsv.
#   --out DIR       Render output directory. Default: $OUT_DIR, else
#                   <repo>/_out.
#   -h, --help      Show this help.
#
# Environment:
#   KUBERNETES_VERSION  Overrides the version in <out>/<profile>/profile.env.
#   KUBECONFORM_SKIP    Comma separated kinds (or group/version/kind) passed
#                       to kubeconform -skip.
#   XDG_CACHE_HOME      Schema cache in $XDG_CACHE_HOME/kubeconform
#                       (default ~/.cache/kubeconform).
#
# Inputs: <out>/<profile>/index.tsv and profile.env written by
# hack/render.sh. Only the files listed in index.tsv are validated; rows
# without a file (remote sources) are skipped.
#
# Schema locations, in this order:
#   1. yannh/kubernetes-json-schema at a pinned commit (standalone, strict);
#   2. the CRD catalog of this run, built from every CustomResourceDefinition
#      in the selected profiles' output;
#   3. datreeio/CRDs-catalog at a pinned commit.
# A resource without a schema in any location fails: there is no
# -ignore-missing-schemas.
#
# CRD catalog: for every version of every rendered CRD, the
# openAPIV3Schema converted with jq to the JSON Schema that kubeconform
# expects: x-kubernetes-int-or-string becomes oneOf string or integer (the
# conflicting type is dropped), nullable: true also allows null, every object
# schema with properties and neither additionalProperties nor
# x-kubernetes-preserve-unknown-fields gets additionalProperties: false
# (metadata of the root and of embedded resources excepted, as the API server
# accepts any ObjectMeta field there), and the root always declares
# apiVersion, kind (strings) and metadata (object).
#
# CustomResourceDefinition itself has no schema in either pinned location
# (its JSONSchemaProps type is recursive and cannot be inlined). When the
# output holds CRDs, its schema is derived from the Kubernetes OpenAPI v3
# document (kubernetes/kubernetes, tag v<newest profile version>,
# api/openapi-spec/v3/apis__apiextensions.k8s.io__v1_openapi.json, cached):
# components become local definitions, the recursion stays a $ref, typed
# fields also allow null (as in the yannh schemas) and objects with
# properties get additionalProperties: false. It is written to the catalog
# as apiextensions.k8s.io/customresourcedefinition_v1.json.
#
# Outputs: <out>/schemas/<group>/<kind>_<version>.json, the catalog of this
# run, overwritten on every run and never removed. kubeconform reads the
# catalog of this run from a temporary directory, so a schema file left in
# <out>/schemas by an older run never validates a resource.
#
# Requirements: kubeconform 0.6+, yq v4 (mikefarah), jq 1.7+, curl, and
# network access for the remote schemas (cached after the first run).
#
# Exit status: 0 when every resource is valid, 1 when a resource is invalid
# or has no schema, 2 for usage errors.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

# renovate: datasource=git-refs depName=https://github.com/yannh/kubernetes-json-schema currentValue=master
readonly K8S_SCHEMA_SHA=6ea44f54bb5cdedb2f61fba42c9b342e97959262
# renovate: datasource=git-refs depName=https://github.com/datreeio/CRDs-catalog currentValue=main
readonly CRD_CATALOG_SHA=3e8a8916ca1b7af6464606c2c2f5869dbafa9653

# kubeconform expands the {{ }} placeholders; they are not shell syntax.
readonly K8S_SCHEMA_LOCATION="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${K8S_SCHEMA_SHA}/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
readonly CRD_CATALOG_LOCATION="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_SHA}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

PROFILES=()
OUT="${OUT_DIR:-$REPO_ROOT/_out}"

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
      --out)
        (($# >= 2)) || usage_error "--out needs a value"
        OUT="$2"
        shift 2
        ;;
      --out=*)
        OUT="${1#*=}"
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

discover_profiles() {
  local f d p
  if ((${#PROFILES[@]} == 0)); then
    for f in "$OUT"/*/index.tsv; do
      [[ -f "$f" ]] || continue
      d="${f%/index.tsv}"
      PROFILES+=("${d##*/}")
    done
    ((${#PROFILES[@]} > 0)) || die "no rendered profile in $OUT: run make render first"
  fi
  for p in "${PROFILES[@]}"; do
    [[ -f "$OUT/$p/index.tsv" ]] || die "$OUT/$p/index.tsv not found: run make render first"
  done
}

# profile_files PROFILE: the files listed in the profile's index, relative to
# OUT, one per line.
profile_files() {
  awk -F'\t' 'NR > 1 && $1 != "-" && $1 != "" && $2 != "remote" { print $1 }' "$OUT/$1/index.tsv"
}

# profile_version PROFILE: KUBERNETES_VERSION, else the profile.env value.
profile_version() {
  local v=""
  if [[ -f "$OUT/$1/profile.env" ]]; then
    v="$(sed -n 's/^KUBERNETES_VERSION=//p' "$OUT/$1/profile.env" | tail -n 1)"
  fi
  v="${KUBERNETES_VERSION:-$v}"
  [[ -n "$v" ]] || die "no Kubernetes version for profile $1: profile.env lacks KUBERNETES_VERSION; run make render"
  printf '%s\n' "${v#v}"
}

readonly K8S_OPENAPI_URL="https://raw.githubusercontent.com/kubernetes/kubernetes/v%s/api/openapi-spec/v3/apis__apiextensions.k8s.io__v1_openapi.json"

# crd_schema DIR VERSION: derives the CustomResourceDefinition schema from
# the Kubernetes OpenAPI v3 document of VERSION into DIR.
crd_schema() {
  local dir="$1" version="$2" cached url
  cached="$CACHE/kubernetes-openapi/v$version/apis__apiextensions.k8s.io__v1_openapi.json"
  # shellcheck disable=SC2059  # the URL template holds one %s
  url="$(printf "$K8S_OPENAPI_URL" "$version")"
  if [[ ! -s "$cached" ]]; then
    mkdir -p "${cached%/*}"
    if ! curl -fsSL --retry 2 -o "$cached.tmp" "$url"; then
      log_warn "cannot fetch $url; CustomResourceDefinition objects will have no schema"
      return 0
    fi
    mv -f "$cached.tmp" "$cached"
  fi
  mkdir -p "$dir/apiextensions.k8s.io"
  jq -c '
    def strict:
      walk(if type == "object" and (.properties | type) == "object" and (has("additionalProperties") | not)
           then .additionalProperties = false else . end);
    def nulls:
      walk(if type == "object" and (.type | type) == "string" and .type != "null"
           then .type = [.type, "null"] else . end);
    def intorstring:
      walk(if type == "object" and (.["x-kubernetes-int-or-string"] == true or .format == "int-or-string")
           then del(.type, .format) | .oneOf = [{type: "string"}, {type: "integer"}] else . end);
    (.components.schemas | intorstring | nulls | strict) as $defs
    | {"$schema": "http://json-schema.org/draft-07/schema#",
       allOf: [{"$ref": "#/definitions/io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1.CustomResourceDefinition"}],
       definitions: $defs}
    | walk(if type == "object" and (.["$ref"] | type) == "string"
           then .["$ref"] |= sub("^#/components/schemas/"; "#/definitions/") else . end)' \
    "$cached" >"$dir/apiextensions.k8s.io/customresourcedefinition_v1.json"
  log_info "CustomResourceDefinition schema derived from the Kubernetes v$version OpenAPI document"
}

# build_catalog DIR: writes the CRD schemas of the selected profiles to DIR.
build_catalog() {
  local dir="$1" p f path schema count=0 skipped=0
  local -a files=()
  for p in "${PROFILES[@]}"; do
    while IFS= read -r f; do
      if [[ -f "$OUT/$f" ]]; then files+=("$OUT/$f"); fi
    done < <(profile_files "$p")
  done
  ((${#files[@]} > 0)) || return 0
  while IFS=$'\t' read -r path schema; do
    if [[ "$path" == skip ]]; then
      log_warn "CRD $schema has a version without openAPIV3Schema; its resources need another schema source"
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$dir/${path%/*}"
    printf '%s\n' "$schema" >"$dir/$path"
    count=$((count + 1))
  done < <(yq -o=json -I=0 'select(.kind == "CustomResourceDefinition")' "${files[@]}" | jq -r '
    def intorstring:
      walk(if type == "object" and .["x-kubernetes-int-or-string"] == true then
             del(.type)
             | if has("oneOf") then .allOf = ((.allOf // []) + [{oneOf: [{type: "string"}, {type: "integer"}]}])
               else .oneOf = [{type: "string"}, {type: "integer"}] end
           else . end);
    def nullable:
      walk(if type == "object" and .nullable == true and (.type | type) == "string" then
             .type = [.type, "null"]
           else . end);
    def strict($root):
      if type != "object" then . else
        (.["x-kubernetes-embedded-resource"] == true) as $embedded
        | (if $embedded and (.properties | type) == "object" then
             .properties = ({apiVersion: {type: "string"}, kind: {type: "string"}, metadata: {type: "object"}} + .properties)
           else . end)
        | (if has("properties") and (has("additionalProperties") | not)
              and (.["x-kubernetes-preserve-unknown-fields"] != true) then
             .additionalProperties = false
           else . end)
        | (if (.properties | type) == "object" then
             .properties |= with_entries(
               if .key == "metadata" and ($root or $embedded) then . else .value |= strict(false) end)
           else . end)
        | (if (.items | type) == "object" then .items |= strict(false)
           elif (.items | type) == "array" then .items |= map(strict(false))
           else . end)
        | (if (.additionalProperties | type) == "object" then .additionalProperties |= strict(false) else . end)
      end;
    select(type == "object")
    | .spec.group as $g
    | (.spec.names.kind | ascii_downcase) as $k
    | (.spec.versions // [{name: .spec.version}])[] as $v
    | ($v.schema.openAPIV3Schema // .spec.validation.openAPIV3Schema) as $s
    | if $s == null then "skip\t\($k).\($g)/\($v.name)"
      else
        ($s
          | .type = (.type // "object")
          | .properties = ({apiVersion: {type: "string"}, kind: {type: "string"}, metadata: {type: "object"}}
                           + (.properties // {}))
          | intorstring | nullable | strict(true)) as $schema
        | "\($g)/\($k)_\($v.name).json\t\($schema | tojson)"
      end')
  log_info "CRD catalog: $count schema(s) from ${#files[@]} rendered file(s), $skipped CRD version(s) without schema"
  if ((count + skipped > 0)); then
    crd_schema "$dir" "$NEWEST_VERSION"
  fi
}

# validate PROFILE CATALOG: runs kubeconform on the profile's files and prints
# its result. Returns non-zero on any invalid resource or missing schema.
validate() {
  local p="$1" catalog="$2" kv log line rc=0
  local summary="" invalid missing other
  local -a files=() cmd=()
  kv="$(profile_version "$p")"
  while IFS= read -r line; do
    if [[ ! -f "$OUT/$line" ]]; then
      log_error "[$p] $line is listed in index.tsv but missing: run make render"
      return 1
    fi
    files+=("$line")
  done < <(profile_files "$p")
  if ((${#files[@]} == 0)); then
    log_warn "[$p] index.tsv lists no files"
    return 0
  fi
  cmd=(kubeconform -strict -summary -output text -kubernetes-version "$kv" -cache "$CACHE"
    -schema-location "$K8S_SCHEMA_LOCATION"
    -schema-location "$catalog/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    -schema-location "$CRD_CATALOG_LOCATION")
  if [[ -n "${KUBECONFORM_SKIP:-}" ]]; then
    cmd+=(-skip "$KUBECONFORM_SKIP")
  fi
  log="$WORK/kubeconform-$p.log"
  log_info "[$p] kubeconform: ${#files[@]} file(s), Kubernetes $kv${KUBECONFORM_SKIP:+, skipping $KUBECONFORM_SKIP}"
  (cd "$OUT" && "${cmd[@]}" "${files[@]}") >"$log" 2>&1 || rc=$?
  while IFS= read -r line; do
    case "$line" in
      Summary:*) summary="$line" ;;
      *) printf '  %s\n' "$line" >&2 ;;
    esac
  done <"$log"
  invalid="$(grep -c ' is invalid: ' "$log" || true)"
  missing="$(grep -c 'could not find schema' "$log" || true)"
  other="$(grep ' failed validation: ' "$log" | grep -vc 'could not find schema' || true)"
  if [[ -z "$summary" ]]; then
    log_error "[$p] kubeconform exited with $rc without a summary"
    return 1
  fi
  if ((rc != 0)); then
    log_error "[$p] ${summary#Summary: } (invalid $invalid, no schema $missing, other errors $other)"
    return 1
  fi
  log_info "[$p] ${summary#Summary: }"
}

main() {
  local p v catalog failed=0
  parse_args "$@"
  require_cmd kubeconform yq jq awk curl
  if ! yq --version 2>/dev/null | grep -q mikefarah; then
    die "yq must be the Go implementation (mikefarah/yq v4); see mise.toml"
  fi
  [[ -d "$OUT" ]] || die "$OUT not found: run make render first"
  OUT="$(cd "$OUT" && pwd -P)"
  discover_profiles

  CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
  mkdir -p "$CACHE"
  NEWEST_VERSION=0.0.0
  for p in "${PROFILES[@]}"; do
    v="$(profile_version "$p")"
    if version_ge "$v" "$NEWEST_VERSION"; then NEWEST_VERSION="$v"; fi
  done

  make_temp_dir WORK kubeconform
  catalog="$WORK/schemas"
  mkdir -p "$catalog"
  build_catalog "$catalog"
  mkdir -p "$OUT/schemas"
  cp -R "$catalog/." "$OUT/schemas/"

  for p in "${PROFILES[@]}"; do
    validate "$p" "$catalog" || failed=$((failed + 1))
  done
  if ((failed > 0)); then
    log_error "kubeconform: $failed of ${#PROFILES[@]} profile(s) failed (${SECONDS}s)"
    exit 1
  fi
  log_info "kubeconform: ${#PROFILES[@]} profile(s) valid (${SECONDS}s)"
}

main "$@"
