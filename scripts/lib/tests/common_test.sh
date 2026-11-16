#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Self-test for scripts/lib/common.sh. Runs with bash 3.2 and later.
# Usage: scripts/lib/tests/common_test.sh   (or: make test-lib)

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
}

check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

check_fails() {
  local name="$1"
  shift
  if (NO_COLOR=1 LOG_LEVEL=error "$@") >/dev/null 2>&1; then not_ok "$name"; else ok "$name"; fi
}

make_temp_dir WORK lib-test

# REPO_ROOT
check "REPO_ROOT contains scripts/lib/common.sh" test -f "${REPO_ROOT}/scripts/lib/common.sh"

# version_ge
check "version_ge equal" version_ge v8.25.0 8.25.0
check "version_ge newer minor" version_ge 8.30.1 v8.25.0
check "version_ge newer major" version_ge 4.0.0 3.99.99
check "version_ge ignores suffix" version_ge 1.2.3-rc.1 1.2.3
check "version_ge short form" version_ge 1.34 1.34.0
check_fails "version_ge older" version_ge 8.24.2 8.25.0

# is_placeholder
check "placeholder CHANGE_ME" is_placeholder CHANGE_ME
check "placeholder YOUR_ORG in URL" is_placeholder https://github.com/YOUR_ORG/repo.git
check "placeholder angle brackets" is_placeholder '<BASE64_KEY>'
check "placeholder empty" is_placeholder ''
check_fails "real value is not a placeholder" is_placeholder platform@example.com

# require_cmd / require_env
check "require_cmd bash" require_cmd bash
check_fails "require_cmd missing" require_cmd definitely-not-a-command-1234
check_fails "require_env missing" require_env DEFINITELY_UNSET_VAR_1234

# load_env_file
ENVF="${WORK}/test.env"
cat >"$ENVF" <<'EOF'
# comment
export GIT_USER="deploy user"
GIT_HOST='git.example.com'
EMPTY_OK=
WITH_DOLLAR=$(touch /should-not-run)
EOF
chmod 600 "$ENVF"
env_file_parses() {
  (
    load_env_file "$ENVF" GIT_USER GIT_HOST EMPTY_OK WITH_DOLLAR
    [[ "$GIT_USER" == "deploy user" && "$GIT_HOST" == "git.example.com" ]] || exit 1
    [[ -z "$EMPTY_OK" ]] || exit 1
    # Values are never evaluated.
    # shellcheck disable=SC2016  # literal comparison is the point of the test
    [[ "$WITH_DOLLAR" == '$(touch /should-not-run)' ]] || exit 1
  )
}
check "load_env_file parses without evaluation" env_file_parses
check_fails "load_env_file rejects keys outside the allowlist" load_env_file "$ENVF" GIT_USER

# config_get
CFG="${WORK}/cluster.yaml"
cat >"$CFG" <<'EOF'
cluster:
  name: lab
  flag: false
rke2:
  version: CHANGE_ME
EOF
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q mikefarah; then
  check "config_get scalar" test "$(config_get "$CFG" .cluster.name)" = lab
  check "config_get false is a value" test "$(config_get "$CFG" .cluster.flag)" = false
  check "config_get_or default" test "$(config_get_or "$CFG" .cluster.missing fallback)" = fallback
  check_fails "config_get missing key" config_get "$CFG" .cluster.missing
  check_fails "config_get placeholder" config_get "$CFG" .rke2.version
else
  printf 'skip config_get tests: mikefarah yq v4 not installed\n'
fi

# write_private_file
SECRET_FILE="${WORK}/secret.txt"
printf 'value' | write_private_file "$SECRET_FILE"
check "write_private_file content" test "$(cat "$SECRET_FILE")" = value
check "write_private_file mode 0600" test "$(file_mode "$SECRET_FILE")" = 600

# make_temp_file is removed on exit
LEFTOVER="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; make_temp_file T x; printf '%s' \"\$T\"")"
check "make_temp_file removed on exit" test ! -e "$LEFTOVER"

# require_confirmation
check "require_confirmation CONFIRM=yes" env CONFIRM=yes bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_confirmation 'test' </dev/null"
check_fails "require_confirmation without terminal" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_confirmation 'test' </dev/null"

# run_cmd honours DRY_RUN
check "run_cmd dry run does not execute" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; DRY_RUN=1 run_cmd false 2>/dev/null"

# ERR trap: guarded failures stay silent, an unguarded one is reported once
# with its own line, and the script exits non-zero.
TRAP_SCRIPT="${WORK}/trap_case.sh"
cat >"$TRAP_SCRIPT" <<EOF
source '${REPO_ROOT}/scripts/lib/common.sh'
if out="\$(false)"; then :; fi
out="\$(false)" || out=fallback
guarded() { false; }
if ! guarded; then :; fi
[[ "\$out" == fallback ]]
value="\$(false)"
echo not-reached
EOF
TRAP_RC=0
TRAP_ERR="$(NO_COLOR=1 bash "$TRAP_SCRIPT" 2>&1 >/dev/null)" || TRAP_RC=$?
check "ERR trap: script fails on the unguarded substitution" test "$TRAP_RC" -ne 0
check "ERR trap: exactly one report" test "$(grep -c 'command failed' <<<"$TRAP_ERR")" = 1
# shellcheck disable=SC2016  # the literal $(false) is the expected text
check "ERR trap: report names line 7 and the command" grep -q 'trap_case.sh:7: value="\$(false)"' <<<"$TRAP_ERR"

FUNC_SCRIPT="${WORK}/trap_func.sh"
cat >"$FUNC_SCRIPT" <<EOF
source '${REPO_ROOT}/scripts/lib/common.sh'
step() {
  false
}
step
EOF
FUNC_RC=0
FUNC_ERR="$(NO_COLOR=1 bash "$FUNC_SCRIPT" 2>&1 >/dev/null)" || FUNC_RC=$?
check "ERR trap: failure in a function fails the script" test "$FUNC_RC" -ne 0
check "ERR trap: failure in a function names the function and command" grep -q 'trap_func.sh:[0-9]* in step(): false$' <<<"$FUNC_ERR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
