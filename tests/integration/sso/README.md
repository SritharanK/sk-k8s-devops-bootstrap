# SSO integration test (Argo CD with an OIDC provider)

Local substitute for the acceptance check of [Argo CD SSO](../../../docs/security/argocd-sso.md). Dex plays the identity provider in a throwaway kind cluster, and the Argo CD API is exercised with real OIDC ID tokens, one per platform group.

```bash
tests/integration/sso/run.sh
```

Requirements: Docker, kind, kubectl, helm, yq (v4), jq, curl, openssl, htpasswd, python3, git. About 1.5 GB of free Docker memory. The run takes about two minutes with cached images and deletes its cluster on exit (`KEEP_CLUSTER=1` keeps it). It exits non-zero when any check fails.

Last result (2026-11-16, Argo CD v3.6.1, Dex v2.46.1, Kubernetes v1.36.4): 37 checks passed, 0 failed.

## What the run does

1. Creates kind cluster `it-sso` (single node, `kindest/node:v1.36.4`, pinned by digest). An existing cluster of that name is deleted first.
2. Generates a random OIDC client secret and one random password per user. Nothing secret is committed; the files live in a private temporary directory removed on exit.
3. Installs Dex v2.46.1 (chart `oci://ghcr.io/dexidp/helm-charts/dex` 0.26.0) with static users whose `groups` come from `platform.groups` in `clusters/lab/cluster.yaml`:

   | User | Group |
   | --- | --- |
   | `sso-admin@example.com` | `platform.groups.admins` |
   | `sso-deployer@example.com` | `platform.groups.deployers` |
   | `sso-viewer@example.com` | `platform.groups.viewers` |
   | `sso-nogroup@example.com` | none |

4. Installs Argo CD from `helmcharts/system-charts/argo-cd` with `values.yaml`, `values-lab.yaml`, the test values in this directory (`values-sso.yaml`: local admin off as in reference, no Gateway route) and a generated file with the `oidc.config` block of `values-reference.yaml`. Only its two `CHANGE_ME` placeholders (issuer, client ID) are replaced by the test Dex, so the reference block itself is under test, including the client secret reference `$argocd-oidc:clientSecret` and the requested `groups` claim. The client secret is delivered as Secret `argocd-oidc` with label `app.kubernetes.io/part-of: argocd`, as in the reference profile.
5. Applies the AppProjects `apps-dev`, `apps-stage`, `apps-prod` and `platform` rendered from `argocd-bootstrap` with the lab cluster definition, and probe Applications in `apps-dev` and `platform`. The probes pin a commit SHA, so a sync request never needs Git access; that the controller later cannot fetch the placeholder repository does not affect the checks.
6. Obtains ID tokens through the Dex password grant and a token for the `ci` role of project `apps-dev` (created by the admin through the API), then calls the Argo CD API with each token. An allowed call must return 200. A denied call must return 403 with "permission denied" in the body, so a denial by another guard (for example a sync window) does not count.

## What it proves

- Argo CD 3.6.1 accepts the reference `oidc.config`: issuer discovery, client secret lookup from a separate Secret, and validation of externally issued ID tokens (signature from the provider's keys, issuer, audience equal to the client ID).
- The `groups` claim reaches Argo CD (`/api/v1/session/userinfo`) and maps to roles through the `argocd-rbac-cm` that the wrapper renders from `platform.groups`.
- RBAC per group, against the real AppProject roles of the root chart:
  - admins: get, sync and delete Applications in any project, list clusters, create and delete projects;
  - deployers: get and sync in `apps-*`; get but not sync in `platform` (the platform `viewers` project role, bound to viewers and deployers); no delete, no project creation, no clusters;
  - viewers: get everywhere, no sync, no delete, no project creation;
  - a user without a group: nothing, because `policy.default` is empty;
  - anonymous requests are rejected.
- The `ci` project role token (the single read-only CI identity) can get Applications of its own project only, and cannot sync or delete.

## What it does not prove

Only a run against the real identity provider (for example Entra ID) can prove:

- The browser login (authorization code flow with PKCE) and `argocd login --sso`: the redirect URI `https://<global.domain>/auth/callback` registered at the provider, consent, and the Gateway route with TLS in front of Argo CD. This test calls the API with tokens only.
- The provider's group claim format: Entra ID emits group object IDs unless configured otherwise, and replaces the claim with an overage reference when a user is in more than 200 groups. `platform.groups` must hold exactly the values the provider emits.
- Issuer reachability and TLS: Dex here is plain HTTP inside the cluster. A real issuer is HTTPS, may need egress through a proxy, and its CA must be trusted by `argocd-server`.
- Token lifetime, signing key rotation, conditional access and multi-factor policies of the provider.
- Delivery of the client secret through External Secrets Operator in the reference profile; here the test creates the Secret directly.
- The reference profile's high availability: Argo CD runs with the lab profile here, plus the reference OIDC block and admin setting.

The password grant used to obtain tokens is enabled on the test Dex only. It must never be enabled on a production identity provider.
