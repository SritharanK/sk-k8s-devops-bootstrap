#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Brings up the lab profile on a local kind cluster (`make demo`).
#
#   1. kind cluster from kind/cluster.yaml (1 control plane, 2 workers), with
#      the node image that matches clusters/<cluster>/cluster.yaml.
#   2. Calico, so NetworkPolicies are enforced, and metrics-server, which
#      RKE2 ships by default.
#   3. hello-api image built from sample-services/hello-api and loaded into kind.
#   4. In-cluster Git server seeded from the local HEAD. Argo CD syncs from it,
#      so nothing is pushed to any hosted repository.
#   5. Argo CD through hack/argocd-install.sh, then the app of apps through
#      hack/bootstrap-gitops.sh, with the Git URL and revision overridden
#      through values.
#   6. Waits until every Application is Synced and Healthy, then calls
#      hello-api through the Gateway with the lab CA.
#
# Safe to re-run: every step converges on the existing cluster.
#
# Usage: hack/demo/up.sh [--until cluster|git|argocd|bootstrap]
# Settings: see hack/demo/lib.sh (DEMO_CLUSTER, DEMO_HTTP_PORT, DEMO_HTTPS_PORT,
# DEMO_TIMEOUT, DEMO_INCLUDE_DIRTY, KIND_NODE_IMAGE, ...).

# shellcheck source=hack/demo/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNTIL="all"

usage() {
  sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --until)
        [[ $# -ge 2 ]] || die "--until needs a value"
        UNTIL="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  case "${UNTIL}" in
    cluster | git | argocd | bootstrap | all) ;;
    *) die "--until must be one of cluster, git, argocd, bootstrap" ;;
  esac
}

step() {
  log_info "==> $*"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

preflight() {
  local mem want_kind have_kind
  require_cmd docker kind kubectl helm git jq yq curl
  docker info >/dev/null 2>&1 || die "Docker is not running or not reachable"
  mem="$(docker info --format '{{.MemTotal}}')"
  if ((mem < 6 * 1024 * 1024 * 1024)); then
    log_warn "Docker has $((mem / 1024 / 1024)) MiB of memory; the demo needs about 6 GiB"
  fi
  want_kind="$(yq -r '.kindVersion' "${REPO_ROOT}/kind/node-images.yaml")"
  have_kind="$(kind version | awk '{print $2}')"
  if [[ "${have_kind}" != "${want_kind}" ]]; then
    log_warn "kind ${have_kind} found, node images are pinned for kind ${want_kind}"
  fi
  mkdir -p "${DEMO_STATE_DIR}" "${DEMO_CACHE_DIR}"
}

# ---------------------------------------------------------------------------
# 1. kind cluster
# ---------------------------------------------------------------------------
render_kind_config() {
  local out="$1" minor image
  image="${KIND_NODE_IMAGE:-}"
  if [[ -z "${image}" ]]; then
    minor="$(cluster_config_get '.cluster.kubernetesMinor' '')"
    if [[ -n "${minor}" ]]; then
      image="$(yq -r ".images[\"${minor}\"] // \"\"" "${REPO_ROOT}/kind/node-images.yaml")"
      [[ -n "${image}" ]] || die "no pinned kind node image for Kubernetes ${minor} in kind/node-images.yaml"
    fi
  fi
  [[ "${DEMO_WORKERS}" =~ ^[0-2]$ ]] || die "DEMO_WORKERS must be 0, 1 or 2"
  NODE_IMAGE="${image}" yq '
      .name = strenv(DEMO_CLUSTER)
      | .nodes = ([.nodes[] | select(.role == "control-plane")] + [.nodes[] | select(.role == "worker")][0:'"${DEMO_WORKERS}"'])
      | (.nodes[] | select(strenv(NODE_IMAGE) != "") | .image) = strenv(NODE_IMAGE)
      | (.nodes[].extraPortMappings[]? | select(.containerPort == 30080) | .hostPort) = env(DEMO_HTTP_PORT)
      | (.nodes[].extraPortMappings[]? | select(.containerPort == 30443) | .hostPort) = env(DEMO_HTTPS_PORT)
    ' "${REPO_ROOT}/kind/cluster.yaml" >"${out}"
}

create_cluster() {
  local config="${DEMO_STATE_DIR}/kind-cluster.yaml" port
  if demo_cluster_exists; then
    log_info "kind cluster ${DEMO_CLUSTER} exists, reusing it"
  else
    for port in "${DEMO_HTTP_PORT}" "${DEMO_HTTPS_PORT}"; do
      if port_in_use "${port}"; then
        die "127.0.0.1:${port} is in use; free it or set DEMO_HTTP_PORT and DEMO_HTTPS_PORT"
      fi
    done
    render_kind_config "${config}"
    log_info "creating kind cluster ${DEMO_CLUSTER} with $(yq -r '.nodes[0].image' "${config}")"
    kind create cluster --name "${DEMO_CLUSTER}" --config "${config}" --kubeconfig "${DEMO_KUBECONFIG}"
  fi
  demo_use_kubeconfig
}

# ---------------------------------------------------------------------------
# 2. Calico
# ---------------------------------------------------------------------------
render_calico() {
  local src="$1" out="$2" pod_cidr
  pod_cidr="$(yq -r '.networking.podSubnet' "${REPO_ROOT}/kind/cluster.yaml")"
  # Uncomment CALICO_IPV4POOL_CIDR with the kind pod subnet, and let Felix
  # start on kind nodes, whose reverse path filter is in loose mode.
  awk -v cidr="${pod_cidr}" '
    /^ *# - name: CALICO_IPV4POOL_CIDR$/ {
      indent = $0; sub(/#.*/, "", indent)
      print indent "- name: CALICO_IPV4POOL_CIDR"
      getline
      print indent "  value: \"" cidr "\""
      print indent "- name: FELIX_IGNORELOOSERPF"
      print indent "  value: \"true\""
      next
    }
    { print }
  ' "${src}" >"${out}"
  grep -q "value: \"${pod_cidr}\"" "${out}" || die "could not set CALICO_IPV4POOL_CIDR in the Calico ${CALICO_VERSION} manifest"
}

install_cni() {
  local src="${DEMO_CACHE_DIR}/calico-${CALICO_VERSION}.yaml"
  local rendered="${DEMO_STATE_DIR}/calico.yaml"
  download_verified "${CALICO_MANIFEST_URL}" "${src}" "${CALICO_MANIFEST_SHA256}"
  render_calico "${src}" "${rendered}"
  log_info "applying Calico ${CALICO_VERSION}"
  kubectl apply --server-side --force-conflicts -f "${rendered}" >/dev/null
  kubectl -n kube-system rollout status daemonset/calico-node --timeout=10m
  kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=5m
  kubectl wait --for=condition=Ready node --all --timeout=5m
}

# kind kubelets serve a self-signed certificate, so metrics-server skips
# kubelet certificate verification on this throwaway cluster only.
install_metrics_server() {
  local src="${DEMO_CACHE_DIR}/metrics-server-${METRICS_SERVER_VERSION}.yaml"
  local rendered="${DEMO_STATE_DIR}/metrics-server.yaml"
  download_verified "${METRICS_SERVER_MANIFEST_URL}" "${src}" "${METRICS_SERVER_MANIFEST_SHA256}"
  awk '{ print } /^ *- --metric-resolution=/ { indent = $0; sub(/-.*/, "", indent); print indent "- --kubelet-insecure-tls" }' \
    "${src}" >"${rendered}"
  grep -q -- '--kubelet-insecure-tls' "${rendered}" || die "could not patch the metrics-server ${METRICS_SERVER_VERSION} manifest"
  log_info "applying metrics-server ${METRICS_SERVER_VERSION}"
  kubectl apply --server-side --force-conflicts -f "${rendered}" >/dev/null
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=5m
}

# ---------------------------------------------------------------------------
# 3. Source commit and hello-api image
# ---------------------------------------------------------------------------
SOURCE_COMMIT=""
IMAGE_REPOSITORY=""
IMAGE_TAG=""

resolve_source_commit() {
  local dirty=""
  SOURCE_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no)" ]]; then
    if [[ "${DEMO_INCLUDE_DIRTY}" == "1" ]]; then
      # A commit object of the working tree; no ref and no stash entry change.
      dirty="$(git -C "${REPO_ROOT}" stash create "demo: uncommitted changes")"
      [[ -n "${dirty}" ]] && SOURCE_COMMIT="${dirty}"
      log_info "publishing uncommitted changes of tracked files (DEMO_INCLUDE_DIRTY=1)"
    else
      log_warn "uncommitted changes are not published to the demo; commit them or set DEMO_INCLUDE_DIRTY=1"
    fi
  fi
  log_info "source commit ${SOURCE_COMMIT:0:12}"
}

build_and_load_image() {
  local context="${REPO_ROOT}/sample-services/hello-api" tree ref
  local -a build_args=()
  if [[ ! -f "${context}/Dockerfile" ]]; then
    log_warn "sample-services/hello-api/Dockerfile not found; hello-api keeps the image of its chart"
    return 0
  fi
  IMAGE_REPOSITORY="$(hello_api_repository)"
  tree="$(git -C "${REPO_ROOT}" rev-parse "${SOURCE_COMMIT}:sample-services/hello-api")"
  IMAGE_TAG="demo-${tree:0:12}"
  ref="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
  if docker image inspect "${ref}" >/dev/null 2>&1 && [[ "${DEMO_INCLUDE_DIRTY}" != "1" ]]; then
    log_info "image ${ref} already built"
  else
    # Attestation manifests make `kind load` fail with the containerd image
    # store of Docker Desktop; the demo image is local only.
    if docker build --help 2>/dev/null | grep -q -- '--provenance'; then
      build_args+=(--provenance=false --sbom=false)
    fi
    log_info "building ${ref}"
    docker build ${build_args[@]+"${build_args[@]}"} --tag "${ref}" \
      --build-arg "VERSION=${IMAGE_TAG}" --build-arg "REVISION=${SOURCE_COMMIT}" \
      "${context}"
  fi
  kind load docker-image --name "${DEMO_CLUSTER}" "${ref}"
  printf '%s\n' "${ref}" >"${DEMO_STATE_DIR}/hello-api-image"
}

# ---------------------------------------------------------------------------
# 4. In-cluster Git server
# ---------------------------------------------------------------------------
random_password() {
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

deploy_git_server() {
  local manifest="${REPO_ROOT}/hack/demo/manifests/git-server.yaml" password
  yq 'select(.kind == "Namespace")' "${manifest}" | kubectl apply -f - >/dev/null
  if ! kubectl -n "${DEMO_GIT_NAMESPACE}" get secret gitea-admin >/dev/null 2>&1; then
    password="$(random_password)"
    # Through stdin, so the password never appears on a command line.
    kubectl -n "${DEMO_GIT_NAMESPACE}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-admin
  labels:
    app.kubernetes.io/part-of: demo
type: Opaque
stringData:
  username: ${DEMO_GIT_OWNER}
  password: ${password}
EOF
  fi
  kubectl apply -f "${manifest}" >/dev/null
  kubectl -n "${DEMO_GIT_NAMESPACE}" rollout status deployment/gitea --timeout=5m
  # Creates the admin account once. Inside the pod the credential comes from
  # the Secret through environment variables.
  # shellcheck disable=SC2016 # expanded by the shell inside the pod
  kubectl -n "${DEMO_GIT_NAMESPACE}" exec deployment/gitea -- sh -c '
    cfg=/etc/gitea/app.ini
    if gitea --config "$cfg" admin user list --admin | awk "NR > 1 {print \$2}" | grep -qx "$GITEA_ADMIN_USERNAME"; then
      exit 0
    fi
    gitea --config "$cfg" admin user create --admin \
      --username "$GITEA_ADMIN_USERNAME" --password "$GITEA_ADMIN_PASSWORD" \
      --email "$GITEA_ADMIN_USERNAME@example.com" --must-change-password=false >/dev/null
  '
}

# Publishes SOURCE_COMMIT plus one commit that points the hello-api env values
# at the image loaded into kind: the local counterpart of the promotion step.
# The working tree of the repository is not touched; the edit happens in a
# clone under DEMO_STATE_DIR that shares the object store.
publish_repository() {
  local work="${DEMO_STATE_DIR}/git-publish" env file changed=0
  if [[ ! -d "${work}/.git" ]]; then
    git clone --quiet --shared --no-checkout "${REPO_ROOT}" "${work}"
  fi
  git -C "${work}" -c advice.detachedHead=false checkout --quiet --force --detach "${SOURCE_COMMIT}"
  for env in dev stage prod; do
    file="${work}/envs/${env}/hello-api/values.yaml"
    [[ -n "${IMAGE_TAG}" && -f "${file}" ]] || continue
    IMAGE_REPOSITORY="${IMAGE_REPOSITORY}" IMAGE_TAG="${IMAGE_TAG}" yq -i '
        .image.repository = strenv(IMAGE_REPOSITORY)
        | .image.tag = strenv(IMAGE_TAG)
        | .image.digest = ""
        | .image.pullPolicy = "IfNotPresent"
      ' "${file}"
    changed=1
  done
  if ((changed == 0)) && [[ -n "${IMAGE_TAG}" ]]; then
    log_warn "no envs/<env>/hello-api/values.yaml found; hello-api keeps its chart image"
  fi
  if [[ -n "$(git -C "${work}" status --porcelain)" ]]; then
    ensure_commit_identity "${work}"
    git -C "${work}" add --all envs
    git -C "${work}" -c commit.gpgsign=false commit --quiet --no-verify \
      -m "chore(demo): deploy hello-api ${IMAGE_TAG} built from ${SOURCE_COMMIT:0:12}"
  fi
  git_server_push "${work}" HEAD
  git -C "${work}" rev-parse HEAD >"${DEMO_STATE_DIR}/published-commit"
  log_info "published $(git -C "${work}" rev-parse --short=12 HEAD) to ${DEMO_GIT_URL} (${DEMO_GIT_BRANCH})"
}

# ---------------------------------------------------------------------------
# 5. Argo CD and the app of apps
# ---------------------------------------------------------------------------
require_script() {
  [[ -f "${REPO_ROOT}/$1" ]] || die "$1 not found; this demo needs it"
}

# Safe on every run: once Argo CD manages itself (Application argo-cd), the
# install script only waits for the rollouts. ARGOCD_REINSTALL=1 forces a
# recovery install; the variable passes through the environment.
install_argocd() {
  require_script hack/argocd-install.sh
  PROFILE="${DEMO_PROFILE}" CLUSTER="${DEMO_GITOPS_CLUSTER}" \
    bash "${REPO_ROOT}/hack/argocd-install.sh"
}

# The Git URL and revision reach the root Application as Helm values
# (valuesObject), so every child Application and AppProject follows them; no
# tracked file changes.
bootstrap_gitops() {
  require_script hack/bootstrap-gitops.sh
  REPO_URL="${DEMO_GIT_URL}" \
    TARGET_REVISION="${DEMO_GIT_BRANCH}" \
    SKIP_ARGOCD_INSTALL=1 \
    bash "${REPO_ROOT}/hack/bootstrap-gitops.sh" "${DEMO_GITOPS_CLUSTER}"
}

# toolchain_enabled NAME: true when the toolchain is enabled for the cluster,
# after merging argocd-bootstrap/values.yaml and the cluster definition the way
# the root Application does.
toolchain_enabled() {
  local cluster_file="${REPO_ROOT}/clusters/${DEMO_GITOPS_CLUSTER}/cluster.yaml"
  [[ -f "${REPO_ROOT}/argocd-bootstrap/values.yaml" && -f "${cluster_file}" ]] || return 1
  # shellcheck disable=SC2016 # $item is a yq variable
  [[ "$(NAME="$1" yq eval-all '. as $item ireduce ({}; . * $item) | .toolchains[strenv(NAME)].enabled // false' \
    "${REPO_ROOT}/argocd-bootstrap/values.yaml" "${cluster_file}")" == "true" ]]
}

# Inputs that optional toolchains expect before their first sync and that no
# lab component creates: the Grafana admin Secret of monitoring.
prepare_optional_toolchains() {
  local password
  toolchain_enabled monitoring || return 0
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged
YAML
  if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    password="$(random_password)"
    kubectl -n monitoring apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
type: Opaque
stringData:
  admin-user: admin
  admin-password: ${password}
YAML
    log_info "created Secret monitoring/grafana-admin"
  fi
}

# A re-run publishes a new commit; ask Argo CD to look now instead of at the
# next poll. A normal refresh, never a hard one.
refresh_applications() {
  local app
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 || return 0
  for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null); do
    kubectl -n argocd annotate "${app}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  done
}

# ---------------------------------------------------------------------------
# 6. Convergence and smoke test
# ---------------------------------------------------------------------------
applications_table() {
  kubectl -n argocd get applications.argoproj.io -o json | jq -r '
    ["WAVE", "APPLICATION", "SYNC", "HEALTH", "OPERATION"],
    (.items
      | sort_by((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0" | tonumber), .metadata.name)
      | .[]
      | [(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-"),
         .metadata.name,
         (.status.sync.status // "-"),
         (.status.health.status // "-"),
         (.status.operationState.phase // "-")])
    | @tsv' | column -t
}

# Prints the Applications that are not Synced and Healthy, or have an
# operation in progress. Empty output means converged.
applications_pending() {
  local json
  if ! json="$(kubectl -n argocd get applications.argoproj.io -o json 2>&1)"; then
    printf 'cannot list Applications: %s\n' "${json}"
    return 0
  fi
  jq -r '
    if (.items | length) == 0 then "no Applications yet"
    else
      .items[]
      | select(.status.sync.status != "Synced"
          or .status.health.status != "Healthy"
          or .status.operationState.phase == "Running")
      | "\(.metadata.name): sync=\(.status.sync.status // "-") health=\(.status.health.status // "-") operation=\(.status.operationState.phase // "-")"
    end' <<<"${json}"
}

wait_for_applications() {
  local start now pending last="" stable=0
  start="$(date +%s)"
  log_info "waiting up to ${DEMO_TIMEOUT}s for all Applications to be Synced and Healthy"
  while true; do
    pending="$(applications_pending)"
    if [[ -z "${pending}" ]]; then
      stable=$((stable + 1))
      if ((stable >= 3)); then
        log_info "all Applications are Synced and Healthy after $(($(date +%s) - start))s"
        applications_table >&2
        return 0
      fi
    else
      stable=0
      if [[ "${pending}" != "${last}" ]]; then
        log_info "pending after $(($(date +%s) - start))s:"$'\n'"${pending}"
        last="${pending}"
      fi
    fi
    now="$(date +%s)"
    if ((now - start >= DEMO_TIMEOUT)); then
      applications_table >&2 || true
      die "Applications did not converge within ${DEMO_TIMEOUT}s"
    fi
    sleep 10
  done
}

hello_api_reachable() {
  curl_gateway "$(app_host dev)" /readyz -o /dev/null 2>/dev/null
}

smoke_test() {
  local host
  host="$(app_host dev)"
  wait_until 300 5 "the lab CA in the Gateway certificate Secret" fetch_lab_ca
  wait_until 300 5 "https://${host} through the Gateway" hello_api_reachable
  log_info "GET https://${host}/ answered:"
  curl_gateway "${host}" / >&2 || true
  printf '\n' >&2
}

print_summary() {
  local https_suffix=""
  [[ "${DEMO_HTTPS_PORT}" == "443" ]] || https_suffix=":${DEMO_HTTPS_PORT}"
  cat <<EOF

The lab platform is running on kind cluster ${DEMO_CLUSTER}.

  export KUBECONFIG=${DEMO_KUBECONFIG}

  Argo CD     https://argocd.${DEMO_DOMAIN}${https_suffix}   (user: admin)
  Password    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  hello-api   https://$(app_host dev)${https_suffix}/
  Lab CA      ${DEMO_CA_FILE}
              curl --cacert ${DEMO_CA_FILE} https://$(app_host dev)${https_suffix}/
  Git server  kubectl -n ${DEMO_GIT_NAMESPACE} port-forward svc/${DEMO_GIT_SERVICE} 3000:3000
              then http://127.0.0.1:3000/${DEMO_GIT_OWNER}/${DEMO_GIT_REPO}

  Tests       make e2e   (or KEEP=1 hack/e2e/run.sh)
  Tear down   make demo-down

EOF
}

main() {
  local started
  parse_args "$@"
  started="$(date +%s)"
  preflight

  step "kind cluster"
  create_cluster
  step "CNI (Calico ${CALICO_VERSION})"
  install_cni
  install_metrics_server
  [[ "${UNTIL}" == "cluster" ]] && return 0

  step "hello-api image"
  resolve_source_commit
  build_and_load_image
  step "in-cluster Git server"
  deploy_git_server
  publish_repository
  [[ "${UNTIL}" == "git" ]] && return 0

  step "Argo CD (profile ${DEMO_PROFILE})"
  install_argocd
  [[ "${UNTIL}" == "argocd" ]] && return 0

  step "app of apps (clusters/${DEMO_GITOPS_CLUSTER})"
  prepare_optional_toolchains
  bootstrap_gitops
  refresh_applications
  [[ "${UNTIL}" == "bootstrap" ]] && return 0

  step "convergence"
  wait_for_applications
  step "smoke test through the Gateway"
  smoke_test
  log_info "demo ready in $(($(date +%s) - started))s"
  print_summary
}

main "$@"
