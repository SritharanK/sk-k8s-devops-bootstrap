# Network probe for the e2e suite: the pinned curl image, unchanged
# (multi-arch index digest, amd64 and arm64).
#
# tests/e2e/lib/netprobe-image.sh tags it under the platform registry prefix
# (ghcr.io/YOUR_ORG/e2e-netprobe:<curl version>) only so that a probe pod in an
# app namespace passes the lab registry allowlist, and loads it into the kind
# cluster. It is never pushed to any registry.
FROM docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
