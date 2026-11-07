# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev@sha256:64f414bffa25ca9ff518f35975ad153a921b2e4850c4a84c31a96885fdb86a02
ARG RUNTIME_IMAGE=cgr.dev/chainguard/python:latest@sha256:f3e5face39b0acd813fae456df27b33bf6a6bffba5d201d15f6498138cb8fd96

# Stage 1 runs the tests on the -dev image (it has a shell); a failing test fails the build.
FROM ${BUILD_IMAGE} AS test
ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY app.py test_app.py ./
RUN python -m unittest -v test_app

# Stage 2 ships only app.py on the minimal runtime: no shell, no pip, no package manager.
FROM ${RUNTIME_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --from=test /app/app.py ./
ARG VERSION=dev
ENV VERSION=${VERSION}
USER 65532
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
