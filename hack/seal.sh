#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Offline sealing of Kubernetes Secrets with Sealed Secrets, per cluster.
# Run hack/seal.sh --help for the interface.
#
# Safety model:
#   - Sealing never contacts a cluster. It encrypts with the controller
#     certificate committed at clusters/<cluster>/sealed-secrets/cert.pem and
#     refuses to run unless that certificate matches the SHA-256 fingerprint
#     pinned in cert.sha256 next to it. kubeseal reads a private copy of the
#     checked bytes, so the file cannot change between check and use.
#   - Plaintext arrives on stdin, from a file that resolves outside the
#     repository, or from the terminal without echo (registry password). It
#     only exists in a pipe or in a private temporary file outside the
#     repository that is removed on exit. Values never appear on a command
#     line, in an environment variable or in a log line.
#   - Output is written atomically to
#     clusters/<cluster>/secrets/<namespace>/<name>.yaml, never replaces an
#     existing file without --force, and is checked to be a SealedSecret
#     before it is moved into place.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

umask 077
# ASCII semantics for every bracket expression and regular expression below.
export LC_ALL=C

readonly DEFAULT_CONTROLLER_NAME="sealed-secrets-controller"
readonly DEFAULT_CONTROLLER_NAMESPACE="kube-system"
readonly DEFAULT_REGISTRY_SECRET_NAME="regcred"
readonly SECRETS_TOOLCHAIN="cluster-secrets"
readonly ANNOTATION_NAMESPACE_WIDE="sealedsecrets.bitnami.com/namespace-wide"
readonly ANNOTATION_CLUSTER_WIDE="sealedsecrets.bitnami.com/cluster-wide"
# Placeholders that must never be sealed: CHANGE_ME, YOUR_*, PLACEHOLDER and
# <UPPER_CASE> tokens. Same family as is_placeholder in scripts/lib/common.sh.
readonly PLACEHOLDER_RE='CHANGE_ME|YOUR_|PLACEHOLDER|<[A-Z][A-Z0-9_]*>'
# Standard base64 on one line, as kubectl writes Secret data.
readonly BASE64_RE='^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'
# Valid Secret data key (Kubernetes IsConfigMapKey).
readonly SECRET_KEY_RE='^[-._a-zA-Z0-9]+$'

usage() {
  cat <<'EOF'
Usage:
  hack/seal.sh fetch-cert --cluster NAME [--controller-name NAME]
                          [--controller-namespace NS] [--force]
  hack/seal.sh secret --cluster NAME --namespace NS [--name NAME]
                      [--scope strict|namespace-wide] [--force] [--from-file PATH]
  hack/seal.sh docker-registry --cluster NAME --namespace NS [--name NAME]
                               --server HOST --username USER [--force]
  hack/seal.sh verify --cluster NAME
  hack/seal.sh -h | --help

Seals Kubernetes Secrets offline with Sealed Secrets. A SealedSecret can only
be decrypted by the controller whose key sealed it, so everything is kept per
cluster:

  clusters/NAME/sealed-secrets/cert.pem     controller certificate (public)
  clusters/NAME/sealed-secrets/cert.sha256  pinned SHA-256 fingerprint
  clusters/NAME/secrets/NS/SECRET.yaml      sealed output, one file per Secret

Commands:
  fetch-cert       Fetch the controller certificate from the current kube
                   context (kubeseal --fetch-cert) and write cert.pem and
                   cert.sha256. Refuses to replace a committed certificate
                   with a different fingerprint unless --force is given, and
                   prints both fingerprints. Defaults: --controller-name
                   sealed-secrets-controller, --controller-namespace
                   kube-system.
  secret           Seal one plaintext Secret manifest read from stdin or from
                   --from-file PATH. PATH must resolve outside the repository,
                   also through symbolic links. metadata.namespace is set
                   from --namespace and must not conflict with it.
                   metadata.name comes from the manifest or from --name and
                   must not conflict either.
  docker-registry  Build a kubernetes.io/dockerconfigjson Secret in memory and
                   seal it (default --name regcred). The password or token is
                   read from the terminal without echo, or from stdin when
                   stdin is not a terminal; it is never accepted as an
                   argument or an environment variable. Seal one pull secret
                   per namespace (dev, stage and prod each get their own).
  verify           Check that cert.pem matches the pin and that every file
                   under clusters/NAME/secrets/ other than README.md is a
                   SealedSecret (bitnami.com/v1alpha1) at NS/NAME.yaml whose
                   metadata.namespace equals its directory name, with no
                   plaintext data or stringData. verify checks structure
                   only; decryption needs the controller's private key.

Options:
  --cluster NAME             Directory under clusters/ that holds cluster.yaml.
  --namespace NS             Namespace of the Secret.
  --name NAME                Secret name.
  --scope SCOPE              strict (default): bound to name and namespace.
                             namespace-wide: bound to the namespace only.
                             cluster-wide is not offered.
  --from-file PATH           Plaintext Secret manifest outside the repository.
  --server HOST              Registry host, for example registry.example.com.
  --username USER            Registry user name.
  --controller-name NAME     Sealed Secrets controller service name.
  --controller-namespace NS  Namespace of the controller.
  --force                    Replace an existing sealed file, or replace a
                             pinned certificate (fetch-cert).
  -h, --help                 Show this help.
  Names and namespaces must be DNS labels (lower case, digits, '-').

Checks before sealing:
  - cert.pem holds exactly one certificate, not expired, whose fingerprint
    equals cert.sha256;
  - the input is exactly one YAML document with kind Secret, apiVersion v1;
  - data and stringData are not both empty, every value is a string, data
    values are base64 and keys are valid Secret keys;
  - no value is empty or contains a placeholder (CHANGE_ME, YOUR_,
    PLACEHOLDER, <TOKEN>); data values are checked after base64 decoding;
  - the input carries no scope annotation (use --scope instead).
  The sealed result must be a SealedSecret with the expected name,
  namespace, scope and keys, and no data or stringData, before it is moved
  into place. Values are never printed.

Key rotation:
  The controller adds a new sealing key every 30 days by default and keeps
  the old ones, so a pinned certificate stays usable. Run fetch-cert --force
  to seal with the newest key. After a cluster rebuild or a key loss, re-seal
  every file under clusters/NAME/secrets/.

kubeseal version:
  Use the kubeseal client release that matches the controller release pinned
  by the sealed-secrets wrapper chart. fetch-cert warns when the minor
  versions differ and kubectl can read the controller image; sealing is
  offline and does not check this.

Requirements: kubeseal, yq (mikefarah v4), openssl. kubectl is optional and
only used by fetch-cert to show the kube context and check the version.

Examples:
  hack/seal.sh fetch-cert --cluster lab
  hack/seal.sh secret --cluster lab --namespace dev --from-file ~/seal-input/db-credentials.yaml
  kubectl create secret generic db-credentials --from-env-file="$HOME/seal-input/db.env" \
    --dry-run=client -o yaml | hack/seal.sh secret --cluster lab --namespace dev
  hack/seal.sh docker-registry --cluster lab --namespace stage \
    --server registry.example.com --username CHANGE_ME < ~/seal-input/registry-token
  hack/seal.sh verify --cluster lab

Exit status: 0 on success, 1 on failure, 2 on a usage error.
EOF
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
cmd=""
opt_cluster=""
opt_namespace=""
opt_name=""
opt_scope="strict"
opt_force=0
opt_from_file=""
opt_server=""
opt_username=""
opt_controller_name="$DEFAULT_CONTROLLER_NAME"
opt_controller_namespace="$DEFAULT_CONTROLLER_NAMESPACE"

CLUSTER_DIR=""
CERT_FILE=""
PIN_FILE=""
SECRETS_DIR=""
CERT_COPY=""
CERT_SHA256=""
PLAIN_FILE=""
SECRET_NAME=""
OUT_FILE=""
VERIFY_ERRORS=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# capture VAR COMMAND [ARG...]
# Runs COMMAND, stores its stdout in VAR and returns non-zero when COMMAND
# fails. Use "capture x cmd || ..." for a command that is allowed to fail.
# One form for every guarded capture in this script, including captures into
# a variable whose name is only known at run time (printf -v).
capture() {
  local __capture_out
  if __capture_out="$("${@:2}" || exit "$?")"; then
    printf -v "$1" '%s' "$__capture_out"
    return 0
  fi
  return 1
}

rel_path() {
  printf '%s\n' "${1#"${REPO_ROOT}"/}"
}

is_dns_label() {
  local re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
  [[ ${#1} -le 63 && "$1" =~ $re ]]
}

require_yq_v4() {
  local version re='version v?4\.'
  require_cmd yq
  capture version yq --version 2>/dev/null || version=""
  if [[ "$version" != *mikefarah* || ! "$version" =~ $re ]]; then
    die "yq must be mikefarah/yq v4 (found: ${version:-unknown})"
  fi
}

# resolve_path PATH
# Prints the absolute physical path of PATH with every symbolic link resolved,
# including a link in the last component. Fails when a directory on the way
# does not exist or links nest more than 40 deep.
resolve_path() {
  local path="$1" dir base target hops=0
  while :; do
    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    if ! dir="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)"; then
      return 1
    fi
    if [[ "$dir" == "/" ]]; then
      path="/${base}"
    else
      path="${dir}/${base}"
    fi
    [[ -L "$path" ]] || break
    hops=$((hops + 1))
    ((hops <= 40)) || return 1
    capture target readlink -- "$path" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="${dir}/${target}" ;;
    esac
  done
  printf '%s\n' "$path"
}

# path_is_inside PATH DIR
# True when the absolute PATH is DIR or lies below it. Compares device and
# inode of every ancestor, so letter case or an alias of DIR cannot hide a
# match.
path_is_inside() {
  local p="$1" root="$2"
  while :; do
    if [[ "$p" -ef "$root" ]]; then
      return 0
    fi
    if [[ "$p" == "/" || "$p" == "." || -z "$p" ]]; then
      return 1
    fi
    p="$(dirname -- "$p")"
  done
}

# cert_fingerprint FILE
# Prints the SHA-256 fingerprint of the first certificate in FILE as lowercase
# hex without colons. Fails when FILE holds no parseable certificate.
cert_fingerprint() {
  local out re='^[0-9a-f]{64}$'
  capture out openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null || return 1
  out="${out#*=}"
  out="${out//:/}"
  out="$(printf '%s' "$out" | tr 'A-F' 'a-f')"
  [[ "$out" =~ $re ]] || return 1
  printf '%s\n' "$out"
}

# read_pin FILE
# Prints the pinned fingerprint. Fails unless FILE holds exactly one line of
# 64 lowercase hex characters.
read_pin() {
  local content re='^[0-9a-f]{64}$'
  capture content cat -- "$1" 2>/dev/null || return 1
  [[ "$content" =~ $re ]] || return 1
  printf '%s\n' "$content"
}

# cert_problems CERT PIN_FILE LABEL
# Prints one line per problem with CERT and its pin, nothing when they are
# valid and match. LABEL names the certificate in the messages.
cert_problems() {
  local cert="$1" pin_file="$2" label="$3" count fp pin
  if [[ ! -f "$cert" ]]; then
    echo "${label} not found; run: hack/seal.sh fetch-cert --cluster ${opt_cluster}"
    return 0
  fi
  if grep -q -- 'PRIVATE KEY' "$cert"; then
    echo "${label} contains a private key; remove it and rotate the sealing key"
    return 0
  fi
  count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$cert" || true)"
  if [[ "$count" != "1" ]]; then
    echo "${label} must hold exactly one certificate (found ${count})"
    return 0
  fi
  if ! capture fp cert_fingerprint "$cert"; then
    echo "${label} is not a valid X.509 certificate"
    return 0
  fi
  if ! openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
    echo "${label} has expired"
  fi
  if [[ ! -f "$pin_file" ]]; then
    echo "$(rel_path "$pin_file") not found; the certificate is not pinned"
    return 0
  fi
  if ! capture pin read_pin "$pin_file"; then
    echo "$(rel_path "$pin_file") must hold one line: the lowercase hex SHA-256 fingerprint"
    return 0
  fi
  if [[ "$fp" != "$pin" ]]; then
    echo "${label} fingerprint ${fp} does not match the pin ${pin}"
  fi
}

# write_public_file DEST
# Writes stdin to DEST with mode 0644, atomically: temporary file in the same
# directory, then rename. For committed, non-secret files only.
write_public_file() {
  local dest="$1" tmp cleanup
  capture tmp mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").XXXXXXXX" ||
    die "cannot create a temporary file next to $(rel_path "$dest")"
  printf -v cleanup 'rm -f -- %q' "$tmp"
  add_cleanup "$cleanup"
  cat >"$tmp" || die "failed to write $(rel_path "$dest")"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$dest"
}

# report_problems PREFIX TEXT
# Logs every line of TEXT as an error and counts it in VERIFY_ERRORS.
report_problems() {
  local prefix="$1" text="$2" line
  [[ -n "$text" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    log_error "${prefix}: ${line}"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
  done <<<"$text"
}

# major_minor TEXT
# Prints MAJOR.MINOR of the first x.y.z version in TEXT, nothing if none.
major_minor() {
  local re='([0-9]+)\.([0-9]+)\.[0-9]+'
  if [[ "$1" =~ $re ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# warn_on_version_skew
# Best effort: compares the kubeseal client minor version with the image tag
# of the controller deployment. Silent when either cannot be determined.
warn_on_version_skew() {
  local client image tag client_mm controller_mm
  command -v kubectl >/dev/null 2>&1 || return 0
  capture client kubeseal --version 2>/dev/null || return 0
  capture image kubectl --request-timeout=5s -n "$opt_controller_namespace" get deployment \
    "$opt_controller_name" -o 'jsonpath={.spec.template.spec.containers[0].image}' 2>/dev/null ||
    return 0
  image="${image%%@*}"
  case "${image##*/}" in
    *:*) tag="${image##*:}" ;;
    *) return 0 ;;
  esac
  client_mm="$(major_minor "$client")"
  controller_mm="$(major_minor "$tag")"
  [[ -n "$client_mm" && -n "$controller_mm" ]] || return 0
  if [[ "$client_mm" != "$controller_mm" ]]; then
    log_warn "kubeseal client ${client_mm} differs from controller ${controller_mm} (${tag});" \
      "use the kubeseal release that matches the controller pinned by the sealed-secrets wrapper chart"
  fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
parse_options() {
  local allowed opt val has_val position=1
  case "$cmd" in
    fetch-cert) allowed=" --cluster --controller-name --controller-namespace --force " ;;
    secret) allowed=" --cluster --namespace --name --scope --force --from-file " ;;
    docker-registry) allowed=" --cluster --namespace --name --server --username --force " ;;
    verify) allowed=" --cluster " ;;
  esac
  while (($# > 0)); do
    opt="$1"
    val=""
    has_val=0
    position=$((position + 1))
    case "$opt" in
      -h | --help)
        usage
        exit 0
        ;;
      --*=*)
        val="${opt#*=}"
        opt="${opt%%=*}"
        has_val=1
        ;;
      --*) ;;
      *)
        # Not echoed: a misplaced argument may be a password.
        die "unexpected argument at position ${position} (see hack/seal.sh --help)" 2
        ;;
    esac
    case "$opt" in
      --password | --token | --password-stdin)
        die "${opt} is not supported: the password or token is read from the terminal or from stdin" 2
        ;;
    esac
    if [[ "$allowed" != *" ${opt} "* ]]; then
      die "unknown option for ${cmd}: ${opt} (see hack/seal.sh --help)" 2
    fi
    if [[ "$opt" == "--force" ]]; then
      ((has_val == 0)) || die "--force takes no value" 2
      opt_force=1
      shift
      continue
    fi
    if ((has_val == 0)); then
      if (($# < 2)) || [[ "$2" == -* ]]; then
        die "option ${opt} needs a value" 2
      fi
      val="$2"
      shift 2
      position=$((position + 1))
    else
      shift
    fi
    case "$opt" in
      --cluster) opt_cluster="$val" ;;
      --namespace) opt_namespace="$val" ;;
      --name) opt_name="$val" ;;
      --scope) opt_scope="$val" ;;
      --from-file) opt_from_file="$val" ;;
      --server) opt_server="$val" ;;
      --username) opt_username="$val" ;;
      --controller-name) opt_controller_name="$val" ;;
      --controller-namespace) opt_controller_namespace="$val" ;;
    esac
  done
}

require_cluster() {
  [[ -n "$opt_cluster" ]] || die "--cluster is required" 2
  is_dns_label "$opt_cluster" || die "invalid cluster name '${opt_cluster}': expected a DNS label" 2
  CLUSTER_DIR="${REPO_ROOT}/clusters/${opt_cluster}"
  if [[ ! -f "${CLUSTER_DIR}/cluster.yaml" ]]; then
    die "unknown cluster '${opt_cluster}': clusters/${opt_cluster}/cluster.yaml not found"
  fi
  CERT_FILE="${CLUSTER_DIR}/sealed-secrets/cert.pem"
  PIN_FILE="${CLUSTER_DIR}/sealed-secrets/cert.sha256"
  SECRETS_DIR="${CLUSTER_DIR}/secrets"
}

require_namespace() {
  local known
  [[ -n "$opt_namespace" ]] || die "--namespace is required" 2
  is_dns_label "$opt_namespace" || die "invalid namespace '${opt_namespace}': expected a DNS label" 2
  capture known yq '(.namespaces // {}) | .[]' "${CLUSTER_DIR}/cluster.yaml" 2>/dev/null || known=""
  if ! printf '%s\n' "$known" | grep -qx -- "$opt_namespace"; then
    log_warn "namespace ${opt_namespace} is not listed under namespaces in clusters/${opt_cluster}/cluster.yaml"
  fi
}

require_secret_name() {
  [[ -n "$1" ]] || die "the secret name is empty" 2
  is_dns_label "$1" || die "invalid secret name '${1}': expected a DNS label" 2
}

# ---------------------------------------------------------------------------
# Sealing steps
# ---------------------------------------------------------------------------

# prepare_cert
# Copies cert.pem to a private temporary file, checks the copy and its pin,
# and sets CERT_COPY and CERT_SHA256. kubeseal reads the checked copy.
prepare_cert() {
  local problems
  [[ -f "$CERT_FILE" ]] ||
    die "$(rel_path "$CERT_FILE") not found; run: hack/seal.sh fetch-cert --cluster ${opt_cluster}"
  make_temp_file CERT_COPY seal-cert
  cat -- "$CERT_FILE" >"$CERT_COPY" || die "cannot read $(rel_path "$CERT_FILE")"
  problems="$(cert_problems "$CERT_COPY" "$PIN_FILE" "$(rel_path "$CERT_FILE")")"
  if [[ -n "$problems" ]]; then
    log_error "${problems//$'\n'/; }"
    die "refusing to seal for cluster ${opt_cluster}: certificate check failed"
  fi
  capture CERT_SHA256 cert_fingerprint "$CERT_COPY" || die "cannot fingerprint $(rel_path "$CERT_FILE")"
}

# prepare_plain_file
# Creates the private temporary file that holds plaintext and makes sure it
# is outside the repository.
prepare_plain_file() {
  local resolved
  make_temp_file PLAIN_FILE seal-plain
  capture resolved resolve_path "$PLAIN_FILE" || die "cannot resolve the temporary file path"
  if path_is_inside "$resolved" "$REPO_ROOT"; then
    die "the temporary directory ${TMPDIR:-/tmp} is inside the repository; set TMPDIR to a directory outside it"
  fi
}

# read_manifest_input
# Copies the plaintext manifest from --from-file or stdin into PLAIN_FILE.
read_manifest_input() {
  local resolved mode
  if [[ -n "$opt_from_file" ]]; then
    capture resolved resolve_path "$opt_from_file" || die "cannot resolve --from-file ${opt_from_file}"
    [[ -f "$resolved" ]] || die "--from-file ${opt_from_file} is not a regular file"
    [[ -r "$resolved" ]] || die "--from-file ${opt_from_file} is not readable"
    if path_is_inside "$resolved" "$REPO_ROOT"; then
      die "refusing to read plaintext from inside the repository: ${opt_from_file} resolves to ${resolved}; keep plaintext manifests outside ${REPO_ROOT}"
    fi
    capture mode file_mode "$resolved" 2>/dev/null || mode=""
    if [[ -n "$mode" && "$mode" != *00 ]]; then
      log_warn "${opt_from_file} is accessible by group or others; run: chmod 600 ${opt_from_file}"
    fi
    cat -- "$resolved" >"$PLAIN_FILE" || die "cannot read ${opt_from_file}"
  else
    [[ ! -t 0 ]] || die "no input: pipe a Secret manifest on stdin or pass --from-file PATH" 2
    cat >"$PLAIN_FILE" || die "cannot read stdin"
  fi
  [[ -s "$PLAIN_FILE" ]] || die "the input is empty"
}

# build_registry_manifest
# Reads the registry password or token and writes a dockerconfigjson Secret
# manifest to PLAIN_FILE. The values reach yq and openssl through pipes only,
# base64 encoded so that yq builds the JSON with correct escaping.
build_registry_manifest() {
  # xtrace would print the password.
  set +x
  local password="" b64_server b64_user b64_pass b64_auth dockerconfig
  read_secret password "Password or token for ${opt_username} at ${opt_server}: "
  # A token file saved with CRLF line endings would otherwise keep the CR.
  password="${password%$'\r'}"
  if is_placeholder "$password"; then
    die "the password or token is empty or a placeholder"
  fi
  if ! b64_server="$(printf '%s' "$opt_server" | openssl base64 -A)" ||
    ! b64_user="$(printf '%s' "$opt_username" | openssl base64 -A)" ||
    ! b64_pass="$(printf '%s' "$password" | openssl base64 -A)" ||
    ! b64_auth="$(printf '%s:%s' "$opt_username" "$password" | openssl base64 -A)"; then
    die "base64 encoding failed"
  fi
  password=""
  if ! dockerconfig="$(
    printf 'server: %s\nusername: %s\npassword: %s\nauth: %s\n' \
      "$b64_server" "$b64_user" "$b64_pass" "$b64_auth" |
      yq -p yaml -o json -I 0 '{"auths": {(.server | @base64d): {"username": (.username | @base64d), "password": (.password | @base64d), "auth": .auth}}}' 2>/dev/null |
      openssl base64 -A
  )"; then
    die "failed to build the docker config JSON"
  fi
  b64_pass=""
  b64_auth=""
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/dockerconfigjson\ndata:\n  .dockerconfigjson: %s\n' \
    "$opt_name" "$opt_namespace" "$dockerconfig" >"$PLAIN_FILE"
  dockerconfig=""
}

# input_query VAR EXPRESSION
# Evaluates EXPRESSION against the single document in PLAIN_FILE and stores
# the result in VAR. yq diagnostics are discarded because they could quote
# plaintext.
input_query() {
  capture "$1" yq ea "select(. != null) | (${2})" "$PLAIN_FILE" 2>/dev/null ||
    die "the input has an unexpected structure"
}

# validate_input
# Validates the plaintext manifest in PLAIN_FILE and sets SECRET_NAME. Reports
# keys, never values.
validate_input() {
  local count tag kind api_version ns name meta_tag data_tag string_tag scoped bad total
  capture count yq ea '[select(. != null)] | length' "$PLAIN_FILE" 2>/dev/null ||
    die "the input is not valid YAML"
  [[ "$count" == "1" ]] || die "the input must hold exactly one YAML document (found ${count})"
  input_query tag 'tag'
  [[ "$tag" == "!!map" ]] || die "the input is not a YAML mapping"

  input_query kind '.kind // ""'
  input_query api_version '.apiVersion // ""'
  [[ "$kind" == "Secret" ]] || die "the input must be kind Secret (found '${kind}')"
  [[ "$api_version" == "v1" ]] || die "the input must be apiVersion v1 (found '${api_version}')"

  input_query meta_tag '.metadata | tag'
  input_query data_tag '.data | tag'
  input_query string_tag '.stringData | tag'
  case "$meta_tag" in "" | "!!null" | "!!map") ;; *) die "metadata must be a mapping" ;; esac
  case "$data_tag" in "" | "!!null" | "!!map") ;; *) die "data must be a mapping" ;; esac
  case "$string_tag" in "" | "!!null" | "!!map") ;; *) die "stringData must be a mapping" ;; esac

  input_query ns '.metadata.namespace // ""'
  if [[ -n "$ns" && "$ns" != "$opt_namespace" ]]; then
    die "metadata.namespace '${ns}' conflicts with --namespace ${opt_namespace}"
  fi
  input_query name '.metadata.name // ""'
  if [[ -n "$opt_name" ]]; then
    if [[ -n "$name" && "$name" != "$opt_name" ]]; then
      die "metadata.name '${name}' conflicts with --name ${opt_name}"
    fi
    name="$opt_name"
  fi
  [[ -n "$name" ]] || die "metadata.name is missing; set it in the manifest or pass --name"
  is_dns_label "$name" || die "invalid secret name '${name}': expected a DNS label"

  input_query scoped "(.metadata.annotations // {}) | (has(\"${ANNOTATION_NAMESPACE_WIDE}\") or has(\"${ANNOTATION_CLUSTER_WIDE}\"))"
  [[ "$scoped" == "false" ]] || die "the input carries a sealedsecrets.bitnami.com scope annotation; remove it and use --scope"

  input_query total '[(.data // {} | keys | .[]), (.stringData // {} | keys | .[])] | unique | length'
  [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] || die "both data and stringData are empty"

  input_query bad '[(.data // {} | to_entries | .[] | select(.value | tag != "!!str") | "data." + .key), (.stringData // {} | to_entries | .[] | select(.value | tag != "!!str") | "stringData." + .key)] | .[]'
  [[ -z "$bad" ]] || die "values must be strings: ${bad//$'\n'/, }"

  input_query bad "[(.data // {} | keys | .[]), (.stringData // {} | keys | .[])] | unique | .[] | select(test(\"${SECRET_KEY_RE}\") | not)"
  [[ -z "$bad" ]] || die "invalid Secret keys (allowed: letters, digits, '-', '_', '.'): ${bad//$'\n'/, }"

  input_query bad "[.data // {} | to_entries | .[] | select(.value | test(\"${BASE64_RE}\") | not) | \"data.\" + .key] | .[]"
  [[ -z "$bad" ]] || die "data values must be single-line base64: ${bad//$'\n'/, }"

  input_query bad '[(.data // {} | to_entries | .[] | select(.value == "") | "data." + .key), (.stringData // {} | to_entries | .[] | select(.value == "") | "stringData." + .key)] | .[]'
  [[ -z "$bad" ]] || die "empty values: ${bad//$'\n'/, }"

  input_query bad "[(.data // {} | to_entries | .[] | select(.value | @base64d | test(\"${PLACEHOLDER_RE}\")) | \"data.\" + .key), (.stringData // {} | to_entries | .[] | select(.value | test(\"${PLACEHOLDER_RE}\")) | \"stringData.\" + .key)] | .[]"
  [[ -z "$bad" ]] || die "placeholder values (CHANGE_ME, YOUR_, PLACEHOLDER or <TOKEN>) in: ${bad//$'\n'/, }"

  SECRET_NAME="$name"
}

# check_output_target
# Sets OUT_FILE and refuses to replace an existing file without --force.
check_output_target() {
  OUT_FILE="${SECRETS_DIR}/${opt_namespace}/${SECRET_NAME}.yaml"
  if [[ -L "$OUT_FILE" ]]; then
    die "$(rel_path "$OUT_FILE") is a symbolic link; refusing to write through it"
  fi
  if [[ -e "$OUT_FILE" && "$opt_force" != "1" ]]; then
    die "$(rel_path "$OUT_FILE") already exists; pass --force to replace it"
  fi
}

# sealed_problems FILE NAMESPACE
# Prints one line per reason why FILE is not a valid SealedSecret for
# NAMESPACE, nothing when it is. Never prints values.
sealed_problems() {
  local file="$1" ns="$2" count tag
  capture count yq ea '[select(. != null)] | length' "$file" 2>/dev/null || {
    echo "not valid YAML"
    return 0
  }
  if [[ "$count" != "1" ]]; then
    echo "expected exactly one YAML document, found ${count}"
    return 0
  fi
  capture tag yq ea 'select(. != null) | tag' "$file" 2>/dev/null || tag=""
  if [[ "$tag" != "!!map" ]]; then
    echo "not a YAML mapping"
    return 0
  fi
  # if/then/else rather than select: yq emits a string literal even when the
  # select before it matched nothing.
  SEAL_EXPECT_NS="$ns" yq ea 'select(. != null) | [
      (if .kind == "Secret" then "kind Secret: plaintext Secret" else null end),
      (if .kind != "Secret" and .kind != "SealedSecret" then "kind is not SealedSecret" else null end),
      (if .apiVersion != "bitnami.com/v1alpha1" then "apiVersion is not bitnami.com/v1alpha1" else null end),
      (if has("data") then "plaintext data at the top level" else null end),
      (if has("stringData") then "plaintext stringData at the top level" else null end),
      (if ((.spec.template.data // {}) | length) > 0 then "plaintext spec.template.data" else null end),
      (if (.metadata.name // "") == "" then "metadata.name is missing" else null end),
      (if (.metadata.namespace // "") != strenv(SEAL_EXPECT_NS) then "metadata.namespace does not equal the directory name" else null end),
      (if (.spec.encryptedData | tag) != "!!map" or ((.spec.encryptedData // {}) | length) == 0 then "spec.encryptedData is missing or empty" else null end)
    ] | .[] | select(. != null)' "$file" 2>/dev/null || echo "unexpected structure"
}

# seal_to_output
# Seals PLAIN_FILE with the checked certificate copy, validates the result
# and moves it to OUT_FILE.
seal_to_output() {
  local out_dir tmp cleanup problems in_keys out_keys out_name ann_ns ann_cw
  check_output_target
  out_dir="$(dirname -- "$OUT_FILE")"
  (umask 022 && mkdir -p -- "$out_dir") || die "cannot create $(rel_path "$out_dir")"
  capture tmp mktemp "${out_dir}/.${SECRET_NAME}.yaml.XXXXXXXX" ||
    die "cannot create a temporary file in $(rel_path "$out_dir")"
  printf -v cleanup 'rm -f -- %q' "$tmp"
  add_cleanup "$cleanup"

  # JSON between yq and kubeseal avoids YAML 1.1 versus 1.2 differences.
  if ! SEAL_NS="$opt_namespace" SEAL_NAME="$SECRET_NAME" yq ea -o json \
    'select(. != null) | .metadata.namespace = strenv(SEAL_NS) | .metadata.name = strenv(SEAL_NAME) | del(.metadata.managedFields) | del(.status)' \
    "$PLAIN_FILE" 2>/dev/null |
    kubeseal --cert "$CERT_COPY" --format yaml --scope "$opt_scope" >"$tmp"; then
    die "kubeseal failed; nothing was written"
  fi

  problems="$(sealed_problems "$tmp" "$opt_namespace")"
  if [[ -n "$problems" ]]; then
    log_error "${problems//$'\n'/; }"
    die "the sealed output failed validation; nothing was written"
  fi
  if ! in_keys="$(yq ea 'select(. != null) | [(.data // {} | keys | .[]), (.stringData // {} | keys | .[])] | unique | .[]' "$PLAIN_FILE" 2>/dev/null | sort)"; then
    die "cannot list the input keys"
  fi
  if ! out_keys="$(yq ea 'select(. != null) | .spec.encryptedData | keys | .[]' "$tmp" 2>/dev/null | sort)"; then
    die "cannot list the sealed keys"
  fi
  [[ "$in_keys" == "$out_keys" ]] || die "the sealed keys differ from the input keys; nothing was written"
  capture out_name yq ea 'select(. != null) | .metadata.name' "$tmp" || die "cannot read the sealed name"
  [[ "$out_name" == "$SECRET_NAME" ]] ||
    die "the sealed metadata.name differs from ${SECRET_NAME}; nothing was written"
  capture ann_ns yq ea "select(. != null) | .spec.template.metadata.annotations[\"${ANNOTATION_NAMESPACE_WIDE}\"] // \"\"" "$tmp" ||
    die "cannot read the sealed scope"
  capture ann_cw yq ea "select(. != null) | .spec.template.metadata.annotations[\"${ANNOTATION_CLUSTER_WIDE}\"] // \"\"" "$tmp" ||
    die "cannot read the sealed scope"
  case "${opt_scope}:${ann_ns}:${ann_cw}" in
    strict::) ;;
    namespace-wide:true:) ;;
    *) die "the sealed scope does not match --scope ${opt_scope}; nothing was written" ;;
  esac

  # A concurrent run may have created the file since the first check.
  check_output_target
  if [[ -e "$OUT_FILE" ]]; then
    log_warn "replacing $(rel_path "$OUT_FILE") (--force)"
  fi
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$OUT_FILE"
}

print_next_step() {
  local rel enabled
  rel="$(rel_path "$OUT_FILE")"
  log_info "sealed ${opt_namespace}/${SECRET_NAME} (scope ${opt_scope}) for cluster ${opt_cluster} with certificate sha256 ${CERT_SHA256}"
  printf '%s\n' "$rel"
  capture enabled yq ".toolchains[\"${SECRETS_TOOLCHAIN}\"].enabled // false" \
    "${CLUSTER_DIR}/cluster.yaml" 2>/dev/null || enabled="false"
  if [[ "$enabled" == "true" ]]; then
    log_info "next: commit ${rel}"
  else
    log_info "next: commit ${rel} and enable the ${SECRETS_TOOLCHAIN} toolchain for cluster ${opt_cluster} (toolchains.${SECRETS_TOOLCHAIN}.enabled: true in clusters/${opt_cluster}/cluster.yaml)"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_fetch_cert() {
  local context="" fetched="" count new_fp old_fp="" old_pin="" problems
  require_cmd kubeseal openssl
  require_cluster
  is_dns_label "$opt_controller_name" || die "invalid --controller-name '${opt_controller_name}'" 2
  is_dns_label "$opt_controller_namespace" || die "invalid --controller-namespace '${opt_controller_namespace}'" 2

  if command -v kubectl >/dev/null 2>&1; then
    capture context kubectl config current-context 2>/dev/null || context=""
  fi
  log_info "fetching the certificate of ${opt_controller_namespace}/${opt_controller_name} from kube context '${context:-unknown}' for cluster ${opt_cluster}"

  make_temp_file fetched seal-fetched-cert
  if ! kubeseal --fetch-cert --controller-name "$opt_controller_name" \
    --controller-namespace "$opt_controller_namespace" >"$fetched"; then
    die "kubeseal --fetch-cert failed; check the kube context and the controller name and namespace"
  fi
  if grep -q -- 'PRIVATE KEY' "$fetched"; then
    die "the fetched data contains a private key; refusing to write it"
  fi
  count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$fetched" || true)"
  [[ "$count" == "1" ]] || die "expected exactly one certificate from the controller (found ${count})"
  capture new_fp cert_fingerprint "$fetched" || die "the fetched data is not a valid X.509 certificate"
  if ! openssl x509 -checkend 0 -noout -in "$fetched" >/dev/null 2>&1; then
    die "the fetched certificate has expired"
  fi
  warn_on_version_skew

  # The committed fingerprint comes from cert.pem, or from the pin alone when
  # cert.pem is missing: a stray pin still protects against the wrong context.
  if [[ -e "$CERT_FILE" ]]; then
    capture old_fp cert_fingerprint "$CERT_FILE" || old_fp="unreadable"
  elif [[ -e "$PIN_FILE" ]]; then
    capture old_fp read_pin "$PIN_FILE" || old_fp="unreadable"
  fi
  if [[ "$old_fp" == "$new_fp" ]]; then
    capture old_pin read_pin "$PIN_FILE" || old_pin=""
    if [[ -f "$CERT_FILE" && "$old_pin" == "$new_fp" ]]; then
      log_info "certificate unchanged (sha256 ${new_fp}); nothing to do"
      return 0
    fi
    log_warn "certificate unchanged, but cert.pem or its pin was missing or different; rewriting both"
  elif [[ -n "$old_fp" ]]; then
    if [[ "$opt_force" != "1" ]]; then
      log_error "committed certificate: sha256 ${old_fp}"
      log_error "fetched certificate:   sha256 ${new_fp}"
      die "the controller certificate differs from the one pinned in $(rel_path "$(dirname -- "$PIN_FILE")")/; pass --force to replace it after confirming the kube context is cluster ${opt_cluster}"
    fi
    log_warn "replacing the pinned certificate (--force)"
    log_warn "old sha256 ${old_fp}"
    log_warn "new sha256 ${new_fp}"
    log_warn "after a routine key renewal the controller keeps the old key; after a rebuild or key loss, re-seal every file under $(rel_path "$SECRETS_DIR")/"
  fi

  (umask 022 && mkdir -p -- "$(dirname -- "$CERT_FILE")") ||
    die "cannot create $(rel_path "$(dirname -- "$CERT_FILE")")"
  write_public_file "$CERT_FILE" <"$fetched"
  write_public_file "$PIN_FILE" <<<"$new_fp"

  problems="$(cert_problems "$CERT_FILE" "$PIN_FILE" "$(rel_path "$CERT_FILE")")"
  [[ -z "$problems" ]] || die "written certificate failed its own check: ${problems//$'\n'/; }"
  log_info "pinned sha256 ${new_fp}"
  printf '%s\n%s\n' "$(rel_path "$CERT_FILE")" "$(rel_path "$PIN_FILE")"
  log_info "next: commit $(rel_path "$CERT_FILE") and $(rel_path "$PIN_FILE")"
}

cmd_secret() {
  require_cmd kubeseal yq openssl
  require_yq_v4
  require_cluster
  require_namespace
  case "$opt_scope" in
    strict | namespace-wide) ;;
    *) die "--scope must be strict or namespace-wide (found '${opt_scope}')" 2 ;;
  esac
  if [[ -n "$opt_name" ]]; then
    require_secret_name "$opt_name"
  fi
  prepare_plain_file
  prepare_cert
  read_manifest_input
  validate_input
  seal_to_output
  print_next_step
}

cmd_docker_registry() {
  local re_bad='[[:space:][:cntrl:]]'
  require_cmd kubeseal yq openssl
  require_yq_v4
  require_cluster
  require_namespace
  opt_name="${opt_name:-$DEFAULT_REGISTRY_SECRET_NAME}"
  require_secret_name "$opt_name"
  if is_placeholder "$opt_server"; then
    die "--server is missing or a placeholder" 2
  fi
  if is_placeholder "$opt_username"; then
    die "--username is missing or a placeholder" 2
  fi
  if [[ "$opt_server" =~ $re_bad || "$opt_username" =~ $re_bad ]]; then
    die "--server and --username must not contain whitespace or control characters" 2
  fi
  case "$opt_server" in
    example.com | *.example.com | example.com[:/]* | *.example.com[:/]*)
      log_warn "--server ${opt_server} is a documentation domain"
      ;;
  esac

  prepare_plain_file
  prepare_cert
  # Fail on an existing output before asking for the password.
  SECRET_NAME="$opt_name"
  check_output_target
  build_registry_manifest
  validate_input
  seal_to_output
  print_next_step
}

cmd_verify() {
  local path rel sub ns_dir stem base problems checked=0 name
  require_cmd yq openssl
  require_yq_v4
  require_cluster

  report_problems "certificate" \
    "$(cert_problems "$CERT_FILE" "$PIN_FILE" "$(rel_path "$CERT_FILE")")"

  if [[ -L "$SECRETS_DIR" ]]; then
    report_problems "$(rel_path "$SECRETS_DIR")" "is a symbolic link"
  elif [[ -d "$SECRETS_DIR" ]]; then
    while IFS= read -r -d '' path; do
      rel="$(rel_path "$path")"
      sub="${path#"${SECRETS_DIR}"/}"
      if [[ -L "$path" ]]; then
        report_problems "$rel" "is a symbolic link"
        continue
      fi
      if [[ ! -f "$path" ]]; then
        report_problems "$rel" "is not a regular file"
        continue
      fi
      # Documentation; the cluster-secrets Application only applies *.yaml.
      if [[ "${sub##*/}" == "README.md" ]]; then
        continue
      fi
      if [[ "$sub" != */* || "${sub#*/}" == */* ]]; then
        report_problems "$rel" "expected clusters/${opt_cluster}/secrets/<namespace>/<name>.yaml"
        continue
      fi
      ns_dir="${sub%%/*}"
      base="${sub#*/}"
      if ! is_dns_label "$ns_dir"; then
        report_problems "$rel" "directory '${ns_dir}' is not a valid namespace name"
        continue
      fi
      checked=$((checked + 1))
      problems="$(sealed_problems "$path" "$ns_dir")"
      if [[ -n "$problems" ]]; then
        report_problems "$rel" "$problems"
        continue
      fi
      case "$base" in
        *.yaml) ;;
        *) log_warn "${rel}: not a .yaml file; the ${SECRETS_TOOLCHAIN} Application only applies *.yaml" ;;
      esac
      capture name yq ea 'select(. != null) | .metadata.name' "$path" 2>/dev/null || name=""
      stem="${base%.yaml}"
      stem="${stem%.yml}"
      if [[ "$name" != "$stem" ]]; then
        log_warn "${rel}: file name differs from metadata.name '${name}'"
      fi
    done < <(find "$SECRETS_DIR" -mindepth 1 ! -type d -print0)
  fi

  if ((VERIFY_ERRORS > 0)); then
    die "verify failed for cluster ${opt_cluster}: ${VERIFY_ERRORS} problem(s)"
  fi
  log_info "cluster ${opt_cluster}: certificate matches its pin; ${checked} sealed secret file(s) valid"
}

main() {
  if (($# == 0)); then
    usage >&2
    exit 2
  fi
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    fetch-cert | secret | docker-registry | verify)
      cmd="$1"
      shift
      ;;
    *) die "unknown command '${1}' (see hack/seal.sh --help)" 2 ;;
  esac
  parse_options "$@"
  case "$cmd" in
    fetch-cert) cmd_fetch_cert ;;
    secret) cmd_secret ;;
    docker-registry) cmd_docker_registry ;;
    verify) cmd_verify ;;
  esac
}

main "$@"
