# openbao

Wrapper chart for OpenBao, the secrets backend of the reference profile. It runs OpenBao in HA mode with integrated Raft storage and TLS end to end. It also renders the External Secrets `ClusterSecretStore` named `openbao`, so workloads consume OpenBao secrets through `ExternalSecret` resources.

## Upstream and versions

| Item | Value |
|---|---|
| Upstream chart | `openbao` 0.30.7 |
| Application | v2.7.2 (`quay.io/openbao/openbao:2.7.2`) |
| Wrapper chart | 0.1.0 |
| Source | <https://github.com/openbao/openbao>, <https://github.com/openbao/openbao-helm> |
| Helm repository | `oci://ghcr.io/openbao/charts` |

0.30.7 (OpenBao v2.7.2) was the current stable release on 2026-11-16.

## Configuration

Owner values live in `values.yaml` under the `openbao` key. Wrapper values (`tls`, `clusterSecretStore`) drive the templates of this chart. `templates/guards.yaml` fails rendering if dev mode is enabled, if `global.tlsDisable` is true, if HA or Raft is disabled, or if the certificate Secret is not mounted as volume `tls`.

- Names are fixed with `fullnameOverride: openbao`: Services `openbao`, `openbao-active`, `openbao-standby`, `openbao-internal` (headless), `openbao-ui`, pods `openbao-<n>`. Wrapper templates derive names from the upstream `openbao.fullname` helper, so they stay aligned with the subchart.
- Dev mode is off in every profile (`server.dev.enabled: false`).
- No agent injector and no CSI provider. External Secrets is the only consumer.
- UI enabled (`ui = true`) behind the ClusterIP Service `openbao-ui`, routed to the active pod only. No Ingress, HTTPRoute or Route. Use `kubectl port-forward` to reach it.
- `server.authDelegator.enabled: true` binds the OpenBao ServiceAccount to `system:auth-delegator`, so the Kubernetes auth method can call the TokenReview API with the pod's own token.
- `podManagementPolicy: Parallel` starts all pods together so each can be unsealed independently. The field is immutable on an existing StatefulSet.
- `updateStrategyType: OnDelete` (upstream default) and `configAnnotation: true`: pods change only when deleted; the config checksum annotation shows which pods still run an old configuration.
- PersistentVolumeClaims are retained when the StatefulSet is deleted or scaled down.
- CPU and memory requests and limits are explicit.
- Security context meets Pod Security Standards `restricted`: UID 100, GID 1000, `fsGroup` 1000, non-root, `RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped, read-only root filesystem with an `emptyDir` on `/tmp` (the entrypoint copies the config there). The upstream default container context lacks `capabilities.drop` and is replaced.
- Metrics stay at upstream defaults. No ServiceMonitor.

### TLS

`templates/certificate.yaml` requests a cert-manager `Certificate` (ECDSA P-256, one year, renewed 30 days before expiry) from `tls.issuerRef`, by default ClusterIssuer `selfsigned` (the platform CA). The Secret `openbao-server-tls` holds `tls.crt`, `tls.key` and `ca.crt` and is mounted at `/openbao/tls`.

DNS SANs cover `openbao`, `openbao-active`, `openbao-standby`, `openbao-ui`, `openbao-internal` and `*.openbao-internal`, each as short name, `.<namespace>`, `.<namespace>.svc` and `.<namespace>.svc.cluster.local`. IP SAN `127.0.0.1` covers the CLI inside the pod.

The listener uses `tls_cert_file`, `tls_key_file` and `tls_client_ca_file` from that mount and `tls_auto_reload = true` (available since OpenBao 2.7.0), so renewed certificates are loaded without restart. `BAO_ADDR` is `https://127.0.0.1:8200` and `BAO_CACERT` is `/openbao/tls/ca.crt` in the container, so the CLI verifies the server. `BAO_API_ADDR` is the per-pod name `https://openbao-<n>.openbao-internal:8200`, covered by the wildcard SAN.

### Raft

`server.ha.raft.config` is rendered with `tpl`. It contains `storage "raft"` on `/openbao/data`, one `retry_join` block per replica (`https://openbao-<n>.openbao-internal:8200` with `leader_ca_cert_file` and `leader_tls_servername`), `service_registration "kubernetes"` and `disable_mlock = true`. mlock was removed in OpenBao 2.0 and the option is obsolete; it is kept to state the intent. The Raft node ID is the pod name (`setNodeId: true`).

When `server.auditStorage.enabled` is true, the config also declares a file audit device writing `/openbao/audit/audit.log`. OpenBao refuses audit devices created through the API by default (`unsafe_allow_api_audit_creation = false`), so the device is part of the config.

The upstream entrypoint substitutes the literal strings `HOST_IP`, `POD_IP`, `HOSTNAME`, `API_ADDR`, `TRANSIT_ADDR` and `RAFT_ADDR` in the config. Do not use them in the config text, comments included.

### ClusterSecretStore

`templates/clustersecretstore.yaml` renders `ClusterSecretStore/openbao` (`external-secrets.io/v1`, dedicated `openBao` provider of External Secrets 2.15.0) when `clusterSecretStore.enabled` is true:

- server `https://openbao-active.<namespace>.svc:8200`, CA from Secret `openbao-server-tls` key `ca.crt`
- KV v2 at path `secret`
- Kubernetes auth at mount `kubernetes`, role `external-secrets`, ServiceAccount `external-secrets/external-secrets`

Without `clusterSecretStore.conditions` every namespace may reference the store, and the role's policy decides what it can read. Restrict it with `conditions` (namespace selectors) when tenants must not read each other's paths.

## Profiles

| Profile | Delta |
|---|---|
| `lab` | Not deployed. `values-lab.yaml` renders one Raft node (not dev mode), 1Gi data volume, no audit volume, no PodDisruptionBudget, no ClusterSecretStore, for trying the chart on kind. |
| `reference` | Three Raft voters with the upstream hard pod anti-affinity on `kubernetes.io/hostname` (three schedulable nodes needed), PodDisruptionBudget `maxUnavailable: 1`, 10Gi data and 10Gi audit volumes on the default StorageClass, file audit device, ClusterSecretStore enabled. Contains a disabled auto-unseal placeholder. |

Volumes use the default StorageClass. Set `openbao.server.dataStorage.storageClass` and `openbao.server.auditStorage.storageClass` to pin one.

## Deployment

Argo CD Application `openbao`, namespace `openbao`, sync wave 4. OpenBao needs manual initialisation, so it sits after the core platform waves and does not gate them.

Order inside the Application:

| Wave | Resources |
|---|---|
| -1 | `Certificate/openbao-server-tls` (Secret must exist before the pods mount it) |
| 0 | StatefulSet, Services, ConfigMap, RBAC, PodDisruptionBudget |
| 1 | `ClusterSecretStore/openbao` (reference) |

Argo CD reports the StatefulSet healthy only when every replica is ready, and a pod is ready only when it is initialised and unsealed. Until then the Application stays Progressing, the ClusterSecretStore is not applied, and in the reference profile the root Application waits at wave 4. The ClusterSecretStore becomes Ready after the configuration steps below.

Both custom resources carry `SkipDryRunOnMissingResource=true`; their CRDs come from the cert-manager and external-secrets Applications.

Cluster-scoped kinds in the render: `ClusterRoleBinding` (lab); `ClusterRoleBinding` and `ClusterSecretStore` (reference).

The upstream chart also renders a Helm test Pod (`openbao-server-test`, hook `test`). Argo CD skips manifests with Helm test hooks, so it is never applied.

## Operations

Commands run from a workstation with `kubectl` access. Configuration steps use the `bao` CLI locally through a port-forward; initialisation and unsealing run inside each pod.

### Initialise (once)

Wait until all three pods run (they stay not ready while sealed), then initialise from one pod:

```sh
kubectl -n openbao get pods
kubectl -n openbao exec -ti openbao-0 -- bao operator init -key-shares=5 -key-threshold=3
```

The output holds five unseal key shares and the initial root token. Store them offline, each share with a different custodian. Never put them in Git, in a Kubernetes Secret, in a ticket or in chat.

### Unseal

Run the unseal command three times per pod, each time with a different key share. The prompt hides the input. Start with `openbao-0`; the other pods join the Raft cluster through `retry_join` and are unsealed with the same shares.

```sh
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal
kubectl -n openbao exec -ti openbao-1 -- bao operator unseal
kubectl -n openbao exec -ti openbao-2 -- bao operator unseal
kubectl -n openbao exec openbao-0 -- bao status
```

With Shamir unseal every pod restart seals that pod again. Unseal it the same way; the other pods keep serving.

### Workstation session

```sh
kubectl -n openbao get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > openbao-ca.crt
kubectl -n openbao port-forward svc/openbao-active 8200:8200
```

In a second shell:

```sh
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=$PWD/openbao-ca.crt
bao login
```

`bao login` prompts for the token (the root token during initial setup).

### Verify Raft peers

```sh
bao operator raft list-peers
```

Expect `openbao-0`, `openbao-1` and `openbao-2`, one leader and two followers, all voters.

### Configure for External Secrets

Enable KV v2 at `secret/` and the Kubernetes auth method. Without `token_reviewer_jwt` and `kubernetes_ca_cert`, OpenBao uses the token and CA of its own pod ServiceAccount.

```sh
bao secrets enable -path=secret kv-v2
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443
```

Read-only policy and the role bound to the External Secrets ServiceAccount:

```sh
bao policy write external-secrets-read - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
# External Secrets validates the store by reading the mount definition.
path "sys/mounts/secret" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-read \
  ttl=1h
```

Check the store and the audit device (reference profile):

```sh
kubectl get clustersecretstore openbao
bao audit list
```

### Revoke the root token

Set up named operator access first (for example an OIDC or userpass auth method with an admin policy), then revoke the root token:

```sh
bao token revoke -self
```

A new root token for break-glass work needs a quorum of unseal key holders: `bao operator generate-root`.

### Raft snapshots

Back up regularly and before every upgrade. The token's policy must cover `sys/storage/raft/snapshot` (save and restore) and `sys/storage/raft/snapshot-force` (forced restore).

```sh
bao operator raft snapshot save openbao-$(date +%Y%m%d-%H%M).snap
```

The snapshot contains the full encrypted dataset. Store it outside the cluster with the same care as the unseal keys; it is only usable together with the key shares of the cluster it came from.

Restore does not follow redirects and must reach the active node; the port-forward to `svc/openbao-active` does. Restore into the same cluster:

```sh
bao operator raft snapshot restore openbao-YYYYMMDD-HHMM.snap
```

Restore into a freshly initialised cluster (disaster recovery): log in with the new cluster's root token, restore with `-force`, then unseal every pod with the key shares of the original cluster.

```sh
bao operator raft snapshot restore -force openbao-YYYYMMDD-HHMM.snap
```

### Audit log

In the reference profile the file audit device writes `/openbao/audit/audit.log` on the audit volume. The file is not rotated; OpenBao reopens it on SIGHUP. OpenBao does not answer requests when no enabled audit device can write, so watch the volume usage.

### Auto-unseal

The reference profile uses Shamir unseal. `values-reference.yaml` holds a disabled `transit` seal placeholder (`openbao.server.ha.raft.sealConfig`) with `address = "https://CHANGE_ME:8200"`, `key_name`, `mount_path`, and the token supplied as `BAO_TOKEN` from a Secret through `extraSecretEnvironmentVars`.

Options:

- `transit`: a key on a separate OpenBao or Vault cluster. Built into OpenBao.
- `pkcs11`: an HSM. External plugin since OpenBao 2.7.
- Cloud KMS (`awskms`, `azurekeyvault`, `gcpckms`, `ocikms`, `alicloudkms`): external plugins since OpenBao 2.7.

Notes for the transit seal: set `tls_ca_cert` in the stanza, because the seal otherwise falls back to `BAO_CACERT`, which points at the platform CA. The `bao` CLI inside the pod also picks up `BAO_TOKEN`.

To migrate an initialised cluster from Shamir: add the seal stanza, replace the pods one at a time (standbys first), and on each pod run `bao operator unseal -migrate` with the Shamir key shares.

## Upgrades

1. Read the upstream chart changes and the OpenBao release notes for every version in between, in particular removed features, storage and seal changes.
2. Take a Raft snapshot.
3. Bump `dependencies[0].version` and `appVersion` in `Chart.yaml`, run `helm dependency update helmcharts/system-charts/openbao` and commit the new `Chart.lock`.
4. Diff the `helm template` output for both profiles against the previous version before merging.
5. After Argo CD has synced the new StatefulSet spec, nothing restarts (`OnDelete`). Replace the pods one at a time, standbys first. For each standby pod, delete it, wait until it is running, unseal it, and check `bao operator raft list-peers` and `bao status` before the next one:

   ```sh
   kubectl -n openbao get pods -l component=server -L openbao-active
   kubectl -n openbao delete pod openbao-2
   kubectl -n openbao exec -ti openbao-2 -- bao operator unseal
   ```

6. Last, move leadership to an upgraded standby with `bao operator step-down`, then replace the former active pod the same way.
