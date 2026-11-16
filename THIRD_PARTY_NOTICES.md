# Third-party notices

The code and documentation in this repository are licensed under the [MIT License](LICENSE), unless a file states otherwise.

The platform installs and uses third-party software that is not part of this repository and is not covered by its licence. Each component keeps its upstream licence. This file lists those components so that operators can check their licence obligations.

How third-party software is used here:

- Platform components are consumed as pinned Helm chart dependencies of thin wrapper charts under `helmcharts/system-charts/`. The upstream chart archives are fetched by `helm dependency build` and are not committed (`charts/` directories are ignored). Container images are pulled from the upstream registries at deploy time.
- Two exceptions are vendored, because upstream publishes no Helm repository for them: the local-path-provisioner chart in `helmcharts/system-charts/local-path/vendor/local-path-provisioner`, and the system-upgrade-controller release manifests in `helmcharts/system-charts/system-upgrade-controller/upstream/`. No other upstream chart or application source code is vendored into this repository.
- The exact version of every chart and image is listed in the generated [support matrix](docs/reference/support-matrix.md).

The licences below are those declared by each upstream project. Check the upstream repository at the pinned version before you redistribute any component.

## Platform components

| Component | Upstream project | Licence | Used as |
| --- | --- | --- | --- |
| Argo CD | <https://github.com/argoproj/argo-cd> | Apache-2.0 | Helm chart (argo-helm) and images |
| Gateway API CRDs | <https://github.com/kubernetes-sigs/gateway-api> | Apache-2.0 | CRDs, installed through the Envoy Gateway `gateway-crds-helm` chart |
| Envoy Gateway | <https://github.com/envoyproxy/gateway> | Apache-2.0 | Helm chart and images (includes Envoy Proxy, Apache-2.0) |
| cert-manager | <https://github.com/cert-manager/cert-manager> | Apache-2.0 | Helm chart and images |
| Kyverno | <https://github.com/kyverno/kyverno> | Apache-2.0 | Helm chart and images |
| Sealed Secrets | <https://github.com/bitnami-labs/sealed-secrets> | Apache-2.0 | Helm chart and images (`lab` profile) |
| External Secrets Operator | <https://github.com/external-secrets/external-secrets> | Apache-2.0 | Helm chart and images (`reference` profile) |
| OpenBao | <https://github.com/openbao/openbao> | MPL-2.0 | Helm chart and images (`reference` profile) |
| NFS subdir external provisioner | <https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner> | Apache-2.0 | Helm chart and images (optional, off by default) |

## Optional components

These are off by default and enabled per cluster in `clusters/<name>/cluster.yaml`.

| Component | Upstream project | Licence | Used as |
| --- | --- | --- | --- |
| kube-prometheus-stack (Prometheus Operator, Prometheus, Alertmanager) | <https://github.com/prometheus-community/helm-charts> | Apache-2.0 | Helm chart and images |
| Grafana | <https://github.com/grafana/grafana> | AGPL-3.0 | Image, through kube-prometheus-stack |
| Grafana Alloy | <https://github.com/grafana/alloy> | Apache-2.0 | Helm chart and images |
| Grafana Loki | <https://github.com/grafana/loki> | AGPL-3.0 | Helm chart and images |
| Grafana Tempo | <https://github.com/grafana/tempo> | AGPL-3.0 | Helm chart and images |
| Sloth | <https://github.com/slok/sloth> | Apache-2.0 | Development-time CLI; the rules it generates are committed in `helmcharts/system-charts/slo/rules/` |
| Velero | <https://github.com/vmware-tanzu/velero> | Apache-2.0 | Helm chart and images |
| SeaweedFS | <https://github.com/seaweedfs/seaweedfs> | Apache-2.0 | Helm chart and images (`lab` S3 target for backups) |
| Argo Rollouts | <https://github.com/argoproj/argo-rollouts> | Apache-2.0 | Helm chart and images |
| Argo Rollouts Gateway API plugin | <https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi> | Apache-2.0 | Plugin binary loaded by Argo Rollouts |
| system-upgrade-controller | <https://github.com/rancher/system-upgrade-controller> | Apache-2.0 | Manifests and images |
| Longhorn | <https://github.com/longhorn/longhorn> | Apache-2.0 | Helm chart and images |
| local-path-provisioner | <https://github.com/rancher/local-path-provisioner> | Apache-2.0 | Helm chart and images |
| CloudNativePG | <https://github.com/cloudnative-pg/cloudnative-pg> | Apache-2.0 | Helm chart and images |
| KEDA | <https://github.com/kedacore/keda> | Apache-2.0 | Helm chart and images |
| OpenCost | <https://github.com/opencost/opencost> | Apache-2.0 | Helm chart and images |
| Falco | <https://github.com/falcosecurity/falco> | Apache-2.0 | Helm chart and images |
| Trivy Operator | <https://github.com/aquasecurity/trivy-operator> | Apache-2.0 | Helm chart and images |
| Jenkins | <https://github.com/jenkinsci/jenkins> | MIT | Installed by the optional `install_jenkins` Ansible role |

Grafana, Loki and Tempo are licensed under the GNU Affero General Public License v3. Running them unmodified inside your own cluster is the intended use; if you modify them and offer them to users over a network, review the AGPL obligations.

## Kubernetes distributions and networking

| Component | Upstream project | Licence | Used as |
| --- | --- | --- | --- |
| RKE2 | <https://github.com/rancher/rke2> | Apache-2.0 | Installed on nodes by the `rke2` Ansible role (`reference` profile) |
| kind | <https://github.com/kubernetes-sigs/kind> | Apache-2.0 | Local cluster for the `lab` profile and CI |
| Gitea | <https://github.com/go-gitea/gitea> | MIT | In-cluster Git server that `make demo` seeds from the local checkout |
| Calico | <https://github.com/projectcalico/calico> | Apache-2.0 | CNI option |
| Cilium | <https://github.com/cilium/cilium> | Apache-2.0 (eBPF programs dual-licensed GPL-2.0 or BSD-2-Clause) | CNI option |

## Sample service dependencies

`sample-services/hello-api` is original code under the MIT License. Its third-party Go modules are listed with their versions in `sample-services/hello-api/go.mod`; the runtime base image is listed below.

| Component | Upstream project | Licence | Used as |
| --- | --- | --- | --- |
| Go standard library | <https://go.dev/> | BSD-3-Clause | Compiled into the binary |
| Prometheus Go client | <https://github.com/prometheus/client_golang> | Apache-2.0 | Go module |
| OpenTelemetry Go | <https://github.com/open-telemetry/opentelemetry-go> | Apache-2.0 | Go module |
| Distroless base images | <https://github.com/GoogleContainerTools/distroless> | Apache-2.0 | Runtime base image, pinned by digest |

## Development and CI tools

These tools are run by the Make targets, the pre-commit hooks and the GitHub Actions workflows. They are not distributed with the repository or with the platform, so their licences do not extend to this repository's code.

| Tool | Licence |
| --- | --- |
| Helm, kubectl, kubeconform, kyverno CLI, cosign, Trivy, Chainsaw, helm-unittest | Apache-2.0 (helm-unittest: MIT) |
| gitleaks, actionlint, zizmor, markdownlint-cli2, yq, Molecule, mise | MIT |
| lychee | Apache-2.0 or MIT |
| shfmt | BSD-3-Clause |
| ShellCheck, hadolint, yamllint, ansible-core, ansible-lint | GPL-3.0 (ansible-core and ansible-lint: GPL-3.0-or-later) |
| OpenTofu | MPL-2.0 |
| GitHub Actions used by the workflows | Pinned by commit SHA in `.github/workflows/`; licence per action repository |
