# cert-manager

cert-manager controller with its CRDs and Gateway API support. It issues the certificate of the platform Gateway and internal TLS certificates (for example OpenBao).

## Source and versions

| Item | Value |
|---|---|
| Upstream chart | `oci://quay.io/jetstack/charts/cert-manager` |
| Chart and app version | v1.21.3 |

This replaces a vendored copy whose templates and CRDs were v1.14.2 under a v1.16.2 label; see [ADR 0007](../../../docs/adr/0007-wrapper-charts-instead-of-vendoring.md).

## Values

- `crds.enabled: true` and `crds.keep: true`. The CRDs are part of the release and carry `helm.sh/resource-policy: keep`, which Argo CD treats as `Delete=false`: deleting the Application never deletes the CRDs and, with them, every Certificate and Issuer. `templates/guards.yaml` fails the render if either value is switched off.
- `config.enableGatewayAPI: true`. ACME HTTP-01 solvers can attach HTTPRoutes to a Gateway, and the Gateway annotation shim is active. The Gateway API CRDs come from `../gateway-api` in the same sync wave; if cert-manager starts first, it restarts until they exist.
- `global.leaderElection.namespace: cert-manager`, so the release needs no Role in `kube-system`.
- Metrics endpoints stay on, but `prometheus.servicemonitor.enabled` is false and no other chart creates a ServiceMonitor or PodMonitor for cert-manager. Prometheus therefore does not scrape cert-manager, and the cert-manager alerts of the `monitoring` chart have no data until a ServiceMonitor with the label `release: monitoring` is added.

## ClusterIssuers

This chart renders no issuers. The ClusterIssuers `selfsigned` (a CA issuer backed by a self-signed root, signed by `selfsigned-bootstrap`), `letsencrypt-staging` and `letsencrypt`, and the root CA Certificate, belong to the `misc` chart, so exactly one Application owns them. The issuer names are the values allowed for `platform.issuer` in the cluster definition.

## Profiles

| Setting | lab | reference |
|---|---|---|
| Controller, webhook, cainjector replicas | 1 | 2 each, spread over nodes |
| PodDisruptionBudgets | none | minAvailable 1 each |

## Deployment

Argo CD Application `cert-manager`, sync wave 0, project `platform`, namespace `cert-manager` (created with Pod Security Standards restricted labels).

## Upgrades

cert-manager supports upgrades one minor version at a time. For each minor: read the upgrade notes at <https://cert-manager.io/docs/releases/>, bump the dependency in `Chart.yaml`, run `helm dependency update`, diff `helm template` output (CRDs included), and back up Certificates and Issuers first (`kubectl get certificates,issuers,clusterissuers -A -o yaml`).
