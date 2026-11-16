#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Generates docs/reference/support-matrix.md: Kubernetes and distribution
# versions per cluster, platform components, container images and the pinned
# toolchain, with end-of-life data from the endoflife.date API.
#
# Usage:
#   hack/support-matrix.sh [--check] [--out DIR] [--repo DIR] [--doc FILE]
#
# Options:
#   --check      Generate into a temporary file and compare it with the
#                committed document, ignoring only the "Generated on:" line.
#                Prints a unified diff and exits 1 when they differ.
#   --out DIR    Render output of hack/render.sh.
#                Default: ${OUT_DIR:-<repository root>/_out}.
#   --repo DIR   Repository to read. Default: the repository of this script.
#   --doc FILE   Document to write or check.
#                Default: <repo>/docs/reference/support-matrix.md.
#   -h, --help   Show this help.
#
# Inputs:
#   <out>/<profile>/index.tsv, profile.env and the files index.tsv lists, for
#     every directory of <out> that has an index.tsv; other files are ignored.
#     In index.tsv "-" marks an empty field and the chart column may list
#     several chart paths separated by commas.
#   <repo>/helmcharts/**/Chart.yaml: name, version, appVersion, dependencies
#     (vendored charts/ directories and test fixtures under tests/ are
#     skipped).
#   <repo>/clusters/*/cluster.yaml: cluster.profile, cluster.kubernetesMinor,
#     rke2.version, rke2.channel, toolchains.
#   <repo>/argocd-bootstrap/values.yaml: toolchains defaults.
#   <repo>/mise.toml: min_version and [tools].
#   <repo>/kind/node-images.yaml: kindVersion and images, when present.
#   ${ENDOFLIFE_API:-https://endoflife.date/api/v1}/products/<product> for
#     each product in the mapping table below.
#   ${SUPPORTED_KUBERNETES_MINORS:-1.35 1.36}: the supported Kubernetes
#     minors (platform baseline), space separated.
#   ${SUPPORT_MATRIX_DATE}: evaluation date (YYYY-MM-DD, UTC) of the status
#     columns. Default: today, or with --check the "Generated on:" date of
#     the committed document, so that --check only fails on a change in the
#     repository or in the endoflife.date data.
#
# How the tables are derived:
#   Kubernetes           The supported minors with their endoflife.date
#                        cycle data, then per cluster definition (and per
#                        rendered profile without one) the kubernetesMinor,
#                        the RKE2 version and channel, and the Kubernetes
#                        version the render used (profile.env).
#   Components           One row per dependency of every chart under
#                        helmcharts/ (one row for a chart without
#                        dependencies), plus one row per remote chart source
#                        (index rows of type remote, not rendered).
#   Enabled in profiles  Profiles with an application or remote index row for
#                        the chart. A toolchain switched on in
#                        argocd-bootstrap/values.yaml merged with the cluster
#                        file, whose chart under helmcharts/system-charts
#                        rendered nothing, is reported as a warning.
#   App version          appVersion of the wrapper chart; when it has none,
#                        the tag of the rendered image whose last path segment
#                        is the upstream chart name, marked "(image tag)".
#   Images               Every string `image` field of every document of the
#                        bootstrap and application rows, including init and
#                        ephemeral containers and custom resources. Rows of
#                        type chart (charts that no Application of the
#                        profile deploys) are not read. Skipped: kyverno.io and
#                        policies.kyverno.io documents, admission policies,
#                        CustomResourceDefinitions and Argo CD Applications
#                        and ApplicationSets, whose image fields are patterns,
#                        schemas or chart values. The registry defaults to
#                        docker.io, and Docker Hub images without a namespace
#                        get library/. A string that is not an image
#                        reference is listed unchanged with a warning.
#   Status               Evaluated on the generation date (UTC) for the
#                        release cycle of the version (major.minor, else
#                        major): "supported", "supported, EOL within 90 days",
#                        "<phase> only" once the product's active support has
#                        ended (for example "security support only"), "end
#                        of life", "cycle not listed" when endoflife.date has
#                        no such cycle, "no version" when the version is
#                        unknown, or "not tracked" for a component without an
#                        endoflife.date product.
#
# Outputs:
#   The document (default), or a unified diff on stdout (--check).
#   Consistency warnings on stderr: RKE2 and kubernetesMinor disagree, a
#   cluster runs a minor outside the baseline, a baseline minor is end of
#   life, an enabled toolchain rendered nothing, an invalid image reference.
#   Exit status 0 on success, 1 when the document is out of date or a step
#   fails, 2 on a usage error.
#
# Requirements: yq v4 (mikefarah), jq, curl, HTTPS access to endoflife.date.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

ENDOFLIFE_API="${ENDOFLIFE_API:-https://endoflife.date/api/v1}"
# Platform baseline: the Kubernetes minors the platform supports. A cluster
# definition on another minor, or a baseline minor that endoflife.date lists
# as end of life, gives a warning.
SUPPORTED_KUBERNETES_MINORS="${SUPPORTED_KUBERNETES_MINORS:-1.35 1.36}"
INDEX_HEADER=$'file\ttype\tname\tchart\tnamespace\tproject'

usage() {
  sed -n '/^# Usage:/,/^# Requirements:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

REPO="$REPO_ROOT"
OUT="${OUT_DIR:-$REPO_ROOT/_out}"
DOC=""
CHECK=0

while (($# > 0)); do
  case "$1" in
    --check)
      CHECK=1
      shift
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
    --doc)
      [[ $# -ge 2 && -n "$2" ]] || die "--doc needs a value" 2
      DOC="$2"
      shift 2
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

[[ -d "$REPO" ]] || die "repository not found: $REPO" 2
REPO="$(cd "$REPO" && pwd -P)"
DOC="${DOC:-$REPO/docs/reference/support-matrix.md}"
[[ -d "$OUT" ]] || die "render output not found: ${OUT} (run hack/render.sh first)"
OUT="$(cd "$OUT" && pwd -P)"

require_cmd yq jq curl
[[ "$(yq --version 2>/dev/null)" == *mikefarah* ]] || die "yq must be mikefarah/yq v4 (see mise.toml)"

make_temp_dir WORK support-matrix
mkdir -p "${WORK}/eol"

# ---------------------------------------------------------------------------
# Rendered profiles
# ---------------------------------------------------------------------------
PROFILES=()
for d in "$OUT"/*/; do
  if [[ -f "${d}index.tsv" ]]; then
    PROFILES+=("$(basename "$d")")
  fi
done
((${#PROFILES[@]} > 0)) || die "no rendered profile under ${OUT} (run hack/render.sh first)"

: >"${WORK}/profiles.jsonl"
: >"${WORK}/images.tsv"
for profile in "${PROFILES[@]}"; do
  idx="${OUT}/${profile}/index.tsv"
  header="$(head -n 1 "$idx" | tr -d '\r')"
  [[ "$header" == "$INDEX_HEADER" ]] ||
    die "unexpected header in ${idx}: expected the columns ${INDEX_HEADER//$'\t'/, }"

  kube_version=""
  if [[ -f "${OUT}/${profile}/profile.env" ]]; then
    kube_version="$(jq -R -s -r '
      split("\n") | map(select(startswith("KUBERNETES_VERSION=")))
      | (first // "") | sub("^KUBERNETES_VERSION="; "") | gsub("^[\"'\'']|[\"'\'']$"; "")' \
      "${OUT}/${profile}/profile.env")"
  fi
  # "-" marks an empty field; the chart column is a comma-separated list.
  tr -d '\r' <"$idx" | jq -R -s -c --arg profile "$profile" --arg kube "$kube_version" '
    def field: if . == null or . == "-" then "" else . end;
    {profile: $profile, kubernetesVersion: $kube,
     rows: [split("\n")[1:][] | select(length > 0) | split("\t") | map(field)
       | {file: .[0], type: .[1], name: .[2], chart: .[3], namespace: .[4],
          charts: [.[3] | split(",")[] | sub("^\\./"; "") | sub("/$"; "") | select(length > 0)]}]}' \
    >>"${WORK}/profiles.jsonl"

  # Image fields per index row: image, charts, profile, type. Rows of type
  # chart (charts that no Application of the profile deploys) and remote
  # rows (no rendered file) are skipped.
  while IFS=$'\037' read -r file type name chart _; do
    [[ -n "$file" && "$file" != "-" && "$type" != "chart" ]] || continue
    [[ -f "${OUT}/${file}" ]] || die "profile ${profile}: index.tsv lists ${file}, which does not exist under ${OUT}"
    [[ -n "$chart" && "$chart" != "-" ]] || chart="$name"
    yq -N '
      select(tag == "!!map")
      | select((((.apiVersion // "") | test("(^|[.])kyverno[.]io/"))
          or ((.kind // "") | test("^(CustomResourceDefinition|Application|ApplicationSet|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingAdmissionPolicy|MutatingAdmissionPolicyBinding)$"))) | not)
      | .. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' \
      "${OUT}/${file}" |
      awk -v chart="$chart" -v profile="$profile" -v type="$type" \
        'NF { print $0 "\t" chart "\t" profile "\t" type }' >>"${WORK}/images.tsv"
  done < <(tail -n +2 "$idx" | tr -d '\r' | tr '\t' '\037')
done
jq -s '.' "${WORK}/profiles.jsonl" >"${WORK}/profiles.json"
jq -R -s '[split("\n")[] | select(length > 0) | split("\t")
  | {image: .[0], charts: [.[1] | split(",")[] | sub("^\\./"; "") | sub("/$"; "")],
     profile: .[2], type: .[3]}]' \
  "${WORK}/images.tsv" >"${WORK}/images.json"

# ---------------------------------------------------------------------------
# Charts, clusters, toolchain, kind node images
# ---------------------------------------------------------------------------
: >"${WORK}/charts.jsonl"
while IFS= read -r chart_file; do
  CHART_PATH="${chart_file#"$REPO"/}"
  CHART_PATH="${CHART_PATH%/Chart.yaml}"
  # shellcheck disable=SC2016  # yq expression, not shell
  CHART_PATH="$CHART_PATH" yq -o json -I0 '{
      "path": strenv(CHART_PATH), "name": .name, "version": .version,
      "appVersion": .appVersion, "type": .type,
      "dependencies": [(.dependencies // [])[] | {"name": .name, "version": .version, "repository": .repository}]
    }' "$chart_file" >>"${WORK}/charts.jsonl"
done < <(find "${REPO}/helmcharts" -name Chart.yaml -type f -not -path '*/charts/*' -not -path '*/tests/*' | LC_ALL=C sort)
jq -s '.' "${WORK}/charts.jsonl" >"${WORK}/charts.json"

: >"${WORK}/clusters.jsonl"
for cluster_file in "${REPO}"/clusters/*/cluster.yaml; do
  [[ -f "$cluster_file" ]] || continue
  cluster="$(basename "$(dirname "$cluster_file")")"
  merge_files=("$cluster_file")
  if [[ -f "${REPO}/argocd-bootstrap/values.yaml" ]]; then
    merge_files=("${REPO}/argocd-bootstrap/values.yaml" "$cluster_file")
  fi
  # shellcheck disable=SC2016  # yq expression, not shell
  toolchains="$(yq ea -o json -I0 '. as $doc ireduce ({}; . * $doc) | (.toolchains // {})' "${merge_files[@]}")"
  CLUSTER="$cluster" yq -o json -I0 '{
      "name": strenv(CLUSTER), "profile": .cluster.profile,
      "kubernetesMinor": .cluster.kubernetesMinor,
      "rke2Version": .rke2.version, "rke2Channel": .rke2.channel
    }' "$cluster_file" |
    jq -c --argjson toolchains "$toolchains" '. + {toolchains: $toolchains}' >>"${WORK}/clusters.jsonl"
done
jq -s '.' "${WORK}/clusters.jsonl" >"${WORK}/clusters.json"

if [[ -f "${REPO}/mise.toml" ]]; then
  yq -p toml -o json '{"minVersion": .min_version, "tools": (.tools // {})}' "${REPO}/mise.toml" >"${WORK}/mise.json"
else
  log_warn "${REPO}/mise.toml not found; the toolchain table will be empty"
  echo '{"minVersion": null, "tools": {}}' >"${WORK}/mise.json"
fi

if [[ -f "${REPO}/kind/node-images.yaml" ]]; then
  yq -o json '{"kindVersion": .kindVersion, "images": (.images // {})}' "${REPO}/kind/node-images.yaml" >"${WORK}/kind.json"
else
  echo 'null' >"${WORK}/kind.json"
fi

# ---------------------------------------------------------------------------
# Model and rendering (jq). MODE "products" prints the endoflife.date
# products to fetch; MODE "warnings" prints consistency warnings; MODE
# "markdown" prints the document.
# ---------------------------------------------------------------------------
cat >"${WORK}/matrix.jq" <<'JQ'
# endoflife.date product per component. Keys are upstream chart names,
# wrapper chart directory names or tool names. Checked against the product
# list at https://endoflife.date/api/v1/products; Helm, RKE2, kind, Envoy
# Gateway, Gateway API, Sealed Secrets and the NFS provisioner have no
# product there and are reported as not tracked.
def products: {
  "kubernetes": "kubernetes",
  "kubectl": "kubernetes",
  "argo-cd": "argo-cd",
  "cert-manager": "cert-manager",
  "kyverno": "kyverno",
  "keda": "keda",
  "longhorn": "longhorn",
  "openbao": "openbao",
  "loki": "grafana-loki",
  "go": "go",
  "node": "nodejs",
  "python": "python",
  "ansible-core": "ansible-core",
  "opentofu": "opentofu"
};

def str: if . == null then "" else tostring end;
def cell: str | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") | if . == "" then "n/a" else . end;
def row: "| " + (map(cell) | join(" | ")) + " |";
def table($header; $rows):
  ($header | row),
  ("| " + ([$header[] | "---"] | join(" | ")) + " |"),
  ($rows[] | row);
def version_key: str | ltrimstr("v") | split(".") | map(tonumber? // 0);
def last_segment: split("/") | last;
def minor_of: str | ltrimstr("v") | split(".")[0:2] | join(".");
# Code span, so that URLs are neither bare URLs nor link-checked.
def code: if . == "" then "" else "`\(.)`" end;
def list_or($empty): if length == 0 then $empty else join(", ") end;

def valid_image: test("^[A-Za-z0-9][A-Za-z0-9._/:@-]*$");

# Image reference to {name, repo, tag, digest, reference}. A string that is
# not an image reference (for example an unrendered template) is kept as is.
def norm_image:
  if valid_image | not then {name: ., repo: "", tag: "", digest: "", reference: "not a valid reference"} else
  (if test("@") then {ref: split("@")[0], digest: (split("@")[1:] | join("@"))}
   else {ref: ., digest: ""} end) as $d
  | ($d.ref | split("/")) as $parts
  | (if ($parts | length) > 1 and (($parts[0] | test("[.:]")) or $parts[0] == "localhost")
     then {registry: $parts[0], path: ($parts[1:] | join("/"))}
     else {registry: "docker.io", path: ($parts | join("/"))} end) as $r
  | ($r.path | if test(":") then {repo: split(":")[0], tag: (split(":")[1:] | join(":"))}
               else {repo: ., tag: ""} end) as $t
  | ($r.registry | if IN("index.docker.io", "registry-1.docker.io", "registry.hub.docker.com")
                   then "docker.io" else . end) as $registry
  | ($t.repo | if $registry == "docker.io" and (contains("/") | not) then "library/" + . else . end) as $repo
  | {name: "\($registry)/\($repo)", repo: $repo, tag: $t.tag, digest: $d.digest,
     reference: (if $d.digest != "" and $t.tag != "" then "\($t.tag)@\($d.digest)"
                 elif $d.digest != "" then $d.digest
                 elif $t.tag != "" then $t.tag
                 else "latest (implicit)" end)}
  end;

def deployed($p; $chart):
  any($p.rows[]; (.type == "application" or .type == "remote") and any(.charts[]; . == $chart));

$profiles[0] as $profiles
| ($charts[0] | sort_by(.path)) as $charts
| $clusters[0] as $clusters
| $images[0] as $images
| $mise[0] as $mise
| $kind[0] as $kind
| ($eol[0] // {}) as $eol
| ($supported | split(" ") | map(select(length > 0))) as $supported_minors
| ($epoch | strftime("%Y-%m-%d")) as $today
| ($epoch + 90 * 86400 | strftime("%Y-%m-%d")) as $soon

# Release cycle record of version $v of component $key, or null.
| def release($key; $v):
    (products[$key]) as $product
    | ($v | str | ltrimstr("v") | sub("[-+].*$"; "") | split(".")) as $parts
    | if $product == null or ($v | str) == "" then null
      else first(($parts[0:2] | join(".")), $parts[0] | . as $c
             | ($eol[$product].releases // [])[] | select(.name == $c)) // null
      end;

# Cycle, EOL date and status of version $v of component $key.
def lifecycle($key; $v):
    (products[$key // ""]) as $product
    | if $product == null then {cycle: "n/a", eol: "n/a", status: "not tracked"}
      elif ($v | str) == "" then {cycle: "unknown", eol: "unknown", status: "no version"}
      else
        release($key; $v) as $r
        | if $r == null then {cycle: "not listed (\($v | minor_of))", eol: "unknown", status: "cycle not listed"}
          else
            {cycle: $r.name,
             eol: ($r.eolFrom // (if $r.isEol then "ended" else "not announced" end)),
             status: (
               if ($r.eolFrom != null and $r.eolFrom <= $today) or ($r.eolFrom == null and $r.isEol == true)
                 then "end of life"
               elif $r.eoasFrom != null and $r.eoasFrom <= $today
                 then "\(($eol[$product].labels.eol // "maintenance") | ascii_downcase) only"
               elif $r.eolFrom != null and $r.eolFrom <= $soon
                 then "supported, EOL within 90 days"
               else "supported" end)}
          end
      end;

# ---- Rows -------------------------------------------------------------------
($images | map(. + (.image | norm_image))) as $imgs

| ([$clusters[].name] + [$profiles[].profile] | unique) as $names
| [$names[] as $n
   | ($clusters | map(select(.name == $n)) | first) as $c
   | ($profiles | map(select(.profile == $n)) | first) as $p
   | ($c.kubernetesMinor // ($p.kubernetesVersion | minor_of) | str) as $minor
   | {cluster: $n, profile: ($c.profile // "n/a" | str), minor: $minor,
      rke2: (if ($c.rke2Version | str) != ""
             then "\($c.rke2Version)\(if ($c.rke2Channel | str) != "" then " (\($c.rke2Channel))" else "" end)"
             else "n/a" end),
      rke2Minor: ($c.rke2Version | minor_of),
      rendered: (if $p == null then "not rendered"
                 elif ($p.kubernetesVersion | str) == "" then "not recorded"
                 else $p.kubernetesVersion end),
      k: "kubernetes", v: $minor}] as $kube_rows

| [$supported_minors[] as $m
   | release("kubernetes"; $m) as $r
   | {minor: $m, released: ($r.releaseDate // "unknown"), eoas: ($r.eoasFrom // "unknown"),
      clusters: ([$kube_rows[] | select(.minor == $m) | .cluster] | list_or("none")),
      k: "kubernetes", v: $m}] as $supported_rows

| [$charts[] as $ch
   | ([$profiles[] | select(deployed(.; $ch.path)) | .profile] | sort) as $enabled
   | (if ($ch.dependencies | length) == 0 then [null] else $ch.dependencies end)[] as $dep
   | ($ch.path | last_segment) as $dir
   | (if $dep != null and products[$dep.name] != null then $dep.name else $dir end) as $key
   | (if ($ch.appVersion | str) != "" then {v: ($ch.appVersion | str), shown: ($ch.appVersion | str)}
      elif $dep != null then
        ([$imgs[] | select(any(.charts[]; . == $ch.path) and (.repo | last_segment) == $dep.name and .tag != "")
          | .tag] | unique | first) as $tag
        | if $tag != null then {v: $tag, shown: "\($tag) (image tag)"} else {v: "", shown: "not set"} end
      else {v: "", shown: "not set"} end) as $app
   | {chart: ($ch.path | ltrimstr("helmcharts/")), version: ($ch.version | str),
      upstream: (if $dep == null then "none" else "\($dep.name) \($dep.version | str)" end),
      repository: (if $dep == null then "local" else ($dep.repository | str | code) end),
      app: $app.shown,
      enabled: (if $ch.type == "library" then "n/a (library)" else ($enabled | list_or("none")) end),
      k: $key, v: $app.v}] as $local_rows

| [[$profiles[] as $p | $p.rows[] | select(.type == "remote") | {profile: $p.profile, name, chart}]
   | group_by(.chart)[]
   | (.[0].chart | capture("^(?<repo>.*)/(?<chart>[^/:]+):(?<rev>[^/]*)$")
      // {repo: .[0].chart, chart: .[0].chart, rev: ""}) as $src
   | {chart: "remote (Application \([.[].name] | unique | join(", ")))", version: "n/a",
      upstream: "\($src.chart) \($src.rev)", repository: ($src.repo | code), app: "unknown (not rendered)",
      enabled: ([.[].profile] | unique | list_or("none")), k: $src.chart, v: ""}] as $remote_rows

| [$imgs | group_by([.name, .reference])[]
   | {image: .[0].name, reference: .[0].reference,
      usedBy: ([.[].charts[] | last_segment] | unique | join(", ")),
      profiles: ([.[].profile] | unique | join(", "))}]
  | sort_by(.image, .reference) as $image_rows

| ($mise.tools // {}) as $tools
| ([$tools | to_entries[]
    | .key as $id | .value as $val
    | ($id | if contains(":") then split(":")[0] else "core" end) as $backend
    | ($id | if contains(":") then (split(":")[1:] | join(":")) else . end) as $tool
    | ($val | if type == "object" then (.version | str)
              elif type == "array" then (map(str) | join(", "))
              else str end) as $version
    | {tool: $tool, version: $version,
       backend: (if ($val | type) == "object" and ($val.python | str) != ""
                 then "\($backend), Python \($val.python)" else $backend end),
       k: ($tool | last_segment), v: ($version | split(", ")[0])}]
   + [[$tools[] | objects | .python | str | select(. != "")] | unique[]
      | {tool: "python", version: ., backend: "uv, interpreter of the pypi tools", k: "python", v: .}]
   | sort_by(.tool | ascii_downcase)) as $tool_rows

| if $mode == "products" then
    (["kubernetes"] + [($local_rows, $remote_rows, $tool_rows)[] | .k]
     | map(products[.] // empty) | unique[])

  elif $mode == "warnings" then
    ($kube_rows[] | select(.rke2Minor != "" and .minor != "" and .rke2Minor != .minor)
     | "cluster \(.cluster): rke2.version \(.rke2) runs Kubernetes \(.rke2Minor), cluster.kubernetesMinor is \(.minor)"),
    ($kube_rows[] | .minor as $m | select($m != "" and ($supported_minors | index([$m]) | not))
     | "cluster \(.cluster): Kubernetes \(.minor) is not a supported minor (\($supported_minors | join(", ")))"),
    ($supported_rows[] | lifecycle(.k; .v) as $l | select($l.status == "end of life" or $l.status == "cycle not listed")
     | "supported Kubernetes minor \(.minor): \($l.status) according to endoflife.date"),
    ($clusters[] as $c
     | ($profiles | map(select(.profile == $c.name)) | first) as $p
     | select($p != null)
     | ($c.toolchains | to_entries[] | select((.value | type) == "object" and .value.enabled == true) | .key) as $t
     | "helmcharts/system-charts/\($t)" as $path
     | select(any($charts[]; .path == $path) and (deployed($p; $path) | not))
     | "cluster \($c.name): toolchains.\($t).enabled is true but nothing from \($path) was rendered"),
    ($imgs[] | select(.image | valid_image | not)
     | "profile \(.profile): unusual image reference \(.image | @json) in \(.charts | join(","))")

  else
    "# Support matrix",
    "",
    "This file is generated by `make support-matrix` (`hack/support-matrix.sh`) from the rendered manifests of every profile (`hack/render.sh`), the chart metadata, the cluster definitions and `mise.toml`. Do not edit it by hand: change the sources and run `make support-matrix` again. `hack/support-matrix.sh --check` fails when this file is out of date.",
    "",
    "End-of-life data comes from the endoflife.date API. Status is evaluated on the generation date for the release cycle of each version; not tracked means that endoflife.date has no product for the component.",
    "",
    "Generated on: \($today) (UTC)",
    "",
    "## Kubernetes and distribution",
    "",
    "Supported Kubernetes minors (platform baseline): \($supported_minors | list_or("none")).",
    "",
    table(["Kubernetes", "Released", "End of active support", "End of life", "Status", "Clusters"];
      [$supported_rows[] | lifecycle(.k; .v) as $l | [.minor, .released, .eoas, $l.eol, $l.status, .clusters]]),
    "",
    "Clusters:",
    "",
    table(["Cluster", "Profile", "Kubernetes", "RKE2", "Rendered with", "Cycle", "EOL", "Status"];
      [$kube_rows[] | lifecycle(.k; .v) as $l | [.cluster, .profile, .minor, .rke2, .rendered, $l.cycle, $l.eol, $l.status]]),
    (if $kind != null then
      "",
      "kind node images, pinned in `kind/node-images.yaml` for kind \($kind.kindVersion | str):",
      "",
      table(["Kubernetes", "Node image", "Status", "Clusters on this minor"];
        [$kind.images | to_entries | sort_by(.key | version_key)[]
         | .key as $m
         | [$m, .value, lifecycle("kubernetes"; $m).status,
            ([$kube_rows[] | select(.minor == $m) | .cluster] | list_or("none"))]])
    else empty end),
    "",
    "## Platform components",
    "",
    "Charts under `helmcharts/` and remote chart sources of Argo CD Applications. Enabled in profiles lists the profiles whose render deploys the chart through an Argo CD Application.",
    "",
    table(["Chart", "Version", "Upstream chart", "Repository", "App version", "Enabled in profiles", "Cycle", "EOL", "Status"];
      [($local_rows + $remote_rows)[] | lifecycle(.k; .v) as $l
       | [.chart, .version, .upstream, .repository, .app, .enabled, $l.cycle, $l.eol, $l.status]]),
    "",
    "## Container images",
    "",
    "Every `image` field in the manifests that the Argo CD Applications of each profile deploy, normalised to registry/repository.",
    "",
    (if ($image_rows | length) == 0 then "No image references were found in the rendered manifests."
     else table(["Image", "Tag or digest", "Used by", "Profiles"];
       [$image_rows[] | [.image, .reference, .usedBy, .profiles]]) end),
    "",
    "## Toolchain",
    "",
    (if ($tool_rows | length) == 0 then "No `mise.toml` with a `[tools]` table was found."
     else
       "Pinned in `mise.toml`\(if ($mise.minVersion | str) != "" then " (mise \($mise.minVersion) or later)" else "" end).",
       "",
       table(["Tool", "Version", "Backend", "Cycle", "EOL", "Status"];
         [$tool_rows[] | lifecycle(.k; .v) as $l | [.tool, .version, .backend, $l.cycle, $l.eol, $l.status]])
     end)
  end
JQ

# run_model MODE: evaluates matrix.jq over the collected inputs.
run_model() {
  jq -n -r -f "${WORK}/matrix.jq" \
    --arg mode "$1" \
    --arg supported "$SUPPORTED_KUBERNETES_MINORS" \
    --argjson epoch "$EPOCH" \
    --slurpfile profiles "${WORK}/profiles.json" \
    --slurpfile charts "${WORK}/charts.json" \
    --slurpfile clusters "${WORK}/clusters.json" \
    --slurpfile images "${WORK}/images.json" \
    --slurpfile mise "${WORK}/mise.json" \
    --slurpfile kind "${WORK}/kind.json" \
    --slurpfile eol "${WORK}/eol.json"
}

# Evaluation date of the status columns. --check uses the generation date of
# the committed document, so a pull request does not fail only because a
# support window ended since the last regeneration. SUPPORT_MATRIX_DATE
# (YYYY-MM-DD, UTC) overrides it; the scheduled CI run sets it to today.
EVAL_DATE="${SUPPORT_MATRIX_DATE:-}"
if [[ -z "$EVAL_DATE" ]] && ((CHECK)) && [[ -f "$DOC" ]]; then
  EVAL_DATE="$(sed -n 's/^Generated on: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) (UTC)$/\1/p' "$DOC" | head -n1)"
fi
if [[ -n "$EVAL_DATE" ]]; then
  EPOCH="$(jq -n --arg d "$EVAL_DATE" '$d + "T00:00:00Z" | fromdateiso8601')" ||
    die "invalid evaluation date: ${EVAL_DATE} (expected YYYY-MM-DD)" 2
else
  EPOCH="$(date -u +%s)"
fi
echo '{}' >"${WORK}/eol.json"

# ---------------------------------------------------------------------------
# End-of-life data
# ---------------------------------------------------------------------------
: >"${WORK}/eol.jsonl"
while IFS= read -r product; do
  [[ -n "$product" ]] || continue
  dest="${WORK}/eol/${product}.json"
  log_info "fetching end-of-life data for ${product}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/json' \
    -o "$dest" "${ENDOFLIFE_API}/products/${product}" ||
    die "could not fetch ${ENDOFLIFE_API}/products/${product}; the support matrix needs HTTPS access to endoflife.date"
  jq -e '.result.releases | type == "array"' "$dest" >/dev/null 2>&1 ||
    die "unexpected response from ${ENDOFLIFE_API}/products/${product}: no .result.releases array"
  jq -c --arg product "$product" '{($product): {labels: (.result.labels // {}), releases: .result.releases}}' \
    "$dest" >>"${WORK}/eol.jsonl"
done < <(run_model products)
jq -s 'add // {}' "${WORK}/eol.jsonl" >"${WORK}/eol.json"

while IFS= read -r warning; do
  log_warn "$warning"
done < <(run_model warnings)

GENERATED="${WORK}/support-matrix.md"
run_model markdown >"$GENERATED"

# ---------------------------------------------------------------------------
# Write or check
# ---------------------------------------------------------------------------
if ((CHECK)); then
  label="${DOC#"$REPO"/}"
  [[ -f "$DOC" ]] || die "${label} does not exist: run make support-matrix"
  grep -v '^Generated on: ' "$DOC" >"${WORK}/committed.md" || true
  grep -v '^Generated on: ' "$GENERATED" >"${WORK}/regenerated.md" || true
  if ! diff -u --label "${label} (committed)" --label "${label} (regenerated)" \
    "${WORK}/committed.md" "${WORK}/regenerated.md"; then
    die "${label} is out of date: run make support-matrix"
  fi
  log_info "${label} is up to date"
else
  mkdir -p "$(dirname "$DOC")"
  cp "$GENERATED" "$DOC"
  log_info "wrote ${DOC#"$REPO"/}"
fi
