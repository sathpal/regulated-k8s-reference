# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:5f7d6fc20e461b7b2d677ced0902b28df1567a7dd8e672ff82a55c04168f81c0
ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:599c3cd7597b84aa149c4282beecc8c6d4e1cb5c95dc8d982e70cd0a2a9147a2

# Production image: tests run in the build stage, only a static binary ships.
FROM ${BUILD_IMAGE} AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
ARG VERSION=dev
# No BuildKit-only features (cache or secret mounts): this file must build the same way with BuildKit
# (docker buildx in CI) and with the legacy builder that ACR Tasks `az acr build` uses.
RUN go test ./... && \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .

# static: CA certificates, tzdata and a nonroot user. No shell, no package manager.
FROM ${RUNTIME_IMAGE}
COPY --from=build /out/payments-api /usr/bin/payments-api
# Numeric user: Kubernetes runAsNonRoot can verify a number, not a name.
USER 65532
EXPOSE 8080
ENTRYPOINT ["/usr/bin/payments-api"]
