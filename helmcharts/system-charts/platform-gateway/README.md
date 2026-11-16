# platform-gateway

The shared edge of the platform ([ADR 0003](../../../docs/adr/0003-gateway-api-with-envoy-gateway.md)). Every application and the Argo CD UI attach an HTTPRoute to Gateway `platform`. This chart has no upstream dependency; it renders platform-owned objects against the CRDs from `../gateway-api` and `../cert-manager`.

## What it renders

| Object | Name | Purpose |
|---|---|---|
| GatewayClass | `envoy` | Bound to the Envoy Gateway controller, parameters from EnvoyProxy `platform` |
| EnvoyProxy | `platform` | Proxy replicas, resources, Service type and node ports, disruption budget |
| Gateway | `platform` | Listener `http` (80) and listener `https` (443, hostname `*.<domain>`, TLS terminated) |
| Certificate | `platform-tls` | Secret `platform-tls` for the https listener |
| HTTPRoute | `platform-https-redirect` | Redirects every plain HTTP request to HTTPS (301) |
| ClientTrafficPolicy | `platform-edge` | TLS 1.2 minimum, rejects headers with underscores, client address handling |

Every object carries `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, because its CRD comes from another Application.

## Contract for routes

Application routes use the https listener:

```yaml
parentRefs:
  - name: platform
    namespace: envoy-gateway-system
    sectionName: https
hostnames:
  - hello-api.dev.localtest.me
```

- The https listener accepts routes from all namespaces. The http listener accepts routes from `envoy-gateway-system` only: plain HTTP exists to redirect, and to serve ACME HTTP-01 challenges for certificates issued in that namespace.
- Hostnames follow `<app>.<env>.<domain>` and `argocd.<domain>`.

## Certificate names

The Certificate comes from the ClusterIssuer named in `platform.issuer`; the issuers belong to the `misc` chart. Its dnsNames depend on the issuer:

| Issuer | `platform.acme.solver` | dnsNames |
|---|---|---|
| `selfsigned` (or any non-ACME issuer) | ignored | `<domain>`, `*.<domain>`, `*.<env>.<domain>` for every entry in `platform.environments` |
| `letsencrypt-staging`, `letsencrypt` | `dns01` | same wildcard list |
| `letsencrypt-staging`, `letsencrypt` | `http01` (default) | exactly `platform.gateway.hostnames`, no wildcard |

A wildcard covers one DNS label, which is why every environment gets its own `*.<env>.<domain>`. Let's Encrypt issues wildcards only through DNS-01, so the HTTP-01 mode lists explicit names. The render fails when the http01 list is empty, contains a wildcard, or contains a name outside `platform.domain` (the https listener would not serve it). HTTP-01 challenges reach cert-manager's solver HTTPRoute, which it creates in `envoy-gateway-system` on the `http` listener; the listener's `from: Same` admits it, and its exact path takes precedence over the redirect.

With `selfsigned` the Secret contains `ca.crt`, the platform root CA, which clients can trust.

## Edge behaviour

ingress-nginx is retired. The configuration that replaced it drops the old edge settings on purpose:

- No configuration snippets of any kind. The redirect is a standard Gateway API filter.
- `X-Forwarded-For` is not trusted by default: the client address is the TCP peer. Set `clientTraffic.xForwardedFor` (`numTrustedHops` or `trustedCIDRs`) only when a load balancer you control sits in front of the gateway.
- Headers with underscores are rejected (`RejectRequest`), which prevents header smuggling through underscore and dash normalisation.

## Profiles

| Setting | lab | reference |
|---|---|---|
| Proxy Service | NodePort, listener `http` on 30080, `https` on 30443, externalTrafficPolicy Cluster | LoadBalancer, externalTrafficPolicy Local |
| Proxy replicas | 1 | 2, spread over nodes (DoNotSchedule) |
| Proxy disruption budget | none | minAvailable 1 |

In lab, kind maps host ports 80 and 443 to the node ports and `*.localtest.me` resolves to 127.0.0.1. The reference profile needs a load balancer implementation (for example kube-vip or MetalLB) or an external load balancer that targets the node ports.

## Deployment

Argo CD Application `platform-gateway`, sync wave 3, project `platform`, namespace `envoy-gateway-system`. The Application passes `platform.domain`, `platform.environments`, `platform.issuer`, `platform.acme` and `platform.gateway.hostnames` from the cluster definition through `helm.valuesObject`.

## Checks

```bash
kubectl -n envoy-gateway-system get gateway platform
kubectl -n envoy-gateway-system wait gateway/platform --for=condition=Programmed --timeout=5m
kubectl -n envoy-gateway-system get secret platform-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > platform-ca.crt
curl --cacert platform-ca.crt https://hello-api.dev.localtest.me/readyz
```
