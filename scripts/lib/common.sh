# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Shared shell library for the scripts in this repository.
#
# Usage, from a script anywhere in the repository:
#
#   #!/usr/bin/env bash
#   # shellcheck source=scripts/lib/common.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)/scripts/lib/common.sh"
#
# or with a path relative to the calling script, for example from hack/:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
#
# Sourcing this file:
#   - enables strict mode (errexit, nounset, pipefail, errtrace) in the caller;
#   - installs an ERR trap that reports file, line and exit code on stderr;
#   - installs an EXIT trap that runs the cleanup handlers registered with
#     add_cleanup, including the temporary files from make_temp_file and
#     make_temp_dir;
#   - exports REPO_ROOT (absolute path of the repository root).
#
# Compatible with bash 3.2 (the macOS system shell) and later. All output of
# the logging helpers goes to stderr so that stdout stays usable for data.
#
# Environment:
#   LOG_LEVEL  debug | info | warn | error   (default: info)
#   NO_COLOR   any value disables colour      (https://no-color.org)
#   DRY_RUN    1 makes run_cmd print instead of execute
#   CONFIRM    yes skips the interactive prompt of require_confirmation

if [ -z "${BASH_VERSION:-}" ]; then
  echo "common.sh: bash is required" >&2
  # shellcheck disable=SC2317  # exit is reached when the file is executed
  return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "common.sh is a library; source it from a script instead of running it." >&2
  exit 1
fi

# Load once per shell.
if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Strict mode
# ---------------------------------------------------------------------------
set -Eeuo pipefail
# Command substitutions inherit errexit on bash 4.4 and later.
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
  shopt -s inherit_errexit
fi

# ---------------------------------------------------------------------------
# Repository root
# ---------------------------------------------------------------------------
# This file lives at <root>/scripts/lib/common.sh. Resolving from its own path
# works without git (release tarballs, containers with a bind mount).
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fi
export REPO_ROOT

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_level_num() {
  case "${1:-info}" in
    debug) echo 10 ;;
    info) echo 20 ;;
    warn | warning) echo 30 ;;
    error) echo 40 ;;
    *) echo 20 ;;
  esac
}

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _C_RESET=$'\033[0m'
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'
else
  _C_RESET=''
  _C_DIM=''
  _C_RED=''
  _C_YELLOW=''
  _C_BLUE=''
fi

_log() {
  local level="$1" colour="$2"
  shift 2
  if (($(_log_level_num "$level") < $(_log_level_num "${LOG_LEVEL:-info}"))); then
    return 0
  fi
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s%s%s %s%-5s%s %s\n' "$_C_DIM" "$ts" "$_C_RESET" "$colour" "$level" "$_C_RESET" "$*" >&2
}

log_debug() { _log debug "$_C_DIM" "$@"; }
log_info() { _log info "$_C_BLUE" "$@"; }
log_warn() { _log warn "$_C_YELLOW" "$@"; }
log_error() { _log error "$_C_RED" "$@"; }
log() { log_info "$@"; }

# die MESSAGE [EXIT_CODE]
die() {
  local code="${2:-1}"
  log_error "$1"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Traps: error report and cleanup handlers
# ---------------------------------------------------------------------------
_COMMON_CLEANUP=()

# add_cleanup COMMAND
# Registers a command to run on exit. Handlers run in reverse order.
add_cleanup() {
  _COMMON_CLEANUP+=("$1")
}

_common_on_exit() {
  local rc=$?
  local i
  set +e
  for ((i = ${#_COMMON_CLEANUP[@]} - 1; i >= 0; i--)); do
    eval "${_COMMON_CLEANUP[$i]}"
  done
  exit "$rc"
}

# _common_on_err EXIT_CODE LINE COMMAND
# Reports a failed command with its file, line and function. The trap passes
# $LINENO and $BASH_COMMAND because both change once the handler runs.
# Inside a function bash 3.2 reports the line of the function definition;
# bash 4 and later report the failing line.
#
# With errtrace (set -E) the trap also runs inside subshells and command
# substitutions, where bash does not know that the caller guards the result,
# for example
#   if out="$(helm get metadata x)"; then ...
#   out="$(cmd)" || out=default
# A report from there would be a false error, so subshells stay silent: when
# the failure matters, the parent shell fails on the substitution or subshell
# and reports it with its own file and line.
_common_on_err() {
  local rc="$1" line="$2" cmd="$3"
  if ((BASH_SUBSHELL > 0)); then
    return 0
  fi
  local src="${BASH_SOURCE[1]:-${0}}" fn="${FUNCNAME[1]:-main}" where
  where="${src#"${REPO_ROOT}"/}:${line}"
  [[ "$fn" == "main" ]] || where="${where} in ${fn}()"
  log_error "command failed with exit code ${rc} at ${where}: ${cmd}"
}

trap _common_on_exit EXIT
trap '_common_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Temporary files
# ---------------------------------------------------------------------------
# make_temp_file VAR [SUFFIX_HINT]
# make_temp_dir  VAR [SUFFIX_HINT]
# Create a private temporary file or directory, store its path in VAR and
# remove it on exit. The variable form avoids the subshell of $(...), in which
# a cleanup registration would be lost.
make_temp_file() {
  local __var="$1" __hint="${2:-tmp}" __path
  __path="$(umask 077 && mktemp "${TMPDIR:-/tmp}/${__hint}.XXXXXXXX")"
  add_cleanup "rm -f -- '${__path}'"
  printf -v "$__var" '%s' "$__path"
}

make_temp_dir() {
  local __var="$1" __hint="${2:-tmp}" __path
  __path="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/${__hint}.XXXXXXXX")"
  add_cleanup "rm -rf -- '${__path}'"
  printf -v "$__var" '%s' "$__path"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
# require_cmd CMD...
# Fails with one message listing every missing command.
require_cmd() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required command(s): ${missing[*]} (see mise.toml for pinned versions)"
  fi
}

# require_env VAR...
# Fails when any variable is unset or empty.
require_env() {
  local missing=() name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required environment variable(s): ${missing[*]}"
  fi
}

# version_ge HAVE WANT
# True when version HAVE >= WANT. Accepts a leading "v" and ignores
# pre-release or build suffixes ("1.2.3-rc.1" compares as 1.2.3).
version_ge() {
  local have="${1#v}" want="${2#v}"
  have="${have%%[-+]*}"
  want="${want%%[-+]*}"
  local IFS=.
  # shellcheck disable=SC2206  # intentional split on dots
  local h=($have) w=($want)
  local i hv wv
  for ((i = 0; i < 3; i++)); do
    hv="${h[$i]:-0}"
    wv="${w[$i]:-0}"
    hv="${hv//[!0-9]/}"
    wv="${wv//[!0-9]/}"
    if ((10#${hv:-0} > 10#${wv:-0})); then return 0; fi
    if ((10#${hv:-0} < 10#${wv:-0})); then return 1; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Placeholders and configuration
# ---------------------------------------------------------------------------
# is_placeholder VALUE
# True for empty values and the repository placeholders CHANGE_ME, YOUR_*
# and <ANGLE_BRACKET> tokens.
is_placeholder() {
  local v="${1:-}"
  [[ -z "$v" ]] && return 0
  case "$v" in
    *CHANGE_ME* | *YOUR_[A-Z]* | *\<[A-Z_]*\>*) return 0 ;;
  esac
  return 1
}

_require_yq_v4() {
  require_cmd yq
  if ! yq --version 2>/dev/null | grep -q 'mikefarah'; then
    die "yq must be the Go implementation (mikefarah/yq v4); see mise.toml"
  fi
}

# config_get FILE EXPRESSION
# Prints the scalar at EXPRESSION (yq syntax, for example .cluster.name).
# Fails when the file is missing, the key is absent or null, or the value is
# a placeholder.
config_get() {
  local file="$1" expr="$2" value
  [[ -f "$file" ]] || die "config file not found: $file"
  _require_yq_v4
  if [[ "$(yq "(${expr}) | tag" "$file")" == "!!null" ]]; then
    die "missing key ${expr} in ${file}"
  fi
  value="$(yq "${expr}" "$file")"
  if is_placeholder "$value"; then
    die "placeholder value for ${expr} in ${file}: replace it before running"
  fi
  printf '%s\n' "$value"
}

# config_get_or FILE EXPRESSION DEFAULT
# Like config_get, but prints DEFAULT when the key is absent or null.
# A placeholder value still fails.
config_get_or() {
  local file="$1" expr="$2" default="$3" value
  [[ -f "$file" ]] || die "config file not found: $file"
  _require_yq_v4
  if [[ "$(yq "(${expr}) | tag" "$file")" == "!!null" ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  value="$(yq "${expr}" "$file")"
  if is_placeholder "$value"; then
    die "placeholder value for ${expr} in ${file}: replace it before running"
  fi
  printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
# file_mode FILE
# Prints the octal permission bits, for example 600. Works with GNU and BSD
# stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# ---------------------------------------------------------------------------
# .env files
# ---------------------------------------------------------------------------
# load_env_file FILE NAME...
# Parses KEY=VALUE lines without executing the file. Only the listed names are
# accepted; any other key fails. Blank lines and lines starting with # are
# skipped, an optional leading "export " is allowed, and one pair of
# surrounding single or double quotes is removed. No expansion takes place.
# Warns when the file is readable by group or others.
load_env_file() {
  local file="$1"
  shift
  [[ -f "$file" ]] || die ".env file not found: $file"
  local allowed=" $* "
  if [[ "$(file_mode "$file")" != *00 ]]; then
    log_warn "${file} is accessible by group or others; run: chmod 600 ${file}"
  fi
  local line key value lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    # Trim leading whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    line="${line#export }"
    if [[ "$line" != *=* ]]; then
      die "${file}:${lineno}: expected KEY=VALUE"
    fi
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "${file}:${lineno}: invalid variable name"
    fi
    if [[ "$allowed" != *" ${key} "* ]]; then
      die "${file}:${lineno}: variable ${key} is not allowed here (allowed:${allowed% })"
    fi
    if [[ ${#value} -ge 2 ]]; then
      case "$value" in
        \"*\") value="${value:1:${#value}-2}" ;;
        \'*\') value="${value:1:${#value}-2}" ;;
      esac
    fi
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163  # export the variable named by $key
    export "$key"
  done <"$file"
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# read_secret VAR PROMPT
# Reads a secret without echo from the terminal, or from stdin when stdin is
# not a terminal (for piping from a password manager). The value never
# appears on a command line.
read_secret() {
  local __var="$1" __prompt="${2:-Secret: }" __value=""
  if [[ -t 0 ]]; then
    IFS= read -r -s -p "$__prompt" __value
    printf '\n' >&2
  else
    IFS= read -r __value || [[ -n "$__value" ]]
  fi
  [[ -n "$__value" ]] || die "empty secret for ${__var}"
  printf -v "$__var" '%s' "$__value"
}

# write_private_file DEST
# Writes stdin to DEST with mode 0600, atomically (temporary file in the same
# directory, then rename).
write_private_file() {
  local dest="$1" dir tmp
  dir="$(dirname -- "$dest")"
  [[ -d "$dir" ]] || die "directory does not exist: $dir"
  tmp="$(umask 077 && mktemp "${dir}/.$(basename -- "$dest").XXXXXXXX")"
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    die "failed to write $dest"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# Execution helpers
# ---------------------------------------------------------------------------
# run_cmd CMD [ARGS...]
# Logs the command at debug level and runs it, or only prints it when
# DRY_RUN=1. Do not pass secrets as arguments.
run_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  log_debug "run: $*"
  "$@"
}

# require_confirmation DESCRIPTION
# Passes when CONFIRM=yes. Otherwise asks on an interactive terminal for the
# literal word "yes", and fails without a terminal.
require_confirmation() {
  local what="$1" answer=""
  if [[ "${CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "refusing to ${what} without confirmation; set CONFIRM=yes"
  fi
  printf 'About to %s. Type "yes" to continue: ' "$what" >&2
  IFS= read -r answer
  [[ "$answer" == "yes" ]] || die "aborted"
}
