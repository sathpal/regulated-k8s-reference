# syntax=docker/dockerfile:1
# Base images pinned by digest: production builds exactly what was tested. Digestabot opens a pull request
# when Chainguard publishes a new digest; the nightly-latest workflow overrides these ARGs to test today's latest.
ARG BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev@sha256:261ceae8cf0ee5055341cd5c417984a70eb0e1406f2ddf83a4c93002bb10c26c
ARG RUNTIME_IMAGE=cgr.dev/chainguard/python:latest@sha256:89281daac77a3d91ef298d70ce3b7a6ccb2ebf268c084fa9a9bda1c92e71c64d

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
