# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev@sha256:47b1a23ae387fc1d5264abd79c395827fcca7ef92afe086908b51ce0747e8e77
ARG RUNTIME_IMAGE=cgr.dev/chainguard/python:latest@sha256:c26e4957fef58d936401b8e2bb9ccb6db0f404f51597a0d2c7586e1d0112df0a

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
