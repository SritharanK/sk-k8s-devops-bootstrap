---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# Gateway API with Envoy Gateway for ingress

This record explains how HTTP traffic enters the cluster and why the platform uses Envoy Gateway as its Gateway API implementation. It is for operators and for app owners who expose a service.

## Context and problem statement

Apps and platform UIs need HTTP and HTTPS entry with certificates from cert-manager, host-based routing per environment (`<app>.<env>.<domain>`), and weighted traffic splitting for canary releases. The ingress-nginx project is retired: best-effort maintenance ended in March 2026, with no further releases or security fixes. RKE2 deploys Traefik as its default ingress controller from v1.36 and removes ingress-nginx for new clusters in v1.37. The entry configuration must behave the same on kind (`lab`) and on RKE2 (`reference`).

Which API and which implementation should carry north-south traffic?

## Decision drivers

- Conformance to Gateway API, so routes stay portable between implementations.
- Independence from the CNI: the `reference` profile supports `canal`, `calico` and `cilium`, and the kind demo runs Calico.
- Identical installation and behaviour on kind and on RKE2, as an ordinary Argo CD toolchain.
- Support in the Argo Rollouts Gateway API plugin for canary traffic splitting.
- cert-manager integration for listener certificates.
- An actively maintained project with open governance.

## Considered options

- Gateway API with Envoy Gateway
- Gateway API with Traefik (the RKE2 default since v1.36)
- Gateway API with Cilium Gateway
- Gateway API with NGINX Gateway Fabric
- Stay on ingress-nginx with the Ingress API

## Decision outcome

Chosen option: "Gateway API with Envoy Gateway", because it meets every driver, installs the same way on kind and on RKE2, and Gateway API is its primary configuration API rather than one provider among several.

Conformance and plugin support do not separate the four Gateway API options. On 2026-11-16 the Gateway API implementations page listed all four as conformant, and the Rollouts plugin's provider status page listed all four as tested. CNI independence and identical behaviour across profiles decide.

The platform layout:

- The Gateway API CRDs install in wave 0, the `envoy-gateway` toolchain in wave 2, and the `platform-gateway` chart in wave 3.
- GatewayClass `envoy`. Gateway `platform` in namespace `envoy-gateway-system`, with listeners `http` (80) and `https` (443). The `https` listener uses the certificate `platform-tls` described [below](#tls-certificate) and accepts routes from all namespaces. The `http` listener accepts routes only from `envoy-gateway-system`: it serves the platform redirect to HTTPS (301) and the ACME HTTP-01 challenge routes, so app routes cannot attach to plain HTTP.
- Apps attach an HTTPRoute through the helm-common keys `route.enabled`, `route.hostnames[]` and `route.parentRefs[]`. The default parent is Gateway `platform`, section `https`. The Argo CD UI uses an HTTPRoute at `argocd.<domain>`.
- The RKE2 role sets `ingress-controller: none` ([ADR 0001](0001-rke2-only.md)). In `lab`, `*.localtest.me` resolves to 127.0.0.1 and kind maps host ports 80 and 443. In `reference` on bare metal, the Envoy Service of type LoadBalancer needs a load balancer implementation, for example MetalLB or the kube-vip cloud provider, or NodePorts behind an external load balancer.

### TLS certificate

The Gateway serves one Certificate, `platform-tls` (Secret `platform-tls`), in `envoy-gateway-system`, referenced by the `https` listener of Gateway `platform`. The ClusterIssuer names equal the values of `platform.issuer`: `selfsigned`, `letsencrypt-staging` and `letsencrypt`. The ClusterIssuers and the root CA come from one owner, the `misc` chart (`helmcharts/system-charts/misc`).

Two facts constrain the names on the certificate. Let's Encrypt issues wildcard certificates only through the DNS-01 challenge. A wildcard covers one label only, so `*.<domain>` does not cover `<app>.<env>.<domain>`. The names therefore depend on the issuer and the ACME solver:

| Issuer and solver | Names on `platform-tls` |
| --- | --- |
| `selfsigned` (lab default) | `<domain>`, `*.<domain>` and `*.<env>.<domain>` for every environment |
| ACME with `platform.acme.solver: dns01` | `<domain>`, `*.<domain>` and `*.<env>.<domain>` for every environment |
| ACME with `platform.acme.solver: http01` (default for ACME) | The explicit list `platform.gateway.hostnames[]`, required in this mode; no wildcard. The render fails when the list is empty, contains a wildcard or names a host outside `cluster.domain`. |

- `selfsigned` is CA-backed: a CA certificate bootstrapped from the ClusterIssuer `selfsigned-bootstrap` signs `platform-tls`, so the Secret `platform-tls` carries `ca.crt`, which clients of the lab can trust.
- With `http01`, the ClusterIssuer uses the cert-manager `gatewayHTTPRoute` solver with the parent Gateway `platform`, namespace `envoy-gateway-system`, section `http`. The Kyverno `PolicyException` for ACME solver pods stays in place for this mode.
- With `dns01`, `platform.acme.dns01` holds the DNS provider block with placeholders only; credentials come from a Secret reference, never inline.

### Consequences

- Good, because one routing API serves apps, the Argo CD UI and canary releases, with the same HTTPRoute on both profiles.
- Good, because responsibilities split cleanly: the platform owns the Gateway and its certificate, app owners own the HTTPRoutes in their namespace.
- Good, because no retired controller remains on any default path.
- Good, because the optional `argo-rollouts` toolchain (off by default) can shift weights on the app's HTTPRoute (`rollout.trafficRouting.gatewayAPI.httpRoute`) through the Gateway API plugin `argoproj-labs/gatewayAPI`.
- Bad, because the shared Gateway accepts routes from every namespace, so one namespace can claim a hostname meant for another. Gateway API precedence rules decide conflicts; the Gateway does not prevent them.
- Bad, because Envoy Gateway runs a controller plus one Envoy proxy Deployment per Gateway: two components to size, monitor and upgrade.
- Bad, because each profile needs its own way to expose the Envoy proxy Service: host port mappings on kind; on bare-metal RKE2, a load balancer implementation such as MetalLB or the kube-vip cloud provider, or NodePorts behind an external load balancer. The repository installs none of these; the operator provides one.
- Bad, because the Envoy Gateway policy CRDs (for example ClientTrafficPolicy, BackendTrafficPolicy and SecurityPolicy) are implementation-specific. Routes that use them are tied to Envoy Gateway.
- Bad, because the Gateway API support in cert-manager is still marked beta.
- Bad, because with an ACME issuer and the default `http01` solver the certificate has no wildcard: every host name the Gateway serves must be listed in `platform.gateway.hostnames[]`, and a new app host name needs that change before its route serves a matching certificate. Wildcard names need `dns01`, which puts a DNS provider credential in the cluster.
- Good, because one certificate and one Secret name (`platform-tls`) serve every profile and issuer, so the Gateway, the lab CA export and the end-to-end checks do not depend on the issuer.
- Neutral, because teams used to Ingress annotations need to learn HTTPRoute, `parentRefs` and section names.

### Confirmation

- The `argocd-bootstrap` job renders helm-common and the app charts and validates the HTTPRoutes with kubeconform against the Gateway API CRD schemas.
- The `e2e-kind` job reaches `hello-api` through the Gateway.
- Review: the output of `make render` contains no `Ingress` objects and no ingress-nginx chart.

## Pros and cons of the options

### Gateway API with Envoy Gateway

- Good, because Gateway API is its primary API, and it is listed as conformant.
- Good, because it is a subproject of Envoy, a CNCF graduated project.
- Good, because it is independent of the CNI and installs from a Helm chart on any cluster.
- Good, because route changes reach the proxies over xDS without restarting them.
- Bad, because it adds managed proxy Deployments next to its controller.
- Bad, because its extension CRDs are implementation-specific.

### Gateway API with Traefik (the RKE2 default since v1.36)

- Good, because RKE2 deploys it by default from v1.36, and it is conformant and tested with the Rollouts plugin.
- Bad, because the bundled copy follows RKE2 releases and RKE2 configuration, outside Argo CD, while kind needs a separate installation path. The two profiles would differ.
- Bad, because Gateway API is one provider next to its own IngressRoute CRDs and its Ingress provider, and much of its documentation uses the Traefik-specific CRDs.
- Neutral, because it could also run as a toolchain like Envoy Gateway, but then the RKE2 default brings no benefit.

### Gateway API with Cilium Gateway

- Good, because it reuses the Envoy proxy that Cilium already runs on each node, and it is conformant and tested with the Rollouts plugin.
- Bad, because it requires Cilium with kube-proxy replacement, so clusters on `canal` or `calico` cannot use it.
- Bad, because ingress upgrades become CNI upgrades.

### Gateway API with NGINX Gateway Fabric

- Good, because it is conformant, independent of the CNI and tested with the Rollouts plugin.
- Good, because teams that know NGINX recognise the data plane.
- Bad, because it offers no advantage over Envoy Gateway for the drivers above, and it is developed mainly by one vendor.
- Neutral, because it is a separate codebase from ingress-nginx, so moving to it is a migration, not an upgrade.

### Stay on ingress-nginx with the Ingress API

- Good, because it needs no migration.
- Bad, because the project is retired and receives no fixes after March 2026, after a history of critical vulnerabilities such as CVE-2025-1974.
- Bad, because RKE2 removes it for new clusters in v1.37.
- Bad, because the Ingress API has no standard traffic splitting; canaries depend on controller annotations.

## More information

Upstream sources, checked on 2026-11-16:

- ingress-nginx retirement: <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>
- CVE-2025-1974: <https://kubernetes.io/blog/2025/03/24/ingress-nginx-cve-2025-1974/>
- RKE2 networking services (Traefik default from v1.36, `ingress-controller: none`): <https://docs.rke2.io/networking/networking_services>
- Gateway API implementations and conformance: <https://gateway-api.sigs.k8s.io/implementations/>
- Argo Rollouts Gateway API plugin, provider status: <https://rollouts-plugin-trafficrouter-gatewayapi.readthedocs.io/en/latest/provider-status/>
- cert-manager Gateway API support: <https://cert-manager.io/docs/usage/gateway/>
- cert-manager HTTP-01 solver, including the Gateway API solver: <https://cert-manager.io/docs/configuration/acme/http01/>
- Let's Encrypt challenge types (wildcards only through DNS-01): <https://letsencrypt.org/docs/challenge-types/>
- MetalLB: <https://metallb.io/> and kube-vip: <https://kube-vip.io/>
- Envoy Gateway: <https://gateway.envoyproxy.io/>
- Traefik Gateway API provider: <https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/>
- Cilium Gateway API prerequisites: <https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/>
- NGINX Gateway Fabric: <https://github.com/nginx/nginx-gateway-fabric>

Related pages and decisions:

- [Architecture overview](../architecture/overview.md) and [helm-common values](../reference/helm-common-values.md)
- [Security controls](../security/controls.md)
- [ADR 0001: RKE2 as the only provisioner](0001-rke2-only.md)
- [ADR 0005: lab and reference profiles](0005-lab-and-reference-profiles.md)
