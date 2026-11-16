---
status: accepted
date: 2026-11-16
decision-makers: platform maintainers
---

# One owned Go sample service

This record explains which sample workload the platform ships to prove its contracts, and why it is a single Go service. It is for evaluators and for app owners who use it as a template.

## Context and problem statement

The platform needs at least one workload that exercises the whole path: build, scan, sign, promote, admission against the workload contract, routing through the Gateway, metrics and traces. The earlier samples were adapted from external projects. They did not build and become Ready on the platform without changes, they did not meet the workload contract, and their attribution had to be tracked separately in [third-party notices](../../THIRD_PARTY_NOTICES.md).

Which sample workload should the repository own?

## Decision drivers

- The smallest image and attack surface, so the scan and signing steps show clean results.
- Code owned by this repository, with clear licensing.
- Meets the workload contract ([ADR 0004](0004-kyverno-cel-policies.md)) with no `PolicyException`.
- Fast CI: quick tests, quick builds, quick start on kind.
- Exposes health, readiness, metrics and traces in the form the platform expects.

## Considered options

- Keep the previous third-party samples
- Go
- Python with FastAPI
- Java with Spring Boot

## Decision outcome

Chosen option: "Go", because a Go binary on a distroless static base gives the smallest image and attack surface, builds and starts in seconds, and meets the workload contract without exceptions.

The service:

- Source in `sample-services/hello-api`, using the standard library `net/http`. Image name `hello-api`, port 8080.
- Endpoints `/healthz` (liveness), `/readyz` (readiness) and `/metrics` (Prometheus format).
- JSON logs, and OpenTelemetry traces configured through the standard OpenTelemetry environment variables.
- Distroless static `nonroot` base image pinned by digest, running as UID 65532 with a read-only root filesystem.
- Chart `helmcharts/app-charts/hello-api` on the helm-common library, with environment values in `envs/<env>/hello-api/values.yaml`.

A two-tier sample backed by a CloudNativePG database is optional future work. It is not part of the platform today.

### Consequences

- Good, because the image contains one static binary and no shell or package manager, which leaves the scanner little to report.
- Good, because the service meets the workload contract in every environment with no exception, which shows that the contract is practical.
- Good, because the code, its tests and its licence belong to this repository.
- Good, because builds, unit tests and the kind start-up are fast, which keeps the end-to-end job short.
- Bad, because one stateless Go service shows neither a second language stack nor a stateful workload; teams on other stacks must adapt the patterns themselves.
- Bad, because the image has no shell. Debugging uses `kubectl debug` with an ephemeral container, which must itself pass the namespace's admission policies.
- Bad, because owned code needs its own maintenance: Go toolchain updates, module updates and security fixes.
- Neutral, because the service is deliberately small; it demonstrates the platform contracts, not application design.

### Confirmation

- `build-image.yml` runs the unit tests before it builds the image.
- The `dockerfile-lint` job runs hadolint and a container smoke test that starts the image and checks `/readyz` and `/metrics`.
- The `argocd-bootstrap` job renders `helmcharts/app-charts/hello-api` for each environment and validates it with kubeconform; the `helm` job lints it and runs the helm-common unit tests.
- The `policy-test` job applies the rendered policies to the rendered app in every environment and expects zero violations.
- The `e2e-kind` job checks that `hello-api` becomes Ready and answers through the Gateway.

## Pros and cons of the options

### Keep the previous third-party samples

- Good, because no new code is needed.
- Bad, because they did not build and become Ready on the platform, and did not meet the workload contract.
- Bad, because their code is not owned by this repository, which complicates licensing and attribution.

### Go

- Good, because a static binary runs on a distroless static base of a few megabytes, as a non-root user.
- Good, because the standard library covers HTTP serving, and established Go libraries cover Prometheus metrics and OpenTelemetry traces.
- Good, because builds and start-up take seconds.
- Bad, because it shows one language only.

### Python with FastAPI

- Good, because it is widely known and quick to read.
- Bad, because the image needs an interpreter and packages, which means a larger image and more findings to triage.

### Java with Spring Boot

- Good, because it is common in larger organisations and has mature health and metrics endpoints.
- Bad, because the JVM needs more memory and starts more slowly, which lengthens CI and the end-to-end job.
- Bad, because the image is larger, with a larger runtime to keep patched.

## More information

Upstream sources, checked on 2026-11-16:

- Go `net/http`: <https://pkg.go.dev/net/http>
- Distroless images: <https://github.com/GoogleContainerTools/distroless>
- OpenTelemetry SDK environment variables: <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- CloudNativePG: <https://cloudnative-pg.io/>

Related pages and decisions:

- [helm-common values and the workload contract](../reference/helm-common-values.md), [observability contract](../operations/observability-contract.md), [Add an app](../operations/add-an-app.md)
- [ADR 0004: Kyverno CEL policies](0004-kyverno-cel-policies.md)
- [ADR 0008: keyless image signing](0008-keyless-image-signing.md)
- [ADR 0011: promotion by pull request and digest](0011-promotion-by-pull-request-and-digest.md)
