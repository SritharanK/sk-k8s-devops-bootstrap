#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Velero restore drill against the current kube context.
#
# Creates a test namespace with a ConfigMap, a Secret, a Deployment that writes
# a random marker to a PersistentVolumeClaim and, when the Sealed Secrets CRD
# and kubeseal are available, a SealedSecret. Backs the namespace up with
# Velero (Kopia file-system backup), deletes it, restores it and verifies every
# object and the volume content. Prints the time from namespace deletion to
# verified restore as the measured namespace RTO.
#
# See hack/dr/README.md.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: hack/dr/restore-drill.sh [options]

Runs a Velero backup and restore drill against the current kube context.

Options:
  --install            Install or upgrade the seaweedfs and velero charts of
                       this repository (lab profile) with Helm first, and create
                       the S3 credential Secrets with generated keys when they do
                       not exist. Not for clusters where Argo CD manages them.
  --namespace NAME     Drill namespace (default: dr-drill). Must not exist.
  --keep               Keep the restored drill namespace at the end.
  --timeout SECONDS    Timeout for each wait step (default: 600).
  -h, --help           Show this help.

Environment:
  VELERO_NAMESPACE           Velero namespace (default: velero)
  SEAWEEDFS_NAMESPACE        SeaweedFS namespace for --install (default: seaweedfs)
  SEALED_SECRETS_NAMESPACE   Sealed Secrets controller namespace (default: kube-system)
  SEALED_SECRETS_CONTROLLER  Sealed Secrets controller name (default: sealed-secrets-controller)
  DRILL_IMAGE                Image of the drill workload (default: docker.io/library/busybox:1.37.0)
  DRILL_STORAGE_CLASS        StorageClass of the drill claim (default: the cluster default)
  LOG_LEVEL, NO_COLOR        See scripts/lib/common.sh.

The Backup object and its data are kept; Velero removes them after the TTL
(168h). Exit status is non-zero on any failure.
EOF
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
INSTALL=0
KEEP=0
DRILL_NS="dr-drill"
TIMEOUT=600
VELERO_NS="${VELERO_NAMESPACE:-velero}"
SWFS_NS="${SEAWEEDFS_NAMESPACE:-seaweedfs}"
SS_NS="${SEALED_SECRETS_NAMESPACE:-kube-system}"
SS_CONTROLLER="${SEALED_SECRETS_CONTROLLER:-sealed-secrets-controller}"
DRILL_IMAGE="${DRILL_IMAGE:-docker.io/library/busybox:1.37.0}"
DRILL_STORAGE_CLASS="${DRILL_STORAGE_CLASS:-}"

BACKUP_TTL="168h"
POLL_SECONDS=5

# Set during the run.
WORK_DIR=""
NS_CREATED=0
SEALED=0
MARKER=""
CM_VALUE=""
SECRET_VALUE=""
SEALED_VALUE=""

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --install)
        INSTALL=1
        ;;
      --keep)
        KEEP=1
        ;;
      --namespace)
        [[ $# -ge 2 && -n "$2" ]] || die "--namespace needs a value"
        DRILL_NS="$2"
        shift
        ;;
      --namespace=*)
        DRILL_NS="${1#*=}"
        ;;
      --timeout)
        [[ $# -ge 2 && -n "$2" ]] || die "--timeout needs a value"
        TIMEOUT="$2"
        shift
        ;;
      --timeout=*)
        TIMEOUT="${1#*=}"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
    shift
  done

  TIMEOUT="${TIMEOUT%s}"
  [[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -gt 0 ]] || die "--timeout must be a positive number of seconds"
  if [[ ! "$DRILL_NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ || ${#DRILL_NS} -gt 63 ]]; then
    die "--namespace must be a valid namespace name: $DRILL_NS"
  fi
  case "$DRILL_NS" in
    default | kube-* | "$VELERO_NS" | "$SWFS_NS" | dev | stage | prod | argocd)
      die "refusing to use namespace $DRILL_NS for the drill: it is deleted during the run"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
now() { date +%s; }

# rand_hex BYTES: prints 2*BYTES lowercase hex characters.
rand_hex() {
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# k8s_secret_value NAMESPACE NAME KEY: prints the decoded value of a Secret key.
k8s_secret_value() {
  kubectl -n "$1" get secret "$2" -o go-template="{{ index .data \"$3\" | base64decode }}"
}

# wait_for_object NAMESPACE KIND NAME: polls until the object exists.
wait_for_object() {
  local ns="$1" kind="$2" name="$3" deadline
  deadline=$(($(now) + TIMEOUT))
  until kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; do
    if (($(now) >= deadline)); then
      die "timeout after ${TIMEOUT}s waiting for $kind/$name in namespace $ns"
    fi
    sleep 2
  done
}

# wait_for_velero_phase KIND NAME: waits for a Backup or Restore to finish.
# Succeeds on Completed, fails on every other terminal phase or on timeout.
wait_for_velero_phase() {
  local kind="$1" name="$2" phase="" last="" deadline
  deadline=$(($(now) + TIMEOUT))
  while :; do
    phase="$(kubectl -n "$VELERO_NS" get "$kind" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" != "$last" ]]; then
      log_info "$kind/$name phase: ${phase:-<none>}"
      last="$phase"
    fi
    case "$phase" in
      Completed)
        return 0
        ;;
      Failed | PartiallyFailed | FailedValidation)
        log_error "$kind/$name ended in phase $phase"
        kubectl -n "$VELERO_NS" get "$kind" "$name" \
          -o jsonpath='{"failureReason: "}{.status.failureReason}{"\nvalidationErrors: "}{.status.validationErrors}{"\nerrors: "}{.status.errors}{"\nwarnings: "}{.status.warnings}{"\n"}' >&2 || true
        die "$kind/$name did not complete; inspect the Velero server logs in namespace $VELERO_NS"
        ;;
    esac
    if (($(now) >= deadline)); then
      die "timeout after ${TIMEOUT}s waiting for $kind/$name (last phase: ${phase:-<none>})"
    fi
    sleep "$POLL_SECONDS"
  done
}

# expect_pod_volume_phase KIND LABEL VALUE: every PodVolumeBackup or
# PodVolumeRestore with the label must be Completed, and there must be at least one.
expect_pod_volume_phase() {
  local kind="$1" label="$2" value="$3" phases p
  phases="$(kubectl -n "$VELERO_NS" get "$kind" -l "${label}=${value}" -o jsonpath='{.items[*].status.phase}')"
  [[ -n "$phases" ]] || die "no $kind found for ${label}=${value}: the volume was not handled by file-system backup"
  for p in $phases; do
    [[ "$p" == "Completed" ]] || die "$kind for ${label}=${value} has phase $p"
  done
  log_info "$kind for ${label}=${value}: ${phases}"
}

# ---------------------------------------------------------------------------
# --install: lab stack from this repository
# ---------------------------------------------------------------------------
ensure_namespace() {
  local ns="$1" level="$2"
  kubectl create namespace "$ns" --dry-run=client -o yaml | run_cmd kubectl apply -f - >/dev/null
  run_cmd kubectl label namespace "$ns" --overwrite \
    "pod-security.kubernetes.io/enforce=${level}" \
    "pod-security.kubernetes.io/audit=restricted" >/dev/null
}

# create_secret_from_file NAMESPACE NAME KEY FILE
create_secret_from_file() {
  run_cmd kubectl -n "$1" create secret generic "$2" --from-file="$3=$4" >/dev/null
  log_info "created Secret $1/$2 (key $3)"
}

write_velero_credentials() {
  local file="$1" access="$2" secret="$3"
  (
    umask 077
    printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$access" "$secret" >"$file"
  )
}

write_seaweedfs_config() {
  local file="$1" access="$2" secret="$3"
  (
    umask 077
    cat >"$file" <<EOF
{
  "identities": [
    {
      "name": "velero",
      "credentials": [
        {
          "accessKey": "${access}",
          "secretKey": "${secret}"
        }
      ],
      "actions": ["Read:velero", "Write:velero", "List:velero", "Tagging:velero"]
    }
  ]
}
EOF
  )
}

# Creates seaweedfs-s3-config and velero-s3-credentials with one generated key
# pair when they are missing. Existing Secrets are never changed.
# Prints 1 when seaweedfs-s3-config was created, 0 otherwise.
ensure_s3_secrets() {
  local have_cfg=0 have_velero=0 access="" secret="" cloud=""
  kubectl -n "$SWFS_NS" get secret seaweedfs-s3-config >/dev/null 2>&1 && have_cfg=1
  kubectl -n "$VELERO_NS" get secret velero-s3-credentials >/dev/null 2>&1 && have_velero=1

  if ((have_cfg == 1 && have_velero == 1)); then
    log_info "Secrets $SWFS_NS/seaweedfs-s3-config and $VELERO_NS/velero-s3-credentials exist; keeping them"
    echo 0
    return 0
  fi
  if ((have_cfg == 1)); then
    die "$SWFS_NS/seaweedfs-s3-config exists but $VELERO_NS/velero-s3-credentials does not; create it with the keys of the velero identity (see helmcharts/system-charts/velero/README.md)"
  fi

  if ((have_velero == 1)); then
    log_info "reusing the key pair of $VELERO_NS/velero-s3-credentials for the SeaweedFS identity"
    cloud="$(k8s_secret_value "$VELERO_NS" velero-s3-credentials cloud)"
    access="$(printf '%s\n' "$cloud" | awk -F= '/^[[:space:]]*aws_access_key_id[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
    secret="$(printf '%s\n' "$cloud" | awk -F= '/^[[:space:]]*aws_secret_access_key[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
    [[ -n "$access" && -n "$secret" ]] || die "cannot read aws_access_key_id and aws_secret_access_key from $VELERO_NS/velero-s3-credentials key cloud"
  else
    access="$(rand_hex 10 | tr 'a-f' 'A-F')"
    secret="$(rand_hex 20)"
    write_velero_credentials "$WORK_DIR/cloud" "$access" "$secret"
    create_secret_from_file "$VELERO_NS" velero-s3-credentials cloud "$WORK_DIR/cloud"
  fi

  write_seaweedfs_config "$WORK_DIR/seaweedfs_s3_config" "$access" "$secret"
  create_secret_from_file "$SWFS_NS" seaweedfs-s3-config seaweedfs_s3_config "$WORK_DIR/seaweedfs_s3_config"
  echo 1
}

install_stack() {
  require_cmd helm
  local charts="$REPO_ROOT/helmcharts/system-charts"
  local swfs_args=() created_cfg had_swfs=0

  log_info "installing the lab backup stack from $charts"
  ensure_namespace "$SWFS_NS" baseline
  ensure_namespace "$VELERO_NS" privileged

  kubectl -n "$SWFS_NS" get deployment seaweedfs-all-in-one >/dev/null 2>&1 && had_swfs=1
  created_cfg="$(ensure_s3_secrets)"

  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    log_warn "ServiceMonitor CRD not found: installing SeaweedFS without its ServiceMonitor"
    swfs_args+=(--set global.seaweedfs.monitoring.enabled=false)
  fi

  run_cmd helm dependency build "$charts/seaweedfs" >/dev/null
  run_cmd helm upgrade --install seaweedfs "$charts/seaweedfs" \
    --namespace "$SWFS_NS" \
    -f "$charts/seaweedfs/values.yaml" -f "$charts/seaweedfs/values-lab.yaml" \
    ${swfs_args[@]+"${swfs_args[@]}"} \
    --wait --timeout "${TIMEOUT}s"
  if [[ "$created_cfg" == "1" && "$had_swfs" == "1" ]]; then
    # SeaweedFS reads the identities file only at start.
    run_cmd kubectl -n "$SWFS_NS" rollout restart deployment/seaweedfs-all-in-one
    run_cmd kubectl -n "$SWFS_NS" rollout status deployment/seaweedfs-all-in-one --timeout="${TIMEOUT}s"
  fi

  # The Velero chart only renders its ServiceMonitor and PodMonitor when the
  # monitoring API exists (upstream autodetect).
  run_cmd helm dependency build "$charts/velero" >/dev/null
  run_cmd helm upgrade --install velero "$charts/velero" \
    --namespace "$VELERO_NS" \
    -f "$charts/velero/values.yaml" -f "$charts/velero/values-lab.yaml" \
    --wait --timeout "${TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Drill steps
# ---------------------------------------------------------------------------
preflight() {
  local crd default_sc
  log_info "kube context: $(kubectl config current-context)"
  kubectl get --raw /readyz >/dev/null || die "the API server of the current context is not reachable or not ready"

  for crd in backups.velero.io restores.velero.io backupstoragelocations.velero.io podvolumebackups.velero.io podvolumerestores.velero.io; do
    kubectl get crd "$crd" >/dev/null 2>&1 || die "Velero CRD $crd not found; install Velero first (or use --install)"
  done

  log_info "waiting for BackupStorageLocation $VELERO_NS/default to be Available"
  kubectl -n "$VELERO_NS" wait backupstoragelocation/default \
    --for=jsonpath='{.status.phase}'=Available --timeout="${TIMEOUT}s" >/dev/null ||
    die "BackupStorageLocation default in namespace $VELERO_NS is not Available"

  kubectl -n "$VELERO_NS" rollout status daemonset/node-agent --timeout="${TIMEOUT}s" >/dev/null ||
    die "the Velero node agent (daemonset/node-agent) is not ready; file-system backup needs it"

  if kubectl get namespace "$DRILL_NS" >/dev/null 2>&1; then
    die "namespace $DRILL_NS already exists; delete it or choose another with --namespace"
  fi

  if [[ -z "$DRILL_STORAGE_CLASS" ]]; then
    default_sc="$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
    [[ -n "$default_sc" ]] || die "no default StorageClass; set DRILL_STORAGE_CLASS"
    log_info "drill claim uses the default StorageClass $default_sc"
  fi

  if kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1 && command -v kubeseal >/dev/null 2>&1; then
    SEALED=1
  else
    log_warn "Sealed Secrets CRD or kubeseal not found: skipping the SealedSecret part of the drill"
  fi
}

cleanup_drill_namespace() {
  if ((NS_CREATED == 0)); then
    return 0
  fi
  if ((KEEP == 1)); then
    log_info "keeping namespace $DRILL_NS (--keep)"
    return 0
  fi
  log_info "deleting drill namespace $DRILL_NS"
  kubectl delete namespace "$DRILL_NS" --ignore-not-found --wait=false >/dev/null 2>&1 ||
    log_warn "could not delete namespace $DRILL_NS; delete it by hand"
}

create_workload() {
  local sc_line=""
  [[ -n "$DRILL_STORAGE_CLASS" ]] && sc_line="storageClassName: ${DRILL_STORAGE_CLASS}"

  log_info "creating drill namespace $DRILL_NS"
  run_cmd kubectl create namespace "$DRILL_NS" >/dev/null
  NS_CREATED=1
  run_cmd kubectl label namespace "$DRILL_NS" --overwrite \
    pod-security.kubernetes.io/enforce=restricted \
    app.kubernetes.io/part-of=dr-drill >/dev/null

  CM_VALUE="$(rand_hex 16)"
  SECRET_VALUE="$(rand_hex 16)"
  run_cmd kubectl -n "$DRILL_NS" create configmap drill-config --from-literal=value="$CM_VALUE" >/dev/null
  (umask 077 && printf '%s' "$SECRET_VALUE" >"$WORK_DIR/secret-value")
  run_cmd kubectl -n "$DRILL_NS" create secret generic drill-secret --from-file=value="$WORK_DIR/secret-value" >/dev/null

  # The container writes a random marker once. If the volume came back empty
  # after the restore, it would write a different value and the check fails.
  run_cmd kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: drill-data
  namespace: ${DRILL_NS}
spec:
  accessModes:
    - ReadWriteOnce
  ${sc_line}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drill
  namespace: ${DRILL_NS}
  labels:
    app.kubernetes.io/name: dr-drill
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: dr-drill
  template:
    metadata:
      labels:
        app.kubernetes.io/name: dr-drill
    spec:
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: ${DRILL_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              if [ ! -s /data/marker ]; then
                head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /data/marker.tmp
                mv /data/marker.tmp /data/marker
              fi
              trap 'exit 0' TERM
              while true; do sleep 5 & wait \$!; done
          readinessProbe:
            exec:
              command: ["test", "-s", "/data/marker"]
            periodSeconds: 2
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: drill-data
EOF
}

create_sealed_secret() {
  ((SEALED == 1)) || return 0
  SEALED_VALUE="$(rand_hex 16)"
  (umask 077 && printf '%s' "$SEALED_VALUE" >"$WORK_DIR/sealed-value")

  # The label is copied to the Secret the controller generates, which keeps that
  # Secret out of the backup. After the restore it can only come back if the
  # controller decrypts the restored SealedSecret with its key.
  kubectl -n "$DRILL_NS" create secret generic drill-sealed \
    --from-file=value="$WORK_DIR/sealed-value" --dry-run=client -o yaml |
    kubectl label --local -f - velero.io/exclude-from-backup=true -o yaml >"$WORK_DIR/plain-secret.yaml"
  kubeseal --controller-namespace "$SS_NS" --controller-name "$SS_CONTROLLER" --format yaml \
    <"$WORK_DIR/plain-secret.yaml" >"$WORK_DIR/sealed-secret.yaml" ||
    die "kubeseal failed; check SEALED_SECRETS_NAMESPACE and SEALED_SECRETS_CONTROLLER"
  run_cmd kubectl apply -f "$WORK_DIR/sealed-secret.yaml" >/dev/null
  # The SealedSecret itself must be part of the backup.
  kubectl -n "$DRILL_NS" label sealedsecret drill-sealed velero.io/exclude-from-backup- >/dev/null 2>&1 || true

  wait_for_object "$DRILL_NS" secret drill-sealed
  [[ "$(k8s_secret_value "$DRILL_NS" drill-sealed value)" == "$SEALED_VALUE" ]] ||
    die "the Secret unsealed by the controller does not match the sealed value"
  if [[ "$(kubectl -n "$DRILL_NS" get secret drill-sealed -o jsonpath='{.metadata.labels.velero\.io/exclude-from-backup}')" != "true" ]]; then
    log_warn "the unsealed Secret lacks velero.io/exclude-from-backup; it will be restored from the backup, so the SealedSecret check no longer proves that the controller can decrypt"
  fi
  log_info "SealedSecret drill-sealed unsealed by $SS_NS/$SS_CONTROLLER"
}

wait_for_workload() {
  log_info "waiting for the drill workload to be ready"
  kubectl -n "$DRILL_NS" wait deployment/drill --for=condition=Available --timeout="${TIMEOUT}s" >/dev/null ||
    die "deployment/drill in $DRILL_NS did not become Available"
  MARKER="$(kubectl -n "$DRILL_NS" exec deployment/drill -c app -- cat /data/marker)"
  [[ -n "$MARKER" ]] || die "the drill workload wrote no marker"
  log_info "volume marker written: $MARKER"
}

create_backup() {
  local name="$1"
  log_info "creating Backup $VELERO_NS/$name"
  run_cmd kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: ${VELERO_NS}
  labels:
    app.kubernetes.io/part-of: dr-drill
spec:
  includedNamespaces:
    - ${DRILL_NS}
  defaultVolumesToFsBackup: true
  snapshotVolumes: false
  storageLocation: default
  ttl: ${BACKUP_TTL}
EOF
  wait_for_velero_phase backup "$name"
  expect_pod_volume_phase podvolumebackups velero.io/backup-name "$name"
}

delete_namespace() {
  log_info "deleting namespace $DRILL_NS"
  run_cmd kubectl delete namespace "$DRILL_NS" --wait=false >/dev/null
  kubectl wait namespace/"$DRILL_NS" --for=delete --timeout="${TIMEOUT}s" >/dev/null 2>&1 ||
    die "namespace $DRILL_NS was not deleted within ${TIMEOUT}s"
  log_info "namespace $DRILL_NS is gone"
}

create_restore() {
  local name="$1" backup="$2"
  log_info "creating Restore $VELERO_NS/$name from $backup"
  run_cmd kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${name}
  namespace: ${VELERO_NS}
  labels:
    app.kubernetes.io/part-of: dr-drill
spec:
  backupName: ${backup}
  includedNamespaces:
    - ${DRILL_NS}
  restorePVs: true
  existingResourcePolicy: none
EOF
  wait_for_velero_phase restore "$name"
  expect_pod_volume_phase podvolumerestores velero.io/restore-name "$name"
}

verify_restore() {
  local got
  kubectl -n "$DRILL_NS" wait deployment/drill --for=condition=Available --timeout="${TIMEOUT}s" >/dev/null ||
    die "restored deployment/drill did not become Available"

  got="$(kubectl -n "$DRILL_NS" get configmap drill-config -o jsonpath='{.data.value}')"
  [[ "$got" == "$CM_VALUE" ]] || die "ConfigMap drill-config: value differs after restore"
  log_info "ConfigMap drill-config: OK"

  got="$(k8s_secret_value "$DRILL_NS" drill-secret value)"
  [[ "$got" == "$SECRET_VALUE" ]] || die "Secret drill-secret: value differs after restore"
  log_info "Secret drill-secret: OK"

  got="$(kubectl -n "$DRILL_NS" exec deployment/drill -c app -- cat /data/marker)"
  [[ "$got" == "$MARKER" ]] || die "volume marker differs after restore (expected $MARKER, got ${got:-<empty>})"
  log_info "volume marker: OK"

  if ((SEALED == 1)); then
    wait_for_object "$DRILL_NS" secret drill-sealed
    got="$(k8s_secret_value "$DRILL_NS" drill-sealed value)"
    [[ "$got" == "$SEALED_VALUE" ]] || die "Secret drill-sealed (unsealed after restore) differs from the sealed value"
    log_info "SealedSecret drill-sealed unsealed after restore: OK"
  fi
}

main() {
  parse_args "$@"
  [[ "${DRY_RUN:-0}" != "1" ]] || die "DRY_RUN is not supported: the drill reads back what it creates"
  require_cmd kubectl od tr awk date

  make_temp_dir WORK_DIR dr-drill
  add_cleanup cleanup_drill_namespace

  if ((INSTALL == 1)); then
    install_stack
  fi

  preflight
  create_workload
  create_sealed_secret
  wait_for_workload

  local stamp backup restore t_delete t_gone t_restore t_restored t_verified
  stamp="$(date -u +%Y%m%d%H%M%S)"
  backup="${DRILL_NS}-${stamp}"
  restore="${backup}-restore"

  create_backup "$backup"

  t_delete="$(now)"
  delete_namespace
  t_gone="$(now)"

  t_restore="$(now)"
  create_restore "$restore" "$backup"
  t_restored="$(now)"

  verify_restore
  t_verified="$(now)"

  log_info "drill passed: backup $VELERO_NS/$backup, restore $VELERO_NS/$restore"
  printf 'Restore drill passed on context %s\n' "$(kubectl config current-context)"
  printf '  Backup:                          %s/%s (ttl %s)\n' "$VELERO_NS" "$backup" "$BACKUP_TTL"
  printf '  Namespace deletion:              %ss\n' "$((t_gone - t_delete))"
  printf '  Restore (created to Completed):  %ss\n' "$((t_restored - t_restore))"
  printf '  Verification:                    %ss\n' "$((t_verified - t_restored))"
  printf '  RTO (deletion to verified):      %ss\n' "$((t_verified - t_delete))"
}

main "$@"
