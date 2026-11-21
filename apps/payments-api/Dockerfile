# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:0e87094aeae3d022d3926c756d7358dcc67bb1028a890989eb4224e2349c8481
ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:8658e9eaeb2294fa0e49b0667f7d66b4e21fa7690b8d2a4c30cd1d013ceb9eb7

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
