#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tracing integration test: hello-api with otel.enabled sends a server span to
# Tempo from the tracing chart, in a throwaway kind cluster with the platform
# network policies of an application namespace. README.md in this directory
# states what the test proves and what it does not.
#
# The run is idempotent: an existing cluster of the same name is deleted
# first, and the cluster is deleted on exit unless KEEP_CLUSTER=1.
#
# Environment:
#   KIND_CLUSTER  kind cluster name. Default: l13-tracing.
#   KIND_IMAGE    kind node image. Default: kindest/node v1.36.4 pinned by digest.
#   KEEP_CLUSTER  1 keeps the cluster after the run (debugging).
#   TIMEOUT       Helm and rollout timeout. Default: 5m.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"

readonly KIND_CLUSTER="${KIND_CLUSTER:-l13-tracing}"
readonly KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed}"
readonly TIMEOUT="${TIMEOUT:-5m}"
readonly NAMESPACE="dev"
readonly IMAGE_TAG="trace-smoke"

require_cmd docker kind kubectl helm yq jq curl python3 openssl

make_temp_dir WORK tracing
export KUBECONFIG="${WORK}/kubeconfig"

PASSED=0
FAILED=0
check() {
  local name="$1"
  shift
  if "$@" >>"${WORK}/checks.log" 2>&1; then
    PASSED=$((PASSED + 1))
    log_info "PASS ${name}"
  else
    FAILED=$((FAILED + 1))
    log_error "FAIL ${name}"
  fi
}

delete_cluster() {
  kind delete cluster --name "${KIND_CLUSTER}" >/dev/null 2>&1 || true
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

port_forward() {
  local ns="$1" svc="$2" port="$3" target="$4" pid i
  kubectl -n "${ns}" port-forward --address 127.0.0.1 "svc/${svc}" "${port}:${target}" >/dev/null 2>&1 &
  pid=$!
  disown "${pid}"
  add_cleanup "kill ${pid} 2>/dev/null || true"
  for i in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  die "port-forward to ${ns}/${svc} did not come up"
}

# Copies a chart and the charts it references with file:// into WORK, so
# helm dependency build never writes into the repository.
stage_charts() {
  mkdir -p "${WORK}/helmcharts/app-charts" "${WORK}/helmcharts/system-charts"
  cp -R "${REPO_ROOT}/helmcharts/helm-common" "${WORK}/helmcharts/"
  cp -R "${REPO_ROOT}/helmcharts/app-charts/hello-api" "${WORK}/helmcharts/app-charts/"
  cp -R "${REPO_ROOT}/helmcharts/system-charts/tracing" "${WORK}/helmcharts/system-charts/"
  cp -R "${REPO_ROOT}/helmcharts/system-charts/network-policies" "${WORK}/helmcharts/system-charts/"
}

# ---------------------------------------------------------------------------
# 1. Image and cluster
# ---------------------------------------------------------------------------
log_info "building hello-api image"
docker build --quiet --build-arg VERSION="${IMAGE_TAG}" --build-arg REVISION="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)" \
  -t "hello-api:${IMAGE_TAG}" "${REPO_ROOT}/sample-services/hello-api" >/dev/null

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
kind load docker-image --name "${KIND_CLUSTER}" "hello-api:${IMAGE_TAG}" >/dev/null

stage_charts
minor="$(yq -r '.cluster.kubernetesMinor' "${REPO_ROOT}/clusters/lab/cluster.yaml")"

# ---------------------------------------------------------------------------
# 2. Namespaces as the platform creates them: Pod Security restricted, and in
#    the application namespace the platform default-deny and allow-dns
#    policies from the network-policies chart.
# ---------------------------------------------------------------------------
for ns in tracing "${NAMESPACE}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "${ns}" --overwrite \
    pod-security.kubernetes.io/enforce=restricted "pod-security.kubernetes.io/enforce-version=v${minor}" >/dev/null
done
helm template network-policies "${WORK}/helmcharts/system-charts/network-policies" --namespace kube-system \
  --set-json "environments={\"${NAMESPACE}\":\"${NAMESPACE}\"}" \
  --show-only templates/default-deny.yaml --show-only templates/allow-dns.yaml |
  yq "select(.metadata.namespace == \"${NAMESPACE}\")" |
  kubectl apply -f - >/dev/null

# ---------------------------------------------------------------------------
# 3. Tempo from the tracing chart (lab values). No Prometheus Operator here,
#    so the ServiceMonitor is off.
# ---------------------------------------------------------------------------
log_info "installing Tempo from helmcharts/system-charts/tracing"
helm dependency build "${WORK}/helmcharts/system-charts/tracing" >/dev/null
helm upgrade --install tracing "${WORK}/helmcharts/system-charts/tracing" --namespace tracing \
  --values "${WORK}/helmcharts/system-charts/tracing/values.yaml" \
  --values "${WORK}/helmcharts/system-charts/tracing/values-lab.yaml" \
  --set tempo.serviceMonitor.enabled=false \
  --wait --timeout "${TIMEOUT}" >/dev/null

# ---------------------------------------------------------------------------
# 4. hello-api from its chart with otel.enabled. The route and the traffic
#    policy need a Gateway, which this test does not install.
# ---------------------------------------------------------------------------
log_info "installing hello-api with otel.enabled"
helm dependency build "${WORK}/helmcharts/app-charts/hello-api" >/dev/null
helm upgrade --install hello-api "${WORK}/helmcharts/app-charts/hello-api" --namespace "${NAMESPACE}" \
  --set global.environment="${NAMESPACE}" \
  --set image.registry=docker.io/library \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy=Never \
  --set route.enabled=false \
  --set trafficPolicy.enabled=false \
  --set otel.enabled=true \
  --wait --timeout "${TIMEOUT}" >/dev/null

# ---------------------------------------------------------------------------
# 5. Requests. One carries a W3C traceparent with a known, sampled trace ID;
#    the parent-based sampler keeps it.
# ---------------------------------------------------------------------------
app_port="$(free_port)"
tempo_port="$(free_port)"
port_forward "${NAMESPACE}" hello-api "${app_port}" 80
port_forward tracing tempo "${tempo_port}" 3200

trace_id="$(openssl rand -hex 16)"
parent_id="$(openssl rand -hex 8)"
curl -fsS -H "traceparent: 00-${trace_id}-${parent_id}-01" "http://127.0.0.1:${app_port}/?name=tracing" \
  >"${WORK}/response.json"
log_info "sent GET / with trace ID ${trace_id}"

# Tempo answers 200 with an empty trace ({"trace":{}}) until the spans are
# ingested, so wait for at least one span, not for the status code.
trace_found() {
  local i
  for i in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:${tempo_port}/api/v2/traces/${trace_id}" -o "${WORK}/trace.json" 2>/dev/null &&
      jq -e '[.trace.resourceSpans[]?.scopeSpans[]?.spans[]?] | length > 0' "${WORK}/trace.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Reduces the Tempo response (OTLP JSON; IDs may be hex or base64) to the
# facts the checks need: server span names, parent span IDs in hex, and the
# resource and span attributes as flat maps.
summarise_trace() {
  python3 -I - "${WORK}/trace.json" >"${WORK}/trace-summary.json" <<'PY'
import base64, json, re, sys

def hexid(value):
    if not value:
        return ""
    if re.fullmatch(r"[0-9a-fA-F]+", value) and len(value) in (16, 32):
        return value.lower()
    return base64.b64decode(value).hex()

def attrs(items):
    out = {}
    for item in items or []:
        value = item.get("value", {})
        out[item["key"]] = next((str(v) for v in value.values()), "")
    return out

doc = json.load(open(sys.argv[1]))
batches = doc.get("trace", doc).get("resourceSpans") or doc.get("trace", doc).get("batches") or []
summary = {"servers": [], "resource": {}, "span": {}}
for batch in batches:
    summary["resource"].update(attrs(batch.get("resource", {}).get("attributes")))
    for scope in batch.get("scopeSpans") or batch.get("instrumentationLibrarySpans") or []:
        for span in scope.get("spans", []):
            if span.get("kind") in ("SPAN_KIND_SERVER", 2):
                summary["servers"].append({"name": span.get("name"), "parent": hexid(span.get("parentSpanId"))})
                summary["span"].update(attrs(span.get("attributes")))
json.dump(summary, sys.stdout)
PY
}

summary() {
  jq -r "$1" "${WORK}/trace-summary.json"
}

check "Tempo returns the trace ${trace_id}" trace_found
summarise_trace || die "could not parse the Tempo response, see ${WORK}/trace.json"
check "the trace holds one server span named 'GET /'" \
  test "$(summary '[.servers[] | select(.name == "GET /")] | length')" = 1
check "the server span is a child of the caller's span ${parent_id}" \
  test "$(summary '.servers[0].parent')" = "${parent_id}"
check "resource service.name is hello-api" test "$(summary '.resource["service.name"]')" = hello-api
check "resource k8s.namespace.name is ${NAMESPACE}" test "$(summary '.resource["k8s.namespace.name"]')" = "${NAMESPACE}"
check "resource k8s.pod.name is set" test -n "$(summary '.resource["k8s.pod.name"] // ""')"
check "resource deployment.environment.name is ${NAMESPACE}" \
  test "$(summary '.resource["deployment.environment.name"]')" = "${NAMESPACE}"
check "span attribute http.route is /" test "$(summary '.span["http.route"]')" = /

kubectl -n "${NAMESPACE}" logs deploy/hello-api >"${WORK}/app.log"
# shellcheck disable=SC2016 # $t is a jq variable
check "the access log line carries trace_id ${trace_id}" \
  jq -e -s --arg t "${trace_id}" 'any(.[]; .msg == "request" and .trace_id == $t)' "${WORK}/app.log"

curl -fsS -H 'Accept: application/openmetrics-text; version=1.0.0' "http://127.0.0.1:${app_port}/metrics" >"${WORK}/metrics.txt"
check "http_requests_total carries an exemplar with the trace ID" \
  grep -E "^http_requests_total\{.*handler=\"/\".*\} [0-9.e+]+ # \{trace_id=\"${trace_id}\"\}" "${WORK}/metrics.txt"
check "http_request_duration_seconds carries an exemplar with the trace ID" \
  grep -E "^http_request_duration_seconds_bucket\{.*\} [0-9.e+]+ # \{trace_id=\"${trace_id}\"\}" "${WORK}/metrics.txt"

kubectl -n "${NAMESPACE}" get networkpolicy hello-api -o json >"${WORK}/networkpolicy.json"
check "the app NetworkPolicy allows egress to the tracing namespace on 4318" \
  jq -e 'any(.spec.egress[]; any(.to[]; .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "tracing") and any(.ports[]; .port == 4318))' \
  "${WORK}/networkpolicy.json"

# ---------------------------------------------------------------------------
# 6. Server-side validation of the other helm-common options against the
#    CRDs of the pinned Envoy Gateway and KEDA charts: the API server applies
#    the OpenAPI schema and the CEL rules of the CRDs (dry run, nothing runs).
# ---------------------------------------------------------------------------
eg_version="$(yq -r '.dependencies[] | select(.name == "gateway-crds-helm") | .version' \
  "${REPO_ROOT}/helmcharts/system-charts/gateway-api/Chart.yaml")"
keda_version="$(yq -r '.dependencies[] | select(.name == "keda") | .version' \
  "${REPO_ROOT}/helmcharts/system-charts/keda/Chart.yaml")"
log_info "installing Gateway API and Envoy Gateway CRDs ${eg_version}, KEDA CRDs ${keda_version}"
helm template crds oci://docker.io/envoyproxy/gateway-crds-helm --version "${eg_version}" \
  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=true |
  yq 'select(.kind == "CustomResourceDefinition")' |
  kubectl apply --server-side -f - >/dev/null
helm template keda keda --repo https://kedacore.github.io/charts --version "${keda_version}" --namespace keda |
  yq 'select(.kind == "CustomResourceDefinition")' |
  kubectl apply --server-side -f - >/dev/null
kubectl wait --for=condition=Established --timeout=60s \
  crd/backendtrafficpolicies.gateway.envoyproxy.io crd/httproutes.gateway.networking.k8s.io crd/scaledobjects.keda.sh >/dev/null

helm template hello-api "${WORK}/helmcharts/app-charts/hello-api" --namespace "${NAMESPACE}" \
  --values "${REPO_ROOT}/helmcharts/app-charts/hello-api/ci/extras-values.yaml" \
  --set global.environment="${NAMESPACE}" --set global.domain=localtest.me \
  --set trafficPolicy.enabled=true --set trafficPolicy.rateLimit.enabled=true \
  --set keda.enabled=true --set autoscaling.enabled=false \
  >"${WORK}/extras.yaml"
for kind in HTTPRoute BackendTrafficPolicy ScaledObject; do
  yq "select(.kind == \"${kind}\")" "${WORK}/extras.yaml" >"${WORK}/extras-${kind}.yaml"
  check "the API server accepts the rendered ${kind} (dry run)" \
    bash -c "test -s '${WORK}/extras-${kind}.yaml' && kubectl apply --dry-run=server -n '${NAMESPACE}' -f '${WORK}/extras-${kind}.yaml'"
done

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if ((FAILED > 0)); then
  log_error "details in ${WORK}/checks.log (kept only with KEEP_CLUSTER=1)"
  [[ "${KEEP_CLUSTER:-0}" == "1" ]] && cp -R "${WORK}" "${WORK}.kept" && log_warn "copied work files to ${WORK}.kept"
fi
log_info "${PASSED} checks passed, ${FAILED} failed"
((FAILED == 0))
