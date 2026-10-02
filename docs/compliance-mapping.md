# Compliance mapping: control, implementation, evidence

Compliance frameworks rarely mention containers. Each row maps a control to what the platform does and to the
evidence an auditor can read. These controls *support evidence for* compliance; the assessment itself belongs to
the customer's QSA, auditor or compliance team.

## Banking: PCI DSS v4.0 (card data), RBI and CERT-In (India)

| Control | Implementation in this repo | Evidence |
|---|---|---|
| PCI DSS 1.3: restrict traffic to and from the cardholder data environment | Default-deny NetworkPolicy, ingress only from the ingress namespace, egress only to DNS ([networkpolicy.yaml](../k8s/base/payments-api/networkpolicy.yaml)); dedicated node pool or cluster for the CDE agreed with the QSA | Rendered policy, connection tests |
| PCI DSS 2.2: secure configuration standards | Pod Security `restricted` on the namespace; hardened `securityContext`; Kyverno policies | Namespace labels, admission refusals in [e2e-kind.sh](../scripts/e2e-kind.sh) |
| PCI DSS 3.4.1: PAN masked when displayed (BIN and last four at most) | `maskPAN` in [main.go](../apps/payments-api/main.go) | `TestPaymentNeverExposesFullPAN` |
| PCI DSS 6.3.2: inventory of bespoke software and third-party components | SBOM generated and attested for every release ([delivery.yml](../.github/workflows/delivery.yml)) | `cosign verify-attestation --type spdxjson` |
| PCI DSS 6.3.3: critical patches within one month | Minimal base images rebuilt continuously, digest pins bumped by automation, scan gate on fixable high findings | Pipeline history, time from CVE to deployed digest |
| PCI DSS 7.2: least-privilege access | No service-account token; RBAC per namespace | `kubectl auth can-i --list` |
| PCI DSS 10.2: audit logs | One JSON audit line per request with request id, caller, status, duration | Log pipeline, `kubectl logs` |
| PCI DSS 10.5.1: keep audit logs 12 months, 3 months immediately available | Logs to stdout, shipped and retained by the log platform (not on the pod) | Log retention settings |
| PCI DSS 11.3.1: internal vulnerability scans every three months | Scan on every build, rescan of running digests on a schedule | Scan reports per digest |
| RBI IT governance and cyber security expectations: change, patch and vulnerability management | GitOps pull request as the change record; manual sync in the approved window ([gitops](../gitops/argocd-applications.yaml)) | Pull request, CAB reference, Argo CD history |
| CERT-In directions (April 2022): report incidents within 6 hours; keep logs 180 days in India | Structured audit logs to an in-region log store; incident runbook with SBOM-based impact analysis | Retention configuration, runbook timestamps |

## Healthcare: HIPAA Security Rule (US), DPDP Act 2023 (India)

| Control | Implementation | Evidence |
|---|---|---|
| HIPAA 164.308(a)(1)(ii)(A): risk analysis | Image findings per release, admission reports, data classification label on every workload | Scan reports, PolicyReports |
| HIPAA 164.308(b) / 164.314(a): business associate agreements | BAA with the cloud provider and with the MSP before PHI is processed | Contracts (outside the platform) |
| HIPAA 164.312(a)(1): access control | Role required for every read; least-privilege RBAC; no token in pods | `test_no_role_is_denied_and_audited` |
| HIPAA Privacy Rule: minimum necessary (164.502(b)) | Role-based views: a records clerk never receives clinical notes | `test_clerk_gets_minimum_necessary` |
| HIPAA 164.312(b): audit controls | Every access, allowed or denied, logged with user, role, record and outcome, no PHI | `test_audit_never_contains_phi` |
| HIPAA 164.312(c)(1): integrity | Signed images verified at admission; read-only root filesystem | `cosign verify`, Kyverno report |
| HIPAA 164.312(a)(2)(iv), (e)(2)(ii): encryption (addressable) | TLS at the gateway and between services; etcd encryption with a customer-managed key; secrets from Key Vault | Cluster configuration |
| HIPAA 164.316(b)(2)(i): keep documentation six years | Policies, runbooks and release records in Git | Repository history |
| DPDP Act 2023: purpose limitation, security safeguards, breach notification | Minimum-necessary views, audit logs, incident runbook | As above |

## Cross-industry: NIST SP 800-190 (Application Container Security Guide)

| Risk area | Countermeasure here |
|---|---|
| Image vulnerabilities and configuration defects | Minimal non-root images, scan gate, multi-stage builds |
| Embedded secrets | `.dockerignore` allowlists; secrets from an external store, never in images or ConfigMaps |
| Untrusted images | Registry allowlist and signature verification at admission |
| Registry risks | Pull through the customer's registry, signatures kept, deploy by digest, retain released digests |
| Orchestrator risks | Pod Security `restricted`, RBAC, NetworkPolicy, no service-account tokens |
| Container runtime and host risks | seccomp RuntimeDefault, capabilities dropped, no privilege escalation, managed node images |
