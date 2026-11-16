# Security controls

This page lists every security control of the platform: what enforces it, where it applies, in which mode, and how it is tested. It is the single source for the security summary; other pages link here instead of repeating it. It is written for reviewers who assess the platform and for operators who need to know what blocks what.

## How to read the matrix

- Layer: where the control acts. CI acts on a change before it merges or on an image build. Admission acts when the Kubernetes API server receives an object. Network acts on traffic between pods. Runtime acts on running workloads. Node acts on hosts and RKE2. Access governs who and what may change the platform or read its secrets.
- Mode: blocking (the change, object or connection is refused), audit (the violation is recorded and the object is admitted), advisory (a report for a human to act on). Controls that are opt-in or planned say so.
- Tested by: the job in `.github/workflows/validate.yml`, or the end-to-end assertion, that fails when the control stops working. The aggregator job `ci-gate` depends on every `validate.yml` job and is the only required check.

## Enforcement matrix

| Control | Layer | Enforced by | Scope | Mode | Tested by |
| --- | --- | --- | --- | --- | --- |
| Secret scanning | CI | gitleaks with `.gitleaks.toml` and `.gitleaksignore` (fingerprints of reviewed findings), job `secrets`; the same scan runs as a `pre-commit` hook | Every push and pull request; a weekly scheduled run scans the full Git history | Blocking | `secrets` |
| Environment data in the repository | CI | Custom gitleaks rules in `.gitleaks.toml`: `hardcoded-ipv4` fails on a single private host address or any public address in YAML, JSON, INI, TOML, Terraform, Jinja, shell, Groovy and Dockerfiles (RFC 5737 documentation ranges and private CIDRs pass); `hardcoded-domain` fails on domains outside the allowlist (`example.com`, `localtest.me` and upstream project domains pass) | Every push and pull request | Blocking | `secrets` |
| No plaintext Secret manifests | CI | `hack/secrets.sh` (`make secrets`) fails on a `kind: Secret` with `data` or `stringData` in a YAML file outside Helm `templates/` directories and `*.example.yaml` files | Whole repository | Blocking | `secrets` |
| Manifest validation | CI | kubeconform in strict mode, with CRD schemas, against the profile's Kubernetes version and against 1.35, on the output of `make render` (`hack/render.sh`, `hack/kubeconform.sh`) | Every chart under `helmcharts/` and `argocd-bootstrap`, for both profiles | Blocking | `argocd-bootstrap` |
| IaC misconfiguration scan | CI | Trivy config scan on the rendered manifests; accepted findings are listed in `.github/trivy-ignore.yaml`, each with an expiry date | Rendered output of every chart, both profiles | Blocking; a finding counts again once its ignore entry expires | `trivy-config` |
| Dockerfile lint | CI | hadolint and a container smoke test | `sample-services/*/Dockerfile` | Blocking | `dockerfile-lint` |
| Image vulnerability scan | CI | Trivy image scan in `.github/workflows/build-image.yml`. On pull requests the image is built locally and scanned, never pushed. On `main` the image is pushed first and the pushed digest is scanned; a failing image stays in GHCR unsigned, gets no dev bump pull request, and is rejected by `stage` and `prod` admission in the `reference` profile | Every image built from `sample-services/` | Blocking on CRITICAL and HIGH findings that have a fix | `build-image.yml` (the scan is the gate) |
| Image signing and attestations | CI | `build-image.yml`: `docker buildx` with `--sbom=true` and `--provenance=mode=max`, cosign keyless signature, a cosign keyless vulnerability attestation of the Trivy report (renewed daily for deployed digests by the `rescan` job), `actions/attest-build-provenance` and `actions/attest-sbom` | Images pushed to GHCR from `main` that pass the Trivy scan | Produces the evidence that admission and consumers verify; a failed signing step fails the build | `build-image.yml`; manual check in [supply chain](supply-chain.md#verify-an-image-by-hand) |
| Workflow hardening | CI | Every action pinned by full commit SHA; `validate.yml` sets workflow-level `permissions: contents: read`, the other workflows set `permissions: {}`, and jobs request what they need; `timeout-minutes` on every job; actionlint and zizmor | All workflows in `.github/workflows/` | Blocking | `workflow-lint` |
| Pod Security Admission | Admission | Namespace labels `pod-security.kubernetes.io/enforce: restricted` with a pinned `enforce-version`, set by the `misc` chart (`helmcharts/system-charts/misc`) | Namespaces `dev`, `stage`, `prod`. The Argo CD install labels `argocd` `restricted`. Other platform namespaces get a level suited to each component through `managedNamespaceMetadata`. With the RKE2 CIS profile, `restricted` is also the cluster-wide default | Blocking for Pods; not enforced on Deployments and other workload controllers | `e2e-kind`: a privileged pod is denied |
| Workload contract | Admission | Kyverno CEL `ValidatingPolicy` resources from `helmcharts/system-charts/kyverno-policies`: non-root, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, read-only root filesystem, CPU and memory requests and limits, readiness and liveness probes, a non-`latest` tag or a digest, registry allowlist. The contract is described in [helm-common values](../reference/helm-common-values.md) | Pods in `dev`, `stage`, `prod`. Exceptions are `PolicyException` objects in the `kyverno` namespace | Audit in `dev` (results in PolicyReports); Enforce in `stage` and `prod` | `policy-test` (`kyverno test` fixtures in `helmcharts/system-charts/kyverno-policies/tests/`, `kyverno apply` against every rendered app and environment); `e2e-kind`: root and `latest` pods are denied |
| Image signature verification | Admission | Kyverno `ImageValidatingPolicy` from `helmcharts/system-charts/kyverno-policies`, values `imageVerification.enabled`, `imageVerification.issuer`, `imageVerification.subjectRegExp`, `imageVerification.registries` | `stage` and `prod` in the `reference` profile. Off in the `lab` profile and in `dev` | Blocking | Rendered and schema-checked by `argocd-bootstrap`. Not exercised by `e2e-kind`, because `lab` disables it |
| Vulnerability attestation gate | Admission | The same policy with `imageVerification.vulnerabilities`: a vuln attestation from the signing identity, no finding of a listed severity (default CRITICAL) except accepted IDs, newest scan younger than `maxScanAge` (default 168h) | `stage` and `prod` in the `reference` profile | Blocking | `policy-test-attestations` (key-based attestor, local registry); the keyless identity match is covered by the image verification tests of `policy-test` |
| Resource bounds | Admission | LimitRange and ResourceQuota per namespace from the `misc` chart | `dev`, `stage`, `prod` | Blocking when a quota is exhausted; the LimitRange fills in container defaults | `helm` |
| Default-deny network policy | Network | `helmcharts/system-charts/network-policies`, project `platform`: only `default-deny` (all ingress and egress) and `allow-dns` (DNS egress) in each app namespace. The CNI enforces it: Calico on kind, `canal`, `calico` or `cilium` on RKE2 | `dev`, `stage`, `prod` | Blocking | `e2e-kind`: traffic between environments is blocked |
| Per-app NetworkPolicy | Network | helm-common template `common.networkpolicy`, rendered by default for every app: ingress on the service port from `envoy-gateway-system` when `route.enabled`, ingress on the metrics port from the monitoring namespace when `metrics.serviceMonitor.enabled`, plus optional `networkPolicy.extraIngress[]` and `networkPolicy.egress[]` | One app in one namespace | Blocking: traffic that no rule allows stays denied | helm-unittest suite in `helmcharts/helm-common/tests/` |
| Broad app NetworkPolicy report | Admission | Kyverno policy from `helmcharts/system-charts/kyverno-policies` that reports app NetworkPolicies admitting ingress from all namespaces to all pods | `dev`, `stage`, `prod` | Audit (results in PolicyReports) | `policy-test` |
| Platform namespace baseline | Network | Baseline NetworkPolicies from the `network-policies` chart. In `argocd`, default-deny policies admit Redis clients only from `argocd-server`, the repo-server and the application controller | `argocd`, `envoy-gateway-system`, `cert-manager`, `kyverno` | Blocking | `helm` |
| TLS at the edge | Network | Certificate `platform-tls` (Secret `platform-tls` in `envoy-gateway-system`) on the `https` listener of Gateway `platform`, signed by the ClusterIssuer named in `platform.issuer` (`selfsigned`, `letsencrypt-staging` or `letsencrypt`; the ClusterIssuers come from the `misc` chart). Names: `<domain>`, `*.<domain>` and `*.<env>.<domain>` with `selfsigned` or ACME DNS-01; the explicit list `platform.gateway.hostnames[]` with ACME HTTP-01 | Every HTTPRoute, including `argocd.<domain>` | Always on for the `https` listener | `e2e-kind`: `hello-api` answers through the Gateway |
| Change control | Access | Pull requests with `ci-gate` as the required check; CODEOWNERS for `envs/prod/`. The branch ruleset that requires both is a GitHub repository setting, not a file in the repository | Every change to `main` | Blocking once the repository owner has configured the ruleset | `ci-gate` |
| Argo CD tenancy | Access | AppProjects `platform`, `apps-dev`, `apps-stage`, `apps-prod` and a locked `default`, from `argocd-bootstrap/templates/projects/`; sync window on prod in the `reference` profile | `platform`: all toolchains, enumerated cluster-scoped kinds. `apps-<env>`: one namespace, no cluster-scoped kinds, no ResourceQuota, LimitRange, Role or RoleBinding | Blocking: Argo CD refuses to sync what the project does not permit | `argocd-bootstrap`: every rendered kind and destination is permitted by its project |
| Argo CD sign-in and authorization | Access | `reference`: OIDC SSO; `argocd-rbac-cm` rendered from `platform.groups` (admins to `role:admin`, deployers to `role:deployer`, viewers to `role:readonly`); empty `policy.default`, so a signed-in user without a mapped group has no rights; local admin disabled. Automation has no local account: the AppProject role `ci` in each app project may only get that project's Applications, with tokens that expire. `lab`: initial admin secret. Values in `helmcharts/system-charts/argo-cd/values-<profile>.yaml` | Argo CD UI, API and CLI | Blocking | `helm`; the SSO login is verified by hand, see [Argo CD SSO](argocd-sso.md#verify-the-login) |
| Argo CD internals | Access | Redis requires a password (Secret `argocd-redis`, key `auth`); Argo CD NetworkPolicies (see the platform namespace baseline above) | `argocd` namespace | Blocking | `e2e-kind`: every Application reaches Synced and Healthy with authentication on |
| Kubernetes RBAC | Access | `misc` chart, groups from `platform.groups`. Admins: the built-in `admin` ClusterRole through a RoleBinding in each environment namespace, and with `rbac.clusterReader.enabled` (default true) cluster-wide `view` plus `platform-cluster-reader` (read on cluster-scoped and platform kinds; patch on nodes and create on `pods/eviction` for node maintenance as the only writes). Deployers: a `deployer` Role in each environment namespace with read on workload state; its only writes are patch on Deployments, StatefulSets and DaemonSets (for rollout restart), patch on Argo Rollouts (promote and abort), pod delete and Job create (for a Job from a CronJob); exec and port-forward only in `rbac.deployer.execEnvironments` (default `dev`); no rule grants Secrets, but a patched workload or a created Job can run a pod that mounts a namespace Secret. Viewers: the built-in `view` ClusterRole in each environment namespace. No `cluster-admin` binding is rendered; break-glass uses the admin kubeconfig of an RKE2 server. Group subjects need an authenticator, see [below](#group-subjects-need-an-authenticator) | Cluster and app namespaces | Blocking | `helm` |
| Secrets in Git | Access | Sealed Secrets with offline sealing in `lab`; External Secrets Operator (ESO) with OpenBao in `reference`; SOPS with age for bootstrap secrets only; Ansible secrets in a gitignored, vault-encrypted `vault.yml`. Details in [secrets handling](secrets-handling.md) | Every secret the platform consumes | Blocking through the CI checks at the top of this table | `secrets` |
| Workload defaults | Runtime | helm-common: ServiceAccount token automount off, non-root user, read-only root filesystem with an `emptyDir` at `/tmp`, all capabilities dropped | Every app chart built on helm-common | Default; the admission rows above enforce it | helm-unittest suite in `helmcharts/helm-common/tests/` |
| Runtime detection | Runtime | Falco (`helmcharts/system-charts/falco`) | Available, off by default; switch `toolchains.falco.enabled` | Advisory (alerts) when enabled | Rendered and schema-checked by `argocd-bootstrap` |
| Continuous image rescanning | CI and runtime | The daily `rescan` job of `build-image.yml` attests the deployed digests again, and the admission gate acts on the newest scan. Trivy Operator (`helmcharts/system-charts/trivy-operator`) additionally scans running workloads | The rescan covers every digest in `envs/`; Trivy Operator is off by default (`toolchains.trivy-operator.enabled`) | Blocking for new pods in `stage` and `prod` (`reference`); advisory for Trivy Operator | `build-image.yml` (`rescan`); Trivy Operator rendered and schema-checked by `argocd-bootstrap` |
| RKE2 CIS profile | Node | `rke2.cisProfile` in `clusters/<name>/cluster.yaml`, applied by `ansible/roles/rke2` with the host preparation it requires. RKE2 then enforces `restricted` Pod Security Admission cluster-wide, except in `kube-system` | RKE2 nodes | Opt-in per cluster | `ansible` (ansible-lint, syntax check); the RKE2 installation itself is verified by hand |
| Secrets encryption in etcd | Node | RKE2, which encrypts Secrets at rest by default | RKE2 clusters; not kind | Always on in RKE2 | Not tested in CI |
| Host firewall | Node | `ansible/roles/firewall`: each port open only to the source CIDRs that need it (cluster nodes for etcd, kubelet and the RKE2 supervisor port; administrators or the load balancer for the API server) | All cluster nodes | Blocking | `ansible` (ansible-lint, Molecule) |
| SSH and host identity | Node | Key-only SSH access; host keys pinned in `known_hosts`; `host_key_checking = True` and no agent forwarding in `ansible/ansible.cfg` | Operator workstation to nodes | Blocking: Ansible refuses a host whose key does not match | `ansible` (ansible-lint) |
| Kubernetes API audit log | Node | `ansible/roles/rke2`: `rke2_audit_policy_enabled: true` by default installs the audit policy and sets `audit-policy-file`; the log stays on each server in `/var/lib/rancher/rke2/server/logs/audit.log` | RKE2 servers; not kind | On by default; not shipped off the nodes | `ansible` (ansible-lint, syntax check); see [known limitations](known-limitations.md#api-audit-logs-stay-on-the-nodes-and-the-rke2-cis-profile-is-opt-in) |

Profile differences in one place: the `lab` profile uses the self-signed issuer and the Argo CD initial admin secret, and does not verify image signatures. Both profiles run Kyverno in Audit in `dev` and in Enforce in `stage` and `prod`. The [known limitations](known-limitations.md) page lists the accepted risks that follow from this.

## What some controls do not cover

### AppProjects limit Applications, not the Argo CD controller

The `platform` project installs CRDs, admission webhooks, ClusterRoles and ClusterRoleBindings. The Argo CD application controller therefore holds cluster-wide write permissions. AppProjects decide what each Application may render and where it may deploy; they do not reduce what the controller itself can do.

- Write access to the paths that the `platform` project deploys from is equivalent to cluster-admin. Pull-request review, `ci-gate` and the branch ruleset are the controls on that path.
- The app projects `apps-dev`, `apps-stage` and `apps-prod` are the tenancy boundary for workloads. An app Application cannot create cluster-scoped objects, deploy outside its single namespace, or replace the quota, limit range or RBAC of that namespace. It does manage its own NetworkPolicy, which can open traffic to its pods but cannot remove the platform's default deny. No app project lists `argocd` as a destination; a project that may deploy into the Argo CD namespace effectively grants Argo CD admin rights.
- The `default` project is locked, so an Application without an explicit project deploys nothing.

The project layout is described in [AppProjects and the tenancy boundary](../architecture/gitops.md#appprojects-and-the-tenancy-boundary).

### Group subjects need an authenticator

The RBAC bindings name groups from `platform.groups` in the cluster file (defaults `platform-admins`, `deployers`, `viewers`). Kubernetes does not manage users or groups. A group binding takes effect only for requests whose identity carries that group.

The `rke2` role can configure an OIDC authenticator on the API server through the Ansible variable `rke2_apiserver_oidc`, off by default. It sets the username and groups prefix `oidc:`, so a group `platform-admins` from the identity provider reaches RBAC as `oidc:platform-admins`, and the bindings must name that form. The prefix keeps identity-provider groups apart from built-in groups such as `system:masters`.

Until an authenticator is configured, operators use the admin kubeconfig that Ansible fetches to `ansible/data/`. That credential belongs to the `system:masters` group and bypasses RBAC, see [known limitations](known-limitations.md#the-admin-kubeconfig-is-a-long-lived-superuser-credential).

### Exceptions

Kyverno exceptions are `PolicyException` objects in the `kyverno` namespace, for example for cert-manager ACME HTTP-01 solver pods (label `acme.cert-manager.io/http01-solver: "true"`). Only the `platform` project deploys to that namespace, so an exception is a reviewed platform change and never part of an app chart. Pod Security Admission has no per-pod exception in this platform: every pod meets the level of its namespace.

## Defence in depth: Pod Security Admission and Kyverno

Pod Security Admission (PSA) and Kyverno check overlapping parts of the same pod specification. The overlap is deliberate.

### Coverage

| Requirement | PSA `restricted` | Kyverno workload contract |
| --- | --- | --- |
| No privileged containers, host namespaces, host ports or `hostPath` volumes | Yes | Privileged containers indirectly: the API server rejects `privileged: true` together with `allowPrivilegeEscalation: false`, which the contract requires |
| `runAsNonRoot: true` | Yes | Yes, at pod and container level |
| `allowPrivilegeEscalation: false` | Yes | Yes |
| All capabilities dropped | Yes | Yes |
| Seccomp profile | `RuntimeDefault` or `Localhost` | `RuntimeDefault` |
| Read-only root filesystem | No | Yes |
| CPU and memory requests and limits | No | Yes |
| Readiness and liveness probes | No | Yes |
| Non-`latest` tag or digest, registry allowlist | No | Yes |
| Image signature | No | Yes, `stage` and `prod` in `reference` |
| Mode per namespace | Enforce in `dev`, `stage`, `prod` | Audit in `dev`, Enforce in `stage` and `prod` |
| Checks Deployments and other controllers at admission | No: it enforces only on the Pods they create | When a policy declares pod-controller autogen (`spec.autogen.podControllers`) |
| Depends on a webhook being reachable | No, built into the API server | Yes |

### Which one rejects first

The API server runs admission in two phases. Mutating admission runs first; this is where the LimitRange fills in default requests and limits. Validating admission runs next, in a fixed order: the built-in `PodSecurity` plugin runs before `ValidatingAdmissionPolicy` and before validating webhooks such as Kyverno's. The first rejection ends the request.

Consequences:

- A pod that violates both PSA and Kyverno is rejected by PSA. The client sees only the PSA message, and Kyverno never evaluates the request, so no PolicyReport entry is written for it. This is why a privileged pod in `stage` or `prod` produces a PSA message, not a Kyverno one. The [policy demonstrations](threat-model.md#policy-demonstrations) show how to tell the two messages apart.
- Audit mode in `dev` only reports on pods that already pass PSA. In practice, the `dev` PolicyReports show the requirements PSA does not cover: probes, resources, read-only root filesystem, image tag and registry.
- PSA enforces on Pods, not on their controllers. A Deployment whose template violates PSA is accepted, and its ReplicaSet then fails to create Pods (a `FailedCreate` event). A Kyverno policy with pod-controller autogen rejects the Deployment itself in `stage` and `prod`, so the failure shows up as a failed Argo CD sync instead of a stalled rollout.
- When the namespace LimitRange sets default requests and limits, a pod without a `resources` block receives them before validation. The Kyverno resource rule then passes for that pod; the `kyverno test` fixtures still exercise it.

### Why both

PSA is built into the API server: it has no availability dependency, and no Kyverno outage, misconfigured webhook or `PolicyException` can switch it off. Kyverno covers what the Pod Security Standards do not, gives `dev` an Audit mode with PolicyReports, verifies image signatures, and handles reviewed exceptions. Each layer compensates for a failure mode of the other.
