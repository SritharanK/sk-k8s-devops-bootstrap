# envoy-gateway

Envoy Gateway control plane: the Gateway API implementation of the platform ([ADR 0003](../../../docs/adr/0003-gateway-api-with-envoy-gateway.md)). It watches GatewayClass `envoy` and provisions one Envoy proxy Deployment and Service per Gateway. The shared Gateway itself lives in `../platform-gateway`.

## Source and versions

| Item | Value |
|---|---|
| Upstream chart | `oci://docker.io/envoyproxy/gateway-helm` |
| Chart version | 1.10.0 |
| Controller image | `docker.io/envoyproxy/gateway:v1.10.0` |

## Values

- `gateway-helm.crds.enabled: false`. The bundled CRD subchart installs the experimental Gateway API channel; the CRDs come from `../gateway-api` (standard channel, sync wave 0). `templates/guards.yaml` fails the render if this is switched on.
- The upstream container and pod security contexts meet Pod Security Standards restricted (UID 65532, read-only root filesystem, all capabilities dropped, RuntimeDefault seccomp). Resources are set explicitly.
- The certgen Job (TLS between the control plane and the proxies) is a Helm pre-install and pre-upgrade hook, which Argo CD runs as a PreSync hook on every sync. Its output Secrets are not overwritten once present.

| Setting | lab | reference |
|---|---|---|
| Controller replicas | 1 | 2, leader election, spread over nodes |
| PodDisruptionBudget | minAvailable 0 | minAvailable 1 |

## Deployment

Argo CD Application `envoy-gateway`, sync wave 2, project `platform`, namespace `envoy-gateway-system`. The Application creates the namespace with Pod Security Standards restricted labels.

## Upgrades

Upgrade together with `../gateway-api` (same chart version, one change). Read the Envoy Gateway release notes for API deprecations in `gateway.envoyproxy.io/v1alpha1` and for changes to the proxy Deployment, which Envoy Gateway rolls on upgrade.
