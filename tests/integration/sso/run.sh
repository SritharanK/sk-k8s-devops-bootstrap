#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# SSO integration test: Argo CD from the wrapper chart with Dex as the OIDC
# provider, in a throwaway kind cluster. README.md in this directory states
# what the test proves and what only the real identity provider can prove.
#
# The run is idempotent: an existing cluster of the same name is deleted
# first, and the cluster is deleted on exit unless KEEP_CLUSTER=1. Client
# secret and user passwords are generated per run and never written to the
# repository.
#
# Environment:
#   KIND_CLUSTER  kind cluster name. Default: it-sso.
#   KIND_IMAGE    kind node image. Default: kindest/node v1.36.4 pinned by digest.
#   KEEP_CLUSTER  1 keeps the cluster after the run (debugging).
#   TIMEOUT       Helm and rollout timeout. Default: 5m.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"

readonly KIND_CLUSTER="${KIND_CLUSTER:-it-sso}"
readonly KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed}"
readonly TIMEOUT="${TIMEOUT:-5m}"
readonly DEX_CHART="oci://ghcr.io/dexidp/helm-charts/dex"
readonly DEX_CHART_VERSION="0.26.0"
readonly ISSUER="http://dex.dex.svc.cluster.local:5556/dex"
readonly CLIENT_ID="argo-cd"
readonly CHART_DIR="${REPO_ROOT}/helmcharts/system-charts/argo-cd"
readonly CLUSTER_FILE="${REPO_ROOT}/clusters/lab/cluster.yaml"
readonly USERS="admin deployer viewer nogroup"

require_cmd kind kubectl helm yq jq curl openssl htpasswd python3 git

make_temp_dir WORK sso
export KUBECONFIG="${WORK}/kubeconfig"

delete_cluster() {
  kind delete cluster --name "${KIND_CLUSTER}" >/dev/null 2>&1 || true
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

wait_http() {
  local url="$1" i
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "${url}" 2>/dev/null && return 0
    sleep 1
  done
  die "timed out waiting for ${url}"
}

port_forward() {
  local ns="$1" svc="$2" port="$3" target="$4" pid
  kubectl -n "${ns}" port-forward --address 127.0.0.1 "svc/${svc}" "${port}:${target}" >/dev/null 2>&1 &
  pid=$!
  disown "${pid}"
  add_cleanup "kill ${pid} 2>/dev/null || true"
}

# ---------------------------------------------------------------------------
# 1. Cluster
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
  log_info "deleting leftover cluster ${KIND_CLUSTER}"
  delete_cluster
fi
log_info "creating kind cluster ${KIND_CLUSTER}"
kind create cluster --name "${KIND_CLUSTER}" --image "${KIND_IMAGE}" --kubeconfig "${KUBECONFIG}" --wait 180s \
  >"${WORK}/kind.log" 2>&1 || {
  cat "${WORK}/kind.log" >&2
  die "kind create cluster failed"
}
if [[ "${KEEP_CLUSTER:-0}" == "1" ]]; then
  log_warn "KEEP_CLUSTER=1: delete it later with: kind delete cluster --name ${KIND_CLUSTER}"
else
  add_cleanup delete_cluster
fi

# ---------------------------------------------------------------------------
# 2. Test identities: one user per platform group plus one without a group.
#    Group names come from the lab cluster definition (platform.groups).
# ---------------------------------------------------------------------------
group_of() {
  case "$1" in
    admin) yq -r '.platform.groups.admins' "${CLUSTER_FILE}" ;;
    deployer) yq -r '.platform.groups.deployers' "${CLUSTER_FILE}" ;;
    viewer) yq -r '.platform.groups.viewers' "${CLUSTER_FILE}" ;;
    *) printf '' ;;
  esac
}

openssl rand -hex 24 | tr -d '\n' >"${WORK}/client-secret"
printf 'user = "%s:%s"\n' "${CLIENT_ID}" "$(cat "${WORK}/client-secret")" >"${WORK}/client.curlrc"

DEX_CLIENT_SECRET="$(cat "${WORK}/client-secret")" DEX_CLIENT_ID="${CLIENT_ID}" yq -n '
  .config.staticClients = [{
    "id": strenv(DEX_CLIENT_ID),
    "name": "Argo CD",
    "secret": strenv(DEX_CLIENT_SECRET),
    "redirectURIs": ["https://argocd.localtest.me/auth/callback"]
  }]' >"${WORK}/dex-users.yaml"

for u in ${USERS}; do
  openssl rand -hex 16 | tr -d '\n' >"${WORK}/pw-${u}"
  # bcrypt with the $2a$ prefix; the dollar signs are literal.
  # shellcheck disable=SC2016
  hash="$(htpasswd -niBC 10 "" <"${WORK}/pw-${u}" | tr -d ':\n' | sed 's/^\$2y\$/$2a$/')"
  USER_NAME="sso-${u}" USER_HASH="${hash}" USER_GROUP="$(group_of "${u}")" yq -i '
    .config.staticPasswords += [{
      "email": strenv(USER_NAME) + "@example.com",
      "username": strenv(USER_NAME),
      "userID": strenv(USER_NAME),
      "hash": strenv(USER_HASH),
      "groups": (strenv(USER_GROUP) | split(",") | map(select(. != "")))
    }]' "${WORK}/dex-users.yaml"
done

# ---------------------------------------------------------------------------
# 3. Dex
# ---------------------------------------------------------------------------
log_info "installing Dex (chart ${DEX_CHART_VERSION})"
helm upgrade --install dex "${DEX_CHART}" --version "${DEX_CHART_VERSION}" \
  --namespace dex --create-namespace \
  --values "${SCRIPT_DIR}/dex-values.yaml" --values "${WORK}/dex-users.yaml" \
  --wait --timeout "${TIMEOUT}" >/dev/null

# ---------------------------------------------------------------------------
# 4. Argo CD from the wrapper. The OIDC block is the one of the reference
#    profile with its two placeholders replaced by the test Dex.
# ---------------------------------------------------------------------------
oidc="$(yq -r '."argo-cd".configs.cm."oidc.config"' "${CHART_DIR}/values-reference.yaml" |
  sed -e "s#https://CHANGE_ME.example.com#${ISSUER}#" -e "s#clientID: CHANGE_ME#clientID: ${CLIENT_ID}#")"
[[ "${oidc}" != *CHANGE_ME* ]] || die "values-reference.yaml oidc.config has placeholders this test does not replace"
OIDC="${oidc}" yq -n '."argo-cd".configs.cm."oidc.config" = strenv(OIDC)' >"${WORK}/values-oidc.yaml"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n argocd create secret generic argocd-oidc --from-file=clientSecret="${WORK}/client-secret" \
  --dry-run=client -o yaml |
  kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml |
  kubectl apply -f - >/dev/null

log_info "installing Argo CD from the wrapper (lab profile plus test values)"
helm dependency build "${CHART_DIR}" --verify --keyring "${CHART_DIR}/keys/argo-helm.asc" >/dev/null
helm upgrade --install argocd "${CHART_DIR}" --namespace argocd \
  --values "${CHART_DIR}/values.yaml" --values "${CHART_DIR}/values-lab.yaml" \
  --values "${SCRIPT_DIR}/values-sso.yaml" --values "${WORK}/values-oidc.yaml" \
  --set-json "platform.groups=$(yq -o=json -I=0 '.platform.groups' "${CLUSTER_FILE}")" \
  --wait --timeout "${TIMEOUT}" >/dev/null

# ---------------------------------------------------------------------------
# 5. AppProjects from the root chart (lab cluster definition) and probe
#    Applications. The probes pin a commit SHA, so a sync request never needs
#    the Git repository; the controller's later fetch failure is irrelevant.
# ---------------------------------------------------------------------------
helm template root "${REPO_ROOT}/argocd-bootstrap" --values "${CLUSTER_FILE}" \
  --show-only templates/projects/apps.yaml --show-only templates/projects/platform.yaml |
  kubectl apply --server-side -f - >/dev/null 2>"${WORK}/projects.log" || {
  cat "${WORK}/projects.log" >&2
  die "applying the AppProjects failed"
}

repo_url="$(yq -r '.git.repoURL' "${CLUSTER_FILE}")"
revision="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
probe() {
  local name="$1" project="$2" namespace="$3"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${name}
  namespace: argocd
spec:
  project: ${project}
  source:
    repoURL: ${repo_url}
    targetRevision: ${revision}
    path: helmcharts/app-charts/hello-api
  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
EOF
}
probe sso-dev apps-dev dev
probe sso-dev-sync-admin apps-dev dev
probe sso-dev-sync-deployer apps-dev dev
probe sso-platform platform monitoring
probe sso-platform-sync-admin platform monitoring

# ---------------------------------------------------------------------------
# 6. Tokens from the Dex password grant, and the ci project role token.
# ---------------------------------------------------------------------------
DEX_PORT="$(free_port)"
ARGOCD_PORT="$(free_port)"
port_forward dex dex "${DEX_PORT}" 5556
port_forward argocd argocd-server "${ARGOCD_PORT}" 80
wait_http "http://127.0.0.1:${DEX_PORT}/dex/.well-known/openid-configuration"
wait_http "http://127.0.0.1:${ARGOCD_PORT}/healthz"

for u in ${USERS}; do
  id_token="$(curl -fsS -K "${WORK}/client.curlrc" \
    --data-urlencode grant_type=password \
    --data-urlencode "username=sso-${u}@example.com" \
    --data-urlencode "password@${WORK}/pw-${u}" \
    --data-urlencode "scope=openid email profile groups" \
    "http://127.0.0.1:${DEX_PORT}/dex/token" | jq -r '.id_token')"
  [[ -n "${id_token}" && "${id_token}" != "null" ]] || die "no ID token for sso-${u}"
  printf 'Authorization: Bearer %s\n' "${id_token}" >"${WORK}/auth-${u}"
done
printf 'X-Probe: anonymous\n' >"${WORK}/auth-anonymous"

FAILS=0
PASSES=0

api() {
  local method="$1" path="$2" who="$3" body="${4:-}"
  local args=(-sS -o "${WORK}/last.json" -w '%{http_code}' -X "${method}" -H "@${WORK}/auth-${who}")
  # Argo CD rejects state-changing requests without a JSON content type (CSRF guard).
  if [[ "${method}" != "GET" ]]; then
    args+=(-H 'Content-Type: application/json')
  fi
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  curl "${args[@]}" "http://127.0.0.1:${ARGOCD_PORT}${path}"
}

record() {
  local ok="$1" desc="$2" detail="$3"
  if [[ "${ok}" == "1" ]]; then
    PASSES=$((PASSES + 1))
    printf 'PASS  %-62s %s\n' "${desc}" "${detail}"
  else
    FAILS=$((FAILS + 1))
    printf 'FAIL  %-62s %s\n' "${desc}" "${detail}"
  fi
}

# expect <description> <HTTP status> <method> <path> <identity> [body]
expect() {
  local desc="$1" want="$2" got
  shift 2
  got="$(api "$@")"
  # A 403 must come from RBAC, not from another guard such as a sync window.
  if [[ "${got}" == "403" ]] && ! grep -qi 'permission denied' "${WORK}/last.json"; then
    got="403 (not an RBAC denial)"
  fi
  if [[ "${got}" == "${want}" ]]; then
    record 1 "${desc}" "${got}"
  else
    record 0 "${desc}" "want ${want}, got ${got}: $(head -c 160 "${WORK}/last.json")"
  fi
}

# expect_json <description> <jq expression that must be true> <method> <path> <identity>
expect_json() {
  local desc="$1" expr="$2" got
  shift 2
  got="$(api "$@")"
  if [[ "${got}" == "200" ]] && jq -e "${expr}" "${WORK}/last.json" >/dev/null 2>&1; then
    record 1 "${desc}" "${expr}"
  else
    record 0 "${desc}" "status ${got}, expected ${expr}: $(head -c 160 "${WORK}/last.json")"
  fi
}

ci_token="$(api POST /api/v1/projects/apps-dev/roles/ci/token admin '{"expiresIn": 3600}' >/dev/null && jq -r '.token // empty' "${WORK}/last.json")"
[[ -n "${ci_token}" ]] || die "could not create a token for the ci role of apps-dev: $(head -c 200 "${WORK}/last.json")"
printf 'Authorization: Bearer %s\n' "${ci_token}" >"${WORK}/auth-ci"

# ---------------------------------------------------------------------------
# 7. Assertions
# ---------------------------------------------------------------------------
g_admins="$(group_of admin)"
g_deployers="$(group_of deployer)"
g_viewers="$(group_of viewer)"

log_info "OIDC configuration and group claims"
expect_json "settings expose the Dex issuer" ".oidcConfig.issuer == \"${ISSUER}\"" GET /api/v1/settings anonymous
expect "anonymous request is rejected" 401 GET /api/v1/applications anonymous
expect_json "admin token: groups claim mapped" "(.groups // []) == [\"${g_admins}\"]" GET /api/v1/session/userinfo admin
expect_json "deployer token: groups claim mapped" "(.groups // []) == [\"${g_deployers}\"]" GET /api/v1/session/userinfo deployer
expect_json "viewer token: groups claim mapped" "(.groups // []) == [\"${g_viewers}\"]" GET /api/v1/session/userinfo viewer
expect_json "no-group token: logged in without groups" ".loggedIn == true and ((.groups // []) | length) == 0" GET /api/v1/session/userinfo nogroup

log_info "admins: everything"
expect "admin gets apps-dev application" 200 GET /api/v1/applications/sso-dev admin
expect "admin gets platform application" 200 GET /api/v1/applications/sso-platform admin
expect "admin syncs apps-dev application" 200 POST /api/v1/applications/sso-dev-sync-admin/sync admin '{}'
expect "admin syncs platform application" 200 POST /api/v1/applications/sso-platform-sync-admin/sync admin '{}'
expect_json "admin lists clusters" "(.items | length) >= 1" GET /api/v1/clusters admin
expect "admin creates a project" 200 POST /api/v1/projects admin \
  '{"project":{"metadata":{"name":"sso-probe"},"spec":{"sourceRepos":["*"],"destinations":[{"server":"https://kubernetes.default.svc","namespace":"sso-probe"}]}}}'
expect "admin deletes that project" 200 DELETE /api/v1/projects/sso-probe admin

log_info "deployers: get and sync in apps projects, not in platform"
expect "deployer gets apps-dev application" 200 GET /api/v1/applications/sso-dev deployer
expect "deployer syncs apps-dev application" 200 POST /api/v1/applications/sso-dev-sync-deployer/sync deployer '{}'
expect "deployer gets platform application (platform viewers role)" 200 GET /api/v1/applications/sso-platform deployer
expect "deployer cannot sync platform application" 403 POST /api/v1/applications/sso-platform/sync deployer '{}'
expect "deployer cannot delete apps-dev application" 403 DELETE "/api/v1/applications/sso-dev?cascade=false" deployer
expect "deployer cannot create a project" 403 POST /api/v1/projects deployer '{"project":{"metadata":{"name":"sso-deny"}}}'
expect_json "deployer sees no clusters" "((.items // []) | length) == 0" GET /api/v1/clusters deployer

log_info "viewers: read-only"
expect "viewer gets apps-dev application" 200 GET /api/v1/applications/sso-dev viewer
expect "viewer gets platform application" 200 GET /api/v1/applications/sso-platform viewer
expect "viewer cannot sync apps-dev application" 403 POST /api/v1/applications/sso-dev/sync viewer '{}'
expect "viewer cannot sync platform application" 403 POST /api/v1/applications/sso-platform/sync viewer '{}'
expect "viewer cannot delete apps-dev application" 403 DELETE "/api/v1/applications/sso-dev?cascade=false" viewer
expect "viewer cannot create a project" 403 POST /api/v1/projects viewer '{"project":{"metadata":{"name":"sso-deny"}}}'

log_info "no group: nothing (policy.default is empty)"
expect_json "no-group user lists no applications" "((.items // []) | length) == 0" GET /api/v1/applications nogroup
expect_json "no-group user lists no projects" "((.items // []) | length) == 0" GET /api/v1/projects nogroup
expect "no-group user cannot get apps-dev application" 403 GET /api/v1/applications/sso-dev nogroup
expect "no-group user cannot get platform application" 403 GET /api/v1/applications/sso-platform nogroup
expect "no-group user cannot sync apps-dev application" 403 POST /api/v1/applications/sso-dev/sync nogroup '{}'

log_info "ci project role token (apps-dev): get only"
expect "ci gets apps-dev application" 200 GET /api/v1/applications/sso-dev ci
expect_json "ci lists only apps-dev applications" "[.items[].spec.project] | unique == [\"apps-dev\"]" GET /api/v1/applications ci
expect "ci cannot sync apps-dev application" 403 POST /api/v1/applications/sso-dev/sync ci '{}'
expect "ci cannot get platform application" 403 GET /api/v1/applications/sso-platform ci
expect "ci cannot delete apps-dev application" 403 DELETE "/api/v1/applications/sso-dev?cascade=false" ci

log_info "admins: delete (last, it removes a probe)"
expect "admin deletes apps-dev application" 200 DELETE "/api/v1/applications/sso-dev?cascade=false" admin

printf '\n%s passed, %s failed\n' "${PASSES}" "${FAILS}"
((FAILS == 0)) || die "${FAILS} SSO check(s) failed"
log_info "SSO integration test passed"
