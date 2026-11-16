# Troubleshooting

This page lists common failures with their likely cause, the command that confirms it, and the fix. It is for operators and developers working on a `lab` or `reference` cluster. Fixes go through Git; a change made directly in the cluster is reverted by Argo CD self-heal.

The `argocd` commands assume a login through the Gateway: `argocd login argocd.<domain> --grpc-web` (add `--sso` in the `reference` profile).

## Application stuck OutOfSync or Progressing

### Likely cause

- A sync wave waits. Argo CD is configured with a health check for the `Application` kind, so the root Application starts a later wave only when every Application in the earlier waves is Healthy. One unhealthy Application in wave 0 or 1 holds back everything after it.
- A resource in the Application is not healthy: a Deployment without available replicas (image pull error, failing probe, policy denial, quota), or a CR whose controller reports an error.
- A permanent diff: a controller or webhook changes a field after the sync, so the Application turns OutOfSync again.
- The AppProject does not permit a kind or namespace. The condition says that the resource is not permitted in the project.
- In prod (`reference` profile), the sync window is closed.

### Check

```bash
kubectl -n argocd get applications
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status'
argocd app get <application> --grpc-web --show-operation
argocd app diff <application> --grpc-web
kubectl -n argocd get application <application> -o jsonpath='{.status.conditions}'
```

`argocd app get <application> --grpc-web --hard-refresh` regenerates the manifests from Git. Use it to rule out a stale cache; it changes nothing in Git or in the cluster.

### Fix

- Work in wave order: fix the lowest-wave Application that is not Healthy first, then let the later waves continue.
- For an unhealthy resource, read its events (`kubectl -n <namespace> describe <kind> <name>`) and continue with the matching section on this page.
- For a permanent diff, add an `ignoreDifferences` entry for that field to the Application template in `argocd-bootstrap/` through a pull request.
- For a project denial, check the kind against the AppProject: app projects allow one namespace and no cluster-scoped kinds; the `platform` project allows an enumerated list of cluster-scoped kinds. See [GitOps](../architecture/gitops.md).
- For a closed sync window, wait for the window (`argocd proj windows list apps-prod --grpc-web`).

## Sync fails because a CRD is missing

### Likely cause

A custom resource is applied before the Application that installs its CRD. The dry run fails with a message that the Kubernetes API could not find the kind and that the CRD must be installed first. Typical cases: a CR in the same wave as its CRD provider, a disabled toolchain that owns the CRD (for example a `ServiceMonitor` while the `monitoring` toolchain is off), or a CR without `SkipDryRunOnMissingResource`.

### Check

```bash
kubectl get crd | grep <group>
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,HEALTH:.status.health.status'
```

### Fix

- The CRD provider must sit in an earlier wave than its consumers: wave 0 for the Gateway API CRDs, cert-manager and the secrets controller, 1 for Kyverno, 2 for Envoy Gateway, 3 for the policies and the platform Gateway, 4 for the optional components, 10 for apps.
- A CR that depends on another Application's CRD carries `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. Argo CD then skips the dry run and the sync retries until the CRD exists.
- If the CRD's toolchain is off on this cluster, enable it in the cluster file or stop rendering the CR (for example `metrics.serviceMonitor.enabled: false`).
- Never delete a CRD to fix ordering: deleting a CRD deletes every object of that kind. CRDs carry `Prune=false,Delete=false` for that reason, except those of `velero`, `trivy-operator`, `longhorn` and `cloudnative-pg` (see [GitOps](../architecture/gitops.md#namespaces-and-crds-survive-a-disabled-toolchain)).

## Kyverno denies a pod

### Likely cause

The pod violates the workload contract: a missing `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault` or `readOnlyRootFilesystem: true`; missing requests, limits or probes; a `latest` tag; an image from a registry outside the allowlist; or, in `stage` and `prod` of the `reference` profile, an image without a valid signature from `build-image.yml`. `dev` runs the policies in Audit mode, so the same violation only shows up in the policy report there and blocks first in `stage`.

### Check

The denial message names the policy and the failing check. It appears in the Argo CD sync result, or as a `FailedCreate` event on the ReplicaSet when the Deployment itself was admitted:

```bash
argocd app get <app>-<env> --grpc-web
kubectl -n <namespace> get events --field-selector reason=FailedCreate
kubectl get policyreports -A
kubectl -n <namespace> get policyreports -o yaml \
  | yq '.items[].results[] | select(.result == "fail") | {"policy": .policy, "rule": .rule, "message": .message}'
kubectl get validatingpolicies.policies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io
```

For a signature failure, verify the image as the policy does (see [promotion](promotion.md#trace-a-running-image-to-its-source)).

### Fix

- Compare the rendered pod spec (`make render`, then the file under `_out/`) with the contract in [helm-common values](../reference/helm-common-values.md). Most violations come from overriding a helm-common security default with `null`, or from a hand-written image reference.
- For a signature failure, promote a digest that `build-image.yml` built and signed on `main`.
- If a workload cannot comply for a good reason, request a `PolicyException`. Exceptions live in the `kyverno` namespace and come from the `kyverno-policies` chart, next to the existing exception for ACME HTTP-01 solver pods (label `acme.cert-manager.io/http01-solver: "true"`). Open a pull request that scopes the exception to one namespace, the named resources and the specific policy, and states the reason and an owner. A platform owner reviews it. Run `make policy-test` before you open it.

## NetworkPolicy blocks traffic

### Likely cause

App namespaces deny all ingress and egress by default and allow only DNS (platform policies `default-deny` and `allow-dns`). Every other path is opened by the app's own NetworkPolicy from helm-common: ingress from `envoy-gateway-system` when the route is enabled, ingress from `monitoring` when the ServiceMonitor is enabled, and the explicit rules in `networkPolicy.extraIngress[]` and `networkPolicy.egress[]`. Traffic that no rule covers times out, including pod-to-pod traffic inside one namespace.

### Check

```bash
kubectl -n <namespace> get networkpolicy
kubectl -n <namespace> describe networkpolicy <name>
kubectl -n <namespace> logs deploy/<app>
```

A blocked connection times out instead of being refused. Through the Gateway, a route to a blocked backend returns an upstream connect error from Envoy.

### Fix

Add the missing rule to the app values with `networkPolicy.extraIngress[]` or `networkPolicy.egress[]` in a pull request (see [add an app](add-an-app.md#5-allow-the-traffic-the-service-needs)). An app behind a route needs `route.enabled: true` so the Gateway rule is rendered. An Audit-mode Kyverno policy reports app NetworkPolicies that are broader than needed; keep rules to the namespaces and ports the service uses. On the kind lab, the CNI (Calico) enforces NetworkPolicy, so the lab shows the same failures as a real cluster.

## HTTPRoute not accepted

### Likely cause

The route does not attach to the Gateway `platform` in `envoy-gateway-system`: a wrong `parentRefs` name, namespace or `sectionName`; a route attached to the `http` listener, which accepts routes from the Gateway namespace only (app routes use `sectionName: https`); a hostname that no listener covers; a backend Service name or port that does not exist; or a listener that is not programmed because its certificate Secret is missing.

### Check

```bash
kubectl get httproute -A
kubectl -n <namespace> get httproute <name> -o yaml | yq '.status.parents'
kubectl -n envoy-gateway-system get gateway platform -o yaml | yq '.status'
kubectl get certificate -A
```

On the route, look at the `Accepted` and `ResolvedRefs` conditions per parent. Common reasons: `NotAllowedByListeners`, `NoMatchingListenerHostname`, `NoMatchingParent`, `BackendNotFound`, `RefNotPermitted`. On the Gateway, every listener needs `Accepted`, `Programmed` and `ResolvedRefs` set to `True`; `InvalidCertificateRef` means the TLS Secret is missing or invalid.

### Fix

- Keep the helm-common default parent (`name: platform`, `namespace: envoy-gateway-system`, `sectionName: https`) unless you have a reason to change it.
- Use a hostname of the form `<app>.<env>.<domain>`; the wildcard certificate covers one DNS label below `<env>.<domain>`.
- Fix the backend reference to match the Service the chart renders.
- If the listener lacks its certificate, continue with [certificate not ready](#certificate-not-ready).

## Certificate not ready

### Likely cause

- The issuer named in `platform.issuer` is not Ready, for example an ACME account that failed to register.
- An ACME HTTP-01 solver pod is denied by Kyverno because the exception does not match it, or the solver route is not reachable on port 80.
- A wildcard name with an ACME issuer: ACME validates wildcard names only through DNS-01, never through HTTP-01. The `letsencrypt-staging` and `letsencrypt` issuers need a DNS-01 solver for the wildcard certificate.
- Rate limits of the production ACME endpoint after repeated failures.

### Check

```bash
kubectl get clusterissuer
kubectl get certificate -A
kubectl -n envoy-gateway-system describe certificate <name>
kubectl get certificaterequests.cert-manager.io,orders.acme.cert-manager.io,challenges.acme.cert-manager.io -A
kubectl -n cert-manager logs -l app.kubernetes.io/name=cert-manager
```

The `describe` output and the Challenge status say which step fails.

### Fix

- Fix the issuer first; a Certificate cannot become Ready while its issuer is not.
- Configure a DNS-01 solver for wildcard certificates with an ACME issuer.
- For HTTP-01 on single names, check that the solver pods carry the label the exception matches and that port 80 reaches the Gateway.
- Validate with `letsencrypt-staging` before switching `platform.issuer` to `letsencrypt`.
- With `selfsigned` (the lab default), the certificate is Ready and browsers warn; that is expected.

## SealedSecret cannot be decrypted

### Likely cause

- Wrong controller key: the SealedSecret was sealed with a certificate whose private key this controller does not have, typically after a lab cluster was recreated without restoring the escrowed key.
- Wrong name or namespace: with the default strict scope, the name and namespace are part of the encrypted data, so a SealedSecret renamed or moved after sealing cannot be decrypted.
- A Secret with the same name already exists and is not managed by the SealedSecret.

### Check

```bash
kubectl -n <namespace> get sealedsecret <name> -o yaml | yq '.status'
kubectl -n kube-system logs -l app.kubernetes.io/name=sealed-secrets
kubeseal --fetch-cert --controller-namespace kube-system --controller-name sealed-secrets-controller \
  | openssl x509 -noout -fingerprint -sha256
```

Compare the fingerprint with the pinned fingerprint of the committed certificate ([secrets handling](../security/secrets-handling.md)).

### Fix

- Wrong key: restore the escrowed key (see [backup and restore](backup-and-restore.md#export-escrow-and-restore-the-sealed-secrets-key)), or re-seal from the source inputs with the current certificate.
- Wrong name or namespace: re-seal with the final name and namespace.
- Existing Secret: remove it, or annotate it with `sealedsecrets.bitnami.com/managed: "true"` so the controller takes it over.

## make demo fails

### Likely cause

- Docker is not running or has too little memory and CPU for a three-node kind cluster.
- Ports 80 or 443 on the host are in use; kind maps them to the Gateway.
- `*.localtest.me` does not resolve: it needs public DNS, so the names fail offline or behind a resolver that blocks answers with `127.0.0.1`.
- A kind cluster from an earlier run still exists.
- On Linux, the inotify limits are too low for several kind nodes.

### Check

```bash
docker info --format '{{.MemTotal}} {{.NCPU}}'
lsof -nP -iTCP:80 -sTCP:LISTEN
lsof -nP -iTCP:443 -sTCP:LISTEN
kind get clusters
dig +short argocd.localtest.me
```

### Fix

- Give Docker the memory listed in [prerequisites](../getting-started/prerequisites.md).
- Stop the process that holds port 80 or 443.
- Offline, add the demo names to `/etc/hosts`, for example `127.0.0.1 argocd.localtest.me hello-api.dev.localtest.me`.
- Remove the old cluster with `make demo-down`, then run `make demo` again.
- On Linux, raise the inotify limits as the kind known-issues page describes:

  ```bash
  sudo sysctl fs.inotify.max_user_watches=524288
  sudo sysctl fs.inotify.max_user_instances=512
  ```

## Ansible preflight fails

### Likely cause

- A placeholder (`CHANGE_ME`, `YOUR_`) is left in `clusters/<name>/cluster.yaml` or the inventory.
- The node runs an unsupported operating system. Supported: Ubuntu 24.04, Debian 12 and 13, Rocky 9.
- Swap is on.
- SSH host key checking is on and the node's host key is not in `known_hosts`.
- The vault password is wrong for the profile's vault ID.

### Check

```bash
make validate-config STRICT=1 CLUSTER=<lab|reference>
make preflight CLUSTER=<lab|reference>
swapon --show
```

The preflight output names the assertion that failed. Run `swapon --show` on the node.

### Fix

- Replace every placeholder; `make validate-config STRICT=1 CLUSTER=<name>` must pass. Without `STRICT=1` placeholders are only warnings.
- Reinstall the node with a supported operating system.
- Turn swap off (`sudo swapoff -a`) and remove the swap entry from `/etc/fstab` so it stays off after a reboot.
- Add the host key to `known_hosts` after you compare its fingerprint with the one shown on the node console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).
- Re-enter the vault password for the profile; see `ansible/README.md`.

## Kubeconfig does not work

### Likely cause

- The file is readable by other users. `make bootstrap-k8s` writes it with mode 0600; a copy may not keep that mode, and Helm warns about group- or world-readable kubeconfig files.
- The server address does not match the API server certificate (an x509 error naming the valid names).
- The kubeconfig belongs to an earlier installation of the cluster (`Unauthorized`).
- The registration address is unreachable (connection refused or timeout).

### Check

```bash
ls -l ansible/data/kubeconfig-<cluster>.yaml
kubectl --kubeconfig ansible/data/kubeconfig-<cluster>.yaml cluster-info
```

### Fix

- Restore the mode with `chmod 600 ansible/data/kubeconfig-<cluster>.yaml`.
- Use the kubeconfig that `make bootstrap-k8s CLUSTER=<lab|reference>` fetched; it points at the registration address. Re-run the target to fetch a fresh copy after a rebuild.
- If the registration address is down, check the VIP or load balancer and the firewall rules for port 6443.

## References

- Argo CD troubleshooting and sync options: <https://argo-cd.readthedocs.io/en/stable/operator-manual/troubleshooting/> and <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/>
- Argo CD sync waves: <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/>
- Kyverno policy reports and exceptions: <https://kyverno.io/docs/policy-reports/> and <https://kyverno.io/docs/exceptions/>
- Gateway API HTTPRoute: <https://gateway-api.sigs.k8s.io/reference/api-types/httproute/>
- cert-manager troubleshooting and ACME DNS-01: <https://cert-manager.io/docs/troubleshooting/> and <https://cert-manager.io/docs/configuration/acme/dns01/>
- Sealed Secrets: <https://github.com/bitnami-labs/sealed-secrets>
- kind known issues: <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Kubernetes NetworkPolicy: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
