# misc

Platform baseline for the application environments: namespaces with Pod Security labels, quotas and limits, namespace and platform RBAC, cert-manager ClusterIssuers and PriorityClasses. Argo CD deploys it as the Application `misc` (project `platform`, sync wave 2) with `values.yaml` followed by `values-<profile>.yaml`, where the profile is `lab` or `reference`.

## What it renders

| Kind | Name | Scope |
| --- | --- | --- |
| Namespace | one per `environments` entry | cluster |
| ResourceQuota, LimitRange | `default` | each environment namespace |
| ServiceAccount | `default` (token automount off) | each environment namespace |
| RoleBinding | `platform-admins` (ClusterRole `admin`), `viewers` (ClusterRole `view`) | each environment namespace |
| Role, RoleBinding | `deployer`, `deployers` | each environment namespace |
| ClusterRole | `platform-cluster-reader` | cluster |
| ClusterRoleBinding | `platform-admins-view`, `platform-admins-cluster-reader` | cluster |
| ClusterIssuer | `selfsigned-bootstrap`, `selfsigned`, `letsencrypt-staging`, `letsencrypt` | cluster |
| Certificate | `platform-root-ca` | `certManager.namespace` |
| PriorityClass | `platform-critical`, `workload-high`, `workload-default`, `workload-batch` | cluster |

Namespaces, their ResourceQuota and their LimitRange carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so Argo CD never deletes an environment namespace and a namespace that stays keeps its quota and defaults. The `default-deny` NetworkPolicy of the network-policies chart follows the same rule. The cert-manager objects carry `SkipDryRunOnMissingResource=true` because their CRDs come from the cert-manager Application.

## Values

The Application injects these keys through `helm.valuesObject`. Their source is `clusters/<name>/cluster.yaml`, mapped in `argocd-bootstrap/templates/toolchains/misc.yaml`.

| Key | Default | Purpose |
| --- | --- | --- |
| `environments` | `{dev: dev, stage: stage, prod: prod}` | Environment key to namespace name |
| `podSecurity.version` | `v1.36` | Pod Security Standards version on every namespace |
| `groups.admins`, `groups.deployers`, `groups.viewers` | `platform-admins`, `deployers`, `viewers` | OIDC group names |
| `certManager.namespace` | `cert-manager` | Namespace of the root CA Certificate |
| `certManager.email` | `platform@example.com` | ACME account contact; the render fails when it is empty and an ACME issuer is enabled |
| `gateway.name`, `gateway.namespace`, `gateway.sectionName` | `platform`, `envoy-gateway-system`, `http` | Gateway listener for HTTP-01 challenges |
| `issuers.letsencryptStaging.enabled`, `issuers.letsencrypt.enabled` | `true` (`false` in `values-lab.yaml`) | Set by the Application: `true` only when `platform.issuer` is an ACME issuer |
| `issuers.acme.solver`, `issuers.acme.dns01` | `http01`, `{}` | From `platform.acme.solver` and `platform.acme.dns01` (`{provider, config, credentialsSecretRef}`) |
| `issuers.acme.server`, `issuers.acme.caBundle` | `""` | Test only, from `platform.acme.server` and `platform.acme.caBundle`: directory URL and base64 PEM CA of a test ACME server for `letsencrypt-staging` (see [`tests/integration/acme`](../../../tests/integration/acme)). `letsencrypt` is never redirected |

Per-environment settings (`podSecurity.levels`, `resourceQuota`, `limitRange`) are looked up by environment key, not by namespace name, and the render fails when a key in `environments` has no entry. Helm merges maps, so a default environment is removed by setting its key to `null`. The other keys (`rbac`, `issuers`, `priorityClasses`, `defaultServiceAccount`) are documented in `values.yaml`.

## RBAC model

- Admins (`groups.admins`) get the built-in `admin` ClusterRole in each environment namespace through a RoleBinding. With `rbac.clusterReader.enabled` they also get cluster-wide `view` (no Secrets) and `platform-cluster-reader`: read access to cluster-scoped and platform kinds, plus node maintenance (patch on nodes, create on `pods/eviction`) as the only write.
- Deployers operate workloads, they do not apply manifests (Argo CD does): read workload state, restart workloads, promote or abort Argo Rollouts, delete pods and run a Job from a CronJob. No rule grants Secrets. Exec and port-forward are granted only in `rbac.deployer.execEnvironments` (default `dev`). Patching a workload or creating a Job can still run a pod that mounts a namespace Secret; Argo CD self-heal and the audit log are the controls for that.
- Viewers get the built-in `view` ClusterRole in each environment namespace.

Break-glass: no cluster-admin binding of any kind is rendered. Break-glass access uses the local admin kubeconfig on an RKE2 server node, and the API server audit log records its use, which requires the audit policy that the provisioning layer installs (the RKE2 default policy logs nothing). Group subjects require API server OIDC, configured by the provisioning layer.

## Issuers

`selfsigned-bootstrap` (a self-signed issuer) signs the `platform-root-ca` Certificate (ECDSA P-384, 10 years, key rotated on renewal). The CA ClusterIssuer `selfsigned` signs with that root, so clients must import the root CA to trust its certificates.

`letsencrypt-staging` and `letsencrypt` are ACME issuers. The Application renders them only when `platform.issuer` is one of them: Let's Encrypt registers an account when the ClusterIssuer is created and rejects placeholder contact addresses, so an unused ACME issuer would stay not Ready. Both use one solver, chosen by `platform.acme.solver`:

- `http01` (default): HTTP-01 through a Gateway API HTTPRoute attached to the configured Gateway listener. The listener must accept routes from the namespaces that request certificates, and cert-manager must run with Gateway API support enabled. HTTP-01 cannot issue wildcard certificates.
- `dns01`: required for wildcard names. `platform.acme.dns01` has the shape `{provider, config, credentialsSecretRef}`: `provider` is a cert-manager DNS-01 provider, `config` holds its non-secret fields, and `credentialsSecretRef` (a Secret in the cert-manager namespace) is rendered as that provider's own reference field, for example `apiTokenSecretRef` for cloudflare or `secretAccessKeySecretRef` for route53. akamai and webhook take their references in `config`. Inline secret values, unknown providers and incomplete references fail the render. Every provider was rendered and validated against the cert-manager ClusterIssuer schema.

For tests, `platform.acme.server` and `platform.acme.caBundle` point `letsencrypt-staging` at another ACME server, such as Pebble in [`tests/integration/acme`](../../../tests/integration/acme). Both stay empty in real clusters.

The names `selfsigned`, `letsencrypt-staging` and `letsencrypt` are a contract: other components reference them through `platform.issuer`.

## Cluster-scoped kinds rendered

- Namespace
- ClusterRole
- ClusterRoleBinding
- ClusterIssuer
- PriorityClass
