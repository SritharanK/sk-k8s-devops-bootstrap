#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Declarative GitOps bootstrap of one cluster. Idempotent: safe to re-run.
#
# Usage:
#   hack/bootstrap-gitops.sh [CLUSTER]
#
# Steps:
#   1. Validate clusters/<CLUSTER>/cluster.yaml (schema and checks).
#   2. Install Argo CD with hack/argocd-install.sh (skip with SKIP_ARGOCD_INSTALL=1).
#   3. Apply an optional repository Secret for a private repository.
#   4. Apply the AppProjects rendered by argocd-bootstrap.
#   5. Apply the root Application rendered by the bootstrap chart.
#   6. Wait until the root Application is Synced (skip with WAIT=0).
# After step 5 Argo CD owns everything, including the AppProjects and Argo CD
# itself; this script is not needed again unless the root Application changes.
#
# Environment:
#   CLUSTER              cluster definition name (default: lab)
#   REPO_URL             override git.repoURL, for example a fork (alias GIT_REPO_URL)
#   TARGET_REVISION      override git.targetRevision, for example a commit SHA in CI
#                        (alias GIT_TARGET_REVISION)
#   REPO_SECRET_FILE     repository Secret manifest outside the repository, or a
#                        SOPS-encrypted file (*.sops.yaml) decrypted with sops
#   HUB_MODE             1 also renders the ApplicationSet that creates a root
#                        Application per registered remote cluster (hub mode)
#   SKIP_ARGOCD_INSTALL  1 skips step 2 (Argo CD already installed)
#   RENDER_ONLY          1 prints the manifests of steps 4 and 5 and exits
#   WAIT                 0 skips step 6
#   WAIT_TIMEOUT         timeout for the waits (default: 600s)
#   DRY_RUN              1 prints the kubectl commands instead of running them

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

usage() {
  sed -n '4,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*) die "unknown option: $1" 2 ;;
esac

CLUSTER="${1:-${CLUSTER:-lab}}"
WAIT="${WAIT:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600s}"
RENDER_ONLY="${RENDER_ONLY:-0}"

[[ "$CLUSTER" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid cluster name: $CLUSTER" 2
cd "$REPO_ROOT" || exit 1

CLUSTER_FILE="clusters/${CLUSTER}/cluster.yaml"
[[ -f "$CLUSTER_FILE" ]] || die "cluster definition not found: $CLUSTER_FILE"

require_cmd helm yq
[[ "$RENDER_ONLY" == "1" ]] || require_cmd kubectl

# 1. Validate the definition. Placeholders elsewhere in the file are allowed
# here; the values this script needs are checked below after overrides.
log_info "validating ${CLUSTER_FILE}"
bash hack/validate-config.sh "$CLUSTER_FILE"

repo_url="${REPO_URL:-${GIT_REPO_URL:-$(yq -r '.git.repoURL' "$CLUSTER_FILE")}}"
target_revision="${TARGET_REVISION:-${GIT_TARGET_REVISION:-$(yq -r '.git.targetRevision' "$CLUSTER_FILE")}}"
profile="$(yq -r '.cluster.profile' "$CLUSTER_FILE")"
argocd_ns="$(yq -r '.namespaces.argocd' "$CLUSTER_FILE")"

if is_placeholder "$repo_url"; then
  die "git.repoURL is a placeholder (${repo_url}); set it in ${CLUSTER_FILE} or pass REPO_URL"
fi
if is_placeholder "$target_revision"; then
  die "git.targetRevision is a placeholder; set it in ${CLUSTER_FILE} or pass TARGET_REVISION"
fi
case "$repo_url" in
  https://* | ssh://* | git@*) ;;
  http://*)
    # Plain HTTP only for a Git server inside the cluster (the kind demo).
    repo_host="${repo_url#http://}"
    repo_host="${repo_host%%/*}"
    repo_host="${repo_host%%:*}"
    case "$repo_host" in
      *.svc | *.svc.cluster.local)
        log_warn "plain HTTP repository ${repo_host}: acceptable only for an in-cluster lab server"
        ;;
      *) die "plain HTTP is allowed only for in-cluster hosts (*.svc, *.svc.cluster.local): ${repo_url}" ;;
    esac
    ;;
  *) die "unsupported repository URL scheme: ${repo_url}" ;;
esac

plain_secret=""
projects_file=""
root_file=""

helm_args=(
  -f "$CLUSTER_FILE"
  --set-string "git.repoURL=${repo_url}"
  --set-string "git.targetRevision=${target_revision}"
)

render_projects() {
  helm template argocd-bootstrap argocd-bootstrap "${helm_args[@]}" \
    --show-only templates/projects/platform.yaml \
    --show-only templates/projects/apps.yaml \
    --show-only templates/projects/default.yaml
}

render_root() {
  local hub="false"
  [[ "${HUB_MODE:-0}" == "1" ]] && hub="true"
  helm template bootstrap bootstrap "${helm_args[@]}" --set "hub.enabled=${hub}"
}

if [[ "$RENDER_ONLY" == "1" ]]; then
  render_projects
  render_root
  exit 0
fi

context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$context" ]] || die "no current kube context; set KUBECONFIG or select a context"
log_info "cluster definition ${CLUSTER} (profile ${profile}), kube context ${context}"
log_info "repository ${repo_url} at ${target_revision}"

# 2. Argo CD.
if [[ "${SKIP_ARGOCD_INSTALL:-0}" != "1" ]]; then
  [[ -f hack/argocd-install.sh ]] || die "hack/argocd-install.sh not found; install Argo CD first or set SKIP_ARGOCD_INSTALL=1"
  log_info "installing Argo CD (profile ${profile})"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run_cmd env PROFILE="$profile" CLUSTER="$CLUSTER" bash hack/argocd-install.sh
  else
    PROFILE="$profile" CLUSTER="$CLUSTER" bash hack/argocd-install.sh
  fi
fi

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  log_info "waiting for the Argo CD CRDs"
  kubectl wait --for condition=Established --timeout "$WAIT_TIMEOUT" \
    crd/applications.argoproj.io crd/appprojects.argoproj.io >/dev/null
  kubectl get namespace "$argocd_ns" >/dev/null 2>&1 ||
    die "namespace ${argocd_ns} does not exist; the Argo CD install must create it"
fi

# 3. Repository credentials for a private repository. The manifest never lives
# in this repository in plain text.
if [[ -n "${REPO_SECRET_FILE:-}" ]]; then
  [[ -f "$REPO_SECRET_FILE" ]] || die "REPO_SECRET_FILE not found: ${REPO_SECRET_FILE}"
  secret_dir="$(cd "$(dirname "$REPO_SECRET_FILE")" && pwd -P)"
  case "$REPO_SECRET_FILE" in
    *.sops.yaml | *.sops.yml)
      require_cmd sops
      make_temp_file plain_secret repo-secret
      sops --decrypt "$REPO_SECRET_FILE" >"$plain_secret"
      ;;
    *)
      case "$secret_dir/" in
        "$REPO_ROOT"/*) die "REPO_SECRET_FILE is inside the repository; keep plain-text secrets outside it or encrypt them with SOPS" ;;
      esac
      plain_secret="$REPO_SECRET_FILE"
      ;;
  esac
  kind="$(yq -r '.kind' "$plain_secret")"
  secret_type="$(yq -r '.metadata.labels."argocd.argoproj.io/secret-type" // ""' "$plain_secret")"
  [[ "$kind" == "Secret" ]] || die "REPO_SECRET_FILE must contain one Secret"
  case "$secret_type" in
    repository | repo-creds) ;;
    *) die "REPO_SECRET_FILE needs label argocd.argoproj.io/secret-type: repository or repo-creds" ;;
  esac
  log_info "applying the repository Secret"
  run_cmd kubectl apply --namespace "$argocd_ns" -f "$plain_secret" >/dev/null
fi

# 4. AppProjects first: the root Application belongs to the platform project.
log_info "applying the AppProjects"
make_temp_file projects_file projects
render_projects >"$projects_file"
run_cmd kubectl apply -f "$projects_file"

# 5. Root Application.
log_info "applying the root Application"
make_temp_file root_file root
render_root >"$root_file"
run_cmd kubectl apply -f "$root_file"

# 6. Wait for the first sync of the root Application.
if [[ "$WAIT" == "1" && "${DRY_RUN:-0}" != "1" ]]; then
  log_info "waiting for the root Application to sync (timeout ${WAIT_TIMEOUT})"
  if ! kubectl --namespace "$argocd_ns" wait application/root \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout "$WAIT_TIMEOUT" >/dev/null; then
    kubectl --namespace "$argocd_ns" get application root -o yaml | yq '.status.conditions // []' >&2 || true
    die "root Application did not sync within ${WAIT_TIMEOUT}"
  fi
fi

log_info "bootstrap complete; follow progress with: kubectl -n ${argocd_ns} get applications"
