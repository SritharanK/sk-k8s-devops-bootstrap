# Add an app

This runbook adds a new service to the platform: source and image, a thin chart on helm-common, environment values, the Argo CD entry and the network rules. It is for developers onboarding a service; `sample-services/hello-api` and `helmcharts/app-charts/hello-api` are the reference to copy from.

A `make new-app` scaffold is planned, not implemented. Until it exists, follow the steps below.

## Purpose

Run a new service in `dev`, ready for promotion to `stage` and `prod`, without exceptions to the platform policies.

## When to use

For every new deployable service in this repository. A service that cannot meet the workload contract needs a reviewed `PolicyException` first (see [troubleshooting](troubleshooting.md#kyverno-denies-a-pod)).

## Preconditions

- The toolchain from `mise.toml` or the devcontainer: `helm` with the helm-unittest plugin, `kubeconform`, the `kyverno` CLI, `yq`.
- The service meets the workload contract in [helm-common values](../reference/helm-common-values.md) and the [observability contract](observability-contract.md):
  - runs as a non-root numeric UID, with no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault` and a read-only root filesystem (writes go to `/tmp`, an emptyDir);
  - serves `/healthz` and `/readyz` for the probes and `/metrics` in Prometheus format;
  - listens on an unprivileged port (8080 by convention) and shuts down cleanly on SIGTERM;
  - has CPU and memory requests and limits.
- The image goes to the registry in `platform.imageRegistry` (`ghcr.io/your-org`), which the admission policy allows.

## Steps

### 1. Add the source and the Dockerfile

Put the code under `sample-services/<app>` with a `Dockerfile` and a `.dockerignore`. The build workflow builds every `sample-services/*/Dockerfile`. The Dockerfile contract:

- multi-stage build; the final stage is distroless or another minimal base, pinned by digest;
- a numeric non-root user that matches the chart (`65532` for the distroless `nonroot` images);
- no shell or package manager needed at runtime;
- OCI labels for source and revision.

A minimal shape for a Go service, based on `sample-services/hello-api/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:<go-version>@sha256:<build-image-digest> AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/<app> ./<main-package>

FROM gcr.io/distroless/static-debian13:nonroot@sha256:<runtime-image-digest>
LABEL org.opencontainers.image.source="https://github.com/YOUR_ORG/sk-k8s-devops-bootstrap"
COPY --from=build /out/<app> /<app>
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/<app>"]
```

Renovate keeps the base image digests current.

### 2. Add a thin chart

Create `helmcharts/app-charts/<app>` by copying `helmcharts/app-charts/hello-api`. The chart depends on the helm-common library chart and contains no templates of its own beyond one-line includes:

```yaml
# helmcharts/app-charts/<app>/Chart.yaml
apiVersion: v2
name: <app>
type: application
version: 0.1.0
appVersion: "0.1.0"
dependencies:
  - name: helm-common
    version: <helm-common-version>
    repository: file://../../helm-common
```

Each file in `templates/` includes one named template, for example `templates/deployment.yaml`:

```yaml
{{- include "common.deployment" . }}
```

Set the base values in `helmcharts/app-charts/<app>/values.yaml`: `image.repository` (`ghcr.io/your-org/<app>`), `containerPorts`, the probes, `resources`, `route.enabled`, the NetworkPolicy rules (step 5) and the per-environment sizing under `environments.<env>`. Leave `route.hostnames` empty: the chart derives `<app>.<env>.<domain>` from the values Argo CD passes for the cluster and environment. Every key is described in [helm-common values](../reference/helm-common-values.md).

### 3. Add the environment files

Create `envs/dev/<app>/values.yaml`, `envs/stage/<app>/values.yaml` and `envs/prod/<app>/values.yaml`. They hold only the image reference, which the build and promotion workflows maintain:

```yaml
image:
  tag: ""
  digest: ""
```

### 4. Register the app with Argo CD

Add an entry to `apps:` in `argocd-bootstrap/values.yaml`. Argo CD then creates one Application per environment, named `<app>-<env>`, in the project `apps-<env>` and the namespace `<env>`:

```yaml
apps:
  - name: <app>
    chart: helmcharts/app-charts/<app>
    environments: [dev, stage, prod]
```

Recommendation: add this entry in a second pull request, after the first image exists and its dev bump pull request is merged, so that no Application points at an image that does not exist yet.

### 5. Allow the traffic the service needs

App namespaces deny all ingress and egress by default, except DNS: the platform keeps only `default-deny` and `allow-dns` in `dev`, `stage` and `prod`. Each app brings its own NetworkPolicy, rendered by helm-common:

- ingress from `envoy-gateway-system` on the service port, when `route.enabled` is true;
- ingress from the `monitoring` namespace on the metrics port, when `metrics.serviceMonitor.enabled` is true.

Anything else the service needs is an explicit rule in `networkPolicy.extraIngress[]` or `networkPolicy.egress[]`, in the Kubernetes NetworkPolicy rule format. For example, egress to the OpenTelemetry collector in the `tracing` namespace:

```yaml
networkPolicy:
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tracing
      ports:
        - port: 4318
          protocol: TCP
```

The egress rule in the example allows OTLP traces to Tempo; list only the destinations the service calls.

### 6. Check locally

```bash
helm dependency build helmcharts/app-charts/<app>
helm lint --strict helmcharts/app-charts/<app> -f envs/dev/<app>/values.yaml
helm template <app> helmcharts/app-charts/<app> -f envs/dev/<app>/values.yaml \
  --set global.environment=dev --set global.domain=localtest.me
make render
make kubeconform
make policy-test
make helm-unittest
```

`make helm-unittest` runs every chart that has `tests/*_test.yaml`, including the helm-common suite in `helmcharts/helm-common/tests/chart` and `helmcharts/app-charts/<app>/tests/` when the chart has its own tests. `make policy-test` runs the Kyverno policies against the rendered manifests, so a contract violation fails here before CI.

### 7. Open the pull request

Open a pull request with the source, the Dockerfile, the chart and the environment files. `ci-gate` must pass; it runs, among others, the `helm`, `policy-test`, `dockerfile-lint` and `e2e-kind` jobs. After the merge, `build-image.yml` tests and builds the image, pushes it to GHCR, scans the pushed digest, and only when the scan passes signs it with cosign, attests it, and opens a pull request that sets the new digest in `envs/dev/<app>/values.yaml`. Merge that pull request after its checks pass, then add the `apps:` entry (step 4).

## Verification

```bash
kubectl -n argocd get application <app>-dev
kubectl -n dev get pods,svc,httproute,networkpolicy -l app.kubernetes.io/name=<app>
kubectl get policyreports -n dev
```

- The Application `<app>-dev` is Synced and Healthy.
- The pods are Ready and the policy report for the namespace shows no failures for the app.
- The service answers through the Gateway at `https://<app>.dev.<domain>/readyz`.

Then promote it as described in [promotion](promotion.md).

## Rollback or abort

- Before the `apps:` entry merges, nothing runs in the cluster: close or revert the pull requests.
- After it merges, remove the entry (or the environment from its `environments` list) in a new pull request. Argo CD prunes the Applications and their resources.

## References

- [helm-common values and the workload contract](../reference/helm-common-values.md)
- [Promotion and deployment policy](promotion.md)
- [GitOps structure: app of apps, AppProjects, values layering](../architecture/gitops.md)
- Helm library charts: <https://helm.sh/docs/topics/library_charts/>
- helm-unittest: <https://github.com/helm-unittest/helm-unittest>
- Kubernetes NetworkPolicy: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- Distroless images: <https://github.com/GoogleContainerTools/distroless>
- Dockerfile best practices: <https://docs.docker.com/build/building/best-practices/>
