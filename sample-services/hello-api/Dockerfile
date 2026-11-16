ARG VERSION=dev
ARG REVISION=unknown

FROM --platform=$BUILDPLATFORM golang:1.27.4-trixie@sha256:b54b2639de8c1bfe538ec5ffc45f29b1932235ac5f6d63c059853646677112d9 AS build

ARG TARGETOS
ARG TARGETARCH
ARG VERSION

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/hello-api .

# Unit tests. Not part of the default target; run with --target test.
FROM build AS test
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go test ./...

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931

ARG VERSION
ARG REVISION

LABEL org.opencontainers.image.title="hello-api" \
      org.opencontainers.image.description="Sample HTTP service that exercises the platform contract: probes, Prometheus metrics, structured logs, tracing and graceful shutdown" \
      org.opencontainers.image.source="https://github.com/SritharanK/sk-k8s-devops-bootstrap" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian13:nonroot"

COPY --from=build /out/hello-api /hello-api

USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/hello-api", "-healthcheck"]

ENTRYPOINT ["/hello-api"]
