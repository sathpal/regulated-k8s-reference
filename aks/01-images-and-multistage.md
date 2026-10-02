# 01. Docker images and multi-stage builds, built in Azure

**Goal:** build the naive and the production image of both services in Azure with ACR Tasks, read the build log
to see the stages and the tests, and measure the difference from the registry (size, layers, user) and from a
vulnerability scan that runs inside the cluster.

**You need:** lab 00 (cluster, registry and `aks/.lab.env`). Azure CLI, `kubectl`, `crane` and `jq` on your
machine; no Docker. About 45 minutes, of which the scans take about 8. Cost: ACR Tasks bills each second of task
run time on top of the registry's daily rate; this lab used about 12 minutes of build time. The four scan Jobs
asked for enough memory that the cluster autoscaler added the third user node for a while.

_Outputs captured on 2026-10-02 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

The image is the unit you ship, scan, sign and run, so what goes into it decides the attack surface, the patch
load and the pull time on every node. A multi-stage build keeps the compiler, the test tools and the package
manager in a build stage and ships only what runs. Building in ACR Tasks instead of on a laptop means the build
runs in Azure next to the registry, with the same toolchain for everyone, and leaves a log you can show an auditor.

**What you will learn**
- What `az acr build` does: context upload, `.dockerignore`, the builder it uses, push, and the dependency report.
- How a test stage turns a failing test into a failed build and an image that never reaches the registry.
- Why a Dockerfile that uses BuildKit-only syntax fails in `az acr build`, and how a task file fixes it.
- What "no layer cache between runs" costs, and how a registry cache brings a rebuild from 71 s to 11 s.
- How to read size, layers and the configured user from the registry, and scan images inside AKS with grype.

## 1. Set up

```bash
cd regulated-k8s-reference
source aks/.lab.env
az acr show -n $ACR --query '{name:name, sku:sku.name, loginServer:loginServer, adminUserEnabled:adminUserEnabled}' -o table
kubectl apply -f aks/manifests/01/namespace.yaml
```

```output
Name             Sku    LoginServer                 AdminUserEnabled
---------------  -----  --------------------------  ------------------
acrregk8s1e1193  Basic  acrregk8s1e1193.azurecr.io  False
namespace/lab-a-images created
```

**What you are seeing:** a Basic registry with the admin user turned off, so every push and pull is made by an
Entra ID identity. The namespace enforces the Pod Security `restricted` profile, which the scanner Jobs in step 10
have to satisfy too.

## 2. Read the two Dockerfiles

```bash
grep -n -E '^(FROM|CMD|RUN)' apps/payments-api/Dockerfile.naive apps/patient-api/Dockerfile.naive
grep -n -E '^(ARG|FROM|USER|RUN|COPY --from)' apps/payments-api/Dockerfile apps/patient-api/Dockerfile
```

```output
apps/payments-api/Dockerfile.naive:2:FROM golang:1.25
apps/payments-api/Dockerfile.naive:5:RUN go build -o /usr/local/bin/payments-api .
apps/payments-api/Dockerfile.naive:7:CMD payments-api
apps/patient-api/Dockerfile.naive:2:FROM python:3.13-slim
apps/patient-api/Dockerfile.naive:5:CMD python app.py
apps/payments-api/Dockerfile:4:ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
apps/payments-api/Dockerfile:5:ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
apps/payments-api/Dockerfile:8:FROM ${BUILD_IMAGE} AS build
apps/payments-api/Dockerfile:11:RUN go mod download
apps/payments-api/Dockerfile:16:RUN go test ./... && \
apps/payments-api/Dockerfile:20:FROM ${RUNTIME_IMAGE}
apps/payments-api/Dockerfile:21:COPY --from=build /out/payments-api /usr/bin/payments-api
apps/payments-api/Dockerfile:23:USER 65532
apps/patient-api/Dockerfile:4:ARG BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev@sha256:261ceae8cf0ee5055341cd5c417984a70eb0e1406f2ddf83a4c93002bb10c26c
apps/patient-api/Dockerfile:5:ARG RUNTIME_IMAGE=cgr.dev/chainguard/python:latest@sha256:89281daac77a3d91ef298d70ce3b7a6ccb2ebf268c084fa9a9bda1c92e71c64d
apps/patient-api/Dockerfile:8:FROM ${BUILD_IMAGE} AS test
apps/patient-api/Dockerfile:12:RUN python -m unittest -v test_app
apps/patient-api/Dockerfile:15:FROM ${RUNTIME_IMAGE}
apps/patient-api/Dockerfile:18:COPY --from=test /app/app.py ./
apps/patient-api/Dockerfile:21:USER 65532
```

**What you are seeing:** the naive files are one stage on a full distribution image, with no tests, no `USER`
(so root) and a shell-form `CMD` that needs `/bin/sh`. The production files have two stages. The first stage
compiles and tests; the second starts from a minimal runtime image and copies one artifact in with `COPY --from`.
Both base images are `ARG`s that carry a tag for readability and a digest for exactness: `name:tag@sha256:...`
pulls the digest, so the build is the same tomorrow even if the tag moves. `USER 65532` is numeric on purpose:
Kubernetes `runAsNonRoot` can only verify a number. The `.dockerignore` in each app is an allowlist (`*`, then
`!*.go` and so on), so nothing else in the folder can reach the build context.

## 3. Build the naive images in ACR Tasks

`az acr build` is an ACR Tasks *quick task*: the CLI packs the folder (honoring `.dockerignore`), uploads it, an
ACR-managed agent runs the build, and the image is pushed to the registry by default. `-f` picks the Dockerfile
inside the context.

```bash
az acr build -r $ACR -t labs/payments-api:naive -f apps/payments-api/Dockerfile.naive apps/payments-api
az acr build -r $ACR -t labs/patient-api:naive  -f apps/patient-api/Dockerfile.naive  apps/patient-api
```

```output
WARNING: Packing source code into tar to upload...
WARNING: Sending context (3.939 KiB) to registry: acrregk8s1e1193...
WARNING: Queued a build with ID: cu7
WARNING: Waiting for an agent...
2026/10/02 14:10:34 Using acb_vol_2f0ae1bc-6b48-4846-8f24-1928d43fa4a2 as the home volume
2026/10/02 14:10:35 Logging in to registry: acrregk8s1e1193.azurecr.io
2026/10/02 14:10:36 Executing step ID: build. Timeout(sec): 28800, Working directory: '', Network: ''
Sending build context to Docker daemon  13.82kB
Step 1/6 : FROM golang:1.25
1.25: Pulling from library/golang
Digest: sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80
Step 2/6 : WORKDIR /src
Step 3/6 : COPY . .
Step 4/6 : RUN go build -o /usr/local/bin/payments-api .
...
Successfully tagged acrregk8s1e1193.azurecr.io/labs/payments-api:naive
2026/10/02 14:11:22 Pushing image: acrregk8s1e1193.azurecr.io/labs/payments-api:naive, attempt 1
naive: digest: sha256:935a1d6f20861f336675662b9a3087b4e0e1a612680c24a999a2e360eb1ead32 size: 2417
2026/10/02 14:11:58 The following dependencies were found:
- image:
    registry: acrregk8s1e1193.azurecr.io
    repository: labs/payments-api
    tag: naive
    digest: sha256:935a1d6f20861f336675662b9a3087b4e0e1a612680c24a999a2e360eb1ead32
  runtime-dependency:
    registry: registry.hub.docker.com
    repository: library/golang
    tag: "1.25"
    digest: sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80
Run ID: cu7 was successful after 1m25s
...
Run ID: cu8 was successful after 24s
```

**What you are seeing:** only 3.9 KiB of context left the laptop, because the allowlist `.dockerignore` kept
everything else out. `Sending build context to Docker daemon` and `Step 1/6` are the classic Docker builder's
output, not BuildKit's (step 6 shows why that matters). ACR Tasks then pushed the image and wrote a dependency
report: which base image, resolved to which digest, went into this build. `golang:1.25` is a tag, so the report
is the only record of what it meant at 14:10 today. The push of 2.4 KB of manifest plus about 318 MB of layers took
35 s of the 85 s run.

## 4. Build the production images: the tests run inside the build

```bash
az acr build -r $ACR -t labs/payments-api:prod apps/payments-api
az acr build -r $ACR -t labs/patient-api:prod  apps/patient-api
```

```output
Step 1/14 : ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
Step 2/14 : ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
Step 3/14 : FROM ${BUILD_IMAGE} AS build
...
Step 9/14 : RUN go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .
 ---> Running in ded9a9c1ef4f
ok  	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.007s
Step 10/14 : FROM ${RUNTIME_IMAGE}
Step 11/14 : COPY --from=build /out/payments-api /usr/bin/payments-api
Step 12/14 : USER 65532
...
prod: digest: sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d size: 738
  runtime-dependency:
    registry: cgr.dev
    repository: chainguard/static
    tag: latest
    digest: sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
  buildtime-dependency:
  - registry: cgr.dev
    repository: chainguard/go
    tag: latest
    digest: sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
Run ID: cuf was successful after 1m23s
...
Step 7/16 : RUN python -m unittest -v test_app
test_audit_never_contains_phi (test_app.PatientApiTest.test_audit_never_contains_phi) ... ok
test_clerk_gets_minimum_necessary (test_app.PatientApiTest.test_clerk_gets_minimum_necessary) ... ok
test_clinician_sees_clinical_fields (test_app.PatientApiTest.test_clinician_sees_clinical_fields) ... ok
test_no_role_is_denied_and_audited (test_app.PatientApiTest.test_no_role_is_denied_and_audited) ... ok
test_readiness_follows_drain (test_app.PatientApiTest.test_readiness_follows_drain) ... ok
----------------------------------------------------------------------
Ran 5 tests in 0.516s

OK
Step 8/16 : FROM ${RUNTIME_IMAGE}
...
prod: digest: sha256:4ca0cc0c97d30d7b4e3919db1dc2c17f1d14d65d9fb6d4b8a5221ac3c7ac72a4 size: 3047
Run ID: cua was successful after 42s
```

**What you are seeing:** the unit tests are a build step. `go test` and `python -m unittest` ran on the ACR agent
inside the build stage, and only after they passed did the next `FROM` start the runtime stage. The dependency
report now separates the `buildtime-dependency` (the Go or Python `-dev` image, which never ships) from the
`runtime-dependency` (the base the image actually contains), both as the pinned digests from the `ARG`s. The
payments-api push was 738 bytes of manifest for an image of two layers. The patient-api test stage creates
`WORKDIR /app` as root under this builder; that works here because the tests do not write to it
(`PYTHONDONTWRITEBYTECODE=1`).

## 5. A failing test stops the build

Copy payments-api to a temporary folder and make the kind of change a tired engineer makes while debugging: return
the full card number instead of the masked one. The repository is not touched.

```bash
BROKEN=$(mktemp -d)
cp -R apps/payments-api/. "$BROKEN"
sed -i.bak 's|return pan\[:6\] + "\*\*\*\*\*\*" + pan\[len(pan)-4:\]|return pan // debugging: show the full card number|' "$BROKEN/main.go"
az acr build -r $ACR -t labs/payments-api:broken "$BROKEN"; echo "exit=$?"
az acr repository show-tags -n $ACR --repository labs/payments-api -o tsv
az acr task list-runs -r $ACR --run-status Failed --top 3 -o table
```

```output
Step 9/14 : RUN go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .
 ---> Running in 1630fac82715

--- FAIL: TestMaskPAN (0.00s)
    main_test.go:42: maskPAN = "4111111111111111"
--- FAIL: TestPaymentNeverExposesFullPAN (0.00s)
    main_test.go:53: full card number leaked into the response or the audit log
FAIL
FAIL	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.007s
FAIL
The command '/bin/sh -c go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .' returned a non-zero code: 1
2026/10/02 14:19:21 Container failed during run: build. No retries remaining.
failed to run step ID: build: exit status 1

Run ID: cun failed after 49s. Error: failed during run, err: exit status 1
ERROR: Run failed
exit=1
latest-bases
naive
prod
RUN ID    TASK    PLATFORM    STATUS    TRIGGER    STARTED               DURATION
--------  ------  ----------  --------  ---------  --------------------  ----------
cuq               linux       Failed    Manual     2026-10-02T14:19:48Z  00:00:24
cun               linux       Failed    Manual     2026-10-02T14:18:32Z  00:00:52
cub               linux       Failed    Manual     2026-10-02T14:12:27Z  00:00:21
```

**What you are seeing:** two tests caught the regression, the step exited non-zero, the run failed, and the CLI
exited 1, which is what stops a pipeline. There is no `broken` tag in the repository: a failed build pushes
nothing. The run stays in the registry's history; `az acr task logs -r $ACR --run-id cun` prints the same log
later, which is useful evidence when someone asks why a release did not happen. (`latest-bases` comes from step 8;
the other failed runs in the list are from step 6 and from other people using the same registry.)

## 6. Break it: BuildKit-only syntax in `az acr build`, then fix it with a task file

A common Dockerfile speed-up is a cache mount for the Go build cache. Add one to a temporary copy and build it the
same way as before.

```bash
CTX=$(mktemp -d)
cp -R apps/payments-api/. "$CTX"
sed -i.bak 's|^RUN go test|RUN --mount=type=cache,target=/root/.cache/go-build go test|' "$CTX/Dockerfile"
az acr build -r $ACR -t labs/payments-api:buildkit "$CTX"
```

```output
Step 9/14 : RUN --mount=type=cache,target=/root/.cache/go-build go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .
the --mount option requires BuildKit. Refer to https://docs.docker.com/go/buildkit/ to learn how to build images with BuildKit enabled
2026/10/02 14:20:09 Container failed during run: build. No retries remaining.
Run ID: cuq failed after 21s. Error: failed during run, err: exit status 1
```

`az acr build` runs the classic builder. You can see what the agent runs:

```bash
az acr run -r $ACR --cmd "docker version" /dev/null
```

```output
Client:
 Version:           20.10.25
...
Server:
 Engine:
  Version:          23.0.7+azure-1
...
Run ID: cuy was successful after 3s
```

The fix that keeps the Dockerfile as it is: run the build as a multi-step task and set `DOCKER_BUILDKIT=1` on the
build step. The task file is [aks/manifests/01/buildkit-build.yaml](manifests/01/buildkit-build.yaml):

```yaml
version: v1.1.0
steps:
  - id: build
    build: -t $Registry/{{.Values.image}} -f Dockerfile .
    env: ["DOCKER_BUILDKIT=1"]
  - id: push
    push: ["$Registry/{{.Values.image}}"]
```

`az acr run` reads the task file from inside the uploaded context, so copy it in and let it through the allowlist:

```bash
cp aks/manifests/01/buildkit-build.yaml "$CTX/acb.yaml"
echo '!acb.yaml' >> "$CTX/.dockerignore"
az acr run -r $ACR -f acb.yaml --set image=labs/payments-api:buildkit "$CTX"
```

```output
#10 [build 1/6] FROM cgr.dev/chainguard/go:latest@sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
#10 DONE 13.0s
...
#16 [build 6/6] RUN --mount=type=cache,target=/root/.cache/go-build go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=dev" -o /out/payments-api .
#16 26.70 ok  	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.008s
#16 DONE 46.7s
#17 [stage-1 2/2] COPY --from=build /out/payments-api /usr/bin/payments-api
#18 naming to acrregk8s1e1193.azurecr.io/labs/payments-api:buildkit done
buildkit: digest: sha256:f893b5dc123dadba8d06c3c5c340af13d63c5b35c5569f389c498c57fdea31a4 size: 738
2026/10/02 14:21:27 Image was built using buildkit, fetching Digest from remote...
Run ID: cur was successful after 1m14s
```

**What you are seeing:** the agent's Docker CLI is 20.10, which uses the classic builder unless BuildKit is asked
for, so `RUN --mount` is a syntax error there. With `DOCKER_BUILDKIT=1` the same Dockerfile builds (the `#16`
style lines are BuildKit's output). Notice the cache mount bought nothing: the agent is new for every run, so
`/root/.cache/go-build` started empty and the test-and-build step still took 46.7 s. This is why the repository's
production Dockerfiles avoid BuildKit-only features: the same file must build with `docker buildx` in CI and with
`az acr build`. (This exact failure happened with the first version of the payments-api Dockerfile.)

## 7. The layer cache: there is none between runs, unless you bring one

Run the production build a second time without pushing, and count what it pulls.

```bash
az acr build -r $ACR -t labs/payments-api:prod --no-push apps/payments-api 2>&1 | tee /tmp/again.log | tail -1
grep -c 'Pulling fs layer' /tmp/again.log
grep -c 'Using cache' /tmp/again.log
```

```output
Run ID: cum was successful after 1m17s
12
0
```

**What you are seeing:** the second run pulled all 12 layers of the two base images again (11 for `go`, 1 for
`static`), reused no step (`Using cache` never appears) and re-ran the tests. Its build step took 74 s, against
73 s the first time. Each ACR Tasks run gets a fresh agent with an empty Docker cache. For a 3.4 MB image this is fine; for a
large build, every run pays for the full base pull and every compile step.

BuildKit can import cache from the registry instead. The task file
[aks/manifests/01/buildkit-inline-cache.yaml](manifests/01/buildkit-inline-cache.yaml) adds
`--cache-from $Registry/<image>` and `--build-arg BUILDKIT_INLINE_CACHE=1`, which stores cache metadata in the
pushed image. Run it twice with no code change:

```bash
CTX=$(mktemp -d)
cp -R apps/payments-api/. "$CTX"
cp aks/manifests/01/buildkit-inline-cache.yaml "$CTX/acb.yaml"
echo '!acb.yaml' >> "$CTX/.dockerignore"
az acr run -r $ACR -f acb.yaml --set image=labs/payments-api:cache-demo "$CTX"   # first run: seeds the cache
az acr run -r $ACR -f acb.yaml --set image=labs/payments-api:cache-demo "$CTX"   # second run: reuses it
```

```output
#9 importing cache manifest from acrregk8s1e1193.azurecr.io/labs/payments-api:cache-demo
#9 ERROR: acrregk8s1e1193.azurecr.io/labs/payments-api:cache-demo: not found
...
#17 26.61 ok  	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.006s
#17 DONE 46.2s
Run ID: cuw was successful after 1m11s
...
#9 importing cache manifest from acrregk8s1e1193.azurecr.io/labs/payments-api:cache-demo
#9 DONE 0.2s
#17 [build 6/6] RUN go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=dev" -o /out/payments-api .
#17 CACHED
#18 [stage-1 2/2] COPY --from=build /out/payments-api /usr/bin/payments-api
#18 CACHED
2026/10/02 15:13:10 Step ID: build marked as successful (elapsed time in seconds: 6.596177)
Run ID: cux was successful after 11s
```

**What you are seeing:** the first run found no cache (`not found` is expected) and took 71 s. The second run read
the cache manifest in 0.2 s, marked every step `CACHED`, did not pull the 275 MB Go image at all, and finished in
11 s. Read the trade-off before you adopt it: on a cache hit **the tests did not run**, because BuildKit decided
their inputs were unchanged. That is correct reasoning, but if your release evidence says "tests ran in the build
that produced this digest", either run tests as a separate pipeline step or skip the cache for release builds.
The two cached runs produced the same layers but different image digests, because the config that carries the
cache metadata differs.

## 8. Build against today's latest bases by overriding the pinned ARGs

The pinned digests are what production builds. To learn early whether tomorrow's base still works, build the same
Dockerfile against the moving tags. First compare today's tags with the pins:

```bash
export DOCKER_CONFIG=$(mktemp -d)     # an empty Docker config, so crane uses no credential helper
crane digest cgr.dev/chainguard/go:latest
crane digest cgr.dev/chainguard/static:latest
az acr build -r $ACR -t labs/payments-api:latest-bases \
  --build-arg BUILD_IMAGE=cgr.dev/chainguard/go:latest \
  --build-arg RUNTIME_IMAGE=cgr.dev/chainguard/static:latest apps/payments-api
az acr build -r $ACR -t labs/patient-api:latest-bases \
  --build-arg BUILD_IMAGE=cgr.dev/chainguard/python:latest-dev \
  --build-arg RUNTIME_IMAGE=cgr.dev/chainguard/python:latest apps/patient-api
```

```output
sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
Step 1/14 : ARG BUILD_IMAGE=cgr.dev/chainguard/go:latest@sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
Step 2/14 : ARG RUNTIME_IMAGE=cgr.dev/chainguard/static:latest@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
Step 3/14 : FROM ${BUILD_IMAGE} AS build
latest: Pulling from chainguard/go
Digest: sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
...
ok  	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.008s
latest-bases: digest: sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95 size: 738
  runtime-dependency:
    registry: cgr.dev
    repository: chainguard/static
    tag: latest
    digest: sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
  buildtime-dependency:
  - registry: cgr.dev
    repository: chainguard/go
    tag: latest
    digest: sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618
Run ID: cuj was successful after 1m20s
...
Run ID: cuk was successful after 44s
```

**What you are seeing:** the log still prints the `ARG` defaults, but `--build-arg` replaced them, so `FROM`
pulled `latest` (`latest: Pulling from chainguard/go`). The dependency report records what `latest` resolved to.
On this day the pins were fresh, so `latest` resolved to the same digests. On a later day the report would show
newer digests, and a test failure here would be the early warning that the next digest bump needs work. Same
bases and same source still gave a new image digest (`5dd0e2...` against `d2315b...` for `prod`): the base layer
is identical, but the binary layer differs (file times) and the config records a new creation time. Rebuilding is
not a way to reproduce a digest; keeping the digest is.

## 9. Compare the images from the registry

Nothing is pulled to the laptop in full: `crane manifest` and `crane config` read a few kilobytes each. The ACR
token from `--expose-token` is valid for 3 hours and carries your own permissions.

```bash
az acr login -n $ACR --expose-token --query accessToken -o tsv 2>/dev/null \
  | crane auth login $ACR.azurecr.io -u 00000000-0000-0000-0000-000000000000 --password-stdin
for app in payments-api patient-api; do for t in naive prod; do
  ref=$ACR.azurecr.io/labs/$app:$t
  printf '%-13s %-6s layers=%-3s compressed=%6.1f MB  user=%s\n' $app $t \
    "$(crane manifest $ref | jq '.layers|length')" \
    "$(crane manifest $ref | jq '[.layers[].size]|add/1048576')" \
    "$(crane config $ref | jq -r '.config.User | if .=="" then "(empty: root)" else . end')"
done; done
az acr manifest list-metadata -r $ACR -n labs/payments-api \
  --query "[?tags && (contains(tags,'naive') || contains(tags,'prod'))].{tags:join(',',tags), imageSize:imageSize}" -o table 2>/dev/null
```

```output
2026/10/02 19:52:31 logged in via /var/folders/.../config.json
payments-api  naive  layers=10  compressed= 317.9 MB  user=(empty: root)
payments-api  prod   layers=2   compressed=   3.4 MB  user=65532
patient-api   naive  layers=6   compressed=  44.9 MB  user=(empty: root)
patient-api   prod   layers=13  compressed=  27.6 MB  user=65532
Tags        ImageSize
----------  -----------
naive       333388077
1.0.0,prod  3585129
```

Then look inside the small one (3.4 MB, safe to stream through the laptop) and at its history:

```bash
crane export $ACR.azurecr.io/labs/payments-api:prod - | tar -t | grep -E '^(usr/)?s?bin/'
crane config $ACR.azurecr.io/labs/payments-api:prod | jq -r '.history[].created_by' | cut -c1-80
crane config $ACR.azurecr.io/labs/payments-api:naive | jq '.config | {User, Cmd, WorkingDir}'
```

```output
usr/bin/payments-api
apko
/bin/sh -c #(nop) COPY file:f94a5cd2110d4c9c9368137a81edd07aa7105c65d28ce20c7541
/bin/sh -c #(nop)  USER 65532
/bin/sh -c #(nop)  EXPOSE 8080
/bin/sh -c #(nop)  ENTRYPOINT ["/usr/bin/payments-api"]
{
  "User": "",
  "Cmd": [
    "/bin/sh",
    "-c",
    "payments-api"
  ],
  "WorkingDir": "/src"
}
```

**What you are seeing:**
- payments-api went from 317.9 MB to 3.4 MB compressed (about 93 times smaller). The production image has one
  executable, `usr/bin/payments-api`; there is no `sh` to exec into and no package manager. Its first layer was
  built by `apko` (the Chainguard `static` base), and the only layer the Dockerfile added is the binary.
- The naive images have an empty `User`, which means root, and a `/bin/sh -c` wrapper as PID 1. The naive Go
  image also kept `/src` with the full source tree and the Go toolchain.
- Layer count is not a size measure. patient-api `prod` has more layers (13) than `naive` (6) because the
  Chainguard `python` base is itself published as 11 layers, yet it is smaller (27.6 MB against 44.9 MB). What
  matters for risk is what is in the layers, which the scan answers.
- `az acr manifest list-metadata` gives the same sizes in bytes without any token, through Azure RBAC. (The
  `1.0.0` tag on the `prod` digest is added in lab 04.)

## 10. Scan the images inside the cluster with grype

The scanner runs as a Job next to the registry, so the 318 MB image never crosses your laptop's connection. The
kubelet can pull from ACR through its managed identity (lab 04), but grype inside the pod is a separate client and
needs its own credentials. Give it a short-lived ACR token as a `dockerconfigjson` Secret in this namespace only,
and delete the Secret when the scans are done. The Job template is
[aks/manifests/01/grype-job.yaml](manifests/01/grype-job.yaml): non-root, read-only root filesystem, no service
account token, the token mounted as `$DOCKER_CONFIG/config.json`, and an `emptyDir` for the vulnerability
database.

```bash
kubectl create secret docker-registry acr-pull -n lab-a-images \
  --docker-server=$ACR.azurecr.io \
  --docker-username=00000000-0000-0000-0000-000000000000 \
  --docker-password="$(az acr login -n $ACR --expose-token --query accessToken -o tsv 2>/dev/null)"
for app in payments-api patient-api; do for t in naive prod; do
  sed -e "s|__NAME__|$app-$t|" -e "s|__IMAGE__|$ACR.azurecr.io/labs/$app:$t|" aks/manifests/01/grype-job.yaml \
    | kubectl apply -f -
done; done
kubectl get events -n lab-a-images --field-selector reason=TriggeredScaleUp -o custom-columns=POD:.involvedObject.name,MSG:.message
kubectl wait -n lab-a-images --for=condition=complete job --all --timeout=15m
kubectl get jobs -n lab-a-images -o custom-columns=NAME:.metadata.name,START:.status.startTime,DONE:.status.completionTime
```

```output
secret/acr-pull created
job.batch/grype-payments-api-naive created
job.batch/grype-payments-api-prod created
job.batch/grype-patient-api-naive created
job.batch/grype-patient-api-prod created
POD                            MSG
grype-patient-api-prod-4n9mp   pod triggered scale-up: [{aks-user-25795745-vmss 2->3 (max: 3)}]
job.batch/grype-patient-api-naive condition met
job.batch/grype-patient-api-prod condition met
job.batch/grype-payments-api-naive condition met
job.batch/grype-payments-api-prod condition met
NAME                       START                  DONE
grype-patient-api-naive    2026-10-02T14:24:03Z   2026-10-02T14:31:33Z
grype-patient-api-prod     2026-10-02T14:24:04Z   2026-10-02T14:30:01Z
grype-payments-api-naive   2026-10-02T14:24:00Z   2026-10-02T14:31:43Z
grype-payments-api-prod    2026-10-02T14:24:01Z   2026-10-02T14:31:30Z
```

Each Job prints grype's JSON report to its log. Summarize it on your machine:

```bash
for app in payments-api patient-api; do for t in naive prod; do
  printf '%-13s %-6s ' $app $t
  kubectl logs -n lab-a-images job/grype-$app-$t | jq -r '"total=\(.matches|length) "
    + ([.matches[].vulnerability.severity] | group_by(.) | map("\(.[0])=\(length)") | join(" "))
    + " fixable=\([.matches[] | select(.vulnerability.fix.state=="fixed")] | length)"'
done; done
kubectl logs -n lab-a-images job/grype-payments-api-prod | jq -r '"\(.descriptor.name) \(.descriptor.version), db built \(.descriptor.db.status.built)"'
kubectl delete secret acr-pull -n lab-a-images
```

```output
payments-api  naive  total=1258 Critical=61 High=228 Low=51 Medium=179 Negligible=703 Unknown=36 fixable=237
payments-api  prod   total=0  fixable=0
patient-api   naive  total=160 High=53 Low=10 Medium=52 Negligible=45 fixable=2
patient-api   prod   total=6 Low=1 Medium=5 fixable=0
grype 0.119.0, db built 2026-10-02T06:31:53Z
secret "acr-pull" deleted from lab-a-images namespace
```

**What you are seeing:**
- The four pods asked for 512 Mi each. With other workloads on the two user nodes, one could not be placed, and
  the cluster autoscaler grew the `aks-user-...-vmss` scale set from 2 to 3 nodes (its configured maximum). It
  scales back down on its own after the nodes are idle.
- Each scan took 6 to 8 minutes, most of it downloading and loading the vulnerability database in each pod.
- payments-api: 1,258 findings with 61 critical in the naive image, 0 in the production image. The naive findings
  are almost all Debian packages from `golang:1.25` that the service never uses. The production image holds four
  packages (CA certificates, tzdata, the base layout and the Go standard library compiled into the binary).
- patient-api: 160 findings with 53 high on `python:3.13-slim`, against 6 low or medium on the Chainguard
  runtime, none with a fix available yet. Those six are the ones worth tracking.
- The token Secret is gone. It carried your own push and delete rights, which is why it lived only in this
  namespace and only for the scans.

## On AKS specifically

- `az acr build` is an ACR Tasks quick task: it sends the context to the registry and, by default, pushes the
  built image when the build completes. ACR Tasks builds for Linux AMD64 unless you pass `--platform`.
- ACR Tasks stores the log of every run. By default logs are kept for 30 days; `az acr task logs --run-id`
  retrieves one. For longer retention, copy logs to your own storage.
- In a task file, `env: ["DOCKER_BUILDKIT=1"]` on a `build` step turns on BuildKit. The default step timeout in a
  task file is 600 seconds; `az acr build` ran with 28,800 seconds here.
- An ACR task can track the base image dependency of the images it builds and rebuild them when the base is
  updated, including in a public registry such as Docker Hub. Each run also ends with the dependency report you
  read in steps 3 and 4.
- ACR Tasks run time is billed per second on every tier. Dedicated agent pools for Tasks are a Premium feature.
- Microsoft notes that ACR Tasks runs are temporarily paused for subscriptions on Azure free credits, and that
  anything on the command line can end up in diagnostic logs: never pass secrets as `--build-arg`.
- The Basic tier includes 10 GiB of storage. The naive Go image alone uses about 318 MB of it.

## In the conversation

**Why it matters in production.** The base image and the build recipe decide most of a container's
vulnerability count before anyone writes code, and every finding has to be triaged by someone. A multi-stage
build with tests in the build stage gives one artifact that is small, has no shell or compiler for an attacker to
use, and could only be produced if the tests passed. Building in ACR Tasks puts the build next to the registry and
leaves a run history, so "which base digest is in production, and did the tests pass for it" has an answer.

**A story from this lab.** When I moved the payments-api build into ACR Tasks, the production Dockerfile failed on
its first run with "the --mount option requires BuildKit". The Dockerfile used a cache mount, which works in
`docker buildx` but not in `az acr build`, because the agent's Docker CLI uses the classic builder. I had two
fixes: a task file with `DOCKER_BUILDKIT=1`, or removing the BuildKit-only feature. I removed it, because the cache
mount bought nothing on agents that start empty every time, and the same Dockerfile now builds identically in CI
and in Azure. The result, measured on the same day with the same grype database: 317.9 MB with 1,258 findings
(61 critical) for the naive build, 3.4 MB with zero for the production one.

**Follow-up questions to expect.**
- *Why not just use a cache in ACR Tasks?* You can: a registry cache took a rebuild from 71 s to 11 s here. But on
  a cache hit BuildKit skipped the test step, so for release builds I either run tests as their own step or build
  without cache. The time saved matters less than the evidence.
- *If the bases are pinned by digest, how do you get patches?* A bot opens a pull request with the new digests
  (the repository uses digestabot), and a nightly build overrides the ARGs to test today's `latest`, as in step 8.
  The pin makes the build reproducible; the override is the early warning.
- *The Chainguard Python image has more layers. Is that worse?* No. Layers are a unit of transfer and caching, not
  of risk. It was smaller (27.6 MB against 44.9 MB) and had 6 findings against 160.
- *Does zero findings mean zero vulnerabilities?* It means grype matched no known vulnerability to the packages
  it identified, with the database built that morning. That is why the scan runs on every build and again on a
  schedule against what is deployed.

## If something looks different

- Runs fail or never start on a subscription that runs on Azure free credits: Microsoft has paused ACR Tasks runs
  for those. Use a pay-as-you-go subscription.
- `jq: parse error` on the naive Go scan: its JSON report is about 20 MB. If your node rotates container logs
  below that size, run that one Job with `--output table` instead and count by the severity column.
- A grype Job stays `Pending` with `Insufficient memory`: the user pool is at its maximum of 3 nodes. Run the four
  scans one after another instead of together.
- Your digests and sizes differ: Chainguard and Docker Hub publish new base digests often. The shape of the
  comparison stays the same.

## Clean up

```bash
kubectl delete namespace lab-a-images
# Optional: remove the lab images. Lab 04 uses labs/payments-api:prod, so keep payments-api if you continue.
az acr repository delete -n $ACR --repository labs/patient-api --yes
```

## Checkpoint

1. A build in ACR Tasks fails at `RUN --mount=type=secret,...`. What are your two options?
   _Hint: think about which builder `az acr build` uses, and what a task file's `env` can change._
2. Two builds from the same commit and the same base digests produced different image digests. Is something
   wrong?
   _Hint: compare what the image config records with what the layers contain._
3. Why does the grype Job need a Secret when the kubelet can already pull from ACR?
   _Hint: who is the client in each case, and which identity does each one present?_

## Further reading

- [Automate container builds with ACR Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
- [ACR Tasks YAML reference](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-reference-yaml)
- [View ACR Tasks run logs](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-logs)
- [Multi-stage builds (Docker docs)](https://docs.docker.com/build/building/multi-stage/)
- [Inline cache (Docker docs)](https://docs.docker.com/build/cache/backends/inline/)
- [Getting started with the Chainguard Go images](https://edu.chainguard.dev/chainguard/containers/getting-started/languages-and-runtimes/go/)
- [Using grype to scan software artifacts (Chainguard Academy)](https://edu.chainguard.dev/chainguard/containers/security-and-compliance/working-with-scanners/grype-tutorial/)
