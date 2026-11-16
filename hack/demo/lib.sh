# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Shared settings and helpers for hack/demo/*.sh and hack/e2e/*.sh.
# Source it; do not execute it.
#
# Settings (environment variables, all optional):
#   DEMO_CLUSTER          kind cluster name                      (default: demo)
#   DEMO_GITOPS_CLUSTER   cluster definition in clusters/<name>  (default: lab)
#   DEMO_PROFILE          Argo CD install profile                (default: lab)
#   DEMO_HTTP_PORT        host port for the Gateway http listener  (default: 80)
#   DEMO_HTTPS_PORT       host port for the Gateway https listener (default: 443)
#   DEMO_DOMAIN           base domain of the lab routes          (default: localtest.me)
#   DEMO_STATE_DIR        kubeconfig, CA and downloads           (default: _out/demo/<cluster>)
#   DEMO_WORKERS          kind worker nodes, 0 to 2              (default: 2)
#   DEMO_TIMEOUT          seconds to wait for all Applications   (default: 1500)
#   DEMO_INCLUDE_DIRTY    1 also publishes uncommitted changes of tracked files
#   DEMO_IMAGE_REPOSITORY hello-api image repository (default: read from the chart values)
#   KIND_NODE_IMAGE       kind node image (default: from kind/node-images.yaml)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib.sh is a library; source it from a script instead of running it." >&2
  exit 1
fi

if [[ -n "${_DEMO_LIB_LOADED:-}" ]]; then
  return 0
fi
_DEMO_LIB_LOADED=1

_demo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
: "${REPO_ROOT:=$(cd "${_demo_lib_dir}/../.." && pwd -P)}"
export REPO_ROOT

# ---------------------------------------------------------------------------
# Strict mode, logging and cleanup: scripts/lib/common.sh when present,
# otherwise a minimal fallback with the same function names.
# ---------------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/scripts/lib/common.sh" ]]; then
  # shellcheck source=scripts/lib/common.sh disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
else
  set -Eeuo pipefail
  _demo_log() {
    local level="$1"
    shift
    printf '%s %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "$*" >&2
  }
  log_debug() { [[ "${LOG_LEVEL:-info}" == debug ]] && _demo_log debug "$@" || true; }
  log_info() { _demo_log info "$@"; }
  log_warn() { _demo_log warn "$@"; }
  log_error() { _demo_log error "$@"; }
  die() {
    log_error "$1"
    exit "${2:-1}"
  }
  _DEMO_CLEANUP=()
  add_cleanup() { _DEMO_CLEANUP+=("$1"); }
  _demo_on_exit() {
    local rc=$? i
    set +e
    for ((i = ${#_DEMO_CLEANUP[@]} - 1; i >= 0; i--)); do
      eval "${_DEMO_CLEANUP[$i]}"
    done
    exit "${rc}"
  }
  trap _demo_on_exit EXIT
  require_cmd() {
    local cmd missing=()
    for cmd in "$@"; do
      command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if ((${#missing[@]} > 0)); then
      die "missing required command(s): ${missing[*]}"
    fi
  }
fi

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
: "${DEMO_CLUSTER:=demo}"
: "${DEMO_GITOPS_CLUSTER:=lab}"
: "${DEMO_PROFILE:=lab}"
: "${DEMO_HTTP_PORT:=80}"
: "${DEMO_HTTPS_PORT:=443}"
: "${DEMO_DOMAIN:=localtest.me}"
: "${DEMO_STATE_DIR:=${REPO_ROOT}/_out/demo/${DEMO_CLUSTER}}"
: "${DEMO_WORKERS:=2}"
: "${DEMO_TIMEOUT:=1500}"
: "${DEMO_INCLUDE_DIRTY:=0}"
export DEMO_CLUSTER DEMO_GITOPS_CLUSTER DEMO_PROFILE DEMO_HTTP_PORT DEMO_HTTPS_PORT \
  DEMO_DOMAIN DEMO_STATE_DIR DEMO_WORKERS DEMO_TIMEOUT DEMO_INCLUDE_DIRTY

: "${DEMO_KUBECONFIG:=${DEMO_STATE_DIR}/kubeconfig}"
: "${DEMO_CA_FILE:=${DEMO_STATE_DIR}/lab-ca.crt}"
# shellcheck disable=SC2034 # used by the scripts that source this file
DEMO_CACHE_DIR="${REPO_ROOT}/_out/demo/cache"
export DEMO_KUBECONFIG DEMO_CA_FILE

# In-cluster Git server that Argo CD reads from.
DEMO_GIT_NAMESPACE="demo-git"
DEMO_GIT_SERVICE="gitea-http"
DEMO_GIT_OWNER="demo"
DEMO_GIT_REPO="sk-k8s-devops-bootstrap"
DEMO_GIT_BRANCH="main"
DEMO_GIT_URL="http://${DEMO_GIT_SERVICE}.${DEMO_GIT_NAMESPACE}.svc.cluster.local:3000/${DEMO_GIT_OWNER}/${DEMO_GIT_REPO}.git"
export DEMO_GIT_NAMESPACE DEMO_GIT_SERVICE DEMO_GIT_OWNER DEMO_GIT_REPO DEMO_GIT_BRANCH DEMO_GIT_URL

# Calico, applied from the upstream manifest and verified by checksum.
# shellcheck disable=SC2034 # used by the scripts that source this file
CALICO_VERSION="v3.33.0"
# shellcheck disable=SC2034
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
# shellcheck disable=SC2034
CALICO_MANIFEST_SHA256="2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5"

# metrics-server, which RKE2 ships by default and kind does not. HPAs and
# kubectl top need it; without it Argo CD reports HPAs as Degraded.
# shellcheck disable=SC2034
METRICS_SERVER_VERSION="v0.9.1"
# shellcheck disable=SC2034
METRICS_SERVER_MANIFEST_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# shellcheck disable=SC2034
METRICS_SERVER_MANIFEST_SHA256="3c7f57cdbee0f57fb0259a150e8f6d6cb4f29d72d1aa5dce8803151dd6d4c2a1"

# Shared platform Gateway and the lab CA.
GATEWAY_NAMESPACE="envoy-gateway-system"
GATEWAY_NAME="platform"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# sha256_of FILE: prints the hex SHA-256 of FILE.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# download_verified URL DEST SHA256: downloads once, verifies the checksum.
download_verified() {
  local url="$1" dest="$2" want="$3" have
  if [[ ! -f "${dest}" ]] || [[ "$(sha256_of "${dest}")" != "${want}" ]]; then
    mkdir -p "$(dirname "${dest}")"
    log_info "downloading ${url}"
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
  fi
  have="$(sha256_of "${dest}")"
  [[ "${have}" == "${want}" ]] || die "checksum mismatch for ${url}: expected ${want}, got ${have}"
}

# demo_cluster_exists: true when the kind cluster exists.
demo_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${DEMO_CLUSTER}"
}

# demo_use_kubeconfig: writes the cluster's kubeconfig to DEMO_KUBECONFIG and
# exports KUBECONFIG, so every command and every called script targets the demo
# cluster whatever the user's current context is.
demo_use_kubeconfig() {
  mkdir -p "${DEMO_STATE_DIR}"
  (
    umask 077
    kind get kubeconfig --name "${DEMO_CLUSTER}" >"${DEMO_KUBECONFIG}.tmp"
  )
  mv "${DEMO_KUBECONFIG}.tmp" "${DEMO_KUBECONFIG}"
  export KUBECONFIG="${DEMO_KUBECONFIG}"
}

# cluster_config_get EXPRESSION DEFAULT: reads clusters/<cluster>/cluster.yaml.
cluster_config_get() {
  local file="${REPO_ROOT}/clusters/${DEMO_GITOPS_CLUSTER}/cluster.yaml" value=""
  if [[ -f "${file}" ]]; then
    value="$(yq -r "$1 // \"\"" "${file}")"
  fi
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    value="$2"
  fi
  printf '%s\n' "${value}"
}

# wait_until TIMEOUT_SECONDS INTERVAL_SECONDS DESCRIPTION COMMAND...
# Runs COMMAND until it succeeds or the timeout expires.
wait_until() {
  local timeout="$1" interval="$2" what="$3" start now
  shift 3
  start="$(date +%s)"
  while true; do
    if "$@"; then
      return 0
    fi
    now="$(date +%s)"
    if ((now - start >= timeout)); then
      log_error "timed out after ${timeout}s waiting for ${what}"
      return 1
    fi
    sleep "${interval}"
  done
}

# start_port_forward VAR NAMESPACE TARGET REMOTE_PORT
# Starts kubectl port-forward on a free local port, stores the port in VAR and
# registers the process for cleanup on exit.
start_port_forward() {
  # Locals carry a prefix: printf -v writes to the caller's variable, which a
  # local of the same name here would shadow.
  local _pf_var="$1" _pf_ns="$2" _pf_target="$3" _pf_remote="$4" _pf_log _pf_pid _pf_port="" _pf_i
  mkdir -p "${DEMO_STATE_DIR}"
  _pf_log="${DEMO_STATE_DIR}/port-forward-${_pf_ns}-${_pf_remote}.log"
  kubectl -n "${_pf_ns}" port-forward "${_pf_target}" ":${_pf_remote}" --address 127.0.0.1 >"${_pf_log}" 2>&1 &
  _pf_pid=$!
  add_cleanup "kill ${_pf_pid} 2>/dev/null || true"
  for _pf_i in $(seq 1 60); do
    _pf_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "${_pf_log}" | head -n1)"
    [[ -n "${_pf_port}" ]] && break
    kill -0 "${_pf_pid}" 2>/dev/null || break
    sleep 0.5
  done
  [[ -n "${_pf_port}" ]] || die "port-forward to ${_pf_ns}/${_pf_target}:${_pf_remote} failed: $(cat "${_pf_log}")"
  printf -v "${_pf_var}" '%s' "${_pf_port}"
}

# git_server_push SRC_REPO REF [REPOSITORY]: force-pushes REF of SRC_REPO to
# the in-cluster Git server as DEMO_GIT_BRANCH of REPOSITORY (default
# DEMO_GIT_REPO); the server creates the repository on first push. The
# credential travels in environment variables, never on a command line.
git_server_push() {
  local src="$1" ref="$2" repo="${3:-${DEMO_GIT_REPO}}" port user password auth
  user="$(kubectl -n "${DEMO_GIT_NAMESPACE}" get secret gitea-admin -o jsonpath='{.data.username}' | base64 -d)"
  password="$(kubectl -n "${DEMO_GIT_NAMESPACE}" get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d)"
  auth="$(printf '%s:%s' "${user}" "${password}" | base64 | tr -d '\n')"
  start_port_forward port "${DEMO_GIT_NAMESPACE}" "svc/${DEMO_GIT_SERVICE}" 3000
  GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.extraHeader" \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" \
    git -C "${src}" push --quiet --force \
    "http://127.0.0.1:${port}/${DEMO_GIT_OWNER}/${repo}.git" \
    "${ref}:refs/heads/${DEMO_GIT_BRANCH}"
}

# git_server_checkout DIR: makes DIR a checkout of DEMO_GIT_BRANCH as it is on
# the in-cluster Git server (anonymous read; the repository is public inside
# the cluster). Clones on first use, then fetches and resets.
git_server_checkout() {
  local dir="$1" port url
  start_port_forward port "${DEMO_GIT_NAMESPACE}" "svc/${DEMO_GIT_SERVICE}" 3000
  url="http://127.0.0.1:${port}/${DEMO_GIT_OWNER}/${DEMO_GIT_REPO}.git"
  if [[ ! -d "${dir}/.git" ]]; then
    GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "${DEMO_GIT_BRANCH}" "${url}" "${dir}"
  else
    GIT_TERMINAL_PROMPT=0 git -C "${dir}" fetch --quiet "${url}" "${DEMO_GIT_BRANCH}"
    git -C "${dir}" checkout --quiet --force -B "${DEMO_GIT_BRANCH}" FETCH_HEAD
  fi
}

# ensure_commit_identity REPO: a throwaway clone needs an identity to commit.
# Uses the configured identity when there is one (local runs) and a neutral
# demo identity only when none is configured (CI runners).
ensure_commit_identity() {
  local repo="$1"
  if ! git -C "${repo}" config user.email >/dev/null 2>&1; then
    git -C "${repo}" config user.email "demo@example.com"
  fi
  if ! git -C "${repo}" config user.name >/dev/null 2>&1; then
    git -C "${repo}" config user.name "Demo"
  fi
}

# hello_api_repository: image repository of hello-api. DEMO_IMAGE_REPOSITORY
# when set, otherwise <platform.imageRegistry>/hello-api from the cluster
# definition, which is also the prefix of the lab registry allowlist, otherwise
# the chart values. Image references must be lowercase.
hello_api_repository() {
  local registry value=""
  if [[ -n "${DEMO_IMAGE_REPOSITORY:-}" ]]; then
    value="${DEMO_IMAGE_REPOSITORY}"
  else
    registry="$(cluster_config_get '.platform.imageRegistry' '')"
    if [[ -n "${registry}" ]]; then
      value="${registry%/}/hello-api"
    elif [[ -f "${REPO_ROOT}/helmcharts/app-charts/hello-api/values.yaml" ]]; then
      value="$(yq -r '.image.repository // ""' "${REPO_ROOT}/helmcharts/app-charts/hello-api/values.yaml")"
    fi
  fi
  [[ -n "${value}" && "${value}" != "null" ]] || die "cannot determine the hello-api image repository; set DEMO_IMAGE_REPOSITORY"
  if [[ ! "${value}" =~ ^[a-z0-9]([a-z0-9._:/-]*[a-z0-9])?$ ]]; then
    die "image repository '${value}' is not a valid lowercase image reference; set platform.imageRegistry in clusters/${DEMO_GITOPS_CLUSTER}/cluster.yaml to a lowercase value"
  fi
  printf '%s\n' "${value}"
}

# hello_api_application ENV: name of the Argo CD Application that deploys
# hello-api to namespace ENV.
hello_api_application() {
  kubectl -n argocd get applications.argoproj.io -o json | jq -r --arg env "$1" '
    [.items[]
      | select(.spec.destination.namespace == $env)
      | select([(.spec.source.path // ""), (.spec.sources // [] | .[].path // "")] | any(test("hello-api")))
      | .metadata.name][0] // empty'
}

# app_host ENV: public host name of hello-api in ENV.
app_host() {
  printf 'hello-api.%s.%s\n' "$1" "${DEMO_DOMAIN}"
}

# curl_gateway HOST PATH [CURL_ARGS...]: HTTPS request through the kind host port
# mapping, verified with the lab CA. Host and SNI stay HOST while the connection
# goes to 127.0.0.1:DEMO_HTTPS_PORT, so no DNS lookup is needed.
curl_gateway() {
  local host="$1" path="$2"
  shift 2
  curl --silent --show-error --fail --max-time 10 \
    --cacert "${DEMO_CA_FILE}" \
    --connect-to "${host}:443:127.0.0.1:${DEMO_HTTPS_PORT}" \
    "$@" "https://${host}${path}"
}

# fetch_lab_ca: writes the CA of the Gateway https certificate to DEMO_CA_FILE.
fetch_lab_ca() {
  local ref name ns
  ref="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o json |
    jq -r '[.spec.listeners[] | select(.protocol == "HTTPS") | .tls.certificateRefs[0]][0] | "\(.namespace // "")/\(.name)"')"
  ns="${ref%%/*}"
  name="${ref#*/}"
  [[ -n "${ns}" ]] || ns="${GATEWAY_NAMESPACE}"
  [[ -n "${name}" && "${name}" != "null" ]] || return 1
  kubectl -n "${ns}" get secret "${name}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"${DEMO_CA_FILE}.tmp" || return 1
  [[ -s "${DEMO_CA_FILE}.tmp" ]] || return 1
  mv "${DEMO_CA_FILE}.tmp" "${DEMO_CA_FILE}"
}
