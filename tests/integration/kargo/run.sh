#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Integration test of the Kargo promotion pipeline on a local single-node kind
# cluster (it-kargo). What it proves and what it cannot prove: README.md next
# to this file.
#
# Usage:
#   tests/integration/kargo/run.sh
#
# Steps: start a local registry with self-signed TLS, create the cluster,
# push hello-api 0.1.0, start the in-cluster Git server of the demo
# (hack/demo/manifests/git-server.yaml), publish HEAD plus a test-only commit
# to it, bootstrap with hack/bootstrap-gitops.sh, then push hello-api 0.1.1
# and drive and check the promotions dev, stage and prod. The cluster and the
# registry are deleted at the end, also on failure. Exit 0 only when every
# check passed.
#
# Environment:
#   KEEP_CLUSTER      1 keeps the cluster and the registry after the run
#   MIN_FREE_GIB      free memory needed in the Docker VM (default: 5)
#   MEMORY_WAIT       seconds to wait for that memory (default: 0, fail at once)
#   PHASE_TIMEOUT     seconds per waiting phase (default: 1200)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
export REPO_ROOT
export DEMO_CLUSTER="it-kargo"
export DEMO_STATE_DIR="${REPO_ROOT}/_out/integration/kargo"
# shellcheck source=hack/demo/lib.sh
source "${REPO_ROOT}/hack/demo/lib.sh"

readonly TEST_DIR="${REPO_ROOT}/tests/integration/kargo"
readonly KIND_NAME="${DEMO_CLUSTER}"
readonly DEFINITION="kargo-test"
readonly ARGOCD_NS="argocd"
readonly PROJECT="kargo-hello-api"
readonly REGISTRY_NAME="it-kargo-registry"
readonly REGISTRY_IMAGE="docker.io/library/registry:3.1.2@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c"
readonly IMAGE_PATH="your-org/hello-api"
readonly IMAGE_REPO="${REGISTRY_NAME}:5000/${IMAGE_PATH}"
readonly GIT_API_REPO="${DEMO_GIT_OWNER}/${DEMO_GIT_REPO}"
# Renovate: datasource=helm registryUrl=https://kubernetes-sigs.github.io/metrics-server/ depName=metrics-server
readonly METRICS_SERVER_CHART_VERSION="3.14.0"

KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
MIN_FREE_GIB="${MIN_FREE_GIB:-5}"
MEMORY_WAIT="${MEMORY_WAIT:-0}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-1200}"

case "${1:-}" in
  -h | --help)
    sed -n '4,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) die "unknown argument: $1" 2 ;;
esac

require_cmd docker kind kubectl helm yq jq git openssl curl htpasswd

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
RESULTS=()
FAILURES=0

record() {
  local status="$1" name="$2" detail="${3:-}"
  RESULTS+=("${status}|${name}|${detail}")
  if [[ "$status" == PASS ]]; then
    log_info "PASS ${name}${detail:+ (${detail})}"
  else
    FAILURES=$((FAILURES + 1))
    log_error "FAIL ${name}${detail:+: ${detail}}"
  fi
}

# check NAME COMMAND...: records PASS when COMMAND succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then
    record PASS "$name"
  else
    record FAIL "$name"
  fi
}

print_results() {
  local line status name detail
  printf '\n%-6s %s\n' "RESULT" "CHECK" >&2
  for line in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r status name detail <<<"$line"
    printf '%-6s %s%s\n' "$status" "$name" "${detail:+ (${detail})}" >&2
  done
  printf '\n%d check(s), %d failed\n' "${#RESULTS[@]}" "$FAILURES" >&2
  mkdir -p "$DEMO_STATE_DIR"
  for line in ${RESULTS[@]+"${RESULTS[@]}"}; do printf '%s\n' "$line"; done >"${DEMO_STATE_DIR}/results.txt"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Free memory in the Docker VM in GiB (MemTotal minus the containers' usage).
docker_free_gib() {
  local total used
  total="$(docker info --format '{{.MemTotal}}')"
  used="$(docker stats --no-stream --format '{{.MemUsage}}' |
    awk '{u=$1; v=u+0; if (u ~ /GiB/) v=v*1024*1024*1024; else if (u ~ /MiB/) v=v*1024*1024; else if (u ~ /[kK]i?B/) v=v*1024; s+=v} END {printf "%.0f", s}')"
  awk -v t="$total" -v u="${used:-0}" 'BEGIN {printf "%.1f", (t - u) / 1024 / 1024 / 1024}'
}

memory_ok() { awk -v f="$(docker_free_gib)" -v m="$MIN_FREE_GIB" 'BEGIN {exit !(f >= m)}'; }

kargo_json() { # kargo_json KIND
  kubectl -n "$PROJECT" get "$1" -o json 2>/dev/null || echo '{"items": []}'
}

# freight_by_tag TAG: name of the Freight whose image has TAG.
freight_by_tag() {
  kargo_json freight.kargo.akuity.io | jq -r --arg t "$1" '[.items[] | select(.images[0].tag == $t) | .metadata.name][0] // empty'
}

freight_exists() { [[ -n "$(freight_by_tag "$1")" ]]; }

freight_digest() { # freight_digest NAME
  kubectl -n "$PROJECT" get freight.kargo.akuity.io "$1" -o jsonpath='{.images[0].digest}'
}

freight_verified_in() { # freight_verified_in NAME STAGE
  [[ "$(kubectl -n "$PROJECT" get freight.kargo.akuity.io "$1" -o json | jq -r --arg s "$2" '.status.verifiedIn | has($s)')" == true ]]
}

# promotion_phase STAGE FREIGHT: phase of the newest Promotion of FREIGHT to STAGE.
promotion_phase() {
  kargo_json promotions.kargo.akuity.io | jq -r --arg s "$1" --arg f "$2" '
    [.items[] | select(.spec.stage == $s and .spec.freight == $f)]
    | sort_by(.metadata.creationTimestamp) | last | .status.phase // empty'
}

promotion_succeeded() { [[ "$(promotion_phase "$1" "$2")" == Succeeded ]]; }

promotions_for_stage() { # promotions_for_stage STAGE: number of Promotions
  kargo_json promotions.kargo.akuity.io | jq --arg s "$1" '[.items[] | select(.spec.stage == $s)] | length'
}

# verification_phase STAGE: phase of the newest verification of the current Freight.
verification_phase() {
  kubectl -n "$PROJECT" get stage.kargo.akuity.io "$1" -o json |
    jq -r '.status.freightHistory[0].verificationHistory[0].phase // empty'
}

stage_verified() { [[ "$(verification_phase "$1")" == Successful ]]; }

# promote STAGE FREIGHT: creates a Promotion, as `kargo promote` does. The
# Kargo webhook replaces the name with <stage>.<id>.<freight>.
promote() {
  kubectl -n "$PROJECT" create -f - >/dev/null <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  name: $1.manual-$(date +%s)
  namespace: ${PROJECT}
spec:
  stage: $1
  freight: $2
EOF
}

deployment_image() { # deployment_image NAMESPACE
  kubectl -n "$1" get deployment hello-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

deployment_runs() { # deployment_runs NAMESPACE DIGEST: rolled out with that digest
  [[ "$(deployment_image "$1")" == *"@$2" ]] &&
    kubectl -n "$1" rollout status deployment/hello-api --timeout=5s >/dev/null 2>&1
}

app_field() { # app_field NAME JQ
  kubectl -n "$ARGOCD_NS" get application "$1" -o json 2>/dev/null | jq -r "$2"
}

# app_at_revision NAME SHA: Synced and Healthy with every source at SHA.
app_at_revision() {
  kubectl -n "$ARGOCD_NS" get application "$1" -o json 2>/dev/null | jq -e --arg r "$2" '
    (.status.sync.status == "Synced") and (.status.health.status == "Healthy")
    and ((.status.sync.revisions // [.status.sync.revision]) | all(. == $r))' >/dev/null
}

# ---------------------------------------------------------------------------
# In-cluster Git server (read through one port-forward)
# ---------------------------------------------------------------------------
GIT_PORT=""

git_api() { # git_api METHOD PATH [BODY]: Gitea API call as the admin user
  local auth
  auth="$(printf '%s:%s' "$GIT_USER" "$GIT_PASSWORD" | base64 | tr -d '\n')"
  curl -fsS -X "$1" -H "Content-Type: application/json" -H @- \
    "http://127.0.0.1:${GIT_PORT}/api/v1/repos/${GIT_API_REPO}$2" ${3:+--data "$3"} \
    <<<"Authorization: Basic ${auth}"
}

git_file() { # git_file PATH: content on the main branch
  curl -fsS "http://127.0.0.1:${GIT_PORT}/api/v1/repos/${GIT_API_REPO}/raw/$1?ref=${DEMO_GIT_BRANCH}"
}

git_head() { git_api GET "/branches/${DEMO_GIT_BRANCH}" | jq -r '.commit.id'; }

values_of() { # values_of ENV: "tag digest" in envs/ENV/hello-api/values.yaml on main
  git_file "envs/$1/hello-api/values.yaml" | yq -r '.image.tag + " " + .image.digest'
}

# ---------------------------------------------------------------------------
# 1. Registry and cluster
# ---------------------------------------------------------------------------
create_cluster() {
  local node
  if kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"; then
    log_info "deleting the leftover cluster ${KIND_NAME}"
    kind delete cluster --name "$KIND_NAME" >/dev/null
  fi
  if ! memory_ok; then
    log_info "waiting up to ${MEMORY_WAIT}s for ${MIN_FREE_GIB} GiB free in the Docker VM ($(docker_free_gib) GiB free)"
    wait_until "$MEMORY_WAIT" 30 "free memory in the Docker VM" memory_ok ||
      die "not enough free memory in the Docker VM: $(docker_free_gib) GiB, need ${MIN_FREE_GIB} GiB"
  fi
  mkdir -p "$DEMO_STATE_DIR"
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    add_cleanup "kind delete cluster --name ${KIND_NAME} >/dev/null 2>&1 || true"
  fi
  log_info "creating kind cluster ${KIND_NAME} (one node, Kubernetes 1.36)"
  kind create cluster --config "${TEST_DIR}/kind.yaml" --kubeconfig "$DEMO_KUBECONFIG" --wait 300s >/dev/null
  export KUBECONFIG="$DEMO_KUBECONFIG"
  # containerd reads registry hosts from certs.d (kind.yaml). Test-only: the
  # registry certificate is self-signed.
  for node in $(kind get nodes --name "$KIND_NAME"); do
    docker exec -i "$node" sh -c "mkdir -p '/etc/containerd/certs.d/${REGISTRY_NAME}:5000' && cat > '/etc/containerd/certs.d/${REGISTRY_NAME}:5000/hosts.toml'" <<EOF
server = "https://${REGISTRY_NAME}:5000"

[host."https://${REGISTRY_NAME}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
  done
}

start_registry() {
  local certs="${DEMO_STATE_DIR}/registry-certs"
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  rm -rf "$certs"
  mkdir -p "$certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${REGISTRY_NAME}" \
    -addext "subjectAltName=DNS:${REGISTRY_NAME},DNS:localhost,IP:127.0.0.1" \
    -keyout "${certs}/tls.key" -out "${certs}/tls.crt" >/dev/null 2>&1
  # The kind network exists once the cluster does. docker cp instead of a bind
  # mount: the repository may live outside the paths Docker Desktop shares.
  docker create --name "$REGISTRY_NAME" --network kind -p 127.0.0.1::5000 \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/tls.crt -e REGISTRY_HTTP_TLS_KEY=/certs/tls.key \
    "$REGISTRY_IMAGE" >/dev/null
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    add_cleanup "docker rm -f ${REGISTRY_NAME} >/dev/null 2>&1 || true"
  fi
  docker cp "${certs}/." "${REGISTRY_NAME}:/certs" >/dev/null
  docker start "$REGISTRY_NAME" >/dev/null
  REGISTRY_PORT="$(docker port "$REGISTRY_NAME" 5000/tcp | head -n1 | awk -F: '{print $NF}')"
  [[ -n "$REGISTRY_PORT" ]] || die "registry ${REGISTRY_NAME} has no published port"
  wait_until 60 2 "the registry" curl -fsSk "https://127.0.0.1:${REGISTRY_PORT}/v2/" -o /dev/null
  log_info "registry ${REGISTRY_NAME}:5000 (host port ${REGISTRY_PORT})"
}

# RKE2 ships metrics-server; kind does not. Without it the hello-api
# HorizontalPodAutoscaler in prod reports Degraded.
install_metrics_server() {
  log_info "installing metrics-server chart ${METRICS_SERVER_CHART_VERSION}"
  helm upgrade --install metrics-server metrics-server \
    --repo https://kubernetes-sigs.github.io/metrics-server/ --version "$METRICS_SERVER_CHART_VERSION" \
    --namespace kube-system --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null
}

# ---------------------------------------------------------------------------
# 2. hello-api releases
# ---------------------------------------------------------------------------
build_images() {
  local version args=()
  if docker build --help 2>/dev/null | grep -q -- '--provenance'; then
    args=(--provenance=false --sbom=false)
  fi
  for version in 0.1.0 0.1.1; do
    log_info "building hello-api ${version}"
    docker build ${args[@]+"${args[@]}"} --quiet --build-arg "VERSION=${version}" \
      --tag "${IMAGE_REPO}:${version}" "${REPO_ROOT}/sample-services/hello-api" >/dev/null
  done
}

# Pushes from the kind node, which reaches the registry on the kind network.
# The Docker daemon of Docker Desktop runs in a VM and cannot reach a port
# published on the host's loopback address.
push_release() { # push_release VERSION
  local node
  node="$(kind get nodes --name "$KIND_NAME" | head -n1)"
  kind load docker-image --name "$KIND_NAME" "${IMAGE_REPO}:$1" >/dev/null
  docker exec "$node" ctr -n k8s.io images push --local --skip-verify "${IMAGE_REPO}:$1" >/dev/null
  log_info "pushed ${IMAGE_REPO}:$1 ($(registry_digest "$1"))"
}

registry_digest() { # registry_digest TAG: manifest digest as the registry serves it
  curl -fsSkI \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://127.0.0.1:${REGISTRY_PORT}/v2/${IMAGE_PATH}/manifests/$1" |
    awk 'tolower($1) == "docker-content-digest:" {print $2}' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# 3. Git server and the published repository
# ---------------------------------------------------------------------------
deploy_git_server() {
  local manifest="${REPO_ROOT}/hack/demo/manifests/git-server.yaml"
  yq 'select(.kind == "Namespace")' "$manifest" | kubectl apply -f - >/dev/null
  GIT_USER="$DEMO_GIT_OWNER"
  GIT_PASSWORD="$(openssl rand -hex 24)"
  # Through stdin, so the password never appears on a command line.
  kubectl -n "$DEMO_GIT_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-admin
type: Opaque
stringData:
  username: ${GIT_USER}
  password: ${GIT_PASSWORD}
EOF
  kubectl apply -f "$manifest" >/dev/null
  kubectl -n "$DEMO_GIT_NAMESPACE" rollout status deployment/gitea --timeout=5m >/dev/null
  # shellcheck disable=SC2016 # expanded by the shell inside the pod
  kubectl -n "$DEMO_GIT_NAMESPACE" exec deployment/gitea -- sh -c '
    cfg=/etc/gitea/app.ini
    gitea --config "$cfg" admin user list --admin | awk "NR > 1 {print \$2}" | grep -qx "$GITEA_ADMIN_USERNAME" && exit 0
    gitea --config "$cfg" admin user create --admin \
      --username "$GITEA_ADMIN_USERNAME" --password "$GITEA_ADMIN_PASSWORD" \
      --email "$GITEA_ADMIN_USERNAME@example.com" --must-change-password=false >/dev/null
  '
  # Kargo calls the Gitea API with a token (git-open-pr, git-wait-for-pr) and
  # uses the same token as the HTTP password for clone and push.
  # shellcheck disable=SC2016 # expanded by the shell inside the pod
  KARGO_GIT_TOKEN="$(kubectl -n "$DEMO_GIT_NAMESPACE" exec deployment/gitea -- sh -c '
    gitea --config /etc/gitea/app.ini admin user generate-access-token \
      --username "$GITEA_ADMIN_USERNAME" --token-name "kargo-$(date +%s)" \
      --scopes write:repository --raw')"
  [[ -n "$KARGO_GIT_TOKEN" ]] || die "could not create a Gitea access token for Kargo"
  start_port_forward GIT_PORT "$DEMO_GIT_NAMESPACE" "svc/${DEMO_GIT_SERVICE}" 3000
}

publish_repository() {
  local env
  WORK="${DEMO_STATE_DIR}/repo"
  rm -rf "$WORK"
  git clone --quiet --shared --no-checkout "$REPO_ROOT" "$WORK"
  git -C "$WORK" -c advice.detachedHead=false checkout --quiet --force --detach HEAD
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    log_warn "uncommitted changes are not part of the test; it runs $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  fi
  ensure_commit_identity "$WORK"
  # Test-only commit: the cluster definition and release 0.1.0 by tag in every
  # environment, so every Application is healthy before Kargo acts.
  mkdir -p "${WORK}/clusters/${DEFINITION}"
  cp "${TEST_DIR}/cluster.yaml" "${WORK}/clusters/${DEFINITION}/cluster.yaml"
  for env in dev stage prod; do
    yq -i '.image.tag = "0.1.0" | .image.digest = ""' "${WORK}/envs/${env}/hello-api/values.yaml"
  done
  git -C "$WORK" add --all
  git -C "$WORK" -c commit.gpgsign=false commit --quiet --no-verify \
    -m "test: kargo integration fixture (cluster ${DEFINITION}, release 0.1.0)"
  git_server_push "$WORK" HEAD
  log_info "published $(git -C "$WORK" rev-parse --short=12 HEAD) to ${DEMO_GIT_URL}"
}

# ---------------------------------------------------------------------------
# 4. Platform inputs that the lab profile expects, then the bootstrap
# ---------------------------------------------------------------------------
prepare_inputs() {
  local password hash
  kubectl apply -f "${TEST_DIR}/manifests/prometheus-stub.yaml" >/dev/null
  # The lab profile reads the Kargo admin account from Secret kargo/kargo-api
  # (a SealedSecret in a real lab). Test-only: created directly, random
  # password, never printed.
  kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  password="$(openssl rand -hex 16)"
  hash="$(htpasswd -nbBC 10 "" "$password" | tr -d ':\n')"
  kubectl -n kargo apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kargo-api
type: Opaque
stringData:
  ADMIN_ACCOUNT_PASSWORD_HASH: '${hash}'
  ADMIN_ACCOUNT_TOKEN_SIGNING_KEY: $(openssl rand -hex 32)
EOF
}

bootstrap() {
  log_info "bootstrapping cluster definition ${DEFINITION} through hack/bootstrap-gitops.sh"
  REPO_ROOT="$WORK" REPO_URL="$DEMO_GIT_URL" TARGET_REVISION="$DEMO_GIT_BRANCH" WAIT=0 \
    bash "${WORK}/hack/bootstrap-gitops.sh" "$DEFINITION"
}

# The Git credential of every Kargo Project, in the shared resources namespace
# that the kargo chart creates (a SealedSecret or an ExternalSecret outside
# this test).
create_git_credential() {
  wait_until "$PHASE_TIMEOUT" 10 "namespace kargo-shared-resources" \
    kubectl get namespace kargo-shared-resources -o name >/dev/null 2>&1
  kubectl -n kargo-shared-resources apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kargo-git
  labels:
    kargo.akuity.io/cred-type: git
type: Opaque
stringData:
  repoURL: ${DEMO_GIT_URL}
  username: ${GIT_USER}
  password: ${KARGO_GIT_TOKEN}
EOF
}

unconverged_apps() {
  kubectl -n "$ARGOCD_NS" get applications -o json 2>/dev/null | jq -r '
    if (.items | length) == 0 then "no Applications yet"
    else .items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
      | "\(.metadata.name)=\(.status.sync.status // "-")/\(.status.health.status // "-")"
    end' | tr '\n' ' '
}

all_apps_healthy() { [[ -z "$(unconverged_apps)" ]]; }

wait_for_platform() {
  log_info "waiting up to ${PHASE_TIMEOUT}s for every Application to be Synced and Healthy"
  if ! wait_until "$PHASE_TIMEOUT" 15 "all Applications Synced and Healthy" all_apps_healthy; then
    log_error "not converged: $(unconverged_apps)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_kargo_restricted() {
  local ns_level not_ready
  ns_level="$(kubectl get namespace kargo -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  not_ready="$(kubectl -n kargo get pods -o json | jq -r '[.items[] | select(.status.phase != "Succeeded")
    | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0) | .metadata.name] | join(" ")')"
  if [[ "$ns_level" == restricted && -z "$not_ready" ]]; then
    record PASS "Kargo runs under Pod Security restricted" "namespace kargo enforce=restricted, all pods Ready"
  else
    record FAIL "Kargo runs under Pod Security restricted" "enforce=${ns_level:-none}, not ready: ${not_ready:-none}"
  fi
}

check_authorization() {
  local env value bad=""
  for env in dev stage prod; do
    value="$(app_field "hello-api-${env}" '.metadata.annotations["kargo.akuity.io/authorized-stage"] // ""')"
    [[ "$value" == "${PROJECT}:${env}" ]] || bad+=" hello-api-${env}=${value:-none}"
  done
  if [[ -z "$bad" ]]; then
    record PASS "Applications authorize their Kargo Stage" "kargo.akuity.io/authorized-stage on hello-api-{dev,stage,prod}"
  else
    record FAIL "Applications authorize their Kargo Stage" "$bad"
  fi
}

check_discovery() { # check_discovery TAG VAR: stores the Freight name in VAR
  local tag="$1" var="$2" name want have
  want="$(registry_digest "$tag")"
  if wait_until "$PHASE_TIMEOUT" 10 "Freight for ${tag}" freight_exists "$tag"; then
    name="$(freight_by_tag "$tag")"
    have="$(freight_digest "$name")"
    printf -v "$var" '%s' "$name"
    if [[ "$have" == "$want" ]]; then
      record PASS "Warehouse discovers ${tag}" "Freight ${name}, digest ${have}"
      return 0
    fi
    record FAIL "Warehouse discovers ${tag}" "Freight digest ${have}, registry digest ${want}"
  else
    record FAIL "Warehouse discovers ${tag}" "no Freight within ${PHASE_TIMEOUT}s"
  fi
  return 1
}

# check_promotion STAGE FREIGHT TAG HOW: the promotion succeeds, the commit
# changes only image.tag and image.digest of envs/STAGE/hello-api, Argo CD
# runs the digest, and verification passes.
check_promotion() {
  local stage="$1" freight="$2" tag="$3" how="$4" digest head values subject changed
  digest="$(freight_digest "$freight")"
  if ! wait_until "$PHASE_TIMEOUT" 10 "Promotion of ${tag} to ${stage}" promotion_succeeded "$stage" "$freight"; then
    record FAIL "${stage}: ${how} promotion of ${tag}" "phase $(promotion_phase "$stage" "$freight"): $(kargo_json promotions.kargo.akuity.io | jq -r --arg s "$stage" '[.items[] | select(.spec.stage == $s)] | last | .status.message // ""')"
    return 1
  fi
  record PASS "${stage}: ${how} promotion of ${tag}" "Promotion Succeeded"

  head="$(git_head)"
  values="$(values_of "$stage")"
  subject="$(git_api GET "/git/commits/${head}" | jq -r '.commit.message' | head -n1)"
  changed="$(git_api GET "/git/commits/${head}?stat=true&files=true" | jq -r '[.files[]?.filename] | join(" ")')"
  if [[ "$values" == "${tag} ${digest}" && ("$subject" == "chore(promote): hello-api ${tag} to ${stage}" || "$how" == "pull request") ]]; then
    record PASS "${stage}: commit lands in Git" "${head:0:12} '${subject}' changes ${changed:-?}; values ${values}"
  else
    record FAIL "${stage}: commit lands in Git" "head ${head:0:12} '${subject}', values '${values}'"
  fi

  if wait_until 300 10 "Argo CD sync of hello-api-${stage}" app_at_revision "hello-api-${stage}" "$head" &&
    wait_until 300 10 "rollout of ${digest} in ${stage}" deployment_runs "$stage" "$digest"; then
    record PASS "${stage}: Argo CD runs the new digest" "hello-api-${stage} Synced and Healthy at ${head:0:12}, image $(deployment_image "$stage")"
  else
    record FAIL "${stage}: Argo CD runs the new digest" "image $(deployment_image "$stage"), app $(app_field "hello-api-${stage}" '"\(.status.sync.status)/\(.status.health.status) \(.status.sync.revisions // .status.sync.revision)"')"
  fi

  if wait_until 600 15 "verification in ${stage}" stage_verified "$stage" &&
    wait_until 60 5 "Freight verified in ${stage}" freight_verified_in "$freight" "$stage"; then
    record PASS "${stage}: verification passes" "success-rate AnalysisRun Successful, Freight verified in ${stage}"
  else
    record FAIL "${stage}: verification passes" "verification phase $(verification_phase "$stage")"
  fi
}

check_no_auto_promotion() { # check_no_auto_promotion STAGE SECONDS
  local stage="$1" seconds="$2" before
  before="$(values_of "$stage")"
  sleep "$seconds"
  if [[ "$(promotions_for_stage "$stage")" == 0 && "$(values_of "$stage")" == "$before" ]]; then
    record PASS "${stage}: no automatic promotion" "no Promotion and unchanged values ${before} ${seconds}s after Freight was verified upstream"
  else
    record FAIL "${stage}: no automatic promotion" "$(promotions_for_stage "$stage") Promotion(s), values $(values_of "$stage")"
  fi
}

pr_number() { git_api GET "/pulls?state=open" | jq -r '.[0].number // empty'; }

check_prod_pull_request() { # check_prod_pull_request FREIGHT TAG
  local freight="$1" tag="$2" before number phase
  before="$(values_of prod)"
  promote prod "$freight"
  wait_until 300 10 "the prod pull request" pr_open || true
  number="$(pr_number)"
  phase="$(promotion_phase prod "$freight")"
  if [[ -n "$number" && "$phase" == Running && "$(values_of prod)" == "$before" ]]; then
    record PASS "prod: promotion opens a pull request and waits" "pull request #${number} open, Promotion Running, main unchanged"
  else
    record FAIL "prod: promotion opens a pull request and waits" "pull request '${number}', phase '${phase}', values $(values_of prod)"
    return 1
  fi
  git_api POST "/pulls/${number}/merge" '{"Do": "merge", "delete_branch_after_merge": true}' >/dev/null
  log_info "merged pull request #${number} as a code owner would"
  check_promotion prod "$freight" "$tag" "pull request"
}

pr_open() { [[ -n "$(pr_number)" ]]; }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local f0 f1
  add_cleanup print_results
  create_cluster
  start_registry
  install_metrics_server
  build_images
  push_release 0.1.0
  deploy_git_server
  publish_repository
  prepare_inputs
  bootstrap
  create_git_credential
  wait_for_platform || record FAIL "platform converges" "$(unconverged_apps)"

  check_kargo_restricted
  check_authorization

  # Release 0.1.0: discovered, auto-promoted to dev, verified.
  check_discovery 0.1.0 f0 || return 1
  check_promotion dev "$f0" 0.1.0 automatic

  # Release 0.1.1.
  push_release 0.1.1
  kubectl -n "$PROJECT" annotate warehouse.kargo.akuity.io hello-api "kargo.akuity.io/refresh=$(date +%s)" --overwrite >/dev/null
  check_discovery 0.1.1 f1 || return 1
  check_promotion dev "$f1" 0.1.1 automatic

  # stage waits for a person; a manual promotion then works.
  check_no_auto_promotion stage 90
  promote stage "$f1"
  check_promotion stage "$f1" 0.1.1 manual

  # prod goes through a pull request.
  check_prod_pull_request "$f1" 0.1.1
}

main "$@"
((FAILURES == 0)) || die "${FAILURES} check(s) failed"
log_info "all checks passed"
