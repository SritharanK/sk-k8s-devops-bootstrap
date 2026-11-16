#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Install or upgrade Argo CD from the wrapper chart helmcharts/system-charts/argo-cd.
#
# Idempotent: runs `helm upgrade --install` with values.yaml and
# values-<PROFILE>.yaml, then waits until every Deployment and StatefulSet in
# the namespace has rolled out. Uses the current KUBECONFIG and context.
# After the root Application is applied, Argo CD manages this release itself
# (argocd-bootstrap/templates/toolchains/argo-cd.yaml). From then on the script
# detects that Application, skips Helm, waits for the rollouts and exits 0, so
# repeated bootstrap runs stay idempotent. ARGOCD_REINSTALL=1 forces a Helm run
# for recovery; it takes ownership of objects that only Argo CD created.
#
# Environment:
#   PROFILE           lab | reference. Default: cluster.profile from the
#                     cluster file when CLUSTER is set, otherwise lab.
#   CLUSTER           Optional cluster name. Reads clusters/<CLUSTER>/cluster.yaml
#                     for profile, domain, namespaces and groups (needs yq v4).
#   DOMAIN            Optional base domain; Argo CD is served at argocd.<DOMAIN>.
#                     Overrides the domain from the cluster file.
#   ARGOCD_NAMESPACE  Default: namespaces.argocd from the cluster file, or argocd.
#   TIMEOUT           Helm and rollout timeout. Default: 10m.
#   VERIFY            1 (default) verifies the provenance of the upstream chart
#                     with keys/argo-helm.asc; 0 skips the check.
#   CONFIRM           yes allows an upgrade from Argo CD 2.x (see the chart README).
#   ARGOCD_REINSTALL  1 runs Helm even when Argo CD already manages the release
#                     (recovery). Argo CD reverts any difference to Git later.
#   DRY_RUN           1 prints the helm command instead of running it.
#
# Examples:
#   PROFILE=lab hack/argocd-install.sh
#   CLUSTER=reference hack/argocd-install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "${SCRIPT_DIR}/../scripts/lib/common.sh" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${SCRIPT_DIR}/../scripts/lib/common.sh"
else
  # Minimal fallback until scripts/lib/common.sh is available.
  set -Eeuo pipefail
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
  log_info() { printf '[info] %s\n' "$*" >&2; }
  log_warn() { printf '[warn] %s\n' "$*" >&2; }
  log_error() { printf '[error] %s\n' "$*" >&2; }
  die() {
    log_error "$1"
    exit "${2:-1}"
  }
  require_cmd() {
    local missing=() c
    for c in "$@"; do
      command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
    done
    if ((${#missing[@]} > 0)); then
      die "missing required commands: ${missing[*]}"
    fi
  }
  run_cmd() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      printf '[dry-run] %s\n' "$*" >&2
      return 0
    fi
    "$@"
  }
  require_confirmation() {
    [[ "${CONFIRM:-}" == "yes" ]] || die "refusing to $1 without confirmation; set CONFIRM=yes"
  }
fi

readonly RELEASE="argocd"
readonly CHART_DIR="${REPO_ROOT}/helmcharts/system-charts/argo-cd"
TIMEOUT="${TIMEOUT:-10m}"
VERIFY="${VERIFY:-1}"

wait_for_rollouts() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  local workloads w
  log_info "waiting for rollouts in ${NAMESPACE}"
  workloads="$(kubectl -n "${NAMESPACE}" get deployments,statefulsets -o name)"
  for w in ${workloads}; do
    kubectl -n "${NAMESPACE}" rollout status "${w}" --timeout="${TIMEOUT}"
  done
}

print_access() {
  local ui
  if [[ -n "${DOMAIN}" ]]; then
    ui="https://argocd.${DOMAIN}"
  elif command -v yq >/dev/null 2>&1; then
    ui="https://$(yq -r '.global.domain // ""' "${CHART_DIR}/values-${PROFILE}.yaml")"
  else
    ui="https://<global.domain in values-${PROFILE}.yaml>"
  fi
  log_info "Argo CD is ready. UI: ${ui} once the platform Gateway is up, or:"
  log_info "  kubectl -n ${NAMESPACE} port-forward svc/argocd-server 8080:80   (http://localhost:8080)"
  if [[ "${PROFILE}" == "lab" ]]; then
    log_info "lab login: user admin, initial password in Secret argocd-initial-admin-secret:"
    log_info "  kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  else
    log_info "local admin is disabled; log in through SSO (Secret argocd-oidc and oidc.config, see the chart README)"
  fi
}

require_cmd helm kubectl

# Values from the cluster definition (clusters/<name>/cluster.yaml), when requested.
cluster_file=""
cluster_domain=""
cluster_namespace=""
gateway_namespace=""
groups_json=""
if [[ -n "${CLUSTER:-}" ]]; then
  cluster_file="${REPO_ROOT}/clusters/${CLUSTER}/cluster.yaml"
  [[ -f "${cluster_file}" ]] || die "cluster file not found: ${cluster_file#"${REPO_ROOT}"/}"
  require_cmd yq
  cluster_profile="$(yq -r '.cluster.profile // ""' "${cluster_file}")"
  cluster_domain="$(yq -r '.cluster.domain // ""' "${cluster_file}")"
  cluster_namespace="$(yq -r '.namespaces.argocd // ""' "${cluster_file}")"
  gateway_namespace="$(yq -r '.namespaces.gateway // ""' "${cluster_file}")"
  groups_json="$(yq -o=json -I=0 '.platform.groups // {}' "${cluster_file}")"
  PROFILE="${PROFILE:-${cluster_profile}}"
fi

PROFILE="${PROFILE:-lab}"
case "${PROFILE}" in
  lab | reference) ;;
  *) die "PROFILE must be lab or reference, got '${PROFILE}'" ;;
esac
NAMESPACE="${ARGOCD_NAMESPACE:-${cluster_namespace:-argocd}}"
DOMAIN="${DOMAIN:-${cluster_domain}}"

[[ -f "${CHART_DIR}/values-${PROFILE}.yaml" ]] || die "missing values-${PROFILE}.yaml in ${CHART_DIR#"${REPO_ROOT}"/}"

kubectl version --request-timeout=15s >/dev/null 2>&1 ||
  die "cannot reach the Kubernetes API with the current KUBECONFIG and context"
log_info "context: $(kubectl config current-context 2>/dev/null || echo unknown), namespace: ${NAMESPACE}, profile: ${PROFILE}"

# Refuse a silent jump from Argo CD 2.x: the 2.14 to 3.x upgrade has manual
# steps (chart README, section "Upgrade from Argo CD 2.14").
if installed="$(helm get metadata "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null)"; then
  installed_app="$(printf '%s\n' "${installed}" | sed -n 's/^APP_VERSION: *//p')"
  log_info "release ${RELEASE} found with app version ${installed_app:-unknown}"
  case "${installed_app}" in
    v2.* | 2.*)
      log_warn "Argo CD ${installed_app} is installed; read the upgrade procedure in helmcharts/system-charts/argo-cd/README.md first"
      require_confirmation "upgrade Argo CD ${installed_app} to 3.x"
      ;;
  esac
fi

# Once Argo CD manages itself, Helm no longer owns every object of the release:
# the Application may have created objects that Helm never installed, such as
# the HTTPRoute after the Gateway API CRDs appeared. A plain Helm run would
# refuse them, so skip Helm unless a recovery run is requested.
managed_by=""
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  managed_by="$(kubectl -n "${NAMESPACE}" get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.source.path}{"\n"}{end}' 2>/dev/null |
    awk '$2 == "helmcharts/system-charts/argo-cd" && !found { print $1; found = 1 }' || true)"
fi
if [[ -n "${managed_by}" ]]; then
  if [[ "${ARGOCD_REINSTALL:-0}" != "1" ]]; then
    log_info "Argo CD manages this release through Application ${managed_by}; skipping Helm (ARGOCD_REINSTALL=1 forces a recovery run)"
    wait_for_rollouts
    print_access
    exit 0
  fi
  [[ "$(helm upgrade --help 2>/dev/null)" == *--take-ownership* ]] ||
    die "ARGOCD_REINSTALL=1 needs Helm 3.17 or later (--take-ownership)"
  log_warn "Argo CD manages this release through Application ${managed_by}; reinstalling from the local tree. Argo CD reverts any difference to Git on its next sync."
fi

# Dependencies from Chart.lock, with provenance verification.
dep_args=(dependency build "${CHART_DIR}")
if [[ "${VERIFY}" == "1" ]]; then
  dep_args+=(--verify --keyring "${CHART_DIR}/keys/argo-helm.asc")
fi
log_info "building chart dependencies (verify=${VERIFY})"
run_cmd helm "${dep_args[@]}" >/dev/null

# Namespace with Pod Security Admission labels, matching the managed namespace
# metadata of the self-managing Application.
server_minor="$(kubectl get --raw /version | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p')"
pss_version="v1.${server_minor:-36}"
if [[ "${DRY_RUN:-0}" != "1" ]]; then
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
run_cmd kubectl label namespace "${NAMESPACE}" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  "pod-security.kubernetes.io/enforce-version=${pss_version}" \
  pod-security.kubernetes.io/warn=restricted \
  "pod-security.kubernetes.io/warn-version=${pss_version}" >/dev/null

helm_args=(
  upgrade --install "${RELEASE}" "${CHART_DIR}"
  --namespace "${NAMESPACE}"
  --values "${CHART_DIR}/values.yaml"
  --values "${CHART_DIR}/values-${PROFILE}.yaml"
  --wait --timeout "${TIMEOUT}"
)
if [[ -n "${managed_by}" ]]; then
  # Adopt objects that only Argo CD created, and let the local tree win over
  # fields Argo CD applied with server-side apply.
  helm_args+=(--take-ownership --force-conflicts)
fi
if [[ -n "${DOMAIN}" ]]; then
  helm_args+=(--set "global.domain=argocd.${DOMAIN}")
fi
if [[ -n "${groups_json}" && "${groups_json}" != "{}" ]]; then
  helm_args+=(--set-json "platform.groups=${groups_json}")
fi
if [[ -n "${gateway_namespace}" ]]; then
  helm_args+=(--set-json "route.parentRefs=[{\"group\":\"gateway.networking.k8s.io\",\"kind\":\"Gateway\",\"name\":\"platform\",\"namespace\":\"${gateway_namespace}\",\"sectionName\":\"https\"}]")
fi
# The Gateway API CRDs are installed later by GitOps. Without them the route is
# skipped here; the self-managing Application adds it once the CRDs exist.
if ! kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  log_info "Gateway API CRDs not installed yet: installing without the HTTPRoute"
  helm_args+=(--set route.enabled=false)
fi

log_info "helm upgrade --install ${RELEASE} (timeout ${TIMEOUT})"
run_cmd helm "${helm_args[@]}"

wait_for_rollouts
print_access
