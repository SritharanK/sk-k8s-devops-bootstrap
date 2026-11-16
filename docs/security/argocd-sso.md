# Argo CD SSO

This page explains how Argo CD sign-in works in each profile and how to connect the `reference` profile to an identity provider, either with native OIDC or through Dex with the GitHub connector. It is for operators who set up or change access to Argo CD. The keys follow the upstream [Argo CD user management](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/) and [RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/) documentation and the [argo-cd Helm chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd). The wrapper chart's [README](../../helmcharts/system-charts/argo-cd/README.md) holds the step-by-step OIDC procedure for this repository.

## Sign-in per profile

| Profile | Sign-in | Authorization |
| --- | --- | --- |
| `lab` | Local `admin` user, password from the initial admin secret | Full rights |
| `reference` | OIDC SSO; local `admin` disabled | Roles mapped from the identity provider's groups; no rights for users without a mapped group |

Argo CD is installed as release `argocd` in namespace `argocd`, which the install labels with the `restricted` Pod Security level. The UI and API are reached at `argocd.<domain>` through an HTTPRoute on Gateway `platform`.

### Lab

Open `https://argocd.localtest.me`, accept the self-signed certificate, and sign in as `admin` with the password from the initial admin secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

This is acceptable for a workstation demonstration only, see [known limitations](known-limitations.md#the-lab-profile-is-a-demonstration-environment).

## Where the settings live

The settings for the `reference` profile are in `helmcharts/system-charts/argo-cd/values-reference.yaml`. The wrapper chart passes everything under its `argo-cd:` key to the upstream chart, which writes the Argo CD ConfigMaps:

| Chart values | Written to | Keys used here |
| --- | --- | --- |
| `global.domain` | Several resources | The chart derives `url` as `https://<global.domain>` unless `configs.cm.url` is set |
| `configs.cm` | ConfigMap `argocd-cm` | `url`, `oidc.config` or `dex.config`, `admin.enabled`, `accounts.<name>` |
| `rbac.*` (wrapper values, not under `argo-cd:`) and `platform.groups` | ConfigMap `argocd-rbac-cm`, rendered by the wrapper template `templates/argocd-rbac-cm.yaml`; upstream `configs.rbac.create` is `false` | `policy.csv`, `policy.default`, `policy.matchMode`, `scopes` |
| `configs.params` | ConfigMap `argocd-cmd-params-cm` | `server.insecure` |
| `dex.enabled` | Dex Deployment | `true` for the Dex option, `false` for native OIDC |

Client secrets never go into values files. Argo CD resolves a value of the form `$<secret>:<key>` in `argocd-cm` from the Kubernetes Secret `<secret>` in the `argocd` namespace. That Secret must carry the label `app.kubernetes.io/part-of: argocd`, or Argo CD ignores it.

## Before you start

1. Register a client in the identity provider. The redirect URI is `https://argocd.example.com/auth/callback` for native OIDC, or `https://argocd.example.com/api/dex/callback` for Dex.
2. For CLI sign-in with native OIDC, also allow `http://localhost:8085/auth/callback`. `argocd login --sso` listens on port 8085 by default (`--sso-port`). Set `cliClientID` in `oidc.config` if the CLI uses a separate public client.
3. Make the provider emit a `groups` claim that contains the groups from `platform.groups` in `clusters/<name>/cluster.yaml` (defaults `platform-admins`, `deployers`, `viewers`).
4. Store the client secret in OpenBao and deliver it to the `argocd` namespace with an `ExternalSecret` that sets the required label. The store name is a placeholder for a `ClusterSecretStore` that accepts requests from `argocd`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-oidc
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: CHANGE_ME
  target:
    name: argocd-oidc
    creationPolicy: Owner
    template:
      metadata:
        labels:
          app.kubernetes.io/part-of: argocd
  data:
    - secretKey: clientSecret
      remoteRef:
        key: platform/argocd/oidc
        property: clientSecret
```

How ESO and OpenBao fit together is described in [secrets handling](secrets-handling.md#reference-external-secrets-operator-with-openbao).

## Option 1: native OIDC

Use this when the identity provider speaks OIDC and returns groups in the ID token. Dex is not needed.

```yaml
argo-cd:
  global:
    domain: argocd.example.com
  dex:
    enabled: false
  configs:
    cm:
      url: https://argocd.example.com
      oidc.config: |
        name: SSO
        issuer: https://login.example.com
        clientID: CHANGE_ME
        clientSecret: $argocd-oidc:clientSecret
        requestedScopes: ["openid", "profile", "email", "groups"]
        requestedIDTokenClaims: {"groups": {"essential": true}}
    params:
      server.insecure: true
```

If the provider's certificate is not signed by a public CA, add its root certificate as `rootCA` in `oidc.config`. Do not switch off TLS verification.

## Option 2: Dex with the GitHub connector

Use this when GitHub organisation teams are the source of groups. Dex runs next to Argo CD and handles the GitHub OAuth flow.

```yaml
argo-cd:
  global:
    domain: argocd.example.com
  dex:
    enabled: true
  configs:
    cm:
      url: https://argocd.example.com
      dex.config: |
        connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: CHANGE_ME
              clientSecret: $argocd-dex-github:clientSecret
              orgs:
                - name: YOUR_ORG
                  teams:
                    - platform-admins
                    - deployers
                    - viewers
              teamNameField: slug
    params:
      server.insecure: true
```

`orgs` is a list of objects. Each entry has a `name` and an optional `teams` list. When `teams` is set, only members of those teams can sign in, and only those teams are returned as groups. The GitHub connector emits groups as `<org>:<team>`, with the team slug because of `teamNameField: slug`. Set `platform.groups` in the cluster file to that form, for example `YOUR_ORG:platform-admins`, so that the role mapping below matches. `platform.groups` also names the groups in the Kubernetes RBAC bindings, so the API server authenticator must deliver the same names. The Secret `argocd-dex-github` with key `clientSecret` is delivered the same way as `argocd-oidc` above. Details of the connector are in the [Dex GitHub connector documentation](https://dexidp.io/docs/connectors/github/).

## TLS termination at the Gateway

TLS ends at Gateway `platform`, which serves the certificate `platform-tls`. `configs.params` sets `server.insecure: true`, so `argocd-server` serves plain HTTP to the Gateway instead of a second, self-signed TLS layer. The trade-off is listed in [known limitations](known-limitations.md#argo-cd-traffic-behind-the-gateway-is-not-encrypted-inside-the-cluster). Use `--grpc-web` with the CLI, so its calls pass through the Gateway as ordinary HTTP requests.

## Group to role mapping

The chart renders `argocd-rbac-cm` from `platform.groups` in the cluster file. With the default group names, the result is:

| Group (`platform.groups` key) | Argo CD role | Rights |
| --- | --- | --- |
| `platform-admins` (`admins`) | `role:admin` | Built-in role: everything |
| `deployers` (`deployers`) | `role:deployer` | Get, sync, run resource actions and read logs for Applications in `apps-dev`, `apps-stage`, `apps-prod`; get on those projects. In `platform`, only get on Applications, through the AppProject role `viewers` |
| `viewers` (`viewers`) | `role:readonly` | Built-in role: read everything |
| Any other signed-in user | none | `policy.default` is empty, so no rights |
| Project role `ci` in each app project | defined in the AppProject, not in `policy.csv` | Get Applications of that project only; tokens with an expiry, no login |

The rendered `argocd-rbac-cm` is equivalent to the block below, written in the upstream `configs.rbac` form. The wrapper does not read these keys (`configs.rbac.create` is `false`); change the group names through `platform.groups` and the projects through `rbac.appProjects`, not by copying this block.

```yaml
argo-cd:
  configs:
    rbac:
      policy.default: ""
      scopes: "[groups]"
      policy.csv: |
        p, role:deployer, applications, get, apps-dev/*, allow
        p, role:deployer, applications, sync, apps-dev/*, allow
        p, role:deployer, applications, action/*, apps-dev/*, allow
        p, role:deployer, logs, get, apps-dev/*, allow
        p, role:deployer, projects, get, apps-dev, allow
        p, role:deployer, applications, get, apps-stage/*, allow
        p, role:deployer, applications, sync, apps-stage/*, allow
        p, role:deployer, applications, action/*, apps-stage/*, allow
        p, role:deployer, logs, get, apps-stage/*, allow
        p, role:deployer, projects, get, apps-stage, allow
        p, role:deployer, applications, get, apps-prod/*, allow
        p, role:deployer, applications, sync, apps-prod/*, allow
        p, role:deployer, applications, action/*, apps-prod/*, allow
        p, role:deployer, logs, get, apps-prod/*, allow
        p, role:deployer, projects, get, apps-prod, allow
        g, platform-admins, role:admin
        g, deployers, role:deployer
        g, viewers, role:readonly
```

Each Application object is `<project>/<application>`, so a rule on `apps-dev/*` reaches only the Applications of that AppProject. Syncs in `apps-prod` remain subject to the prod sync window. `scopes: "[groups]"` tells Argo CD to match `g` lines against the `groups` claim.

The empty `policy.default` is deliberate: Argo CD grants the default role to every authenticated user and evaluates it first, so a non-empty default cannot be narrowed by a `deny` rule. Read access comes from membership in `viewers` instead.

Check a policy change before it merges, against the rendered policy file or against the live cluster:

```bash
argocd admin settings rbac validate --policy-file policy.csv
argocd admin settings rbac can role:deployer sync applications 'apps-prod/*' --policy-file policy.csv
argocd admin settings rbac can role:deployer sync applications 'platform/*' --namespace argocd
```

Automation has no local account. Each app project defines a read-only role `ci` (`applications, get` on that project only) in `argocd-bootstrap/templates/projects/apps.yaml`. `promote.yml` reads the health of the source Application with a token of that role, created with `argocd proj role create-token apps-<env> ci` and an expiry; see [secret rotation](../operations/secret-rotation.md#argo-cd-api-token-for-ci).

## Verify the login

Verify SSO with a member of each group before the local admin is disabled:

```bash
argocd login argocd.example.com --sso --grpc-web
argocd account get-user-info --grpc-web
argocd account can-i sync applications 'apps-dev/*' --grpc-web
argocd account can-i sync applications 'platform/*' --grpc-web
```

Expected: `get-user-info` shows the user and the groups from the identity provider. A member of `deployers` gets `yes` for `apps-dev/*` and `no` for `platform/*`; a member of `platform-admins` gets `yes` for both. Repeat the check in the UI at `https://argocd.example.com`.

## Disable the local admin

The reference values set:

```yaml
argo-cd:
  configs:
    cm:
      admin.enabled: "false"
```

On a new `reference` cluster, the local admin is therefore off from the first sync. Prepare the client registration, the client secret and the groups claim before `make bootstrap-gitops CLUSTER=reference`, so that SSO works right away; until it does, the admin kubeconfig is the only way in. Alternatively, keep `admin.enabled: "true"` for the first sync and set it to `"false"` in a pull request once the checks above pass. Argo CD manages itself, so the change takes effect when that pull request merges.

If the identity provider fails later, Argo CD keeps syncing from Git; only UI and CLI sign-in stop. To regain access, re-enable the local admin through a pull request, handle its password as described in [secret rotation](../operations/secret-rotation.md), and disable it again once SSO works.
