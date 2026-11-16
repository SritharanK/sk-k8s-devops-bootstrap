#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Validate cluster definitions (clusters/<name>/cluster.yaml) and tenant
# definitions (tenants/*.yaml) against their JSON Schemas, then run the
# checks a schema cannot express.
#
# Usage:
#   hack/validate-config.sh [--strict] [FILE...]
#
# Without FILE arguments every clusters/*/cluster.yaml and tenants/*.yaml is
# checked. Placeholders (CHANGE_ME, YOUR_*, your-org, <TOKEN>) are reported
# as warnings; with --strict (or STRICT=1) they are errors, and so is an
# example.com domain in the reference profile. Use --strict before a real
# install.
#
# Requirements: uvx (or check-jsonschema at the pinned version on PATH), yq v4.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

# Renovate: datasource=pypi depName=check-jsonschema
CHECK_JSONSCHEMA_VERSION="0.39.0"

usage() {
  sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

STRICT="${STRICT:-0}"
files=()
while (($# > 0)); do
  case "$1" in
    --strict) STRICT=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" 2 ;;
    *) files+=("$1") ;;
  esac
  shift
done

require_cmd yq

check_jsonschema() {
  if command -v check-jsonschema >/dev/null 2>&1 &&
    [[ "$(check-jsonschema --version 2>/dev/null)" == *"${CHECK_JSONSCHEMA_VERSION}"* ]]; then
    check-jsonschema "$@"
  else
    require_cmd uvx
    uvx --quiet --from "check-jsonschema==${CHECK_JSONSCHEMA_VERSION}" check-jsonschema "$@"
  fi
}

cd "$REPO_ROOT" || exit 1

if ((${#files[@]} == 0)); then
  shopt -s nullglob
  files=(clusters/*/cluster.yaml tenants/*.yaml)
  shopt -u nullglob
fi
((${#files[@]} > 0)) || die "no configuration files found"

cluster_files=()
tenant_files=()
for f in "${files[@]}"; do
  [[ -f "$f" ]] || die "file not found: $f"
  case "$f" in
    # The schema and anything below tenants/<dir>/ (the tenant chart) are not
    # tenant definitions.
    tenants/schema.json | tenants/*/*) ;;
    tenants/*.yaml) tenant_files+=("$f") ;;
    *) cluster_files+=("$f") ;;
  esac
done

errors=0
fail() {
  log_error "$1"
  errors=$((errors + 1))
}

# Toolchain names that a template under argocd-bootstrap/templates reads,
# either literally (dig "<name>" "enabled" ...) or through a variable
# ($name := "<name>" and dig $name "enabled" ... in the same file).
# shellcheck disable=SC2016  # $name is Helm template text, not shell
known_toolchains="$(
  {
    grep -rhoE --include="*.yaml" 'dig "[a-z0-9-]+" "enabled"' argocd-bootstrap/templates 2>/dev/null |
      awk -F'"' '{print $2}'
    grep -rlE --include="*.yaml" 'dig \$name "enabled"' argocd-bootstrap/templates 2>/dev/null |
      while IFS= read -r tpl; do
        grep -hoE '\$name := "[a-z0-9-]+"' "$tpl" | awk -F'"' '{print $2}'
      done
  } | sort -u || true
)"

# placeholder_paths FILE: prints "path<TAB>value" for every placeholder string.
placeholder_paths() {
  yq -r '
    .. | select(tag == "!!str") |
    select(test("CHANGE_ME|YOUR_[A-Z]|your-org|<[A-Z_]+>")) |
    (path | join(".")) + "\t" + .
  ' "$1"
}

report_placeholders() {
  local file="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$STRICT" == "1" ]]; then
      fail "${file}: placeholder at ${line%%$'\t'*}"
    else
      log_warn "${file}: placeholder at ${line%%$'\t'*} (allowed without --strict)"
    fi
  done < <(placeholder_paths "$file")
}

if ((${#cluster_files[@]} > 0)); then
  log_info "schema: clusters/schema.json (${#cluster_files[@]} file(s))"
  check_jsonschema --schemafile clusters/schema.json "${cluster_files[@]}" || errors=$((errors + 1))

  for f in "${cluster_files[@]}"; do
    name="$(yq -r '.cluster.name // ""' "$f")"
    profile="$(yq -r '.cluster.profile // ""' "$f")"
    dir="$(basename "$(dirname "$f")")"

    # The directory name is the cluster's identity for Ansible and Argo CD.
    if [[ "$f" == clusters/*/cluster.yaml && "$name" != "$dir" ]]; then
      fail "${f}: cluster.name '${name}' does not match directory '${dir}'"
    fi

    # Application namespaces must be distinct from each other and from argocd.
    dupes="$(yq -r '[.namespaces.argocd, .namespaces.dev, .namespaces.stage, .namespaces.prod] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$f")"
    [[ -z "$dupes" ]] || fail "${f}: namespaces argocd, dev, stage and prod must be distinct (duplicate: ${dupes//$'\n'/, })"

    # Every toolchain switch must match a toolchain template.
    while IFS= read -r tc; do
      [[ -n "$tc" ]] || continue
      if ! grep -qx -- "$tc" <<<"$known_toolchains"; then
        fail "${f}: toolchains.${tc} matches no argocd-bootstrap/templates/toolchains template"
      fi
    done < <(yq -r '(.toolchains // {}) | keys | .[]' "$f")

    # ACME HTTP-01 issues one certificate for an explicit name list, so every
    # route the platform serves must be on it: the Argo CD UI, the UIs of
    # enabled toolchains (Grafana, Kargo) and
    # <app>.<env>.<domain> for every app environment this cluster hosts.
    issuer="$(yq -r '.platform.issuer // ""' "$f")"
    solver="$(yq -r '.platform.acme.solver // "http01"' "$f")"
    if [[ "$issuer" == letsencrypt* && "$solver" == "http01" ]]; then
      domain="$(yq -r '.cluster.domain' "$f")"
      hostnames="$(yq -r '(.platform.gateway.hostnames // []) | .[]' "$f")"
      while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        [[ "$h" == "$domain" || "$h" == *".${domain}" ]] ||
          fail "${f}: platform.gateway.hostnames entry ${h} is outside cluster.domain ${domain}"
      done <<<"$hostnames"
      expected="argocd.${domain}"
      # Toolchains that serve a UI through the Gateway.
      [[ "$(yq -r '.toolchains.monitoring.enabled // false' "$f")" == "true" ]] &&
        expected+=$'\n'"grafana.${domain}"
      [[ "$(yq -r '.toolchains.kargo.enabled // false' "$f")" == "true" ]] &&
        expected+=$'\n'"kargo.${domain}"
      hosted="$(yq -o=json -I=0 '.cluster.environments // ["dev", "stage", "prod"]' "$f")"
      # shellcheck disable=SC2016  # $a and $e are yq variables, not shell
      while IFS= read -r route; do
        [[ -n "$route" ]] && expected+=$'\n'"${route}.${domain}"
      done < <(HOSTED="$hosted" yq -r '.apps[] as $a | $a.environments[] | select(. as $e | env(HOSTED) | contains([$e])) | $a.name + "." + .' argocd-bootstrap/values.yaml)
      while IFS= read -r name; do
        grep -qxF -- "$name" <<<"$hostnames" ||
          fail "${f}: platform.gateway.hostnames lacks ${name} (ACME http01 issues no wildcard)"
      done <<<"$expected"
    fi

    report_placeholders "$f"

    if [[ "$STRICT" == "1" && "$profile" == "reference" ]]; then
      domain="$(yq -r '.cluster.domain' "$f")"
      case "$domain" in
        example.com | *.example.com | example.org | *.example.org)
          fail "${f}: cluster.domain '${domain}' is a documentation domain; set the real domain"
          ;;
      esac
    fi
  done
fi

if ((${#tenant_files[@]} > 0)); then
  [[ -f tenants/schema.json ]] || die "tenants/schema.json not found"
  log_info "schema: tenants/schema.json (${#tenant_files[@]} file(s))"
  check_jsonschema --schemafile tenants/schema.json "${tenant_files[@]}" || errors=$((errors + 1))

  seen=""
  for f in "${tenant_files[@]}"; do
    tname="$(yq -r '.name // ""' "$f")"
    base="$(basename "$f" .yaml)"
    [[ "$tname" == "$base" ]] || fail "${f}: name '${tname}' does not match file name '${base}'"
    if grep -qx -- "$tname" <<<"$seen"; then
      fail "${f}: duplicate tenant name '${tname}'"
    fi
    seen+="${tname}"$'\n'
    report_placeholders "$f"
  done
fi

if ((errors > 0)); then
  die "configuration validation failed with ${errors} error(s)"
fi
log_info "configuration valid"
