# preview-namespace

Guardrails of one pull request preview namespace. The `previews-namespaces` ApplicationSet (`argocd-bootstrap/templates/previews/applicationsets.yaml`) renders this chart once per labelled pull request, from `git.targetRevision` and never from the pull request itself; nobody installs it by hand. See [preview environments](../../../docs/how-to/preview-environments.md).

## What it renders

Everything goes into the release namespace, which Argo CD sets to the destination namespace `pr-<number>`.

| Object | Name | Notes |
| --- | --- | --- |
| Namespace | release namespace | Pod Security `restricted` for enforce, audit and warn, pinned to `podSecurity.version` |
| ResourceQuota | `preview-quota` | From `quota`; not rendered when `quota` is empty |
| LimitRange | `preview-limits` | Type Container: `default`, `defaultRequest` and `max` from `limitRange` |
| NetworkPolicy | `default-deny` | Denies all ingress and egress |
| NetworkPolicy | `allow-dns` | Egress UDP and TCP 53 to the pods selected by `dns` |

Every object carries `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`, `app.kubernetes.io/part-of: previews` and, when `pullRequest` is set, `pull-request: "<number>"`.

No object carries `Prune=false` or `Delete=false`. Deleting the Application deletes the Namespace and everything in it, which is how a preview is cleaned up. The environment namespaces (`dev`, `stage`, `prod`) and tenant namespaces work the other way round on purpose.

## Values

Three layers, lowest first. Argo CD applies `valuesObject` after the chart's `values.yaml`.

1. `values.yaml`: defaults.
2. `previews.namespace.values` in `argocd-bootstrap/values.yaml`, with `toolchains.previews.values.namespace.values` from the cluster file merged over it.
3. `pullRequest` and `podSecurity.version` (`v<cluster.kubernetesMinor>`), set by the ApplicationSet.

| Key | Default | Notes |
| --- | --- | --- |
| `pullRequest` | `""` | Pull request number; adds the `pull-request` label |
| `podSecurity.version` | `v1.36` | `v<major>.<minor>` or `latest` |
| `quota` | `requests.cpu` 1, `requests.memory` 1Gi, `limits.cpu` 2, `limits.memory` 2Gi, `pods` 10, `services` 5, `services.loadbalancers` 0, `services.nodeports` 0, `persistentvolumeclaims` 2, `requests.storage` 5Gi | ResourceQuota `spec.hard` |
| `limitRange.default` | 250m, 256Mi | Container limits when a container sets none |
| `limitRange.defaultRequest` | 25m, 32Mi | Container requests when a container sets none |
| `limitRange.max` | 1, 1Gi | Per-container maximum |
| `dns.namespace`, `dns.podSelector` | `kube-system`, `k8s-app: kube-dns` | Same selector as the network-policies chart |

`values.schema.json` validates the merged values on every render.

## Local render

```bash
helm lint --strict helmcharts/app-charts/preview-namespace
helm template x helmcharts/app-charts/preview-namespace -n pr-7 --set pullRequest=7
```
