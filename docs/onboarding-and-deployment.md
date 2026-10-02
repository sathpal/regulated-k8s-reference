# Onboarding and deployment strategy with a delivery partner

## Who does what (RACI)

R = responsible, A = accountable, C = consulted, I = informed.

| Activity | Customer platform and security | Partner (SI or MSP) | Partner SA (me) |
|---|---|---|---|
| Success criteria and wave plan | A | R | C |
| Image inventory and baseline scan | C | R | C (method, scripts) |
| Golden Dockerfiles, pipeline template, policy pack | C | R from wave 1 | R in wave 0, then C |
| Landing zone, network, identity | A, R | C | C |
| Migration of each service | I | A, R | C (wave 0 pairing) |
| Policy rollout: Audit, exceptions, Enforce | A | R | C |
| Production change approval | A (CAB) | R (change record) | I |
| Escalations to Chainguard product and support | I | R (raise) | A (triage, follow through) |

## Onboarding plan

| Week | Milestone | Exit criteria |
|---|---|---|
| 0 | Kickoff with customer, partner and me | Success criteria agreed and written down; scope and waves drafted |
| 1 to 2 | Discovery | Every image listed with owner; baseline findings with one scanner and database; risky patterns found (root users, shell entrypoints, curl healthchecks, logs or state on local disk, secrets in images) |
| 2 to 4 | Wave 0: prove the path with one non-regulated service | Built, scanned, signed, deployed by digest through GitOps, rolled back in a drill; partner engineers did the work |
| 4 to 8 | Wave 1: low-risk services | Partner migrates with the golden templates; policies in Audit, reports reviewed weekly |
| 8 to 12 | Wave 2: regulated scope (CDE or PHI) | Dedicated node pool or cluster as agreed; policies in Enforce; canary or blue/green in place; evidence pack for audit |
| 12 onward | Hand over and run | Partner runs waves without me; CVE runbook rehearsed; monthly report on the success metrics |

### Discovery questions that save weeks
- Which registry does every artifact pass through, and who controls it? (Artifactory, ACR, Harbor)
- Can clusters reach `cgr.dev`, or only the internal registry? Proxies, TLS inspection, allowlists?
- Which builder does CI use? (BuildKit, legacy Docker builder in ACR Tasks, Kaniko, Buildah)
- How are changes approved in production? Change windows, freeze periods, CAB?
- What does the security team scan with, and which findings block a release today?
- Who owns an exception, and when does it expire?
- Which services need a shell, package manager or specific OS at runtime, and why?

### Quality gates (a service is "done" when all pass)
1. Builds from the golden template, multi-stage, numeric non-root user, exec-form entrypoint.
2. Scan gate: no fixable critical or high findings; remaining findings triaged.
3. SBOM and signature attached; deployed by digest.
4. Passes Pod Security `restricted` with read-only root and no capabilities.
5. Readiness, liveness and startup probes that mean something; requests and a memory limit.
6. Handles SIGTERM: fails readiness, drains, exits 0.
7. No secrets in the image, environment variables from ConfigMaps, or Git.
8. Rollback rehearsed at least once in a non-production environment.

## Deployment strategies: which, and when

| Strategy | Use it for | Why | In this repo |
|---|---|---|---|
| Rolling update, `maxUnavailable: 0`, readiness gates | Most stateless APIs | Full capacity throughout; a release that never becomes ready is contained | Base Deployment; rehearsed in [e2e-kind.sh](../scripts/e2e-kind.sh) |
| Canary with automated analysis | Payment and other high-value paths | Small blast radius; promotion based on error rate and latency, not on hope | Argo Rollouts or Flagger on top of the same manifests |
| Blue/green | Clinician-facing changes, anything needing an instant switch back | Two full environments; switch and switch back in seconds | Two Deployments behind one Service selector, or the rollout tool |
| Expand and contract | Schema and contract changes | Old and new code both work during the transition | Release plan, not a manifest |
| Feature flags | Behaviour changes inside one release | Decouple deploy from release | Application concern |

### Cutover and rollback plan (template)
1. **Before the window:** digest built, scanned, signed and verified; change approved; rollback digest recorded;
   dashboards for error rate, latency and saturation open; decision makers named.
2. **During:** sync the GitOps change; watch rollout status and the canary analysis; smoke tests from outside.
3. **Go or no-go at each step:** pre-agreed thresholds (for example error rate above 0.5 percent or p99 latency
   above the baseline by 20 percent means roll back).
4. **Rollback:** revert the GitOps pull request (or `kubectl rollout undo` in an emergency, then reconcile Git).
   Rehearsed, so nobody improvises at 2 a.m.
5. **After:** hypercare window, release notes, update the runbook with anything that surprised you.

### Base-image updates are releases too
Pin base images by digest. Let automation (Renovate, Digestabot) open a pull request when a new digest
is published. CI builds, tests and scans it; it goes through the same canary as code. That turns "patch the
operating system" from an emergency into a normal, tested release, which is what makes a one-month patch SLA
achievable.
