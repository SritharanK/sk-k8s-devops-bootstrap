#!/usr/bin/env bash
# Lint the Jenkins CI adapter: ci/jenkins/ and the install_jenkins role.
#
# Static checks (no container needed):
#   - Jenkinsfiles and Job DSL scripts never start with a '#' header line.
#   - Every sample-services/<dir> with a Dockerfile has an entry in
#     ci/jenkins/services.yaml, and every entry points at an existing Dockerfile.
#   - Every image in ci/jenkins/pod-templates/ is pinned by digest.
#   - plugins.txt pins an exact version for every plugin and contains every
#     top-level plugin from plugins.in.txt.
#   - The configuration-as-code template renders as valid YAML for the oidc,
#     ldap and local security realms.
#
# Controller checks (skipped with --static-only; need Docker):
#   - Boots the pinned Jenkins LTS with the role's exact plugin set and the
#     rendered configuration. Any configuration error fails the boot.
#   - Runs the declarative linter on every ci/jenkins/pipelines/*.Jenkinsfile.
#   - Checks that the Job DSL generated services/<name>/build and
#     services/<name>/promote for every service, from SCM, with the build
#     identity (Authorize Project) and SCM polling restricted to the service.
#   - Checks the security baseline: anonymous gets 403, the built-in node has
#     0 executors, the credentials exist, the build identity may use them,
#     and the exported configuration contains no secret value.
#
# Usage: hack/jenkins-lint.sh [--static-only] [--keep]
#   --static-only  run only the static checks
#   --keep         leave the lint controller running for inspection
#
# Requirements: bash, yq (v4), jq, curl, ansible-playbook; docker for the
# controller checks.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if [[ -f scripts/lib/common.sh ]]; then
  # shellcheck source=/dev/null
  source scripts/lib/common.sh
fi
if ! declare -F log >/dev/null; then
  log() { printf '%s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null; then
  die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
  }
fi
if ! declare -F require_cmd >/dev/null; then
  require_cmd() {
    local cmd
    for cmd in "$@"; do
      command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
    done
  }
fi

static_only=false
keep=false
for arg in "$@"; do
  case "${arg}" in
    --static-only) static_only=true ;;
    --keep) keep=true ;;
    -h | --help)
      sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

require_cmd yq jq curl ansible-playbook

readonly services_file=ci/jenkins/services.yaml
readonly role_dir=ansible/roles/install_jenkins
readonly lint_secrets_vars=ci/jenkins/lint/vars.yml

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-lint.XXXXXX")"
container=""
failures=0

cleanup() {
  if [[ "${keep}" == true ]]; then
    return
  fi
  if [[ -n "${container}" ]]; then
    docker rm -f "${container}" >/dev/null 2>&1 || true
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT

fail() {
  log "FAIL: $*"
  failures=$((failures + 1))
}

pass() {
  log "ok:   $*"
}

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

check_headers() {
  local before=${failures}
  local file first
  while IFS= read -r file; do
    first="$(grep -m1 -v '^[[:space:]]*$' "${file}" || true)"
    if [[ "${first}" == '#'* ]]; then
      fail "${file}: first line starts with '#', which Groovy rejects"
    fi
  done < <(find ci/jenkins -type f \( -name '*.Jenkinsfile' -o -name 'Jenkinsfile' -o -name '*.groovy' \) | sort)
  if ((failures == before)); then
    pass "Groovy files have no '#' header"
  fi
}

check_services_inventory() {
  local before=${failures}
  local name path dockerfile dir
  local -a declared=()

  yq -e '.environments | length >= 2' "${services_file}" >/dev/null ||
    fail "${services_file}: environments needs at least two entries"

  while IFS=$'\t' read -r name path dockerfile; do
    declared+=("${path}")
    [[ "${name}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail "${services_file}: invalid name '${name}'"
    [[ "${path}" =~ ^sample-services/[a-z0-9][a-z0-9._-]*$ ]] || fail "${services_file}: invalid path '${path}'"
    [[ -f "${path}/${dockerfile}" ]] || fail "${services_file}: ${name}: ${path}/${dockerfile} does not exist"
  done < <(yq -r '.services[] | [.name, .path, .dockerfile] | @tsv' "${services_file}")

  for dir in sample-services/*/; do
    dir="${dir%/}"
    [[ -f "${dir}/Dockerfile" ]] || continue
    if [[ " ${declared[*]} " != *" ${dir} "* ]]; then
      fail "${dir} has a Dockerfile but no entry in ${services_file}"
    fi
  done
  if ((failures == before)); then
    pass "services.yaml matches sample-services/"
  fi
}

check_pod_template_images() {
  local before=${failures}
  local file image
  local -a templates=()
  while IFS= read -r file; do
    templates+=("${file}")
  done < <(find ci/jenkins/pod-templates -type f -name '*.yaml' 2>/dev/null | sort)
  if ((${#templates[@]} == 0)); then
    fail "no pod template found under ci/jenkins/pod-templates"
  fi
  for file in "${templates[@]}"; do
    yq -e '.kind == "Pod"' "${file}" >/dev/null || fail "${file}: not a Pod manifest"
    while IFS= read -r image; do
      if [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
        fail "${file}: image not pinned by digest: ${image}"
      fi
      if [[ "${image}" == *:latest* ]]; then
        fail "${file}: image uses latest: ${image}"
      fi
    done < <(yq -r '.. | select(has("image")) | .image' "${file}")
  done
  if ((failures == before)); then
    pass "pod template images are pinned by digest"
  fi
}

check_plugins() {
  local before=${failures}
  local line plugin
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == '#'* ]] && continue
    [[ "${line}" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._+-]+$ ]] || fail "plugins.txt: not an exact id:version pin: ${line}"
  done <"${role_dir}/files/plugins.txt"

  while IFS= read -r plugin; do
    plugin="${plugin%%#*}"
    plugin="${plugin//[[:space:]]/}"
    [[ -z "${plugin}" ]] && continue
    grep -q "^${plugin}:" "${role_dir}/files/plugins.txt" || fail "plugins.txt: top-level plugin ${plugin} missing"
  done <"${role_dir}/files/plugins.in.txt"
  if ((failures == before)); then
    pass "plugins.txt pins exact versions"
  fi
}

render() {
  local realm="$1" out="$2"
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, ci/jenkins/lint/render.yml \
    -e "lint_output_dir=${out}" -e "install_jenkins_security_realm=${realm}" >"${out}.log" 2>&1 || {
    cat "${out}.log" >&2
    return 1
  }
}

check_render() {
  local before=${failures}
  local realm out
  for realm in oidc ldap local; do
    out="${work_dir}/render-${realm}"
    if ! render "${realm}" "${out}"; then
      fail "configuration template does not render for realm ${realm}"
      continue
    fi
    yq -e '.jenkins.numExecutors == 0' "${out}/casc/jenkins.yaml" >/dev/null ||
      fail "realm ${realm}: rendered configuration is not valid YAML or allows executors on the controller"
  done
  if ((failures == before)); then
    pass "configuration template renders for oidc, ldap and local"
  fi
}

# ---------------------------------------------------------------------------
# Controller checks
# ---------------------------------------------------------------------------

install_jenkins_url=""
admin_auth=""
cookie_jar="${work_dir}/cookies"
crumb_header=""

boot_controller() {
  local context="${work_dir}/image" image hash port code deadline
  mkdir -p "${context}"
  cp ci/jenkins/lint/Dockerfile "${context}/Dockerfile"
  cp "${role_dir}/files/plugins.txt" "${context}/plugins.txt"
  hash="$(cat "${context}/Dockerfile" "${context}/plugins.txt" | shasum -a 256 | cut -c1-12)"
  image="jenkins-lint:${hash}"

  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    log "building ${image} (pinned LTS with the role's plugins)"
    docker build --quiet --tag "${image}" "${context}" >/dev/null
  fi

  container="jenkins-lint-${hash}-$$"
  docker run --detach --name "${container}" \
    --publish 127.0.0.1::8080 \
    --volume "${work_dir}/render-local/casc:/etc/jenkins/casc:ro" \
    --volume "${work_dir}/render-local/casc-secrets:/etc/jenkins/casc-secrets:ro" \
    "${image}" >/dev/null

  port="$(docker port "${container}" 8080/tcp | head -n1 | sed 's/.*://')"
  install_jenkins_url="http://127.0.0.1:${port}"
  admin_auth="admin:$(yq -r '.lint_secrets.local_admin_password' "${lint_secrets_vars}")"

  log "waiting for the lint controller at ${install_jenkins_url}"
  deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "${container}")" != true ]]; then
      docker logs "${container}" >&2 || true
      die "lint controller exited during startup"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' "${install_jenkins_url}/login" || true)"
    [[ "${code}" == 200 ]] && break
    sleep 3
  done
  if [[ "${code}" != 200 ]]; then
    docker logs "${container}" >&2 || true
    die "lint controller did not become ready (last HTTP status ${code})"
  fi
  if docker logs "${container}" 2>&1 | grep -E 'ConfiguratorException|UnknownAttributesException|SEVERE' >"${work_dir}/startup-errors"; then
    cat "${work_dir}/startup-errors" >&2
    fail "the controller logged configuration errors at startup"
  else
    pass "pinned LTS boots with the rendered configuration and the locked plugins"
  fi

  local crumb_json
  crumb_json="$(curl -fsS -c "${cookie_jar}" -u "${admin_auth}" "${install_jenkins_url}/crumbIssuer/api/json")"
  crumb_header="$(jq -r '.crumbRequestField + ": " + .crumb' <<<"${crumb_json}")"
}

api_get() {
  curl -fsSg -b "${cookie_jar}" -u "${admin_auth}" "${install_jenkins_url}$1"
}

api_post() {
  local path="$1"
  shift
  curl -fsSg -b "${cookie_jar}" -c "${cookie_jar}" -u "${admin_auth}" -H "${crumb_header}" -X POST "$@" "${install_jenkins_url}${path}"
}

check_declarative_lint() {
  local file result
  local -a files=()
  while IFS= read -r file; do
    files+=("${file}")
  done < <(find ci/jenkins/pipelines -type f -name '*.Jenkinsfile' | sort)
  if ((${#files[@]} == 0)); then
    fail "no Jenkinsfile found under ci/jenkins/pipelines"
    return
  fi
  for file in "${files[@]}"; do
    if ! result="$(api_post /pipeline-model-converter/validate -F "jenkinsfile=<${file}")"; then
      fail "declarative linter request failed for ${file}"
      continue
    fi
    if [[ "${result}" == *"successfully validated"* ]]; then
      pass "declarative linter: ${file}"
    else
      log "${result}"
      fail "declarative linter: ${file}"
    fi
  done
}

check_generated_jobs() {
  local name path environments config promote
  environments="$(yq -r '.environments[1:] | join(",")' "${services_file}")"
  while IFS=$'\t' read -r name path; do
    if ! config="$(api_get "/job/services/job/${name}/job/build/config.xml")"; then
      fail "job services/${name}/build was not generated"
      continue
    fi
    grep -q '<scriptPath>ci/jenkins/pipelines/build.Jenkinsfile</scriptPath>' <<<"${config}" ||
      fail "services/${name}/build: wrong script path"
    grep -q "<includedRegions>${path}/\.\*" <<<"${config}" ||
      fail "services/${name}/build: SCM polling is not restricted to ${path}"
    grep -q 'SpecificUsersAuthorizationStrategy' <<<"${config}" ||
      fail "services/${name}/build: does not run as the build identity"

    if ! promote="$(api_get "/job/services/job/${name}/job/promote/api/json?tree=property[parameterDefinitions[name,choices]]")"; then
      fail "job services/${name}/promote was not generated"
      continue
    fi
    [[ "$(jq -r '[.property[].parameterDefinitions[]? | select(.name == "TARGET_ENV") | .choices[]] | join(",")' <<<"${promote}")" == "${environments}" ]] ||
      fail "services/${name}/promote: TARGET_ENV choices differ from ${environments}"
    pass "Job DSL generated services/${name}/build and services/${name}/promote"
  done < <(yq -r '.services[] | [.name, .path] | @tsv' "${services_file}")
}

check_security_baseline() {
  local code executors ids export_file secret result
  code="$(curl -s -o /dev/null -w '%{http_code}' "${install_jenkins_url}/api/json")"
  if [[ "${code}" == 403 ]]; then
    pass "anonymous access is denied"
  else
    fail "anonymous GET /api/json returned ${code}, expected 403"
  fi

  executors="$(api_get '/computer/api/json?tree=computer[displayName,numExecutors]' |
    jq -r '[.computer[] | select(.displayName == "Built-In Node" or .displayName == "built-in") | .numExecutors] | first // "missing"')"
  if [[ "${executors}" == 0 ]]; then
    pass "built-in node has 0 executors"
  else
    fail "built-in node executors: ${executors}"
  fi

  ids="$(api_get '/credentials/store/system/domain/_/api/json?tree=credentials[id]' | jq -r '[.credentials[].id] | sort | join(",")')"
  if [[ "${ids}" == "argocd-token-dev,argocd-token-stage,cosign-key,cosign-password,git-checkout,github-token,k8s-agent-token,registry-push" ]]; then
    pass "credentials defined: ${ids}"
  else
    fail "unexpected credentials: ${ids}"
  fi

  # The build identity resolves through Authorize Project and may use the
  # job's credentials (Credentials/UseItem), without being an administrator.
  local script service
  service="$(yq -r '.services[0].name' "${services_file}")"
  script="$(
    cat <<'GROOVY'
import com.cloudbees.plugins.credentials.CredentialsProvider
def job = jenkins.model.Jenkins.get().getItemByFullName('services/@SERVICE@/build')
def auth = CredentialsProvider.getDefaultAuthenticationOf2(job)
println([auth.name,
         job.getACL().hasPermission2(auth, CredentialsProvider.USE_ITEM),
         job.getACL().hasPermission2(auth, hudson.model.Item.CONFIGURE),
         jenkins.model.Jenkins.get().getACL().hasPermission2(auth, jenkins.model.Jenkins.ADMINISTER)].join(','))
GROOVY
  )"
  script="${script//@SERVICE@/${service}}"
  result="$(api_post /scriptText --data-urlencode "script=${script}" | tr -d '\r\n')"
  local expected
  expected="$(yq -r '.install_jenkins_build_user // "jenkins-ci"' "${role_dir}/defaults/main.yml"),true,false,false"
  if [[ "${result}" == "${expected}" ]]; then
    pass "builds run as the build identity, which may use credentials but not configure jobs"
  else
    fail "build identity check: got '${result}', expected '${expected}'"
  fi

  export_file="${work_dir}/export.yaml"
  api_post /configuration-as-code/export -o "${export_file}"
  yq -e '.jenkins.numExecutors == 0' "${export_file}" >/dev/null || fail "exported configuration: numExecutors is not 0"
  while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue
    if grep -qF -- "${secret}" "${export_file}"; then
      fail "exported configuration contains a plain secret value"
    fi
  done < <(yq -r '.lint_secrets | to_entries | .[] | .value | split("\n") | .[0]' "${lint_secrets_vars}")
  pass "exported configuration contains no secret value"
}

main() {
  check_headers
  check_services_inventory
  check_pod_template_images
  check_plugins
  check_render

  if [[ "${static_only}" != true ]]; then
    require_cmd docker
    docker info >/dev/null 2>&1 || die "docker is not reachable (use --static-only to skip the controller checks)"
    boot_controller
    check_declarative_lint
    check_generated_jobs
    check_security_baseline
    if [[ "${keep}" == true ]]; then
      log "lint controller left running: ${install_jenkins_url} (container ${container}, user admin)"
    fi
  fi

  if ((failures > 0)); then
    die "${failures} check(s) failed"
  fi
  log "jenkins-lint: all checks passed"
}

main
