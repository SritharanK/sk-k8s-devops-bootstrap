# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Helpers shared by the scripts in tests/e2e/lib. Source it; do not execute it.
#
# Chainsaw runs every script with a temporary KUBECONFIG for the target cluster
# (no namespace set in its context) and exports NAMESPACE, the ephemeral test
# namespace. Every kubectl call therefore names its namespace explicitly.

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
# shellcheck disable=SC2034 # used by the scripts that source this file
E2E_ENVS="dev stage prod"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# hello_api_apps ENV: names of the hello-api Applications of ENV, one per line.
# An Application belongs to ENV when its project is apps-ENV or its destination
# namespace is ENV; it is a hello-api Application when a source path (or, as a
# fallback, its name) contains hello-api.
hello_api_apps() {
  kubectl get applications.argoproj.io -n "${ARGOCD_NAMESPACE}" -o json |
    jq -r --arg env "$1" '
      .items[]
      | select(.spec.project == ("apps-" + $env) or .spec.destination.namespace == $env)
      | select(
          any(([.spec.source] + (.spec.sources // []))[] | select(. != null);
              (.path // "") | test("hello-api"))
          or (.metadata.name | test("hello-api")))
      | .metadata.name'
}

# env_configured ENV: true when the AppProject apps-ENV or the namespace ENV exists.
env_configured() {
  kubectl get appprojects.argoproj.io "apps-$1" -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 ||
    kubectl get namespace "$1" >/dev/null 2>&1
}

# hello_api_deployment NAMESPACE: name of the hello-api Deployment, matched by
# the app.kubernetes.io/name label, the name or the container image.
hello_api_deployment() {
  kubectl get deployments.apps -n "$1" -o json |
    jq -r '
      [.items[]
       | select((.metadata.labels["app.kubernetes.io/name"] // "") == "hello-api"
                or (.metadata.name | test("hello-api"))
                or any(.spec.template.spec.containers[]; .image | test("/hello-api([:@]|$)")))]
      | sort_by(.metadata.name) | .[0].metadata.name // empty'
}

# hello_api_image NAMESPACE DEPLOYMENT: image of the hello-api container (the
# container whose image names hello-api, else the first container).
hello_api_image() {
  kubectl get deployment.apps "$2" -n "$1" -o json |
    jq -r '
      .spec.template.spec.containers as $c
      | ([$c[] | select(.image | test("/hello-api([:@]|$)"))] + $c)[0].image // empty'
}

# image_repository IMAGE: IMAGE without digest and tag. A port in the registry
# host (localhost:5000/x) is kept because only the last path segment is checked.
image_repository() {
  local ref="${1%%@*}"
  case "${ref##*/}" in
    *:*) ref="${ref%:*}" ;;
  esac
  printf '%s\n' "${ref}"
}

# service_for_deployment NAMESPACE DEPLOYMENT: prints "SERVICE PORT" for the
# first Service whose selector matches the Deployment's pod template labels.
# PORT is the port named http, else the first port.
service_for_deployment() {
  local labels
  labels="$(kubectl get deployment.apps "$2" -n "$1" -o json | jq -c '.spec.template.metadata.labels // {}')"
  kubectl get services -n "$1" -o json |
    jq -r --argjson labels "${labels}" '
      [.items[]
       | select((.spec.selector // {}) != {})
       | select(.spec.selector | to_entries | all(.value == $labels[.key]))]
      | sort_by(.metadata.name) | .[0] // empty
      | "\(.metadata.name) \(([.spec.ports[] | select(.name == "http")] + .spec.ports)[0].port)"'
}

# application_state NAME: prints "SYNC HEALTH" of an Application, or nothing
# when it does not exist.
application_state() {
  kubectl get applications.argoproj.io "$1" -n "${ARGOCD_NAMESPACE}" -o json 2>/dev/null |
    jq -r '"\(.status.sync.status // "Unknown") \(.status.health.status // "Unknown")"' ||
    true
}
