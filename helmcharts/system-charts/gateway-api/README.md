# gateway-api

Installs every CRD the gateway stack needs, ahead of the controller: the Gateway API standard channel and the Envoy Gateway extension CRDs (EnvoyProxy, ClientTrafficPolicy, BackendTrafficPolicy, SecurityPolicy and others). It renders no workloads.

## Source and versions

| Item | Value |
|---|---|
| Upstream chart | `oci://docker.io/envoyproxy/gateway-crds-helm` |
| Chart version | 1.10.0 (same release as `gateway-helm` in `../envoy-gateway`) |
| Gateway API bundle | v1.6.1, standard channel |

The Gateway API project publishes its CRDs as release manifests, not as a chart. `gateway-crds-helm` is the Envoy Gateway project's packaging of exactly the bundle that Envoy Gateway 1.10 is tested against, so the CRD version always matches the controller.

## What it renders

- 10 Gateway API CRDs (`gateway.networking.k8s.io`), including HTTPRoute, GRPCRoute, TLSRoute, TCPRoute, UDPRoute, ListenerSet, ReferenceGrant and BackendTLSPolicy.
- 8 Envoy Gateway CRDs (`gateway.envoyproxy.io`).
- The upstream `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy and its binding. It rejects experimental-channel CRDs on top of standard ones and CRD downgrades.

`templates/guards.yaml` fails the render if a values change would drop CRDs from the output or switch to the experimental channel.

## Deployment

Argo CD Application `gateway-api`, sync wave 0, project `platform`, destination namespace `envoy-gateway-system` (all objects are cluster-scoped). The Application sets `Prune=false` and `Delete=false` for all of its resources: no sync and no removal of the Application deletes a CRD, because deleting a CRD deletes every Gateway and route in the cluster. `ServerSideApply=true` is required: the CRDs exceed the client-side apply annotation limit.

There is no profile delta; `values-lab.yaml` and `values-reference.yaml` exist for the toolchain convention.

## Upgrades

1. Read the Envoy Gateway release notes and the Gateway API release notes for the bundled version.
2. Bump `gateway-crds-helm` here and `gateway-helm` in `../envoy-gateway/Chart.yaml` to the same version in one change, then run `helm dependency update` in both directories.
3. Diff the rendered CRDs (`helm template gateway-api . | yq '.metadata.annotations'` shows the bundle version).
4. Sync `gateway-api` before `envoy-gateway`; the sync waves do this automatically.

Removing a CRD that upstream dropped is a manual step (`kubectl delete crd ...`) after checking that no objects of that kind remain.
