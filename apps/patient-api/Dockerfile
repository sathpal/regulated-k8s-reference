# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev@sha256:157a562dbc225a2a9039dbd8249cbf704202260ba27bf525f24e47a3a685050f
ARG RUNTIME_IMAGE=cgr.dev/chainguard/python:latest@sha256:35d6025b288eb1c40ae631db77ed6cdd26c6f51d898428d8fc9989db7f29e784

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
