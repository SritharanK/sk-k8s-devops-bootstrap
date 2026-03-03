# Argo CD SSO (OIDC)

Enable SSO so users log in via your identity provider instead of the local admin password.

## Options

1. **Argo CD native OIDC** — Configure `server.config` with your OIDC provider (e.g. GitHub, GitLab, Okta, Azure AD).
2. **Dex** — Argo CD chart can deploy Dex as a sidecar; configure `dex.config` in values.

## Steps (outline)

1. In your IdP, register an OAuth application and note: **Client ID**, **Client Secret**, **Issuer URL** (or authorization/token endpoints).
2. Set Argo CD server URL: `server.config.url` in values (e.g. `https://argocd.YOUR_DOMAIN`).
3. Add to `values-production.yaml` (or a dedicated `values-oidc-example.yaml`):

   ```yaml
   server:
     config:
       url: https://argocd.YOUR_DOMAIN
       dex.config: |
         connectors:
           - type: github
             id: github
             name: GitHub
             config:
               clientID: YOUR_CLIENT_ID
               clientSecret: $oidc.github.clientSecret
               orgs:
                 - YOUR_ORG
   ```

   Use a secret for `clientSecret` (e.g. sealed secret or external secrets); do not commit the raw value.

4. Or use native OIDC: `server.config.oidc.config` with your provider’s issuer and client credentials.

See [Argo CD SSO documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/) for full details.

## Placeholders in repo

- `helmcharts/system-charts/argo-cd/values-production.yaml` may include a commented block for Dex/OIDC (clientID, clientSecret, issuer URL). Fill these via CI/CD or a secret manager; do not commit real client secrets.
