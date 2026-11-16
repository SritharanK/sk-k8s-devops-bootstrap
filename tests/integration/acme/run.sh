#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# ACME integration test: issues the platform gateway
# certificate from a local Pebble ACME server in a kind cluster.
#
#   1. Creates the single-node kind cluster it-acme (an existing one with the
#      same name is replaced).
#   2. Runs Pebble (test ACME server) behind a TLS certificate from a test CA
#      generated here, and pebble-challtestsrv as the DNS server for the
#      cluster domain. CoreDNS forwards that zone to challtestsrv, so Pebble
#      and cert-manager resolve the gateway host names the same way.
#   3. Builds a cluster definition from clusters/lab/cluster.yaml with
#      platform.issuer letsencrypt-staging, platform.acme.server and caBundle
#      pointing at Pebble, and explicit platform.gateway.hostnames; validates
#      it with hack/validate-config.sh.
#   4. Renders argocd-bootstrap with it and installs gateway-api,
#      cert-manager, envoy-gateway, misc and platform-gateway with helm, using
#      the path, value files and valuesObject of each rendered Application.
#   5. HTTP-01: waits for ClusterIssuer letsencrypt-staging and Certificate
#      platform-tls; records the solver HTTPRoute (listener http), checks the
#      Pebble validation log, the renewal time, the TLS handshake on the
#      https listener against the Pebble root only, and the plain HTTP
#      redirect; then forces a renewal and checks that a new certificate with
#      a new key is served.
#   6. DNS-01 (with --dns01): replaces challtestsrv by BIND with a TSIG key
#      for the cluster domain, switches platform.acme.solver to dns01 with the
#      rfc2136 provider and checks the wildcard certificate the same way.
#   7. Deletes the cluster, unless --keep.
#
# Evidence (served certificates, solver route, Pebble log, resources) is
# written to _out/integration/acme/.
#
# Usage: tests/integration/acme/run.sh [--dns01] [--keep]
# Environment:
#   ACME_CLUSTER       kind cluster name (default it-acme)
#   ACME_DNS01=1       same as --dns01
#   ACME_KEEP=1        same as --keep
#   ACME_MIN_FREE_MIB  free Docker memory required before the cluster is
#                      created (default 2500)
#   ACME_TIMEOUT       seconds to wait for each readiness check (default 300)
# Requirements: docker, kind, kubectl, helm, yq v4, jq, openssl, and uvx or
# check-jsonschema for hack/validate-config.sh. Network access to the chart
# and image registries.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/common.sh"

require_cmd docker kind kubectl helm yq jq openssl

usage() {
  sed -n '3,/^# and image registries/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CLUSTER="${ACME_CLUSTER:-it-acme}"
DNS01="${ACME_DNS01:-0}"
KEEP="${ACME_KEEP:-0}"
MIN_FREE_MIB="${ACME_MIN_FREE_MIB:-2500}"
TIMEOUT="${ACME_TIMEOUT:-300}"
for arg in "$@"; do
  case "$arg" in
    --dns01) DNS01=1 ;;
    --keep) KEEP=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# Pinned test images. Pebble and challtestsrv are released together.
KIND_NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
PEBBLE_IMAGE="ghcr.io/letsencrypt/pebble:2.10.3@sha256:0c81f05db371f436c97fb894bd6d2ab8fc9c8e2ce40f8bef8a8e15941bcd75ef"
CHALLTESTSRV_IMAGE="ghcr.io/letsencrypt/pebble-challtestsrv:2.10.3@sha256:0152c8cb506e2ecba2900ed47d23932e27e3e6575a7d2c8ef93c7719ee3dea4c"
CURL_IMAGE="curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93"
# BIND: the ISC image is amd64 only; this one is multi-arch.
BIND_IMAGE="ubuntu/bind9:9.20-26.04_stable@sha256:7cb9c4d3f8d6457a38ddf6a5d8e5e1cba75907985946cebf696eb5bba39637cc"

LAB_FILE="${REPO_ROOT}/clusters/lab/cluster.yaml"
DOMAIN="$(yq -r '.cluster.domain' "$LAB_FILE")"
GW_NS="$(yq -r '.namespaces.gateway // "envoy-gateway-system"' "$LAB_FILE")"
CM_NS="$(yq -r '.namespaces.certManager // "cert-manager"' "$LAB_FILE")"
# ACME HTTP-01 issues no wildcard: the certificate lists the Argo CD host and
# <app>.<env>.<domain> for every app environment the lab cluster hosts, the
# names hack/validate-config.sh requires.
HOSTNAMES=("argocd.${DOMAIN}")
HOSTED="$(yq -o=json -I=0 '.cluster.environments // ["dev", "stage", "prod"]' "$LAB_FILE")"
# shellcheck disable=SC2016 # $a and $e are yq variables
while IFS= read -r route; do
  [[ -n "$route" ]] && HOSTNAMES+=("${route}.${DOMAIN}")
done < <(HOSTED="$HOSTED" yq -r '.apps[] as $a | $a.environments[] | select(. as $e | env(HOSTED) | contains([$e])) | $a.name + "." + .' "${REPO_ROOT}/argocd-bootstrap/values.yaml")
PEBBLE_NS=pebble
CHECK_NS=acme-check
ACME_SERVER="https://pebble.${PEBBLE_NS}.svc.cluster.local:14000/dir"
TOOLCHAINS=(gateway-api cert-manager envoy-gateway misc platform-gateway)
EVIDENCE="${REPO_ROOT}/_out/integration/acme"
TSIG_KEY_NAME=acme-update

make_temp_dir WORK acme
mkdir -p "$EVIDENCE"

k() { kubectl --context "kind-${CLUSTER}" "$@"; }
h() { helm --kube-context "kind-${CLUSTER}" "$@"; }

# Collected on any failed wait, before the cluster is deleted.
diagnose() {
  log_warn "diagnostics follow (also in ${EVIDENCE}/diagnostics.txt)"
  {
    k get clusterissuers,certificates,certificaterequests,orders,challenges -A -o wide
    k get gateway,httproute -A
    k -n "$GW_NS" describe certificate platform-tls
    k get challenges -A -o yaml
    k -n "$CM_NS" logs deploy/cert-manager --tail=80
    k -n "$PEBBLE_NS" logs deploy/pebble --tail=80
  } >"${EVIDENCE}/diagnostics.txt" 2>&1 || true
  tail -n 60 "${EVIDENCE}/diagnostics.txt" >&2
}

# wait_until DESCRIPTION COMMAND...
wait_until() {
  local what="$1" deadline=$((SECONDS + TIMEOUT))
  shift
  log_info "waiting for ${what}"
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      diagnose
      die "timed out after ${TIMEOUT}s waiting for ${what}"
    fi
    sleep 5
  done
}

docker_free_mib() {
  local total used
  total=$(($(docker info --format '{{.MemTotal}}') / 1048576))
  used="$(docker stats --no-stream --format '{{.MemUsage}}' | awk '
    { v = $1; u = v; gsub(/[0-9.]/, "", u); sub(/[A-Za-z]+$/, "", v)
      m = (u == "GiB") ? 1024 : (u == "MiB") ? 1 : (u == "KiB") ? 1 / 1024 : 0
      s += v * m }
    END { printf "%d", s }')"
  echo $((total - used))
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    log_info "replacing existing kind cluster ${CLUSTER}"
    kind delete cluster --name "$CLUSTER"
  fi
  local free
  free="$(docker_free_mib)"
  log_info "free Docker memory: ${free} MiB (required ${MIN_FREE_MIB})"
  ((free >= MIN_FREE_MIB)) || die "not enough free Docker memory; stop another kind cluster or set ACME_MIN_FREE_MIB"
  if [[ "$KEEP" != 1 ]]; then
    add_cleanup "kind delete cluster --name '${CLUSTER}' >/dev/null 2>&1 || true"
  fi
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
}

# ---------------------------------------------------------------------------
# Test CA and Pebble
# ---------------------------------------------------------------------------
make_pebble_tls() {
  local d="${WORK}/tls"
  mkdir -p "$d"
  openssl ecparam -name prime256v1 -genkey -noout -out "${d}/ca.key" 2>/dev/null
  openssl req -x509 -new -key "${d}/ca.key" -sha256 -days 2 \
    -subj "/CN=ACME integration test CA" -out "${d}/ca.crt" 2>/dev/null
  openssl ecparam -name prime256v1 -genkey -noout -out "${d}/tls.key" 2>/dev/null
  openssl req -new -key "${d}/tls.key" -subj "/CN=pebble" -out "${d}/tls.csr" 2>/dev/null
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=DNS:pebble.${PEBBLE_NS}.svc.cluster.local,DNS:pebble.${PEBBLE_NS}.svc,DNS:pebble" \
    >"${d}/ext.cnf"
  openssl x509 -req -in "${d}/tls.csr" -CA "${d}/ca.crt" -CAkey "${d}/ca.key" \
    -CAcreateserial -days 2 -sha256 -extfile "${d}/ext.cnf" -out "${d}/tls.crt" 2>/dev/null
  CA_BUNDLE="$(base64 <"${d}/ca.crt" | tr -d '\n')"
}

deploy_pebble() {
  local d="${WORK}/tls"
  k create namespace "$PEBBLE_NS"
  k -n "$PEBBLE_NS" create secret tls pebble-tls --cert="${d}/tls.crt" --key="${d}/tls.key"
  # Validation on the standard ports, 90-day certificates as Let's Encrypt.
  k -n "$PEBBLE_NS" create configmap pebble-config --from-literal=pebble-config.json='{
  "pebble": {
    "listenAddress": "0.0.0.0:14000",
    "managementListenAddress": "0.0.0.0:15000",
    "certificate": "/tls/tls.crt",
    "privateKey": "/tls/tls.key",
    "httpPort": 80,
    "tlsPort": 443,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false,
    "domainBlocklist": [],
    "retryAfter": {"authz": 3, "order": 5},
    "keyAlgorithm": "ecdsa",
    "profiles": {"default": {"description": "90 days", "validityPeriod": 7776000}}
  }
}'
  k apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: challtestsrv
  namespace: ${PEBBLE_NS}
spec:
  selector:
    matchLabels: {app: challtestsrv}
  template:
    metadata:
      labels: {app: challtestsrv}
    spec:
      containers:
        - name: challtestsrv
          image: ${CHALLTESTSRV_IMAGE}
          # DNS and management only; unknown names get no address.
          args: [-defaultIPv4, "", -defaultIPv6, "", -http01, "", -https01, "", -tlsalpn01, "", -dnsserver, ":8053", -management, ":8055"]
          ports:
            - {name: dns-udp, containerPort: 8053, protocol: UDP}
            - {name: dns-tcp, containerPort: 8053, protocol: TCP}
            - {name: management, containerPort: 8055}
---
apiVersion: v1
kind: Service
metadata:
  name: challtestsrv
  namespace: ${PEBBLE_NS}
spec:
  selector: {app: challtestsrv}
  ports:
    - {name: dns-udp, port: 53, targetPort: 8053, protocol: UDP}
    - {name: dns-tcp, port: 53, targetPort: 8053, protocol: TCP}
    - {name: management, port: 8055, targetPort: 8055}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pebble
  namespace: ${PEBBLE_NS}
spec:
  selector:
    matchLabels: {app: pebble}
  template:
    metadata:
      labels: {app: pebble}
    spec:
      containers:
        - name: pebble
          image: ${PEBBLE_IMAGE}
          # No -dnsserver: Pebble uses the cluster DNS, like cert-manager.
          args: [-config, /config/pebble-config.json, -strict]
          env:
            - {name: PEBBLE_VA_NOSLEEP, value: "1"}
            - {name: PEBBLE_WFE_NONCEREJECT, value: "0"}
            # Every order is validated again, also the renewal.
            - {name: PEBBLE_AUTHZREUSE, value: "0"}
          ports:
            - {name: acme, containerPort: 14000}
            - {name: management, containerPort: 15000}
          volumeMounts:
            - {name: config, mountPath: /config}
            - {name: tls, mountPath: /tls}
      volumes:
        - name: config
          configMap: {name: pebble-config}
        - name: tls
          secret: {secretName: pebble-tls}
---
apiVersion: v1
kind: Service
metadata:
  name: pebble
  namespace: ${PEBBLE_NS}
spec:
  selector: {app: pebble}
  ports:
    - {name: acme, port: 14000}
    - {name: management, port: 15000}
EOF
  k -n "$PEBBLE_NS" rollout status deploy/challtestsrv --timeout="${TIMEOUT}s"
  k -n "$PEBBLE_NS" rollout status deploy/pebble --timeout="${TIMEOUT}s"
}

# Toolbox pod for HTTP calls from inside the cluster. The test CA is mounted
# so the Pebble management API is verified as well.
deploy_toolbox() {
  k create namespace "$CHECK_NS"
  k -n "$CHECK_NS" create configmap test-ca --from-file=ca.crt="${WORK}/tls/ca.crt"
  k apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  namespace: ${CHECK_NS}
spec:
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command: [sleep, "86400"]
      volumeMounts:
        - {name: test-ca, mountPath: /test-ca}
  volumes:
    - name: test-ca
      configMap: {name: test-ca}
EOF
  k -n "$CHECK_NS" wait pod/toolbox --for=condition=Ready --timeout="${TIMEOUT}s"
}

toolbox() { k -n "$CHECK_NS" exec toolbox -- "$@"; }

# point_zone_at IP: CoreDNS forwards the cluster domain to IP:53, without
# caching, so new records are visible at once.
point_zone_at() {
  local ip="$1" corefile
  corefile="$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
    awk -v d="$DOMAIN" '$0 ~ "^" d ":53 \\{" { skip = 1 } !skip { print } skip && /^}/ { skip = 0 }')"
  corefile+=$'\n'"${DOMAIN}:53 {"$'\n'"    errors"$'\n'"    forward . ${ip}:53"$'\n'"}"
  k -n kube-system create configmap coredns --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n kube-system rollout restart deploy/coredns >/dev/null
  k -n kube-system rollout status deploy/coredns --timeout="${TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Platform charts, installed as the rendered Applications describe them
# ---------------------------------------------------------------------------
# write_cluster_file SOLVER: test cluster definition from the lab file.
write_cluster_file() {
  local solver="$1" hosts_json
  hosts_json="$(printf '%s\n' "${HOSTNAMES[@]}" | jq -R . | jq -sc .)"
  CLUSTER_FILE="${WORK}/cluster.yaml"
  SOLVER="$solver" SERVER="$ACME_SERVER" CA="$CA_BUNDLE" HOSTS="$hosts_json" \
    yq '
      .platform.issuer = "letsencrypt-staging" |
      .platform.acme.solver = strenv(SOLVER) |
      .platform.acme.server = strenv(SERVER) |
      .platform.acme.caBundle = strenv(CA) |
      .platform.gateway.hostnames = (strenv(HOSTS) | fromjson) |
      .toolchains.misc.enabled = true |
      .toolchains.misc.values.issuers.letsencrypt.enabled = false
    ' "$LAB_FILE" >"$CLUSTER_FILE"
  if [[ "$solver" == dns01 ]]; then
    NS_ADDR="${BIND_IP}:53" KEYNAME="$TSIG_KEY_NAME" yq -i '
      .platform.acme.dns01 = {
        "provider": "rfc2136",
        "config": {"nameserver": strenv(NS_ADDR), "tsigKeyName": strenv(KEYNAME), "tsigAlgorithm": "HMACSHA256"},
        "credentialsSecretRef": {"name": "rfc2136-tsig", "key": "tsig-secret"}
      }' "$CLUSTER_FILE"
  fi
  "${REPO_ROOT}/hack/validate-config.sh" "$CLUSTER_FILE"
  cp "$CLUSTER_FILE" "${EVIDENCE}/cluster-${solver}.yaml"
}

render_applications() {
  helm template argocd-bootstrap "${REPO_ROOT}/argocd-bootstrap" -f "$CLUSTER_FILE" \
    --set-string git.repoURL=https://github.com/YOUR_ORG/sk-k8s-devops-bootstrap.git \
    --set-string git.targetRevision=main >"${WORK}/applications.yaml"
}

# install_toolchain NAME: helm install of the chart the Application points to,
# with its value files and valuesObject (which wins, as in Argo CD).
install_toolchain() {
  local name="$1" app path release ns vf
  app="${WORK}/app-${name}.yaml"
  NAME="$name" yq 'select(.kind == "Application" and (.spec.source.path | test("/" + strenv(NAME) + "$")))' \
    "${WORK}/applications.yaml" >"$app"
  [[ -s "$app" ]] || die "no Application rendered for toolchain ${name}"
  path="${REPO_ROOT}/$(yq -r '.spec.source.path' "$app")"
  release="$(yq -r '.spec.source.helm.releaseName // .metadata.name' "$app")"
  ns="$(yq -r '.spec.destination.namespace' "$app")"
  yq '.spec.source.helm.valuesObject // {}' "$app" >"${WORK}/values-${name}.yaml"
  local args=(upgrade --install "$release" "$path" --namespace "$ns" --create-namespace
    --timeout "${TIMEOUT}s")
  # helm --wait also waits for the Certificate of platform-gateway, which
  # becomes Ready only after the DNS records below are in place.
  [[ "$name" == platform-gateway ]] || args+=(--wait)
  while IFS= read -r vf; do
    [[ -f "${path}/${vf}" ]] && args+=(-f "${path}/${vf}")
  done < <(yq -r '.spec.source.helm.valueFiles[]' "$app")
  args+=(-f "${WORK}/values-${name}.yaml")
  if yq -e '.dependencies | length > 0' "${path}/Chart.yaml" >/dev/null 2>&1; then
    helm dependency build "$path" >/dev/null
  fi
  log_info "installing ${name} into ${ns}"
  # The cert-manager webhook can take a few seconds after its rollout.
  local attempt
  for attempt in 1 2 3; do
    h "${args[@]}" >/dev/null && return 0
    log_warn "helm install of ${name} failed (attempt ${attempt}), retrying"
    sleep 10
  done
  die "helm install of ${name} failed"
}

install_platform() {
  local t
  for t in "${TOOLCHAINS[@]}"; do
    install_toolchain "$t"
  done
}

gateway_ip() {
  k -n "$GW_NS" get service \
    -l "gateway.envoyproxy.io/owning-gateway-name=platform,gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}" \
    -o jsonpath='{.items[0].spec.clusterIP}'
}

gateway_ip_set() { [[ -n "$(gateway_ip)" ]]; }

# Fixed node ports of the lab profile, as "<listener>=<port>" pairs.
LAB_NODE_PORTS="$(yq -r '.proxy.service.nodePorts // {} | to_entries | map(.key + "=" + (.value | tostring)) | sort | join(" ")' \
  "${REPO_ROOT}/helmcharts/system-charts/platform-gateway/values-lab.yaml")"

# node_ports_match: the proxy Service exposes exactly the lab node ports
# (Envoy Gateway names its ports <listener>-<port>).
node_ports_match() {
  local got
  got="$(k -n "$GW_NS" get service \
    -l "gateway.envoyproxy.io/owning-gateway-name=platform,gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}" -o json |
    jq -r '[.items[0].spec.ports[] | select(.nodePort) | "\(.name | sub("-[0-9]+$"; ""))=\(.nodePort)"] | sort | join(" ")')"
  [[ "$got" == "$LAB_NODE_PORTS" ]]
}

node_ip() {
  k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
issuer_ready() {
  [[ "$(k get clusterissuer letsencrypt-staging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]]
}

cert_ready_at_revision() {
  local want="$1"
  [[ "$(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] &&
    (($(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.revision}' || echo 0) >= want))
}

# start_watch PHASE: records every Challenge and every HTTP-01 solver
# HTTPRoute (JSON lines) while they exist; cert-manager deletes both once the
# order is valid.
start_watch() {
  local phase="$1"
  : >"${EVIDENCE}/${phase}-challenges.jsonl"
  : >"${EVIDENCE}/${phase}-solver-httproutes.jsonl"
  (
    while :; do
      k -n "$GW_NS" get challenges.acme.cert-manager.io -o json 2>/dev/null |
        jq -c '.items[] | {name: .metadata.name, type: .spec.type, dnsName: .spec.dnsName, wildcard: .spec.wildcard, solver: .spec.solver, state: .status.state}' \
          >>"${EVIDENCE}/${phase}-challenges.jsonl" 2>/dev/null || true
      k -n "$GW_NS" get httproute -l acme.cert-manager.io/http01-solver=true -o json 2>/dev/null |
        jq -c '.items[] | {name: .metadata.name, hostnames: .spec.hostnames, parentRefs: .spec.parentRefs, rules: .spec.rules, status: .status}' \
          >>"${EVIDENCE}/${phase}-solver-httproutes.jsonl" 2>/dev/null || true
      sleep 2
    done
  ) &
  WATCH_PID=$!
  add_cleanup "kill ${WATCH_PID} 2>/dev/null || true"
}

stop_watch() { kill "$WATCH_PID" 2>/dev/null || true; }

# check_challenges PHASE TYPE NAME...: every challenge seen has TYPE and one
# was seen for each NAME (wildcards as *.<base>).
check_challenges() {
  local phase="$1" type="$2" out seen n
  shift 2
  out="${EVIDENCE}/${phase}-challenges.jsonl"
  [[ -s "$out" ]] || die "no Challenge was observed in ${phase}"
  [[ "$(jq -r '.type' "$out" | sort -u)" == "$type" ]] || die "${phase}: challenges other than ${type} were used"
  seen="$(jq -r 'if .wildcard then "*." + .dnsName else .dnsName end' "$out" | sort -u | tr '\n' ' ')"
  for n in "$@"; do
    [[ " $seen" == *" $n "* ]] || die "${phase}: no ${type} challenge for ${n}"
  done
  log_info "${phase}: ${type} challenges for ${seen}"
}

# check_solver_routes PHASE: the solver routes attached to listener http of
# Gateway platform only, one per host name.
check_solver_routes() {
  local out="${EVIDENCE}/${1}-solver-httproutes.jsonl" sections hosts hn
  [[ -s "$out" ]] || die "no HTTP-01 solver HTTPRoute was observed"
  sections="$(jq -r '.parentRefs[] | "\(.namespace)/\(.name)/\(.sectionName)"' "$out" | sort -u | tr '\n' ' ')"
  hosts="$(jq -r '.hostnames[]' "$out" | sort -u | tr '\n' ' ')"
  log_info "solver HTTPRoutes attached to: ${sections}; hosts: ${hosts}"
  [[ "$sections" == "${GW_NS}/platform/http " ]] || die "solver routes did not attach to listener http only"
  for hn in "${HOSTNAMES[@]}"; do
    [[ " $hosts" == *" $hn "* ]] || die "no solver route for ${hn}"
  done
}

# check_pebble_http PHASE: Pebble fetched the token of every host name on
# port 80.
check_pebble_http() {
  local log="${EVIDENCE}/${1}-pebble.log" n
  k -n "$PEBBLE_NS" logs deploy/pebble >"$log"
  for n in "${HOSTNAMES[@]}"; do
    grep -qF "Attempting to validate w/ HTTP: http://${n}:80/.well-known/acme-challenge/" "$log" ||
      die "Pebble log shows no HTTP-01 validation for ${n}"
  done
  log_info "Pebble validated ${HOSTNAMES[*]} over HTTP on port 80"
}

# check_bind_updates NAME...: BIND accepted a TSIG-signed TXT update for the
# _acme-challenge record of every name (wildcards share their base name).
check_bind_updates() {
  local log="${EVIDENCE}/dns01-bind.log" n base
  k -n "$PEBBLE_NS" logs deploy/bind >"$log"
  for n in "$@"; do
    base="${n#\*.}"
    grep -F "/key ${TSIG_KEY_NAME}:" "$log" | grep -qF "adding an RR at '_acme-challenge.${base}' TXT" ||
      die "BIND log shows no signed TXT update for _acme-challenge.${base}"
  done
  log_info "BIND accepted TSIG-signed TXT updates for $*"
}

fetch_pebble_root() {
  toolbox curl -fsS --cacert /test-ca/ca.crt \
    "https://pebble.${PEBBLE_NS}.svc.cluster.local:15000/roots/0" >"${WORK}/pebble-root.pem"
  k -n "$CHECK_NS" exec -i toolbox -- sh -c 'cat >/tmp/pebble-root.pem' <"${WORK}/pebble-root.pem"
  cp "${WORK}/pebble-root.pem" "${EVIDENCE}/pebble-root.pem"
}

secret_leaf_fingerprint() {
  k -n "$GW_NS" get secret platform-tls -o jsonpath='{.data.tls\.crt}' | base64 -d |
    openssl x509 -noout -fingerprint -sha256 | cut -d= -f2
}

# served_leaf HOST IP OUT: TLS handshake on 443 that trusts the Pebble root
# only; the served leaf certificate is written to OUT.
served_leaf() {
  local host="$1" ip="$2" out="$3"
  toolbox curl -sS -o /dev/null --cacert /tmp/pebble-root.pem \
    --resolve "${host}:443:${ip}" -w '%{certs}' "https://${host}/" |
    awk '/-----BEGIN CERTIFICATE-----/ { n++ } n == 1 { print } /-----END CERTIFICATE-----/ && n == 1 { exit }' >"$out"
  [[ -s "$out" ]]
}

# serves_current HOST IP LEAF WANT: the served leaf has fingerprint WANT.
serves_current() {
  served_leaf "$1" "$2" "$3" &&
    [[ "$(openssl x509 -in "$3" -noout -fingerprint -sha256 | cut -d= -f2)" == "$4" ]]
}

# check_https HOST... : every host presents the platform-tls certificate,
# issued by Pebble and verified against the Pebble root alone.
check_https() {
  local ip want host leaf got
  ip="$(gateway_ip)"
  want="$(secret_leaf_fingerprint)"
  for host in "$@"; do
    leaf="${EVIDENCE}/served-${host}.pem"
    wait_until "https on ${host} to serve the current platform-tls certificate" \
      serves_current "$host" "$ip" "$leaf" "$want"
    got="$(openssl x509 -in "$leaf" -noout -issuer -serial -enddate | tr '\n' ' ')"
    log_info "${host}: ${got}"
    openssl x509 -in "$leaf" -noout -issuer | grep -q "Pebble Intermediate" ||
      die "${host} is not served a Pebble-issued certificate"
  done
}

# check_node_port_https: the https node port of the lab profile serves the
# certificate, the path kind maps to host port 443.
check_node_port_https() {
  local port host="${HOSTNAMES[0]}" ip
  port="$(yq -r '.proxy.service.nodePorts.https' "${REPO_ROOT}/helmcharts/system-charts/platform-gateway/values-lab.yaml")"
  ip="$(node_ip)"
  # No -f: any HTTP status is fine, a TLS or connection error is not.
  toolbox curl -sS -o /dev/null --cacert /tmp/pebble-root.pem \
    --resolve "${host}:${port}:${ip}" "https://${host}:${port}/" ||
    die "TLS through node port ${port} failed for ${host}"
  log_info "node port ${port} on ${ip} serves ${host} with a certificate trusted through the Pebble root"
}

check_http_redirect() {
  local ip code
  ip="$(gateway_ip)"
  code="$(toolbox curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' \
    --resolve "${HOSTNAMES[0]}:80:${ip}" "http://${HOSTNAMES[0]}/")"
  log_info "plain HTTP on ${HOSTNAMES[0]}: ${code}"
  [[ "$code" == "301 https://${HOSTNAMES[0]}/" ]] || die "unexpected HTTP redirect: ${code}"
}

check_renewal_config() {
  local not_after renewal expected
  not_after="$(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.notAfter}')"
  renewal="$(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.renewalTime}')"
  expected="$(jq -rn --arg t "$not_after" '$t | fromdateiso8601 - 720 * 3600 | todateiso8601')"
  log_info "platform-tls notAfter ${not_after}, renewalTime ${renewal} (expected ${expected})"
  [[ "$renewal" == "$expected" ]] || die "renewalTime is not notAfter minus renewBefore (720h)"
  k -n "$GW_NS" get certificate platform-tls -o yaml >"${EVIDENCE}/certificate-platform-tls.yaml"
}

# force_renewal: what cmctl renew does, a manual Issuing condition.
force_renewal() {
  local now gen
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gen="$(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.metadata.generation}')"
  k -n "$GW_NS" patch certificate platform-tls --subresource=status --type=json -p "[{
    \"op\": \"add\", \"path\": \"/status/conditions/-\",
    \"value\": {\"type\": \"Issuing\", \"status\": \"True\", \"reason\": \"ManuallyTriggered\",
      \"message\": \"Renewal triggered by the integration test\", \"lastTransitionTime\": \"${now}\",
      \"observedGeneration\": ${gen}}}]" >/dev/null
}

# ---------------------------------------------------------------------------
# DNS-01 through RFC2136
# ---------------------------------------------------------------------------
deploy_bind() {
  local secret ip
  secret="$(openssl rand -base64 32)"
  ip="$(gateway_ip)"
  k apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: bind
  namespace: ${PEBBLE_NS}
spec:
  selector: {app: bind}
  ports:
    - {name: dns-udp, port: 53, targetPort: 5353, protocol: UDP}
    - {name: dns-tcp, port: 53, targetPort: 5353, protocol: TCP}
EOF
  BIND_IP="$(k -n "$PEBBLE_NS" get service bind -o jsonpath='{.spec.clusterIP}')"
  k -n "$CM_NS" create secret generic rfc2136-tsig --from-literal=tsig-secret="$secret"
  # The image runs named as a non-root user: port 5353, no pid file, and the
  # update journal on a writable volume next to the read-only zone file. The
  # NS name resolves to the server itself, because the cert-manager
  # propagation check queries the authoritative servers of the zone directly.
  k -n "$PEBBLE_NS" create configmap bind-config \
    --from-literal=named.conf="key \"${TSIG_KEY_NAME}\" { algorithm hmac-sha256; secret \"${secret}\"; };
options {
  directory \"/var/cache/bind\"; pid-file none; session-keyfile \"/var/cache/bind/session.key\";
  listen-on port 5353 { any; }; listen-on-v6 { none; };
  recursion no; allow-query { any; }; dnssec-validation no;
};
zone \"${DOMAIN}\" {
  type primary; file \"/config/zone.db\"; journal \"/var/cache/bind/zone.db.jnl\";
  update-policy { grant ${TSIG_KEY_NAME} subdomain ${DOMAIN}. TXT; };
};" \
    --from-literal=zone.db="\$TTL 60
@ IN SOA ns.${DOMAIN}. hostmaster.${DOMAIN}. 1 60 60 3600 60
@ IN NS ns.${DOMAIN}.
ns IN A ${BIND_IP}
@ IN A ${ip}
* IN A ${ip}
"
  k apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bind
  namespace: ${PEBBLE_NS}
spec:
  selector:
    matchLabels: {app: bind}
  template:
    metadata:
      labels: {app: bind}
    spec:
      containers:
        - name: bind
          image: ${BIND_IMAGE}
          command: [/usr/sbin/named, -g, -c, /config/named.conf]
          ports:
            - {name: dns-udp, containerPort: 5353, protocol: UDP}
            - {name: dns-tcp, containerPort: 5353, protocol: TCP}
          volumeMounts:
            - {name: config, mountPath: /config}
            - {name: cache, mountPath: /var/cache/bind}
      volumes:
        - name: config
          configMap: {name: bind-config}
        - name: cache
          emptyDir: {}
EOF
  k -n "$PEBBLE_NS" rollout status deploy/bind --timeout="${TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
log_info "cluster ${CLUSTER}, domain ${DOMAIN}, hosts ${HOSTNAMES[*]}, evidence in ${EVIDENCE}"
create_cluster
make_pebble_tls
deploy_pebble
deploy_toolbox
point_zone_at "$(k -n "$PEBBLE_NS" get service challtestsrv -o jsonpath='{.spec.clusterIP}')"

log_info "phase 1: HTTP-01 through the gatewayHTTPRoute solver"
write_cluster_file http01
render_applications
start_watch http01
install_platform
wait_until "the platform Gateway service" gateway_ip_set
GW_IP="$(gateway_ip)"
# Before any DNS record exists, so the https listener has no certificate yet.
wait_until "the lab node ports (${LAB_NODE_PORTS}) on the proxy Service" node_ports_match
log_info "proxy Service exposes ${LAB_NODE_PORTS} while platform-tls is $(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}')"
for host in "${HOSTNAMES[@]}"; do
  toolbox curl -fsS -d "{\"host\":\"${host}\",\"addresses\":[\"${GW_IP}\"]}" \
    "http://challtestsrv.${PEBBLE_NS}.svc.cluster.local:8055/add-a" >/dev/null
done
log_info "challtestsrv resolves ${HOSTNAMES[*]} to the gateway ${GW_IP}"
wait_until "ClusterIssuer letsencrypt-staging Ready (Pebble account over the test CA)" issuer_ready
wait_until "Certificate platform-tls Ready" cert_ready_at_revision 1
stop_watch
check_challenges http01 HTTP-01 "${HOSTNAMES[@]}"
check_solver_routes http01
check_pebble_http http01
check_renewal_config
fetch_pebble_root
check_https "${HOSTNAMES[@]}"
check_node_port_https
check_http_redirect

log_info "renewal: forcing a re-issue of platform-tls"
old_fp="$(secret_leaf_fingerprint)"
old_key="$(k -n "$GW_NS" get secret platform-tls -o jsonpath='{.data.tls\.key}')"
start_watch renewal
force_renewal
wait_until "Certificate platform-tls Ready at revision 2" cert_ready_at_revision 2
stop_watch
check_challenges renewal HTTP-01 "${HOSTNAMES[@]}"
check_solver_routes renewal
check_pebble_http renewal
[[ "$(secret_leaf_fingerprint)" != "$old_fp" ]] || die "renewal kept the old certificate"
[[ "$(k -n "$GW_NS" get secret platform-tls -o jsonpath='{.data.tls\.key}')" != "$old_key" ]] ||
  die "renewal kept the old private key (rotationPolicy Always)"
check_https "${HOSTNAMES[@]}"
log_info "phase 1 passed"

if [[ "$DNS01" == 1 ]]; then
  log_info "phase 2: DNS-01 through RFC2136 (BIND with TSIG)"
  deploy_bind
  point_zone_at "$BIND_IP"
  write_cluster_file dns01
  render_applications
  rev="$(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{.status.revision}')"
  start_watch dns01
  install_toolchain misc
  install_toolchain platform-gateway
  wait_until "ClusterIssuer letsencrypt-staging Ready with the rfc2136 solver" issuer_ready
  wait_until "Certificate platform-tls Ready with the wildcard names" cert_ready_at_revision $((rev + 1))
  stop_watch
  names=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(k -n "$GW_NS" get certificate platform-tls -o jsonpath='{range .spec.dnsNames[*]}{@}{"\n"}{end}')
  log_info "dnsNames: ${names[*]}"
  check_challenges dns01 DNS-01 "${names[@]}"
  [[ "$(jq -r '.solver.dns01 | keys[]' "${EVIDENCE}/dns01-challenges.jsonl" | sort -u)" == rfc2136 ]] ||
    die "DNS-01 challenges did not use the rfc2136 solver"
  check_bind_updates "${names[@]}"
  check_renewal_config
  check_https "acme-check.${DOMAIN}" "hello-api.dev.${DOMAIN}" "any.prod.${DOMAIN}"
  log_info "phase 2 passed"
fi

k get clusterissuers,certificates -A -o wide >"${EVIDENCE}/resources.txt"
log_info "ACME integration test passed; evidence in ${EVIDENCE}"
