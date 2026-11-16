#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Installs the pinned CLI tools that hack/demo and hack/e2e use: kind, chainsaw,
# kubectl, helm and yq. Every download is verified against the SHA-256
# constants in this file before it is installed.
#
# Usage: hack/e2e/install-tools.sh [BIN_DIR]
#
#   BIN_DIR          install directory; default TOOLS_BIN_DIR, then
#                    ${REPO_ROOT}/_out/tools/bin
#   TOOLS_CACHE_DIR  verified downloads; default ${REPO_ROOT}/_out/tools/cache
#
# A tool is skipped when the binary in BIN_DIR already reports the pinned
# version. Logs go to stderr; stdout carries only the PATH export, so
#   eval "$(hack/e2e/install-tools.sh)"
# puts the tools on PATH in the current shell. Under GitHub Actions
# (GITHUB_PATH set) BIN_DIR is also added to PATH for the following steps.
#
# Platforms: linux/amd64, linux/arm64, darwin/amd64, darwin/arm64.
#
# Bumping a tool: change its version and all four checksums together, copied
# from the upstream checksum file named above its block in pinned_sha256.
# Never take a checksum from a local download.

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../demo/lib.sh"

# Versions match mise.toml, which the per-pull-request e2e job and local
# developers use; bump both together, with the checksums below.
KIND_VERSION="v0.33.0"
CHAINSAW_VERSION="v0.2.15"
# Same minor as the Kubernetes baseline (cluster.kubernetesMinor 1.36, kind
# node image v1.36.4). Latest 1.36 patch per
# https://dl.k8s.io/release/stable-1.36.txt.
KUBECTL_VERSION="v1.36.6"
HELM_VERSION="v4.3.1"
YQ_VERSION="v4.54.3"

# INSTALL_TOOLS selects a subset, for example INSTALL_TOOLS=chainsaw.
TOOLS="${INSTALL_TOOLS:-kind chainsaw kubectl helm yq}"

usage() {
  cat <<'EOF'
Usage: hack/e2e/install-tools.sh [BIN_DIR]

Installs pinned, checksum-verified kind, chainsaw, kubectl, helm and yq into
BIN_DIR (default: TOOLS_BIN_DIR, then _out/tools/bin in the repository).
EOF
}

# pinned_version TOOL
pinned_version() {
  case "$1" in
    kind) echo "${KIND_VERSION}" ;;
    chainsaw) echo "${CHAINSAW_VERSION}" ;;
    kubectl) echo "${KUBECTL_VERSION}" ;;
    helm) echo "${HELM_VERSION}" ;;
    yq) echo "${YQ_VERSION}" ;;
    *) die "unknown tool: $1" ;;
  esac
}

# pinned_sha256 TOOL OS ARCH: SHA-256 of the release asset for OS/ARCH.
pinned_sha256() {
  case "$1/$2/$3" in
    # kind v0.33.0, one checksum file per asset:
    # https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-<os>-<arch>.sha256sum
    kind/linux/amd64) echo "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d" ;;
    kind/linux/arm64) echo "20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2" ;;
    kind/darwin/amd64) echo "5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0" ;;
    kind/darwin/arm64) echo "0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f" ;;

    # chainsaw v0.2.15:
    # https://github.com/kyverno/chainsaw/releases/download/v0.2.15/checksums.txt
    chainsaw/linux/amd64) echo "295d226c89f126c0a97775d364be149f47a810c8a3f9829ee410583d0c1abe3c" ;;
    chainsaw/linux/arm64) echo "fecf5f3ea74d11da2cd5d95a4c016d5d2543cbc4844ce21adf5e727e7ffd9e44" ;;
    chainsaw/darwin/amd64) echo "ddb56002ff8c6265f55ec40c82eb0ef0dddec5127dd12d4fc5e7953453481f4b" ;;
    chainsaw/darwin/arm64) echo "502bef17dd822217e82590e9ccf01c1e26a56b3fa34a835789b9af73e82a169a" ;;

    # kubectl v1.36.6, one checksum file per binary:
    # https://dl.k8s.io/release/v1.36.6/bin/<os>/<arch>/kubectl.sha256
    kubectl/linux/amd64) echo "29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634" ;;
    kubectl/linux/arm64) echo "35507ef408c3d38849e5d3203e18f8e861db822aa664101a9ced0869edd06046" ;;
    kubectl/darwin/amd64) echo "2e22d382f2423c88d9d076246f860bb3d5c743dd279ca63e113474bb88382426" ;;
    kubectl/darwin/arm64) echo "1cf735c3d35ccfec28d0618784cb06a4614d2c42aade28b6be0eab76a2ffb623" ;;

    # helm v4.3.1, one checksum file per archive:
    # https://get.helm.sh/helm-v4.3.1-<os>-<arch>.tar.gz.sha256sum
    helm/linux/amd64) echo "0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b" ;;
    helm/linux/arm64) echo "8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88" ;;
    helm/darwin/amd64) echo "34bec4eba761ba5c16d1965ee6b8f5b0abe5993974a802274e2a4f0418893d89" ;;
    helm/darwin/arm64) echo "6b4e61c8cd27d99e5a801e63ff25dd5c70b36875c2cd659d3e9ce6b76fc23198" ;;

    # yq v4.54.3, SHA256 lines of:
    # https://github.com/mikefarah/yq/releases/download/v4.54.3/checksums-bsd
    yq/linux/amd64) echo "129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973" ;;
    yq/linux/arm64) echo "89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67" ;;
    yq/darwin/amd64) echo "96d5105ffd693d6845c54fbd825b2d1bbdb8619e0a2ce6af95e5654e841e0984" ;;
    yq/darwin/arm64) echo "a2aebb93b5bdcb61bb76f630e42a0ef6a3ee10842a6516cd7b9e4080786ec593" ;;

    *) die "no pinned checksum for $1 on $2/$3" ;;
  esac
}

# asset_url TOOL OS ARCH
asset_url() {
  case "$1" in
    kind) echo "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-$2-$3" ;;
    chainsaw) echo "https://github.com/kyverno/chainsaw/releases/download/${CHAINSAW_VERSION}/chainsaw_$2_$3.tar.gz" ;;
    kubectl) echo "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/$2/$3/kubectl" ;;
    helm) echo "https://get.helm.sh/helm-${HELM_VERSION}-$2-$3.tar.gz" ;;
    yq) echo "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_$2_$3" ;;
    *) die "unknown tool: $1" ;;
  esac
}

# archive_member TOOL OS ARCH: path of the binary inside the release archive,
# empty when the asset is the binary itself.
archive_member() {
  case "$1" in
    chainsaw) echo "chainsaw" ;;
    helm) echo "$2-$3/helm" ;;
    *) echo "" ;;
  esac
}

# installed_version TOOL: version reported by BIN_DIR/TOOL, empty when absent.
installed_version() {
  local bin="${BIN_DIR}/$1"
  [[ -x "${bin}" ]] || return 0
  case "$1" in
    # kind v0.33.0 go1.x linux/amd64
    kind) "${bin}" version | awk '{print $2}' ;;
    # Version: 0.2.15
    chainsaw) "${bin}" version | awk '$1 == "Version:" {print $2}' ;;
    # Client Version: v1.36.6
    kubectl) "${bin}" version --client | awk '$1 == "Client" && $2 == "Version:" {print $3}' ;;
    helm) "${bin}" version --template '{{.Version}}' ;;
    # yq (https://github.com/mikefarah/yq/) version v4.54.3
    yq) "${bin}" --version | awk '{print $NF}' ;;
    *) die "unknown tool: $1" ;;
  esac
}

# same_version A B: true when A and B match, ignoring a leading "v".
same_version() {
  [[ -n "$1" && "${1#v}" == "${2#v}" ]]
}

detect_platform() {
  case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="darwin" ;;
    *) die "unsupported OS: $(uname -s) (supported: linux, darwin)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *) die "unsupported architecture: $(uname -m) (supported: amd64, arm64)" ;;
  esac
}

install_tool() {
  local tool="$1" want have url sha asset member tmp
  want="$(pinned_version "${tool}")"
  have="$(installed_version "${tool}" 2>/dev/null)" || have=""
  if same_version "${have}" "${want}"; then
    log_info "${tool} ${want} already installed"
    return 0
  fi

  url="$(asset_url "${tool}" "${OS}" "${ARCH}")"
  sha="$(pinned_sha256 "${tool}" "${OS}" "${ARCH}")"
  asset="${CACHE_DIR}/${tool}/${want}/${OS}-${ARCH}/${url##*/}"
  download_verified "${url}" "${asset}" "${sha}"

  # Write next to the target and rename, so an interrupted run never leaves a
  # truncated binary under the final name.
  tmp="${BIN_DIR}/.${tool}.download"
  member="$(archive_member "${tool}" "${OS}" "${ARCH}")"
  if [[ -n "${member}" ]]; then
    tar -xzf "${asset}" -O "${member}" >"${tmp}"
  else
    cp "${asset}" "${tmp}"
  fi
  chmod 0755 "${tmp}"
  mv -f "${tmp}" "${BIN_DIR}/${tool}"

  have="$(installed_version "${tool}")" || die "${tool}: installed binary does not run"
  same_version "${have}" "${want}" || die "${tool}: installed binary reports '${have}', expected ${want}"
  log_info "installed ${tool} ${want} (${OS}/${ARCH})"
}

main() {
  local tool
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
  esac
  (($# <= 1)) || {
    usage >&2
    die "expected at most one argument, got $#"
  }

  require_cmd awk curl tar uname
  detect_platform

  BIN_DIR="${1:-${TOOLS_BIN_DIR:-${REPO_ROOT}/_out/tools/bin}}"
  CACHE_DIR="${TOOLS_CACHE_DIR:-${REPO_ROOT}/_out/tools/cache}"
  mkdir -p "${BIN_DIR}" "${CACHE_DIR}"
  BIN_DIR="$(cd "${BIN_DIR}" && pwd -P)"
  CACHE_DIR="$(cd "${CACHE_DIR}" && pwd -P)"

  for tool in ${TOOLS}; do
    install_tool "${tool}"
  done

  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "${BIN_DIR}" >>"${GITHUB_PATH}"
    log_info "added ${BIN_DIR} to GITHUB_PATH"
  fi

  log_info "tools are in ${BIN_DIR}; to use them in this shell run:"
  printf 'export PATH=%q:"%s"\n' "${BIN_DIR}" "\$PATH"
}

main "$@"
