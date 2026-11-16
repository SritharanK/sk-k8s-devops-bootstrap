# network-policies

Baseline NetworkPolicies for the application namespaces (dev, stage and prod) and the platform namespaces. Application namespaces get default-deny in both directions plus DNS egress, nothing else; platform namespaces get default-deny for ingress with explicit allow-lists for the traffic their controllers serve.

| Item | Value |
|---|---|
| Argo CD Application | `network-policies`, project `platform`, sync wave 2 |
| Value files | `values.yaml`, then `values-<profile>.yaml` (`lab`, `reference`; both empty, no delta) |
| Minimum Kubernetes | 1.35 (`kubeVersion` in `Chart.yaml`) |

## Policies

| Namespace type | Policy | Effect |
|---|---|---|
| Application | `default-deny` | Denies all ingress and egress; kept on prune and on Application deletion (`Prune=false,Delete=false`) |
| Application | `allow-dns` | Egress to the cluster DNS pods, UDP and TCP 53 |
| Platform | `default-deny-ingress` | Denies all ingress; egress is not restricted |
| Platform | `allow-same-namespace` | Ingress from pods in the same namespace |
| Platform | `allow-from-monitoring` | Ingress on any port from Prometheus |
| Platform | one per `extraIngress` item | See the table below |

## Trust model for application pods

The platform makes the application namespaces closed by default: no pod can receive a connection, and the only outbound flow is DNS. Each application opens what it needs with its own NetworkPolicy, rendered by the application chart (helm-common) and synced by the application's Argo CD project: ingress on the service port from the gateway namespace when a route is enabled, ingress on the metrics port from the monitoring namespace when metrics are scraped, and any declared extra ingress or egress. NetworkPolicies are additive, so an application can open a flow for its own pods but cannot close the platform baseline. The `restrict-networkpolicy-broad-ingress-audit` policy in the kyverno-policies chart reports application policies that admit every namespace to every pod.

## Platform namespaces

| Namespace | Policy | Pods | Port | Source | Verified against |
|---|---|---|---|---|---|
| `argocd` | `allow-gateway-to-server` | `app.kubernetes.io/name: argocd-server` | TCP 8080 | gateway namespace | argo-cd chart 10.18.0 |
| `cert-manager` | `allow-webhook` | `app.kubernetes.io/name: webhook`, `app.kubernetes.io/component: webhook` | TCP 10250 | any | cert-manager chart v1.21.3 |
| `kyverno` | `allow-webhooks` | `app.kubernetes.io/part-of: kyverno` | TCP 9443 | any | kyverno chart 3.10.0 |
| `envoy-gateway-system` | `allow-proxy-traffic` | Envoy proxy pods (`app.kubernetes.io/component: proxy`, `app.kubernetes.io/managed-by: envoy-gateway`) | any | any | Envoy Gateway v1.10.0 |
| `envoy-gateway-system` | `allow-controller-webhook` | `control-plane: envoy-gateway` | TCP 9443 | any | gateway-helm chart 1.10.0 |

Admission webhooks admit any source on the webhook port: the API server calls them from the host network, which namespace and pod selectors cannot match. The proxies are the cluster edge and admit any source on any port. The proxies (xDS, Wasm modules) and the rate limit service reach the controller inside `envoy-gateway-system`, which is why `allowSameNamespace` must stay true there.

Egress is open in platform namespaces. The controllers talk to the API server, whose endpoints are on the host network, and to image registries, ACME servers and Git hosts outside the cluster. A portable NetworkPolicy cannot select the API server endpoints; an `ipBlock` for node addresses is cluster specific, and restricting it properly needs CNI-specific policy (a Calico policy that matches the `default/kubernetes` Service, or a `CiliumNetworkPolicy` with the `kube-apiserver` entity). The accepted risk: a compromised platform pod can open outbound connections, but other namespaces can reach it only through the rules above.

## Values

| Key | Default | Source |
|---|---|---|
| `environments` | `dev`, `stage`, `prod` | injected |
| `dns.namespace`, `dns.podSelector` | `kube-system`, `k8s-app: kube-dns` | chart default |
| `gateway.namespace` | `envoy-gateway-system` | injected (source of the Argo CD server rule) |
| `monitoring.namespace` | `monitoring` | injected |
| `monitoring.podSelector` | `app.kubernetes.io/name: prometheus` | chart default |
| `platformNamespaces.<key>.enabled`, `.namespace` | `true`; `argocd`, `cert-manager`, `kyverno`, `envoy-gateway-system` | injected |
| `platformNamespaces.<key>.allowSameNamespace`, `.allowFromMonitoring`, `.extraIngress` | `true`, `true`, see above | chart default |

Injected keys are set from `clusters/<name>/cluster.yaml` by `argocd-bootstrap/templates/toolchains/network-policies.yaml` through `helm.valuesObject`. Helm merges maps, so an injected `environments` adds to the defaults; set a default key to `null` to remove it. An `extraIngress` item takes `name`, `podSelector`, optional `ports` (omitted: all ports) and optional `from` (omitted: any source). `from` is rendered through `tpl`, so it can reference other values such as `{{ .Values.gateway.namespace }}`.

## Requirements and limits

- The CNI must enforce NetworkPolicy: Calico or Canal on RKE2, Calico or Cilium on kind. Flannel alone does not; the API server accepts the objects and nothing is enforced.
- CoreDNS must carry `k8s-app: kube-dns` (kubeadm manifests used by kind, rke2-coredns chart). With NodeLocal DNSCache the DNS destination is a host-network pod that the pod selector does not match; add an `ipBlock` rule for the cache address in that case.
- The selectors for platform pods follow upstream labels. Re-check them on every upstream chart upgrade: `helm template` the new chart version and compare the pod labels and container ports with the table above.
