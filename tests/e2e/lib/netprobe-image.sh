#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Builds the network probe image from tests/e2e/probe/Dockerfile and loads it
# into the kind cluster DEMO_CLUSTER. Prints the image reference on stdout;
# build and load output goes to stderr.
#
# The image is tagged <registry prefix>/e2e-netprobe:<curl version>. The
# registry prefix is the one of the dev hello-api image (ghcr.io/YOUR_ORG in
# lab), only so that a probe pod in an app namespace passes the registry
# allowlist. The image exists only in the local Docker daemon and on the kind
# nodes; it is never pushed. The build is skipped when the image exists, and
# kind load skips nodes that already have it.
#
# Settings:
#   DEMO_CLUSTER        kind cluster name (exported by the runner)
#   E2E_PROBE_REGISTRY  registry prefix override (default: from the dev hello-api image)
set -euo pipefail

lib_dir="${BASH_SOURCE[0]%/*}"
[[ "${lib_dir}" != "${BASH_SOURCE[0]}" ]] || lib_dir=.
# shellcheck source=SCRIPTDIR/common.sh
source "${lib_dir}/common.sh"

cluster="${DEMO_CLUSTER:?DEMO_CLUSTER is not set}"
context_dir="${lib_dir}/../probe"
dockerfile="${context_dir}/Dockerfile"
[[ -f "${dockerfile}" ]] || fail "missing ${dockerfile}"

# The tag follows the curl version pinned in the FROM line.
version="$(sed -n 's|^FROM [^:]*:\([^@]*\)@.*|\1|p' "${dockerfile}")"
[[ -n "${version}" ]] || fail "cannot read the curl version from the FROM line of ${dockerfile}"

registry="${E2E_PROBE_REGISTRY:-}"
if [[ -z "${registry}" ]]; then
  deployment="$(hello_api_deployment dev)"
  [[ -n "${deployment}" ]] || fail "no hello-api Deployment in dev to derive the registry prefix from; set E2E_PROBE_REGISTRY"
  repository="$(image_repository "$(hello_api_image dev "${deployment}")")"
  registry="${repository%/*}"
fi
image="${registry}/e2e-netprobe:${version}"

if docker image inspect "${image}" >/dev/null 2>&1; then
  printf 'probe image %s exists locally, build skipped\n' "${image}" >&2
else
  docker build --provenance=false --sbom=false -t "${image}" "${context_dir}" >&2
fi
kind load docker-image --name "${cluster}" "${image}" >&2

printf '%s\n' "${image}"
