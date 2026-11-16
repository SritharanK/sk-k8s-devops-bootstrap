#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Integration test of the reference profile on a local three-node kind cluster
# (it-reference). What it proves and what it cannot prove: README.md next to this
# file.
#
# Usage:
#   tests/integration/reference/run.sh
#
# Steps: create the cluster, build and load hello-api, start an in-cluster Git
# server, publish HEAD plus test-only commits to it, bootstrap with
# hack/bootstrap-gitops.sh, initialise and unseal OpenBao, then run the checks.
# The cluster is deleted at the end, also on failure. Exit 0 only when every
# check passed.
#
# Environment:
#   KEEP_CLUSTER      1 keeps the cluster after the run (default: delete it)
#   MIN_FREE_GIB      free memory needed in the Docker VM (default: 6)
#   MEMORY_WAIT       seconds to wait for that memory (default: 0, fail at once)
#   PHASE_TIMEOUT     seconds per waiting phase (default: 1500)

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/common.sh"

readonly TEST_DIR="${REPO_ROOT}/tests/integration/reference"
readonly KIND_NAME="it-reference"
readonly DEFINITION="ref-test"
readonly STATE_DIR="${REPO_ROOT}/_out/integration/reference"
readonly GIT_NS="ref-git"
readonly GIT_OWNER="ref"
readonly GIT_REPO="sk-k8s-devops-bootstrap"
readonly GIT_BRANCH="main"
readonly GIT_URL="http://gitea-http.${GIT_NS}.svc.cluster.local:3000/${GIT_OWNER}/${GIT_REPO}.git"
readonly ARGOCD_NS="argocd"
readonly IMAGE_REPO="ghcr.io/your-org/hello-api"
# Renovate: datasource=helm registryUrl=https://kubernetes-sigs.github.io/metrics-server/ depName=metrics-server
readonly METRICS_SERVER_CHART_VERSION="3.14.0"

KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
MIN_FREE_GIB="${MIN_FREE_GIB:-6}"
MEMORY_WAIT="${MEMORY_WAIT:-0}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-1500}"

usage() {
  sed -n '4,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *) die "unknown argument: $1" 2 ;;
esac

require_cmd docker kind kubectl helm yq jq git openssl

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
  if [[ -d "$STATE_DIR" ]]; then
    for line in ${RESULTS[@]+"${RESULTS[@]}"}; do printf '%s\n' "$line"; done >"${STATE_DIR}/results.txt"
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
wait_until() {
  local timeout="$1" interval="$2" what="$3" start=$SECONDS
  shift 3
  until "$@"; do
    if ((SECONDS - start >= timeout)); then
      log_error "timed out after ${timeout}s waiting for ${what}"
      return 1
    fi
    sleep "$interval"
  done
}

app_field() { # app_field NAME JQ
  kubectl -n "$ARGOCD_NS" get application "$1" -o json 2>/dev/null | jq -r "$2"
}

app_exists() { kubectl -n "$ARGOCD_NS" get application "$1" >/dev/null 2>&1; }

refresh_app() {
  kubectl -n "$ARGOCD_NS" annotate application "$1" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

deployment_image() { # deployment_image NAMESPACE NAME
  kubectl -n "$1" get deployment "$2" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

# Free memory in the Docker VM in GiB (MemTotal minus the containers' usage).
docker_free_gib() {
  local total used
  total="$(docker info --format '{{.MemTotal}}')"
  used="$(docker stats --no-stream --format '{{.MemUsage}}' |
    awk '{u=$1; v=u+0; if (u ~ /GiB/) v=v*1024*1024*1024; else if (u ~ /MiB/) v=v*1024*1024; else if (u ~ /[kK]i?B/) v=v*1024; s+=v} END {printf "%.0f", s}')"
  awk -v t="$total" -v u="${used:-0}" 'BEGIN {printf "%.1f", (t - u) / 1024 / 1024 / 1024}'
}

memory_ok() { awk -v f="$(docker_free_gib)" -v m="$MIN_FREE_GIB" 'BEGIN {exit !(f >= m)}'; }

start_port_forward() { # start_port_forward VAR NAMESPACE TARGET REMOTE_PORT
  local _var="$1" _ns="$2" _target="$3" _remote="$4" _log _pid _port="" _i
  _log="${STATE_DIR}/port-forward-${_ns}-${_remote}.log"
  kubectl -n "$_ns" port-forward "$_target" ":${_remote}" --address 127.0.0.1 >"$_log" 2>&1 &
  _pid=$!
  add_cleanup "kill ${_pid} 2>/dev/null || true"
  for _i in $(seq 1 60); do
    _port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$_log" | head -n1)"
    [[ -n "$_port" ]] && break
    kill -0 "$_pid" 2>/dev/null || break
    sleep 0.5
  done
  [[ -n "$_port" ]] || die "port-forward to ${_ns}/${_target}:${_remote} failed"
  printf -v "$_var" '%s' "$_port"
}

# ---------------------------------------------------------------------------
# 1. Cluster
# ---------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"; then
    log_info "deleting the leftover cluster ${KIND_NAME}"
    kind delete cluster --name "$KIND_NAME" >/dev/null
  fi
  if ! memory_ok; then
    log_info "waiting up to ${MEMORY_WAIT}s for ${MIN_FREE_GIB} GiB free in the Docker VM ($(docker_free_gib) GiB free)"
    wait_until "$MEMORY_WAIT" 30 "free memory in the Docker VM" memory_ok ||
      die "not enough free memory in the Docker VM: $(docker_free_gib) GiB, need ${MIN_FREE_GIB} GiB"
  fi
  mkdir -p "$STATE_DIR"
  export KUBECONFIG="${STATE_DIR}/kubeconfig"
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    add_cleanup "kind delete cluster --name ${KIND_NAME} >/dev/null 2>&1 || true"
  fi
  log_info "creating kind cluster ${KIND_NAME} (1 control plane, 2 workers, Kubernetes 1.36)"
  kind create cluster --config "${TEST_DIR}/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 300s >/dev/null
  # Like RKE2 servers, every node runs workloads: redis-ha and the OpenBao
  # Raft voters spread over three nodes with hard anti-affinity.
  kubectl taint node "${KIND_NAME}-control-plane" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null
}

# RKE2 ships metrics-server (rke2-metrics-server); kind does not. Without it
# the hello-api HorizontalPodAutoscaler in prod reports Degraded. kind's
# kubelets serve self-signed certificates, hence --kubelet-insecure-tls.
install_metrics_server() {
  log_info "installing metrics-server chart ${METRICS_SERVER_CHART_VERSION} (part of RKE2, missing in kind)"
  helm upgrade --install metrics-server metrics-server \
    --repo https://kubernetes-sigs.github.io/metrics-server/ --version "$METRICS_SERVER_CHART_VERSION" \
    --namespace kube-system --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null
}

# ---------------------------------------------------------------------------
# 2. hello-api image (unsigned, loaded into the nodes)
# ---------------------------------------------------------------------------
build_image() {
  local short
  short="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  TAG_A="ref-${short}"
  TAG_B="ref-${short}-b"
  log_info "building ${IMAGE_REPO}:${TAG_A}"
  local args=()
  if docker build --help 2>/dev/null | grep -q -- '--provenance'; then
    args=(--provenance=false --sbom=false)
  fi
  docker build ${args[@]+"${args[@]}"} --quiet --tag "${IMAGE_REPO}:${TAG_A}" \
    "${REPO_ROOT}/sample-services/hello-api" >/dev/null
  docker tag "${IMAGE_REPO}:${TAG_A}" "${IMAGE_REPO}:${TAG_B}"
  kind load docker-image --name "$KIND_NAME" "${IMAGE_REPO}:${TAG_A}" "${IMAGE_REPO}:${TAG_B}" >/dev/null
}

# ---------------------------------------------------------------------------
# 3. In-cluster Git server and the published repository
# ---------------------------------------------------------------------------
deploy_git_server() {
  local manifest="${TEST_DIR}/manifests/git-server.yaml" password
  yq 'select(.kind == "Namespace")' "$manifest" | kubectl apply -f - >/dev/null
  password="$(openssl rand -hex 24)"
  # Through stdin, so the password never appears on a command line.
  kubectl -n "$GIT_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-admin
type: Opaque
stringData:
  username: ${GIT_OWNER}
  password: ${password}
EOF
  kubectl apply -f "$manifest" >/dev/null
  kubectl -n "$GIT_NS" rollout status deployment/gitea --timeout=5m >/dev/null
  # shellcheck disable=SC2016 # expanded by the shell inside the pod
  kubectl -n "$GIT_NS" exec deployment/gitea -- sh -c '
    cfg=/etc/gitea/app.ini
    gitea --config "$cfg" admin user list --admin | awk "NR > 1 {print \$2}" | grep -qx "$GITEA_ADMIN_USERNAME" && exit 0
    gitea --config "$cfg" admin user create --admin \
      --username "$GITEA_ADMIN_USERNAME" --password "$GITEA_ADMIN_PASSWORD" \
      --email "$GITEA_ADMIN_USERNAME@example.com" --must-change-password=false >/dev/null
  '
}

git_push() { # pushes HEAD of the work clone to the Git server
  local user password auth port
  user="$(kubectl -n "$GIT_NS" get secret gitea-admin -o jsonpath='{.data.username}' | base64 -d)"
  password="$(kubectl -n "$GIT_NS" get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d)"
  auth="$(printf '%s:%s' "$user" "$password" | base64 | tr -d '\n')"
  [[ -n "${GIT_PORT:-}" ]] || start_port_forward GIT_PORT "$GIT_NS" "svc/gitea-http" 3000
  port="$GIT_PORT"
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.extraHeader" GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" \
    git -C "$WORK" push --quiet --force "http://127.0.0.1:${port}/${GIT_OWNER}/${GIT_REPO}.git" "HEAD:refs/heads/${GIT_BRANCH}"
}

work_commit() { # work_commit MESSAGE
  git -C "$WORK" add --all
  git -C "$WORK" -c commit.gpgsign=false commit --quiet --no-verify -m "$1"
}

# A daily allow window in UTC that starts START_HOUR and lasts DURATION.
set_prod_window() { # set_prod_window START_HOUR DURATION
  START="0 $1 * * *" DURATION="$2" yq -i '
    .projects.apps.syncWindows.reference.prod = [{
      "kind": "allow", "schedule": strenv(START), "duration": strenv(DURATION),
      "timeZone": "UTC", "applications": ["*"], "manualSync": true
    }]' "${WORK}/argocd-bootstrap/values.yaml"
}

set_image_tag() { # set_image_tag ENV TAG
  TAG="$2" yq -i '.image.tag = strenv(TAG) | .image.digest = ""' "${WORK}/envs/$1/hello-api/values.yaml"
}

publish_repository() {
  local hour env
  WORK="${STATE_DIR}/repo"
  rm -rf "$WORK"
  git clone --quiet --shared --no-checkout "$REPO_ROOT" "$WORK"
  git -C "$WORK" -c advice.detachedHead=false checkout --quiet --force --detach HEAD
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    log_warn "uncommitted changes in the working tree are not part of the test; it runs $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  fi
  git -C "$WORK" config user.email >/dev/null 2>&1 || git -C "$WORK" config user.email "integration-test@example.com"
  git -C "$WORK" config user.name >/dev/null 2>&1 || git -C "$WORK" config user.name "integration test"

  # Test-only commit: the cluster definition, the locally loaded image and a
  # prod sync window that is open now (the window test closes it later).
  mkdir -p "${WORK}/clusters/${DEFINITION}"
  cp "${TEST_DIR}/cluster.yaml" "${WORK}/clusters/${DEFINITION}/cluster.yaml"
  for env in dev stage prod; do set_image_tag "$env" "$TAG_A"; done
  hour="$(date -u +%H)"
  OPEN_START=$(((10#$hour + 23) % 24))
  set_prod_window "$OPEN_START" 3h
  work_commit "test: reference integration fixture (cluster ${DEFINITION}, image ${TAG_A})"
  git_push
  log_info "published $(git -C "$WORK" rev-parse --short=12 HEAD) to ${GIT_URL}"
}

# ---------------------------------------------------------------------------
# 4. Bootstrap, OpenBao initialisation
# ---------------------------------------------------------------------------
bootstrap() {
  log_info "bootstrapping the reference profile through hack/bootstrap-gitops.sh"
  # WAIT=0: the root Application cannot finish before OpenBao (wave 4) is
  # unsealed, which this script does after checking the wave gate.
  # REPO_ROOT points at the clone, which holds clusters/${DEFINITION}.
  REPO_ROOT="$WORK" REPO_URL="$GIT_URL" TARGET_REVISION="$GIT_BRANCH" WAIT=0 TIMEOUT=15m \
    bash "${WORK}/hack/bootstrap-gitops.sh" "$DEFINITION"
}

openbao_pods_running() {
  local i phase
  for i in 0 1 2; do
    phase="$(kubectl -n openbao get pod "openbao-${i}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Running ]] || return 1
  done
}

bao_status() { # bao_status POD -> JSON (bao status exits 2 while sealed)
  kubectl -n openbao exec "$1" -- bao status -format=json 2>/dev/null || true
}

# Not ".sealed // true": jq's alternative operator also replaces false.
openbao_unsealed() { [[ "$(bao_status "$1" | jq -r '.sealed')" == false ]]; }

# Submits the unseal key to POD until it reports unsealed. A follower rejects
# the key until its Raft retry_join with the active node has gone through.
# "bao write ... key=-" reads the key from stdin ("bao operator unseal" does
# not); jq -j leaves out the newline, which the API would reject.
unseal_pod() { # unseal_pod POD
  openbao_unsealed "$1" && return 0
  jq -j '.unseal_keys_b64[0]' "$BAO_INIT" |
    kubectl -n openbao exec -i "$1" -- bao write sys/unseal key=- >/dev/null 2>&1 || true
  openbao_unsealed "$1"
}

# Test-only: one key share, kept in a private temporary file that is removed
# on exit. Keys and the root token reach the pods on stdin only.
init_openbao() {
  local pod
  make_temp_file BAO_INIT openbao-init
  log_info "initialising OpenBao (test-only: one key share)"
  kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=1 -key-threshold=1 -format=json >"$BAO_INIT"
  for pod in openbao-0 openbao-1 openbao-2; do
    wait_until 300 5 "${pod} to unseal" unseal_pod "$pod"
  done
}

configure_openbao() {
  BAO_TEST_VALUE="ref-$(openssl rand -hex 8)"
  log_info "configuring OpenBao for External Secrets (steps of the openbao wrapper README)"
  {
    jq -r '.root_token' "$BAO_INIT"
    cat <<EOF
set -eu
bao secrets enable -path=secret kv-v2 >/dev/null
bao auth enable kubernetes >/dev/null
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
bao policy write external-secrets-read - >/dev/null <<'HCL'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
path "sys/mounts/secret" {
  capabilities = ["read"]
}
HCL
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-read ttl=1h >/dev/null
bao kv put secret/integration/reference message=${BAO_TEST_VALUE} >/dev/null
EOF
  } | kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec sh -s'
}

raft_voters() {
  {
    jq -r '.root_token' "$BAO_INIT"
    echo 'bao operator raft list-peers -format=json'
  } | kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec sh -s' |
    jq '[.data.config.servers[] | select(.voter == true)] | length'
}

three_raft_voters() { [[ "$(raft_voters)" == 3 ]]; }

# Autopilot promotes a joined server to voter after its stabilization time
# (10 s by default), so the last pod to unseal is briefly a non-voter.
check_raft_voters() {
  if ! wait_until 120 5 "autopilot to promote three Raft voters" three_raft_voters; then
    log_error "OpenBao Raft voters: $(raft_voters)"
    return 1
  fi
  log_info "OpenBao Raft voters: 3"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
# Child Applications of the root, as "wave<TAB>name<TAB>creationTimestamp<TAB>health".
child_apps() {
  kubectl -n "$ARGOCD_NS" get applications -o json | jq -r '
    .items[]
    | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith("root:"))
    | [(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"), .metadata.name,
       .metadata.creationTimestamp, (.status.health.status // "Unknown")]
    | @tsv'
}

all_apps_healthy() {
  local bad
  bad="$(kubectl -n "$ARGOCD_NS" get applications -o json | jq -r '
    [.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name] | join(" ")')"
  [[ -z "$bad" ]]
}

unhealthy_apps() {
  kubectl -n "$ARGOCD_NS" get applications -o json | jq -r '
    .items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
    | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"' | tr '\n' ' '
}

# Wave gate, while OpenBao (wave 4) is sealed by construction: no
# Application of wave 10 exists.
wave10_absent() {
  local late
  late="$(child_apps | awk -F'\t' '$1 + 0 >= 10 {printf "%s ", $2}')"
  if [[ -n "$late" ]]; then
    log_error "wave 10 Applications exist while OpenBao is sealed: ${late}"
    return 1
  fi
}

early_waves_unhealthy() {
  child_apps | awk -F'\t' '$1 + 0 < 4 && $4 != "Healthy" {printf "%s=%s ", $2, $4}'
}

early_waves_healthy() { [[ -z "$(early_waves_unhealthy)" ]]; }

# Waves 0 to 3 report Healthy. Argo CD ignores status-only updates by default
# (resource.customizations.ignoreResourceUpdates.all: /status), so an
# Application can show a stale health, for example a CRD that became
# Established, until the next periodic reconcile (timeout.reconciliation 120 s
# plus up to 60 s jitter). Allow 300 s.
check_early_waves_healthy() {
  if ! wait_until 300 10 "waves 0 to 3 to report Healthy" early_waves_healthy; then
    log_error "waves 0 to 3 not Healthy: $(early_waves_unhealthy)"
    return 1
  fi
}

# Samples every 10 s for 120 s.
check_wave_gate_holds() {
  local i
  for i in $(seq 1 12); do
    wave10_absent || return 1
    sleep 10
  done
}

# Creation order: no Application of a later wave was created before an
# Application of an earlier wave.
check_wave_order() {
  child_apps | sort -t$'\t' -k1,1n -k3,3 | awk -F'\t' '
    BEGIN { cur = "none"; prevmax = ""; curmax = "" }
    { t = $3
      if ($1 != cur) { if (curmax > prevmax) prevmax = curmax; cur = $1; curmax = "" }
      if (prevmax != "" && t < prevmax) {
        printf "wave %s Application %s created %s, before the last Application of an earlier wave (%s)\n", $1, $2, t, prevmax > "/dev/stderr"
        bad = 1
      }
      if (t > curmax) curmax = t }
    END { exit bad }'
}

# Every Deployment and StatefulSet in NAMESPACE is fully ready, and its pods
# run on at least MIN_NODES nodes.
check_workloads_ready() { # NAMESPACE MIN_NODES
  local ns="$1" min="$2" not_ready nodes
  not_ready="$(kubectl -n "$ns" get deployments,statefulsets -o json | jq -r '
    [.items[] | select((.status.readyReplicas // 0) < .spec.replicas) | "\(.kind)/\(.metadata.name)"] | join(" ")')"
  nodes="$(kubectl -n "$ns" get pods -o json | jq '[.items[] | select(.status.phase == "Running") | .spec.nodeName] | unique | length')"
  [[ -z "$not_ready" ]] || log_error "${ns}: not ready: ${not_ready}"
  ((nodes >= min)) || log_error "${ns}: pods run on ${nodes} node(s), expected at least ${min}"
  [[ -z "$not_ready" ]] && ((nodes >= min))
}

replicas_of() { # replicas_of NAMESPACE KIND/NAME -> ready replicas
  kubectl -n "$1" get "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

check_argocd_ha() {
  local redis haproxy server repo appset ok=0
  server="$(replicas_of "$ARGOCD_NS" deployment/argocd-server)"
  repo="$(replicas_of "$ARGOCD_NS" deployment/argocd-repo-server)"
  appset="$(replicas_of "$ARGOCD_NS" deployment/argocd-applicationset-controller)"
  redis="$(kubectl -n "$ARGOCD_NS" get statefulsets -o json | jq '[.items[] | select(.metadata.name | test("redis-ha-server$")) | .status.readyReplicas // 0] | add // 0')"
  haproxy="$(kubectl -n "$ARGOCD_NS" get deployments -o json | jq '[.items[] | select(.metadata.name | test("redis-ha-haproxy$")) | .status.readyReplicas // 0] | add // 0')"
  log_info "argocd ready replicas: server ${server:-0}, repo-server ${repo:-0}, applicationset ${appset:-0}, redis-ha ${redis}, haproxy ${haproxy}"
  ((${server:-0} >= 2 && ${repo:-0} >= 2 && ${appset:-0} >= 2 && redis >= 3 && haproxy >= 3)) || ok=1
  check_workloads_ready "$ARGOCD_NS" 3 || ok=1
  return "$ok"
}

check_kyverno_ha() {
  local admission
  admission="$(replicas_of kyverno deployment/kyverno-admission-controller)"
  log_info "kyverno admission controller ready replicas: ${admission:-0}"
  ((${admission:-0} >= 3)) && check_workloads_ready kyverno 2
}

# A pod that passes Pod Security restricted but uses the tag latest must be
# denied in stage by the policy engine (Kyverno), not by Pod Security.
latest_tag_pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: integration-latest-tag
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: app
      image: ${IMAGE_REPO}:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      readinessProbe: {httpGet: {path: /readyz, port: 8080}}
      livenessProbe: {httpGet: {path: /healthz, port: 8080}}
EOF
}

check_kyverno_enforces() {
  local out
  if out="$(latest_tag_pod | kubectl -n stage apply --dry-run=server -f - 2>&1)"; then
    log_error "a pod with tag latest was admitted in stage"
    return 1
  fi
  if grep -qi "podsecurity" <<<"$out"; then
    log_error "denied by Pod Security instead of the policy engine: ${out}"
    return 1
  fi
  log_info "denied as expected: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
}

external_secret_value_matches() {
  [[ "$(kubectl -n dev get secret integration-reference -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null)" == "$BAO_TEST_VALUE" ]]
}

check_external_secret() {
  kubectl -n dev apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: integration-reference
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: integration-reference
  data:
    - secretKey: message
      remoteRef:
        key: integration/reference
        property: message
EOF
  wait_until 300 5 "the ExternalSecret to deliver the OpenBao value" external_secret_value_matches
}

check_store_ready() {
  [[ "$(kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}

check_app_projects() {
  local ok=0 env dest kinds
  for env in dev stage prod; do
    dest="$(kubectl -n "$ARGOCD_NS" get appproject "apps-${env}" -o json | jq -c '[.spec.destinations[].namespace]')"
    kinds="$(kubectl -n "$ARGOCD_NS" get appproject "apps-${env}" -o json | jq '(.spec.clusterResourceWhitelist // []) | length')"
    if [[ "$dest" != "[\"${env}\"]" || "$kinds" != 0 ]]; then
      log_error "apps-${env}: destinations ${dest}, cluster-scoped kinds ${kinds}"
      ok=1
    fi
  done
  [[ "$(kubectl -n "$ARGOCD_NS" get appproject default -o json | jq '(.spec.sourceRepos // []) + (.spec.destinations // []) | length')" == 0 ]] || {
    log_error "project default is not locked"
    ok=1
  }
  return "$ok"
}

test_application() { # NAME PROJECT NAMESPACE PATH
  kubectl -n "$ARGOCD_NS" apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  labels: {app.kubernetes.io/part-of: integration-reference}
spec:
  project: $2
  source:
    repoURL: ${GIT_URL}
    targetRevision: ${GIT_BRANCH}
    path: $4
  destination:
    server: https://kubernetes.default.svc
    namespace: $3
  syncPolicy:
    automated: {prune: false, selfHeal: false}
    retry: {limit: 0}
EOF
}

app_messages() {
  app_field "$1" '[(.status.conditions // [])[].message, (.status.operationState.message // ""),
    ((.status.operationState.syncResult.resources // [])[].message // "")] | join("\n")'
}

app_reports() { app_messages "$1" | grep -qi -- "$2"; }

check_project_denials() {
  local ok=0
  test_application integration-default-project default dev tests/integration/reference/fixtures/allowed
  test_application integration-wrong-namespace apps-dev prod tests/integration/reference/fixtures/allowed
  test_application integration-forbidden-kinds apps-dev dev tests/integration/reference/fixtures/forbidden
  wait_until 180 5 "the default project to reject its Application" app_reports integration-default-project "not permitted" || ok=1
  wait_until 180 5 "apps-dev to reject destination prod" app_reports integration-wrong-namespace "do not match any of the allowed destinations" || ok=1
  wait_until 180 5 "apps-dev to reject a ClusterRole and a ResourceQuota" app_reports integration-forbidden-kinds "not permitted" || ok=1
  if ((ok != 0)); then
    log_error "project messages: $(app_messages integration-default-project | tr '\n' ' ') | $(app_messages integration-wrong-namespace | tr '\n' ' ') | $(app_messages integration-forbidden-kinds | tr '\n' ' ')"
  fi
  kubectl get clusterrole integration-reference-forbidden >/dev/null 2>&1 && {
    log_error "the forbidden ClusterRole was created"
    ok=1
  }
  kubectl -n "$ARGOCD_NS" delete applications -l app.kubernetes.io/part-of=integration-reference --wait=false >/dev/null
  return "$ok"
}

project_window_is() { # project_window_is SCHEDULE
  [[ "$(kubectl -n "$ARGOCD_NS" get appproject apps-prod -o jsonpath='{.spec.syncWindows[0].schedule}')" == "$1" ]]
}

stage_runs() { [[ "$(deployment_image stage hello-api)" == "${IMAGE_REPO}:$1" ]]; }
prod_runs() { [[ "$(deployment_image prod hello-api)" == "${IMAGE_REPO}:$1" ]]; }

# The prod sync window: close it, change stage and prod, and expect stage to
# follow while prod stays OutOfSync; then a manual sync passes (manualSync).
check_sync_window() {
  local hour closed_start ok=0
  hour="$(date -u +%H)"
  closed_start=$(((10#$hour + 6) % 24))
  set_prod_window "$closed_start" 1h
  work_commit "test: close the prod sync window (opens at ${closed_start}:00 UTC)"
  git_push
  refresh_app root
  wait_until 300 5 "apps-prod to carry the closed window" project_window_is "0 ${closed_start} * * *" || return 1

  set_image_tag stage "$TAG_B"
  set_image_tag prod "$TAG_B"
  work_commit "test: deploy ${TAG_B} to stage and prod"
  git_push
  refresh_app hello-api-stage
  refresh_app hello-api-prod
  if wait_until 300 5 "stage to deploy ${TAG_B}" stage_runs "$TAG_B"; then
    record PASS "sync window: stage (no window) deploys the new commit"
  else
    record FAIL "sync window: stage (no window) deploys the new commit"
    ok=1
  fi
  sleep 90
  refresh_app hello-api-prod
  sleep 30
  if prod_runs "$TAG_A" && [[ "$(app_field hello-api-prod '.status.sync.status')" == OutOfSync ]]; then
    record PASS "sync window: prod stays OutOfSync on ${TAG_A} outside the window"
  else
    record FAIL "sync window: prod stays OutOfSync on ${TAG_A} outside the window" \
      "image $(deployment_image prod hello-api), sync $(app_field hello-api-prod '.status.sync.status')"
    ok=1
  fi

  kubectl -n "$ARGOCD_NS" patch application hello-api-prod --type merge \
    -p '{"operation":{"initiatedBy":{"username":"integration-test"},"sync":{}}}' >/dev/null
  if wait_until 300 5 "a manual prod sync" prod_runs "$TAG_B"; then
    record PASS "sync window: a manual sync passes outside the window (manualSync)"
  else
    record FAIL "sync window: a manual sync passes outside the window (manualSync)" "$(app_messages hello-api-prod | tr '\n' ' ' | cut -c1-200)"
    ok=1
  fi
  return "$ok"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
trap_results() { print_results; }
add_cleanup trap_results

create_cluster
install_metrics_server
build_image
deploy_git_server
publish_repository
bootstrap

log_info "waiting for the OpenBao pods (wave 4) to run sealed"
wait_until "$PHASE_TIMEOUT" 10 "OpenBao pods" openbao_pods_running || die "OpenBao pods did not start: $(unhealthy_apps)"
check "sync waves: waves 0 to 3 Healthy while OpenBao (wave 4) is sealed" check_early_waves_healthy
check "sync waves: no wave 10 Application while OpenBao is sealed (sampled for 120 s)" check_wave_gate_holds

init_openbao
configure_openbao
check "openbao: all three pods unsealed, three Raft voters" check_raft_voters

log_info "waiting for every Application to be Synced and Healthy"
if wait_until "$PHASE_TIMEOUT" 15 "all Applications Synced and Healthy" all_apps_healthy; then
  record PASS "all Applications Synced and Healthy" "$(kubectl -n "$ARGOCD_NS" get applications --no-headers | wc -l | tr -d ' ') Applications"
else
  record FAIL "all Applications Synced and Healthy" "$(unhealthy_apps)"
fi

check "sync waves: creation order follows the waves" check_wave_order
check "argo cd HA: server, repo-server, applicationset x2, redis-ha x3, haproxy x3, spread over 3 nodes" check_argocd_ha
check "kyverno HA: admission controller x3, all controllers ready, spread over nodes" check_kyverno_ha
check "kyverno enforces in stage (tag latest denied by policy, not by Pod Security)" check_kyverno_enforces
check "external secrets: controllers ready" check_workloads_ready external-secrets 2
check "external secrets: ClusterSecretStore openbao Ready" check_store_ready
check "external secrets: an ExternalSecret in dev receives the OpenBao value" check_external_secret
check "app projects: apps-<env> one namespace and no cluster kinds; default locked" check_app_projects
check "app projects: default project, foreign destination and platform kinds rejected" check_project_denials
check_sync_window || true

((FAILURES == 0)) || die "${FAILURES} check(s) failed"
log_info "all checks passed"
