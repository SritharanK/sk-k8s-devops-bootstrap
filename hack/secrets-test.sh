#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Self-test for the gitleaks configuration (.gitleaks.toml).
#
# Builds fixtures at runtime in a private temporary directory (no key
# material or environment data is stored in the repository), scans each one
# in directory mode and in Git mode, and checks the expected outcome:
#   - a freshly generated ed25519 private key is reported, also in *.example;
#   - a key skeleton with a placeholder body passes only in *.example files;
#   - SealedSecret ciphertexts pass, a high-entropy password does not;
#   - IPv4 literals pass only as loopback, RFC 5737, private CIDRs, tags,
#     RKE2 release notation, or private host addresses in *.example files;
#   - host names pass only for placeholder and allowlisted upstream domains.
#
# Usage: hack/secrets-test.sh   (or: make secrets-test)

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

require_cmd gitleaks ssh-keygen git openssl jq

CONFIG="${REPO_ROOT}/.gitleaks.toml"
GITLEAKS_MIN="8.25.0"

have="$(gitleaks version)"
version_ge "$have" "$GITLEAKS_MIN" || die "gitleaks ${have} is older than ${GITLEAKS_MIN}"

make_temp_dir WORK gitleaks-test

PASS=0
FAIL=0

# new_case NAME: creates and prints a fresh fixture directory.
new_case() {
  local dir="${WORK}/cases/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# scan MODE DIR: prints the sorted, unique rule IDs found (one per line).
scan() {
  local mode="$1" dir="$2" report="${WORK}/report-$RANDOM.json"
  case "$mode" in
    dir)
      # Scan from the fixture root, as hack/secrets.sh does for the tree, so
      # finding paths are relative like repository paths.
      (
        cd "$dir" || exit 1
        gitleaks dir . --no-banner --redact --exit-code 0 --log-level error \
          -c "$CONFIG" --gitleaks-ignore-path "${WORK}/empty-ignore" \
          --report-format json --report-path "$report"
      )
      ;;
    git)
      (
        cd "$dir" || exit 1
        git init -q .
        git add -A
        git -c user.name=fixture -c user.email=fixture@example.com \
          -c commit.gpgsign=false commit -q -m fixture
      )
      gitleaks git "$dir" --no-banner --redact --exit-code 0 --log-level error \
        -c "$CONFIG" --gitleaks-ignore-path "${WORK}/empty-ignore" \
        --report-format json --report-path "$report"
      ;;
  esac
  jq -r '.[].RuleID' "$report" | sort -u
}

# expect NAME EXPECTED_RULES DIR
# EXPECTED_RULES is a space-separated list, empty for "no finding".
expect() {
  local name="$1" want="$2" dir="$3" mode got
  want="$(tr ' ' '\n' <<<"$want" | sed '/^$/d' | sort -u)"
  for mode in dir git; do
    local copy="${dir}-${mode}"
    cp -R "$dir" "$copy"
    got="$(scan "$mode" "$copy")"
    if [[ "$got" == "$want" ]]; then
      PASS=$((PASS + 1))
      printf 'ok   [%s] %s\n' "$mode" "$name"
    else
      FAIL=$((FAIL + 1))
      printf 'FAIL [%s] %s: want {%s} got {%s}\n' "$mode" "$name" \
        "$(printf '%s' "$want" | tr '\n' ' ')" "$(printf '%s' "$got" | tr '\n' ' ')"
    fi
  done
}

: >"${WORK}/empty-ignore"

# --- Private keys ------------------------------------------------------------
KEYDIR="${WORK}/keys"
mkdir -p "$KEYDIR"
ssh-keygen -q -t ed25519 -N '' -C fixture -f "${KEYDIR}/id_ed25519"

d="$(new_case real-key)"
cp "${KEYDIR}/id_ed25519" "${d}/deploy_key"
expect "generated ed25519 key is reported" "private-key" "$d"

d="$(new_case real-key-in-example)"
{
  printf 'stringData:\n  sshPrivateKey: |\n'
  sed 's/^/    /' "${KEYDIR}/id_ed25519"
} >"${d}/repo-secret.yaml.example"
expect "real key in an *.example file is reported" "private-key" "$d"

skeleton() {
  # The armour lines are assembled at runtime so that this script does not
  # match the private-key rule itself.
  local dashes='-----' kind='OPENSSH PRIVATE KEY'
  printf 'stringData:\n  sshPrivateKey: |\n'
  printf '    %sBEGIN %s%s\n' "$dashes" "$kind" "$dashes"
  printf '    <BASE64_OR_PEM_ENCODED_PRIVATE_KEY>\n'
  printf '    %sEND %s%s\n' "$dashes" "$kind" "$dashes"
}

d="$(new_case skeleton-example)"
skeleton >"${d}/repo-secret.yaml.example"
expect "placeholder key skeleton in *.example passes" "" "$d"

d="$(new_case skeleton-plain)"
skeleton >"${d}/repo-secret.yaml"
expect "placeholder key skeleton outside *.example is reported" "private-key" "$d"

# --- Sealed ciphertext and generic secrets -----------------------------------
sealed_value() {
  # Shape of a kubeseal value: 0x02 0x00, then random bytes, base64 encoded.
  {
    printf '\002\000'
    openssl rand 700
  } | openssl base64 -A
}

d="$(new_case sealed)"
cat >"${d}/sealed-secret.yaml" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: repo
  namespace: argocd
spec:
  encryptedData:
    password: $(sealed_value)
    username: $(sealed_value)
EOF
expect "SealedSecret ciphertext passes" "" "$d"

d="$(new_case generic-password)"
cat >"${d}/values.yaml" <<EOF
grafana:
  adminPassword: "$(openssl rand -base64 24 | tr -d '/+=')"
EOF
expect "high-entropy password is reported" "generic-api-key" "$d"

d="$(new_case placeholder-password)"
cat >"${d}/values.yaml.example" <<'EOF'
grafana:
  adminPassword: CHANGE_ME
  apiToken: YOUR_API_TOKEN
EOF
expect "placeholder password in *.example passes" "" "$d"

# Fixture lines are assembled with printf so that this script itself holds
# no id:version or key = value literal that the rules would report.
PLUGINS_DIR="ansible/roles/install_jenkins/files"
plugin_lines() {
  printf '%s:%s\n' "asm-api" "9.11.1-226.vff833a_e4c58e"
  printf '%s:%s\n' "jackson2-api" "2.20.0-424.v8a_e3e3b_8c3f6"
}

d="$(new_case jenkins-plugins)"
mkdir -p "${d}/${PLUGINS_DIR}"
plugin_lines >"${d}/${PLUGINS_DIR}/plugins.txt"
expect "Jenkins plugin lock lines pass" "" "$d"

d="$(new_case jenkins-plugins-secret)"
mkdir -p "${d}/${PLUGINS_DIR}"
{
  plugin_lines
  printf '%s = "%s"\n' "jenkins_api_token" "$(openssl rand -base64 24 | tr -d '/+=')"
} >"${d}/${PLUGINS_DIR}/plugins.txt"
expect "token in the Jenkins plugin lock is reported" "generic-api-key" "$d"

hex64() { openssl rand -hex 32; }

d="$(new_case digest-pins)"
{
  printf '%s: "%s"\n' "jenkins_repo_key_sha256" "$(hex64)"
  printf '%s: "%s"\n' "jenkins_repo_key_fingerprint" "$(openssl rand -hex 20 | tr 'a-f' 'A-F')"
} >"${d}/main.yml"
expect "hex digests on checksum and fingerprint keys pass" "" "$d"

d="$(new_case digest-like-secret)"
printf '%s: "%s"\n' "grafana_api_key" "$(hex64)" >"${d}/main.yml"
expect "hex value on a key name is reported" "generic-api-key" "$d"

# --- IPv4 ----------------------------------------------------------------------
d="$(new_case ipv4-allowed)"
cat >"${d}/cluster.yaml" <<'EOF'
listen: 0.0.0.0
loopback: 127.0.0.1
example: 192.0.2.10
example2: "198.51.100.7:6443"
example3: 203.0.113.0/24
podCidr: 10.42.0.0/16
serviceCidr: 10.43.0.0/16
policy: [172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10]
metadata: 169.254.169.254/32
netmask: 255.255.255.0
image:
  tag: 15.4.14.3
oid: 1.3.6.1.4.1.311.20.2.3
version: v1.2.3.4
EOF
expect "loopback, RFC 5737, private CIDRs, tags and OIDs pass" "" "$d"

d="$(new_case ipv4-private-host)"
printf 'server: 10.0.0.5\n' >"${d}/hosts.yml"
expect "private host address is reported" "hardcoded-ipv4" "$d"

d="$(new_case ipv4-public)"
printf 'upstream: "https://8.8.4.4:443"\n' >"${d}/values.yaml"
expect "public address is reported" "hardcoded-ipv4" "$d"

d="$(new_case ipv4-public-cidr)"
printf 'allow: [8.8.4.0/24]\n' >"${d}/values.yaml"
expect "public CIDR is reported" "hardcoded-ipv4" "$d"

d="$(new_case ipv4-inventory)"
printf '[rke2_servers]\nnode1 ansible_host=172.20.1.11\n' >"${d}/hosts"
expect "address in an INI inventory is reported" "hardcoded-ipv4" "$d"

d="$(new_case ipv4-example-private-host)"
printf 'rke2_node_ip: 10.0.0.10\nother: 192.168.10.5\n' >"${d}/hosts.yml.example"
expect "private host address in an example file passes" "" "$d"

d="$(new_case ipv4-example-public-host)"
printf 'rke2_node_ip: 8.8.4.4\n' >"${d}/hosts.yml.example"
expect "public address in an example file is reported" "hardcoded-ipv4" "$d"

d="$(new_case ipv4-rke2-release)"
printf '# v1.36.6+rke2r1 becomes 1.36.6.1.\n' >"${d}/main.yml"
expect "RKE2 release notation passes" "" "$d"

# --- Domains -------------------------------------------------------------------
d="$(new_case domain-allowed)"
cat >"${d}/values.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
metadata:
  labels:
    app.kubernetes.io/name: hello-api
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    cert-manager.io/cluster-issuer: selfsigned
hosts: ["hello-api.dev.localtest.me", "*.example.com"]
email: platform@example.com
repoURL: https://github.com/YOUR_ORG/sk-k8s-devops-bootstrap.git
chart: oci://ghcr.io/argoproj/argo-helm/argo-cd
image: registry.k8s.io/pause:3.10
namespace: {{ .Values.namespaces.dev }}
parameters:
  - name: global.domain
EOF
expect "placeholder and upstream domains pass" "" "$d"

d="$(new_case domain-org)"
printf 'ingress:\n  hosts:\n    - grafana.fixture-not-allowed.com\n' >"${d}/values-prod.yaml"
expect "organisation host name is reported" "hardcoded-domain" "$d"

d="$(new_case domain-wildcard)"
printf 'dnsNames: ["*.fixture-not-allowed.be"]\n' >"${d}/certificate.yaml"
expect "wildcard host name is reported" "hardcoded-domain" "$d"

d="$(new_case domain-email)"
printf 'email: ops@fixture-not-allowed.net\n' >"${d}/cluster.yaml"
expect "e-mail domain is reported" "hardcoded-domain" "$d"

d="$(new_case domain-url)"
printf 'targets: ["prometheus.fixture-not-allowed.io:9090"]\n' >"${d}/values.yaml"
expect "host:port target is reported" "hardcoded-domain" "$d"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
