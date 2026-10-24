# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:c81d42afe2d9f5728a63998d93340553b46b0a8f149888527f1ab9deb3dfa9ef
ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:c12f0107f8afb0bbc1b0eff96ff8675e85a10c6083d039b777c51fef5c27420f

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
