# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:65e8b42e2c06a951df80725171337d9bdc8d3a2181d33cd2ef411a8a3d8873cc
ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:fc42af33e643f20d08baf03cddcc1c02ba57052dfb02edb0d79f3fc47bcea8d9

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
