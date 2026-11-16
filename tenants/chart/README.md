# tenant chart

Onboards one tenant from `tenants/<name>.yaml`. The `tenants` ApplicationSet
(`argocd-bootstrap/templates/tenants/applicationset.yaml`) renders this chart
once per tenant file; nobody installs it by hand.

## What it renders

For every environment `<env>` in `environments`, in namespace `tenant-<name>-<env>`:

| Object | Name | Notes |
|--------|------|-------|
| Namespace | `tenant-<name>-<env>` | Labels `tenant`, `environment`; Pod Security `restricted` for enforce, audit and warn, pinned to `v<cluster.kubernetesMinor>` |
| ResourceQuota | `tenant-quota` | From `quota` |
| LimitRange | `tenant-limits` | Type Container, from `limitRange` |
| NetworkPolicy | `default-deny-all` | Denies all ingress and egress |
| NetworkPolicy | `allow-dns-egress` | UDP and TCP 53 to namespace `kube-system` |
| NetworkPolicy | `allow-egress-cidrs` | Only when `network.allowEgressCidrs` is set |
| RoleBinding | `tenant-admins-edit` (dev) or `tenant-admins-view` (stage, prod) | `groups.admins` to ClusterRole `edit` in dev, `view` elsewhere |
| RoleBinding | `tenant-viewers-view` | `groups.viewers` to ClusterRole `view` |

Once, in namespace `namespaces.argocd`: the AppProject `tenant-<name>`
(`<cluster>-tenant-<name>` in hub mode) with the tenant's `sourceRepos`,
exactly the tenant namespaces as destinations, no cluster-scoped kinds,
ResourceQuota, LimitRange, Role and RoleBinding blacklisted,
and two roles: `admins` (get, sync) and `viewers` (get). Neither role can
create or delete Applications; the platform team creates the tenant's
Applications in this project.

Every object carries `app.kubernetes.io/name`, `app.kubernetes.io/instance`,
`app.kubernetes.io/managed-by`, `app.kubernetes.io/part-of: tenants` and
`tenant: <name>`; namespaced objects also carry `environment`.

## Values

Three layers, lowest first. Argo CD applies `valuesObject` after `valueFiles`.

1. `values.yaml`: defaults. Maps merge key by key, so the default
   `quota.services.loadbalancers: 0` and `quota.services.nodeports: 0` and the
   `limitRange` defaults apply unless the tenant file sets the same key.
2. `tenants/<name>.yaml`: the tenant definition. Contract: `tenants/schema.json`.
3. ApplicationSet `valuesObject`: `namespaces.argocd`, `namespaces.gateway`,
   `cluster.name`, `cluster.kubernetesMinor`, `cluster.destination.name` and
   `components`. Platform-owned; it always overrides the tenant file, so a
   tenant file cannot move its namespaces, its AppProject or its cluster.

`values.schema.json` validates the merged values on every render, in Argo CD
as well, and rejects unknown keys. Its tenant keys mirror `tenants/schema.json`;
change both together.

## Lifecycle

Onboarding: add `tenants/<name>.yaml`, run `hack/validate-config.sh`, open a
pull request. After merge the ApplicationSet creates Application
`tenant-<name>` in project `tenants`.

Changes: edit the tenant file. Removing an environment removes its role
bindings and allow policies, but the namespace, `default-deny-all`,
`tenant-quota` and `tenant-limits` stay (`Prune=false`); the Application then
reports them as requiring pruning until an administrator deletes the
namespace.

Offboarding: delete the tenant file. The ApplicationSet deletes the
Application only (`preserveResourcesOnDeletion`); the namespaces, their
guardrails and the AppProject stay (`Delete=false`). An administrator moves or
deletes the tenant's Applications, then deletes the AppProject and the
namespaces.

## Prerequisites

- `toolchains.tenants.enabled: true` for the cluster.
- Argo CD 3.x, for the `exclude` entry of the Git files generator. With Argo
  CD's default (greedy) globbing, `tenants/*.yaml` alone would also match the
  files of this chart; the generator excludes `tenants/chart/**` explicitly.
- Tenant routes attach to the `https` listener of Gateway `platform`, which
  admits routes from all namespaces.

## Hub mode

When `cluster.destination.name` names a remote cluster, the AppProject must
live in the hub and the namespaces on the remote cluster. The root chart then
renders two ApplicationSets: `<cluster>-tenants` creates
`<cluster>-tenant-<name>` with `components.project: false` (remote cluster),
and `<cluster>-tenant-projects` creates `<cluster>-tenant-<name>-proj` with
`components.namespaces: false` (hub). Tenant Applications reference project
`<cluster>-tenant-<name>`.

## Not covered here

- ClusterRole `edit` includes write access to NetworkPolicies. In dev, tenant
  admins can add an allow policy that Argo CD does not track. Close this with
  an admission policy (see below) or replace `edit` with a narrower
  ClusterRole maintained by the platform.
- `allowEgressCidrs` is meant for ranges outside the cluster. With Canal or
  Calico an `ipBlock` also matches pod IPs, so never list the pod or service
  CIDR, and treat `0.0.0.0/0` as a reviewed exception.
- Ingress from the gateway and from monitoring, and traffic between pods, are
  allowed by each application's own NetworkPolicy (helm-common), as in the
  dev, stage and prod namespaces. This chart only renders the
  default deny, DNS egress and the approved egress CIDRs.
- Admission policies (Kyverno) are owned by the platform charts. Select tenant namespaces by the
  label `tenant` (or `environment`) rather than by name.

## Local checks

```bash
helm lint --strict tenants/chart -f tenants/team-a.yaml
helm template tenant-team-a tenants/chart -f tenants/team-a.yaml
hack/validate-config.sh tenants/team-a.yaml
```

The chart does not render without a tenant file: `name`, `groups`,
`environments` and `sourceRepos` have no usable defaults.
