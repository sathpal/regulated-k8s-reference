# Regulated Kubernetes Reference: banking and healthcare

A working reference implementation of how I take containerized services into production for regulated
customers with a delivery partner: a payments service for a bank and a patient-records service for a
healthcare provider, built, secured, tested, deployed and rolled back the same way.

| | Bank: `payments-api` (Go) | Healthcare: `patient-api` (Python) |
|---|---|---|
| Data | Card data, PCI DSS scope | Patient records (PHI), HIPAA / DPDP |
| App controls | PAN masked (first 6, last 4), idempotent payments, JSON audit log | Role-based access, minimum-necessary views, audit log with no PHI |
| Image | Multi-stage onto `cgr.dev/chainguard/static`, uid 65532, no shell | Tests in a `-dev` stage, ships on `cgr.dev/chainguard/python`, uid 65532 |
| Namespace | `bank-payments`, Pod Security `restricted` | `health-records`, Pod Security `restricted` |
| Release | Manual sync inside the change window (CAB) | Automatic sync of pre-approved digest bumps |

## What is in here

```text
apps/payments-api      Go service, tests, Dockerfile (production) and Dockerfile.naive (for comparison)
apps/patient-api       Python service (standard library only), tests, both Dockerfiles
k8s/base/<app>         Deployment (probes, resources, rollout settings, hardened securityContext), Service,
                       PodDisruptionBudget, HorizontalPodAutoscaler, ServiceAccount without a token,
                       default-deny NetworkPolicy plus an allow rule
k8s/overlays           bank-prod, health-prod (namespaces with Pod Security labels), bank-prod-artifactory, e2e
policy/kyverno/cluster admission policies: allowed registries, no :latest, resources and probes, data label
policy/kyverno/prod    signature verification for production (keyless, this repo's release workflow)
policy/kyverno/tests   16 policy tests: each policy refuses the pod built to break it, admits the real workloads
policy/kyverno/artifactory  Artifactory-only admission for a JFrog customer (3 tests)
jfrog                  Artifactory repository layout for Chainguard and what was verified against a real JCR
scripts/e2e-kind.sh    build -> kind -> Kyverno -> deploy -> smoke test -> admission refusals -> bad release + rollback
scripts/compare-images.sh  naive vs production Dockerfile: size, user, shell, CVEs (same scanner, same database)
.github/workflows      delivery: verify -> evidence -> e2e on kind -> publish by digest, sign, attest (main)
                       nightly-latest: build and test against today's latest bases (early warning)
                       digestabot: daily pull request with new base-image digests
gitops                 Argo CD Applications: pull-based promotion by digest
docs                   the playbook, compliance mapping, onboarding and deployment strategy
```

## Run it

```bash
# Unit tests, manifests and policies (no Docker needed)
(cd apps/payments-api && go test ./...)
(cd apps/patient-api && python3 -m unittest -v test_app)
kubectl kustomize k8s/overlays/e2e
kyverno test policy/kyverno/tests

# The whole path on a local cluster (needs docker, kind, kubectl, helm)
scripts/e2e-kind.sh          # KEEP=1 keeps the cluster afterwards
scripts/compare-images.sh    # needs grype and jq
```

## Read next

- [aks/](aks/): hands-on deep dive of every topic on a real AKS cluster
- [docs/examples](docs/examples): a commented security-focused multi-stage Dockerfile and the sign, attest and verify flow
- [docs/compliance-mapping.md](docs/compliance-mapping.md): control, where it is implemented, what the evidence is
- [docs/onboarding-and-deployment.md](docs/onboarding-and-deployment.md): onboarding plan with a partner, deployment strategies, cutover and rollback
