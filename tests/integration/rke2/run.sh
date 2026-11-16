#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Integration test for the RKE2 provisioning path on a local Ubuntu 24.04 VM (Lima).
#
# Creates the VM, renders an inventory for it, runs playbooks/preflight.yml and playbooks/site.yml with
# clusters/lab/cluster.yaml, verifies the node, re-runs site.yml to prove idempotence, runs
# playbooks/rke2_uninstall.yml, and deletes the VM. See README.md for what this proves and what it cannot.
#
# Usage: tests/integration/rke2/run.sh
# Environment:
#   KEEP_VM=1          keep the VM and the work directory after the run (for debugging)
#   VM_NAME            Lima instance name (default it-rke2)
#   VM_CPUS, VM_MEMORY_GIB, VM_DISK_GIB   VM size (defaults 4, 6, 40)
#   MIN_FREE_GIB       host memory that must be available before the VM starts (default 7)
#   WAIT_TIMEOUT_SEC   how long to wait for free memory or a running demo to finish (default 1800)
#   DEMO_CLUSTER       name of the kind demo cluster to wait for (default demo)
set -euo pipefail

VM_NAME=${VM_NAME:-it-rke2}
VM_CPUS=${VM_CPUS:-4}
VM_MEMORY_GIB=${VM_MEMORY_GIB:-6}
VM_DISK_GIB=${VM_DISK_GIB:-40}
MIN_FREE_GIB=${MIN_FREE_GIB:-7}
WAIT_TIMEOUT_SEC=${WAIT_TIMEOUT_SEC:-1800}
KEEP_VM=${KEEP_VM:-0}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
ANSIBLE_DIR="$REPO_ROOT/ansible"
CLUSTER_FILE="$REPO_ROOT/clusters/lab/cluster.yaml"
WORK_DIR=""
VM_IP=""

log() { printf '[rke2-it] %s\n' "$*" >&2; }
die() {
  log "FAIL: $*"
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

cleanup() {
  local rc=$?
  if [[ $KEEP_VM == 1 ]]; then
    log "KEEP_VM=1: leaving VM '$VM_NAME' and work directory $WORK_DIR in place"
  else
    if limactl list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
      log "deleting VM $VM_NAME"
      limactl delete --force "$VM_NAME" >/dev/null 2>&1 || log "could not delete VM $VM_NAME; run: limactl delete --force $VM_NAME"
    fi
    # The work directory holds the generated token and the fetched admin kubeconfig.
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
      rm -rf -- "$WORK_DIR"
    fi
  fi
  if [[ $rc == 0 ]]; then log "PASS"; else log "exit code $rc"; fi
  exit "$rc"
}

# Available memory in GiB: free, inactive and speculative pages on macOS, MemAvailable on Linux.
available_gib() {
  if [[ $(uname -s) == Darwin ]]; then
    vm_stat | awk -v page="$(pagesize)" '
      /Pages free|Pages inactive|Pages speculative/ { gsub(/\./, "", $NF); pages += $NF }
      END { printf "%d\n", pages * page / 1024 / 1024 / 1024 }'
  else
    awk '/MemAvailable/ { printf "%d\n", $2 / 1024 / 1024 }' /proc/meminfo
  fi
}

demo_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DEMO_CLUSTER:-demo}-"
}

wait_for_capacity() {
  local waited=0
  while demo_running || (($(available_gib) < MIN_FREE_GIB)); do
    ((waited < WAIT_TIMEOUT_SEC)) || die "not enough free memory (need ${MIN_FREE_GIB} GiB, have $(available_gib) GiB) or the demo cluster is still running after ${WAIT_TIMEOUT_SEC}s"
    log "waiting: available $(available_gib) GiB, demo running: $(demo_running && echo yes || echo no)"
    sleep 30
    waited=$((waited + 30))
  done
  log "host has $(available_gib) GiB available"
}

# Run a command on the VM over the same SSH path that Ansible uses.
vm_ssh() {
  ssh -F "$WORK_DIR/ssh_config" "$VM_NAME" "$@"
}

# Read a value from the cluster definition with yq.
cluster_value() {
  yq -r "$1" "$CLUSTER_FILE"
}

# Count tasks that changed in the play recap of an ansible-playbook log.
recap_changed() {
  awk -v host="$VM_NAME" '$1 == host && $2 == ":" { for (i = 3; i <= NF; i++) if ($i ~ /^changed=/) { split($i, a, "="); print a[2] } }' "$1"
}

main() {
  require_cmd limactl ansible-playbook ansible-galaxy ssh ssh-keyscan yq jq awk openssl
  [[ -f $CLUSTER_FILE ]] || die "missing $CLUSTER_FILE"
  trap cleanup EXIT

  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rke2-it.XXXXXX")
  chmod 0700 "$WORK_DIR"
  log "work directory $WORK_DIR"

  if limactl list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
    log "removing VM $VM_NAME left over from an earlier run"
    limactl delete --force "$VM_NAME" >/dev/null
  fi

  wait_for_capacity

  # Plain mode: no host mounts, no port forwarding, no containerd. The VM only sees what Ansible installs.
  log "creating VM $VM_NAME (Ubuntu 24.04, ${VM_CPUS} CPU, ${VM_MEMORY_GIB} GiB memory, ${VM_DISK_GIB} GiB disk)"
  limactl create --tty=false --name="$VM_NAME" --plain \
    --cpus="$VM_CPUS" --memory="$VM_MEMORY_GIB" --disk="$VM_DISK_GIB" template:ubuntu-24.04 >/dev/null
  limactl start --tty=false --timeout=10m "$VM_NAME" >/dev/null

  local ssh_port ssh_user ssh_key lima_dir
  lima_dir=$(limactl list --format '{{.Dir}}' "$VM_NAME")
  ssh_port=$(limactl list --format '{{.SSHLocalPort}}' "$VM_NAME")
  ssh_user=$(limactl list --format json "$VM_NAME" | jq -r '.config.user.name // empty')
  [[ -n $ssh_user ]] || ssh_user=$(id -un)
  ssh_key="$(dirname -- "$(dirname -- "$lima_dir")")/_config/user"
  [[ -f $ssh_key ]] || ssh_key="$HOME/.lima/_config/user"
  [[ -f $ssh_key ]] || die "Lima SSH key not found"

  # Pin the VM's host key for this run instead of disabling host key checking. The key is read over the
  # loopback forward of a VM this script created a moment ago.
  ssh-keyscan -p "$ssh_port" -t ed25519 127.0.0.1 2>/dev/null |
    sed "s/^127.0.0.1 /[127.0.0.1]:$ssh_port /" >"$WORK_DIR/known_hosts"
  [[ -s $WORK_DIR/known_hosts ]] || die "could not read the VM host key"

  cat >"$WORK_DIR/ssh_config" <<EOF
Host $VM_NAME
  HostName 127.0.0.1
  Port $ssh_port
  User $ssh_user
  IdentityFile $ssh_key
  IdentitiesOnly yes
  UserKnownHostsFile $WORK_DIR/known_hosts
  StrictHostKeyChecking yes
EOF

  local ssh_source node_cidr
  # shellcheck disable=SC2016 # expanded by the remote shell on the VM
  ssh_source=$(vm_ssh 'printf "%s" "${SSH_CLIENT%% *}"')
  node_cidr=$(vm_ssh "ip -o -4 route show scope link | awk '\$0 !~ /docker|cni|flannel|cali/ { print \$1; exit }'")
  VM_IP=$(vm_ssh "ip -o -4 addr show scope global | awk '{ split(\$4, a, \"/\"); print a[1]; exit }'")
  [[ -n $ssh_source && -n $node_cidr && -n $VM_IP ]] ||
    die "could not determine the SSH source address, the node network or the VM address"
  log "VM reachable on port $ssh_port, SSH source $ssh_source, node network $node_cidr, VM address $VM_IP"

  # Inventory: the committed lab group_vars (cluster definition mapping) plus a generated hosts.yml.
  mkdir -p "$WORK_DIR/inventory"
  cp -R "$ANSIBLE_DIR/inventories/lab/group_vars" "$WORK_DIR/inventory/group_vars"
  cat >"$WORK_DIR/inventory/hosts.yml" <<EOF
---
all:
  vars:
    ansible_user: $ssh_user
    ansible_ssh_private_key_file: $ssh_key
    ansible_ssh_common_args: >-
      -o IdentitiesOnly=yes -o UserKnownHostsFile=$WORK_DIR/known_hosts -o StrictHostKeyChecking=yes
    firewall_node_cidrs: ["$node_cidr"]
    firewall_ssh_cidrs: ["$ssh_source/32"]
    firewall_api_cidrs: []
    # Ansible reaches the VM through a loopback forward, so name the address the kubeconfig must use.
    rke2_api_endpoint: $VM_IP
  children:
    k8s_cluster:
      children:
        rke2_servers:
          hosts:
            $VM_NAME:
              ansible_host: 127.0.0.1
              ansible_port: $ssh_port
        rke2_agents:
          hosts: {}
    nfs_server:
      hosts: {}
    jenkins:
      hosts: {}
EOF

  # Secrets as extra vars from a file in the private work directory; never on the command line.
  printf -- '---\nvault_rke2_token: "%s"\n' "$(openssl rand -hex 32)" >"$WORK_DIR/secrets.yml"
  chmod 0600 "$WORK_DIR/secrets.yml"

  local -a playbook_args=(
    -i "$WORK_DIR/inventory/hosts.yml"
    -e "@$WORK_DIR/secrets.yml"
    -e "rke2_kubeconfig_local_path=$WORK_DIR/kubeconfig-lab.yaml"
  )

  cd "$ANSIBLE_DIR"
  ansible-galaxy collection install -r collections/requirements.yml -p collections >/dev/null

  log "preflight.yml"
  ansible-playbook "${playbook_args[@]}" playbooks/preflight.yml | tee "$WORK_DIR/preflight.log"

  log "site.yml (first run)"
  ansible-playbook "${playbook_args[@]}" playbooks/site.yml | tee "$WORK_DIR/site-1.log"

  verify

  log "site.yml (second run, must change nothing)"
  ansible-playbook "${playbook_args[@]}" playbooks/site.yml | tee "$WORK_DIR/site-2.log"
  local changed
  changed=$(recap_changed "$WORK_DIR/site-2.log")
  [[ $changed == 0 ]] || die "second site.yml run reported changed=$changed; the roles are not idempotent"
  log "idempotence: changed=0"

  log "rke2_uninstall.yml without confirmation must refuse"
  if ansible-playbook "${playbook_args[@]}" playbooks/rke2_uninstall.yml >"$WORK_DIR/uninstall-refused.log" 2>&1; then
    die "rke2_uninstall.yml ran without -e confirm=yes"
  fi
  vm_ssh 'test -x /usr/local/bin/rke2 || test -x /usr/bin/rke2' || die "RKE2 disappeared although the uninstall was refused"

  log "rke2_uninstall.yml -e confirm=yes"
  ansible-playbook "${playbook_args[@]}" -e confirm=yes playbooks/rke2_uninstall.yml | tee "$WORK_DIR/uninstall.log"
  if vm_ssh 'test -e /usr/local/bin/rke2 || test -e /usr/bin/rke2 || test -d /var/lib/rancher/rke2'; then
    die "RKE2 binaries or data are still present after the uninstall"
  fi
  log "uninstall removed the binaries and /var/lib/rancher/rke2"
}

verify() {
  local want_version want_schedule kubectl node_name
  want_version=$(cluster_value '.rke2.version')
  want_schedule=$(cluster_value '.rke2.etcdSnapshots.schedule')
  kubectl='sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml'
  node_name=$(vm_ssh 'hostname' | tr '[:upper:]' '[:lower:]')

  log "verify: node $node_name is Ready"
  [[ $(vm_ssh "$kubectl get node $node_name -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'") == True ]] ||
    die "node $node_name is not Ready"

  log "verify: RKE2 version is the pinned $want_version"
  [[ $(vm_ssh "$kubectl get node $node_name -o jsonpath='{.status.nodeInfo.kubeletVersion}'") == "$want_version" ]] ||
    die "kubelet version differs from $want_version"
  vm_ssh 'rke2 --version 2>/dev/null || /usr/local/bin/rke2 --version' | grep -q -- "version $want_version" ||
    die "rke2 --version differs from $want_version"

  log "verify: etcd snapshot schedule '$want_schedule' is configured and a snapshot can be taken"
  [[ $(vm_ssh "sudo awk -F': ' '/^etcd-snapshot-schedule-cron:/ { gsub(/\"/, \"\", \$2); print \$2 }' /etc/rancher/rke2/config.yaml") == "$want_schedule" ]] ||
    die "etcd-snapshot-schedule-cron in config.yaml differs from '$want_schedule'"
  vm_ssh 'sudo /usr/local/bin/rke2 etcd-snapshot save --name it-check >/dev/null 2>&1 || sudo rke2 etcd-snapshot save --name it-check >/dev/null'
  vm_ssh 'sudo ls /var/lib/rancher/rke2/server/db/snapshots/' | grep -q '^it-check' ||
    die "on-demand etcd snapshot was not written"

  log "verify: configuration file is private and ingress controller is off"
  [[ $(vm_ssh 'sudo stat -c %a /etc/rancher/rke2/config.yaml') == 600 ]] || die "config.yaml is not mode 0600"
  vm_ssh 'sudo grep -q "^ingress-controller: \"none\"" /etc/rancher/rke2/config.yaml' || die "ingress-controller is not none"

  log "verify: host firewall table is loaded"
  vm_ssh 'sudo nft list table inet rke2_host' | grep -q 'dport 9345' || die "nftables table rke2_host is missing"

  log "verify: fetched kubeconfig is mode 0600 and points at https://$VM_IP:6443"
  [[ -f $WORK_DIR/kubeconfig-lab.yaml ]] || die "kubeconfig was not fetched"
  [[ $(stat -f %Lp "$WORK_DIR/kubeconfig-lab.yaml" 2>/dev/null || stat -c %a "$WORK_DIR/kubeconfig-lab.yaml") == 600 ]] ||
    die "fetched kubeconfig is not mode 0600"
  [[ $(yq -r '.clusters[0].cluster.server' "$WORK_DIR/kubeconfig-lab.yaml") == "https://$VM_IP:6443" ]] ||
    die "kubeconfig server is not https://$VM_IP:6443"
}

main "$@"
