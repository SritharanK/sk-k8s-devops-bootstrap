#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Offline test of the vulnerability attestation gate of the image verification
# policy (templates/imagevalidatingpolicy.yaml). README.md in this directory
# states what the test proves and what it does not.
#
# The run starts a throwaway registry on 127.0.0.1, pushes one small image per
# case, signs each with an ephemeral cosign key, attests the predicates from
# predicates/ with fresh or old scan times, renders the policy from the chart
# with that public key, and runs `kyverno test` against the pushed digests.
# No transparency log, timestamp authority or Sigstore trust root is used.
#
# Images are pushed through the registry HTTP API instead of `docker push`:
# with Docker Desktop the daemon runs in a VM and cannot reach a registry
# bound to the loopback interface of the host.
#
# The run is idempotent: a registry container left over by an interrupted run
# is replaced, and the container, the keys and every temporary file are
# removed on exit.
#
# Usage:
#   run.sh   (or: make policy-test-attestations)
#
# Environment:
#   REGISTRY_NAME   Container name. Default: kyverno-policies-vuln-attestation.
#   REGISTRY_IMAGE  Registry image. Default: registry 3.1.2, pinned by digest.
#
# Requirements: docker, cosign 3.1.4 or later, kyverno CLI 1.20.0 or later,
# helm, jq, curl. Network access only to pull the registry image.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../../../../scripts/lib/common.sh
source "${HERE}/../../../../../scripts/lib/common.sh"

readonly CHART="${REPO_ROOT}/helmcharts/system-charts/kyverno-policies"
readonly REGISTRY_NAME="${REGISTRY_NAME:-kyverno-policies-vuln-attestation}"
readonly REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:3.1.2@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c}"
readonly KYVERNO_MIN="1.20.0"
readonly COSIGN_MIN="3.1.4"
readonly REPOSITORY="vuln-attestation"
readonly CASES=(pass accepted critical unfixed stale missing foreign renewed regressed)

require_cmd docker cosign kyverno helm jq curl
# check_version NAME VERSION MINIMUM
check_version() {
  if [[ -z "$2" ]]; then
    log_warn "could not read the $1 version; $3 or later is expected"
  elif ! version_ge "$2" "$3"; then
    die "$1 $2 is older than $3 (see mise.toml)"
  fi
}
check_version "kyverno CLI" "$(kyverno version 2>/dev/null | awk '/^Version:/ {v = $2} END {print v}')" "${KYVERNO_MIN}"
check_version cosign "$(cosign version 2>/dev/null | awk '/^GitVersion:/ {v = $2} END {print v}')" "${COSIGN_MIN}"

make_temp_dir WORK vuln-attestation
mkdir -p "${WORK}/keys" "${WORK}/images" "${WORK}/docker-config"
REFS="${WORK}/refs.tsv"
: >"${REFS}"

# cosign and kyverno read registry credentials from DOCKER_CONFIG. An empty
# one keeps the developer's credential helpers out of the run.
cosign_run() {
  DOCKER_CONFIG="${WORK}/docker-config" COSIGN_PASSWORD="" cosign "$@"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

size_of() {
  wc -c <"$1" | tr -d ' '
}

# upload_blob REPOSITORY FILE DIGEST: monolithic blob upload (POST, then PUT).
upload_blob() {
  local repo="$1" file="$2" digest="$3" location separator="?"
  location="$(curl -fsS -X POST -D - -o /dev/null "http://${REGISTRY}/v2/${repo}/blobs/uploads/" |
    tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')"
  [[ -n "${location}" ]] || die "registry returned no upload location for ${repo}"
  [[ "${location}" == http* ]] || location="http://${REGISTRY}${location}"
  [[ "${location}" != *\?* ]] || separator="&"
  curl -fsS -X PUT -H 'Content-Type: application/octet-stream' --data-binary "@${file}" \
    -o /dev/null "${location}${separator}digest=${digest}"
}

# push_image CASE: pushes a single-layer image whose only file, /case, holds
# the case name, so every case has its own digest. Records the digest
# reference in REFS.
push_image() {
  local name="$1" dir="${WORK}/images/$1" repo="${REPOSITORY}/$1"
  local layer_digest config_digest manifest_digest
  mkdir -p "${dir}/root"
  printf '%s\n' "${name}" >"${dir}/root/case"
  tar -cf "${dir}/layer.tar" -C "${dir}/root" case
  layer_digest="sha256:$(sha256_of "${dir}/layer.tar")"
  jq -cnj --arg diff "${layer_digest}" \
    '{architecture: "amd64", os: "linux", config: {}, rootfs: {type: "layers", diff_ids: [$diff]}}' \
    >"${dir}/config.json"
  config_digest="sha256:$(sha256_of "${dir}/config.json")"
  upload_blob "${repo}" "${dir}/layer.tar" "${layer_digest}"
  upload_blob "${repo}" "${dir}/config.json" "${config_digest}"
  jq -cnj \
    --arg config "${config_digest}" --argjson config_size "$(size_of "${dir}/config.json")" \
    --arg layer "${layer_digest}" --argjson layer_size "$(size_of "${dir}/layer.tar")" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
      config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $config, size: $config_size},
      layers: [{mediaType: "application/vnd.oci.image.layer.v1.tar", digest: $layer, size: $layer_size}]}' \
    >"${dir}/manifest.json"
  manifest_digest="sha256:$(sha256_of "${dir}/manifest.json")"
  curl -fsS -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary "@${dir}/manifest.json" -o /dev/null "http://${REGISTRY}/v2/${repo}/manifests/test"
  printf '%s\t%s\n' "${name}" "${REGISTRY}/${repo}@${manifest_digest}" >>"${REFS}"
}

ref_of() {
  awk -F '\t' -v name="$1" '$1 == name {print $2}' "${REFS}"
}

# attest CASE PREDICATE SCAN_TIME KEY: attests the predicate with both scan
# times set to SCAN_TIME (RFC 3339).
attest() {
  local name="$1" predicate="$2" scanned="$3" key="$4" file="${WORK}/images/$1/predicate.json"
  jq --arg t "${scanned}" '.metadata.scanStartedOn = $t | .metadata.scanFinishedOn = $t' \
    "${HERE}/predicates/${predicate}" >"${file}"
  cosign_run attest --yes --key "${key}" --signing-config "${WORK}/signing-config.json" \
    --type vuln --predicate "${file}" "$(ref_of "${name}")" >/dev/null 2>"${WORK}/cosign.log" || {
    cat "${WORK}/cosign.log" >&2
    die "cosign attest failed for ${name}"
  }
}

# ---------------------------------------------------------------------------
# 1. Registry on a free loopback port chosen by Docker
# ---------------------------------------------------------------------------
docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
add_cleanup "docker rm -f '${REGISTRY_NAME}' >/dev/null 2>&1 || true"
log_info "starting registry ${REGISTRY_NAME}"
docker run --detach --rm --name "${REGISTRY_NAME}" --publish 127.0.0.1::5000 "${REGISTRY_IMAGE}" >/dev/null
REGISTRY="$(docker port "${REGISTRY_NAME}" 5000/tcp | head -n 1)"
[[ "${REGISTRY}" == 127.0.0.1:* ]] || die "unexpected registry address: ${REGISTRY}"
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null && break
  sleep 1
done
curl -fsS -o /dev/null "http://${REGISTRY}/v2/" || die "registry on ${REGISTRY} did not become ready"
log_info "registry ready on ${REGISTRY}"

# ---------------------------------------------------------------------------
# 2. Images, keys, signatures and attestations
# ---------------------------------------------------------------------------
for name in "${CASES[@]}"; do
  push_image "${name}"
done

# Ephemeral key pairs: the signer of every image, and a foreign key that only
# attests the foreign case. They live in WORK and are removed on exit.
(cd "${WORK}/keys" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix signer >/dev/null 2>&1)
(cd "${WORK}/keys" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix foreign >/dev/null 2>&1)
# A signing config without services: no transparency log upload and no
# timestamp authority.
cosign signing-config create --out "${WORK}/signing-config.json" >/dev/null

log_info "signing and attesting with an ephemeral key"
for name in "${CASES[@]}"; do
  cosign_run sign --yes --key "${WORK}/keys/signer.key" --signing-config "${WORK}/signing-config.json" \
    "$(ref_of "${name}")" >/dev/null 2>"${WORK}/cosign.log" || {
    cat "${WORK}/cosign.log" >&2
    die "cosign sign failed for ${name}"
  }
done

now="$(jq -nr 'now | todate')"
two_days_ago="$(jq -nr '(now - 2 * 86400) | todate')"
month_ago="$(jq -nr '(now - 30 * 86400) | todate')"
attest pass clean.json "${now}" "${WORK}/keys/signer.key"
attest accepted accepted.json "${now}" "${WORK}/keys/signer.key"
attest critical critical.json "${now}" "${WORK}/keys/signer.key"
attest unfixed unfixed.json "${now}" "${WORK}/keys/signer.key"
attest stale clean.json "${month_ago}" "${WORK}/keys/signer.key"
attest foreign clean.json "${now}" "${WORK}/keys/foreign.key"
# Two attestations each, as after a rescan. The newest scan decides, not the
# order of upload: regressed gets its newer scan first.
attest renewed clean.json "${month_ago}" "${WORK}/keys/signer.key"
attest renewed clean.json "${now}" "${WORK}/keys/signer.key"
attest regressed critical.json "${now}" "${WORK}/keys/signer.key"
attest regressed clean.json "${two_days_ago}" "${WORK}/keys/signer.key"

# ---------------------------------------------------------------------------
# 3. kyverno test runs
# ---------------------------------------------------------------------------
resources="$(<"${HERE}/pods.yaml")"
for name in "${CASES[@]}"; do
  resources="${resources//<image:${name}>/$(ref_of "${name}")}"
done
if grep -q '^[[:space:]]*image: <image:' <<<"${resources}"; then
  die "pods.yaml references a case that run.sh does not push"
fi

# run_test NAME TEST_FILE [HELM_ARGS...]: renders the policy with the test key
# and registry plus HELM_ARGS into WORK/NAME, next to the pods and TEST_FILE
# as kyverno-test.yaml, and runs kyverno test. kyverno test compares the
# result of each pod with TEST_FILE; the messages land in WORK/NAME/results.json.
run_test() {
  local name="$1" test_file="$2" dir="${WORK}/$1" rc=0
  shift 2
  mkdir -p "${dir}"
  helm template kyverno-policies "${CHART}" --namespace kyverno \
    --show-only templates/imagevalidatingpolicy.yaml \
    --values "${HERE}/chart-values.yaml" \
    --set-file "imageVerification.publicKey=${WORK}/keys/signer.pub" \
    --set "imageVerification.registries[0]=${REGISTRY}/${REPOSITORY}/*" \
    "$@" >"${dir}/policies.yaml"
  printf '%s\n' "${resources}" >"${dir}/resources.yaml"
  cp "${HERE}/values.yaml" "${dir}/values.yaml"
  cp "${HERE}/${test_file}" "${dir}/kyverno-test.yaml"
  log_info "kyverno test: ${name}"
  DOCKER_CONFIG="${WORK}/docker-config" kyverno test "${dir}" --require-tests --detailed-results \
    --remove-color --output-format json >"${dir}/kyverno.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    cat "${dir}/kyverno.log" >&2
    die "kyverno test ${name} failed with exit code ${rc}"
  fi
  awk '/^\[/ {p = 1} p {print} /^\]/ {p = 0}' "${dir}/kyverno.log" >"${dir}/results.json"
  echo "${name}: $(grep -E '^Test Summary:' "${dir}/kyverno.log")"
  jq -r '.[] | "  \(.RESULT)  \(.RESOURCE | sub("^v1/Pod/prod/"; ""))  \(.Message)"' "${dir}/results.json"
}

# Registry and verification errors also show up as a failed policy, so each
# denial is checked for its message as well: a case must fail for its own
# reason only.
MESSAGE_FAILURES=0
message_of() {
  jq -r --arg r "v1/Pod/prod/$2" '.[] | select(.RESOURCE == $r) | .Message' "${WORK}/$1/results.json"
}
# expect_message RUN POD FRAGMENT...: the message for POD contains each FRAGMENT.
expect_message() {
  local run="$1" pod="$2" message fragment
  shift 2
  message="$(message_of "${run}" "${pod}")"
  for fragment in "$@"; do
    if [[ "${message}" != *"${fragment}"* ]]; then
      log_error "${run}/${pod}: the message does not contain \"${fragment}\""
      MESSAGE_FAILURES=$((MESSAGE_FAILURES + 1))
    fi
  done
}
# expect_no_message RUN POD FRAGMENT: the message for POD lacks FRAGMENT.
expect_no_message() {
  if [[ "$(message_of "$1" "$2")" == *"$3"* ]]; then
    log_error "$1/$2: the message contains \"$3\""
    MESSAGE_FAILURES=$((MESSAGE_FAILURES + 1))
  fi
}

found="Found: ${REGISTRY}/${REPOSITORY}"
no_attestation="Missing or invalid for: ${REGISTRY}/${REPOSITORY}"

# Chart defaults: CRITICAL blocks, fixed or not.
run_test defaults test.yaml
expect_message defaults critical "${found}/critical@" "CVE-2099-0001 CRITICAL" "CVE-2099-0003 CRITICAL"
expect_no_message defaults critical "CVE-2099-0101"
expect_message defaults critical-init "${found}/critical@" "CVE-2099-0001 CRITICAL"
expect_message defaults unfixed "${found}/unfixed@" "CVE-2099-0003 CRITICAL"
expect_message defaults stale "Too old: ${REGISTRY}/${REPOSITORY}/stale@"
expect_message defaults missing "${no_attestation}/missing@"
expect_message defaults foreign-attestation "${no_attestation}/foreign@"
expect_message defaults regressed "${found}/regressed@" "CVE-2099-0001 CRITICAL"

# ignoreUnfixed: only CRITICAL findings with a fixed version block.
run_test ignore-unfixed test-ignore-unfixed.yaml --set imageVerification.vulnerabilities.ignoreUnfixed=true
expect_message ignore-unfixed critical "${found}/critical@" "CVE-2099-0001 CRITICAL"
expect_no_message ignore-unfixed critical "CVE-2099-0003"

((MESSAGE_FAILURES == 0)) || die "${MESSAGE_FAILURES} denial message check(s) failed"
log_info "vulnerability attestation gate: every case has the expected result and reason"
