#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Package a chart of this repository and push it to an OCI registry. The
# default is the helm-common library chart, the one chart meant for reuse.
#
# Dry run by default: the chart is linted and packaged, and the push command
# is printed but not executed. Pass --push to publish.
#
# Usage:
#   hack/publish-chart.sh            # dry run (make publish-chart)
#   hack/publish-chart.sh --push     # publish (make publish-chart PUSH=1)
#
# Environment:
#   CHART          chart directory relative to the repository root
#                  (default helmcharts/helm-common)
#   HELM_OCI_REPO  OCI repository for charts (default oci://ghcr.io/your-org/charts)
#
# Authenticate first, for example:
#   helm registry login ghcr.io --username <user> --password-stdin
# Published versions are immutable: bump version in Chart.yaml before pushing.

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

usage() {
  sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DRY_RUN=1
while (($# > 0)); do
  case "$1" in
    --push) DRY_RUN=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" 2 ;;
  esac
  shift
done
export DRY_RUN

HELM_OCI_REPO="${HELM_OCI_REPO:-oci://ghcr.io/your-org/charts}"
CHART_DIR="${REPO_ROOT}/${CHART:-helmcharts/helm-common}"
[[ -f "${CHART_DIR}/Chart.yaml" ]] || die "no Chart.yaml in ${CHART_DIR} (set CHART to a chart directory)"

require_cmd helm

[[ "${HELM_OCI_REPO}" == oci://* ]] || die "HELM_OCI_REPO must start with oci:// (got ${HELM_OCI_REPO})"
if [[ "${HELM_OCI_REPO}" == *your-org* || "${HELM_OCI_REPO}" == *YOUR_ORG* ]]; then
  if [[ "${DRY_RUN}" == "0" ]]; then
    die "HELM_OCI_REPO still contains the your-org placeholder"
  fi
  log_warn "HELM_OCI_REPO contains the your-org placeholder; acceptable for a dry run only"
fi

chart_field() {
  helm show chart "${CHART_DIR}" | awk -v key="$1:" '$1 == key { print $2; exit }'
}

name="$(chart_field name)"
version="$(chart_field version)"
[[ -n "${name}" && -n "${version}" ]] || die "cannot read name and version from ${CHART_DIR}/Chart.yaml"
log_info "chart ${name} ${version} -> ${HELM_OCI_REPO}"

log_info "linting ${CHART_DIR}"
helm lint --strict "${CHART_DIR}" >&2

pkg_dir=""
make_temp_dir pkg_dir publish-chart
helm package "${CHART_DIR}" --destination "${pkg_dir}" >&2
package="${pkg_dir}/${name}-${version}.tgz"
[[ -f "${package}" ]] || die "expected package ${package} was not produced"

if [[ "${DRY_RUN}" == "0" ]]; then
  if helm show chart "${HELM_OCI_REPO}/${name}" --version "${version}" >/dev/null 2>&1; then
    die "${name} ${version} already exists in ${HELM_OCI_REPO}; bump the chart version"
  fi
fi

run_cmd helm push "${package}" "${HELM_OCI_REPO}"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "dry run complete; rerun with --push to publish"
else
  log_info "published ${HELM_OCI_REPO}/${name}:${version}"
fi
