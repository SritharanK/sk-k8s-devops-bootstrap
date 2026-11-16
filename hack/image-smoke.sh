#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Container smoke test for every sample service (make image-smoke).
#
# For each sample-services/<service>/Dockerfile, or only the services given as
# arguments:
#   1. builds the image as local/<service>:smoke;
#   2. runs it the way the Helm chart and the restricted Pod Security profile
#      do: read-only root file system, all capabilities dropped,
#      no-new-privileges, non-root UID 65532, a writable /tmp only;
#   3. waits for GET /readyz to return 200, then checks GET /healthz (200)
#      and GET /metrics (Prometheus exposition format);
#   4. stops the container.
#
# Runtime contract: port 8080, endpoints /healthz, /readyz and /metrics, UID 65532.
#
# Usage: hack/image-smoke.sh [SERVICE...]
# Environment: SMOKE_TIMEOUT seconds to wait for readiness (default 30).
# Requirements: docker (with a running daemon), curl.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

require_cmd docker curl

PORT=8080
UID_GID="65532:65532"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

cd "$REPO_ROOT" || die "cannot enter ${REPO_ROOT}"

services=()
if (($# > 0)); then
  services=("$@")
else
  for f in sample-services/*/Dockerfile; do
    [[ -f "$f" ]] || continue
    services+=("$(basename "$(dirname "$f")")")
  done
fi
((${#services[@]} > 0)) || die "no sample-services/*/Dockerfile found"

docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"

# Idempotent: the container runs with --rm, so it is gone once stopped.
stop_container() {
  if [[ -n "$(docker ps --quiet --filter "id=$1")" ]]; then
    docker stop --time 5 "$1" >/dev/null || log_warn "could not stop container $1"
  fi
}

show_logs() {
  docker logs "$1" >&2 || log_warn "could not read the logs of container $1"
}

smoke() {
  local service="$1" image="local/${1}:smoke" cid host_port base i code
  [[ -f "sample-services/${service}/Dockerfile" ]] || die "no Dockerfile for ${service}"

  log_info "${service}: build ${image}"
  docker build --quiet --tag "$image" "sample-services/${service}" >/dev/null

  log_info "${service}: run read-only as ${UID_GID}"
  cid="$(docker run --detach --rm \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --cap-drop ALL --security-opt no-new-privileges \
    --user "$UID_GID" \
    --publish "127.0.0.1::${PORT}" \
    "$image")"
  add_cleanup "stop_container ${cid}"

  host_port="$(docker port "$cid" "${PORT}/tcp" | head -n1 | sed 's/.*://')"
  [[ -n "$host_port" ]] || die "${service}: port ${PORT} is not published"
  base="http://127.0.0.1:${host_port}"

  code=000
  for ((i = 0; i < TIMEOUT; i++)); do
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 "${base}/readyz")" || code=000
    [[ "$code" == "200" ]] && break
    if [[ "$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]]; then
      show_logs "$cid"
      die "${service}: container exited before it became ready"
    fi
    sleep 1
  done
  if [[ "$code" != "200" ]]; then
    show_logs "$cid"
    die "${service}: /readyz returned ${code} after ${TIMEOUT}s"
  fi

  curl --fail --silent --show-error --max-time 5 --output /dev/null "${base}/healthz" ||
    die "${service}: /healthz did not return 200"
  local metrics
  metrics="$(curl --fail --silent --show-error --max-time 5 "${base}/metrics")" ||
    die "${service}: /metrics did not return 200"
  grep -q '^# TYPE ' <<<"$metrics" ||
    die "${service}: /metrics is not in Prometheus exposition format"

  stop_container "$cid"
  log_info "${service}: ok (readyz, healthz, metrics; read-only, non-root, no capabilities)"
}

for s in "${services[@]}"; do
  smoke "$s"
done
