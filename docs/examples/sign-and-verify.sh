#!/usr/bin/env bash
# =====================================================================================================
# Reference: how the image from Dockerfile.secure-multistage is verified, built, signed, attested and
# checked again before it runs. For reading and discussion, in pipeline order.
#
# The one rule behind all of it: sign and deploy the DIGEST, never a tag. A tag can be moved to point at
# different content after it was signed; a digest is the content.
# =====================================================================================================
set -euo pipefail

IMAGE=registry.example.com/payments-api
VERSION=1.4.2
WORKFLOW_ID="https://github.com/example/payments-api/.github/workflows/release.yml@refs/heads/main"
OIDC_ISSUER="https://token.actions.githubusercontent.com"


# -----------------------------------------------------------------------------------------------------
# 1. Before building: trust the base images
# -----------------------------------------------------------------------------------------------------
# Resolve the base tags to digests, then check Chainguard signed exactly those digests from its release
# workflow. If anyone tampered with the image or the registry, verification fails and the build stops.
BUILD_DIGEST=$(crane digest cgr.dev/chainguard/python:latest-dev)
RUNTIME_DIGEST=$(crane digest cgr.dev/chainguard/python:latest)
for ref in "cgr.dev/chainguard/python@${BUILD_DIGEST}" "cgr.dev/chainguard/python@${RUNTIME_DIGEST}"; do
  cosign verify "$ref" \
    --certificate-identity "https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main" \
    --certificate-oidc-issuer "$OIDC_ISSUER" > /dev/null
done


# -----------------------------------------------------------------------------------------------------
# 2. Build and push, with BuildKit's own attestations
# -----------------------------------------------------------------------------------------------------
#  --provenance=mode=max   SLSA provenance: what was built, from which source, with which base digests
#                          and build arguments (one more reason secrets never go in ARG)
#  --sbom=true             BuildKit attaches an SBOM to the pushed image
#  --secret                the private package index credentials, mounted only for the pip install step
#  --metadata-file         lets us read the digest that was actually pushed
docker buildx build \
  --build-arg BUILD_IMAGE="cgr.dev/chainguard/python:latest-dev@${BUILD_DIGEST}" \
  --build-arg RUNTIME_IMAGE="cgr.dev/chainguard/python:latest@${RUNTIME_DIGEST}" \
  --build-arg VERSION="$VERSION" --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --secret id=pip_conf,src="$HOME/.config/pip/pip.conf" \
  --provenance=mode=max --sbom=true \
  --metadata-file build-metadata.json \
  -f Dockerfile.secure-multistage \
  -t "${IMAGE}:${VERSION}" --push .
DIGEST=$(jq -r '."containerimage.digest"' build-metadata.json)
REF="${IMAGE}@${DIGEST}"            # from here on, everything uses the digest


# -----------------------------------------------------------------------------------------------------
# 3. Gate: do not sign something you would not ship
# -----------------------------------------------------------------------------------------------------
# Fail on critical or high findings that already have a fix. Unfixed ones are triaged, not ignored.
grype "$REF" --only-fixed --fail-on high


# -----------------------------------------------------------------------------------------------------
# 4. SBOM you control (in addition to BuildKit's)
# -----------------------------------------------------------------------------------------------------
syft "$REF" -o spdx-json=sbom.spdx.json


# -----------------------------------------------------------------------------------------------------
# 5. Sign. Option A: keyless (Sigstore), the default in CI
# -----------------------------------------------------------------------------------------------------
# The CI job's OIDC identity (here: the GitHub Actions workflow on main) gets a short-lived certificate from
# Fulcio; the signature is recorded in the Rekor transparency log. No private key to store, rotate or leak.
# Requires `permissions: id-token: write` on the GitHub Actions job.
cosign sign --yes "$REF"

# Option B: a key held in a cloud KMS (common in banks that want their own key and audit trail).
# The private key never leaves the KMS; cosign asks it to sign.
#   cosign generate-key-pair --kms azurekms://<vault-name>.vault.azure.net/<key-name>     (once)
#   cosign sign --yes --key azurekms://<vault-name>.vault.azure.net/<key-name> "$REF"
#   (also awskms://, gcpkms://, hashivault://)
#
# Option C: Notation (Notary Project), common with Azure Container Registry and Azure Key Vault:
#   notation sign --key <key-name> "$REF"
#   Pick one signing system per platform; admission policy must verify the one you chose.


# -----------------------------------------------------------------------------------------------------
# 6. Attest: sign statements ABOUT the image (SBOM, scan result, test result)
# -----------------------------------------------------------------------------------------------------
# An attestation binds the SBOM to this exact digest and to the identity that produced it, so an auditor
# can trust the inventory came from the pipeline, not from someone's laptop.
cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$REF"


# -----------------------------------------------------------------------------------------------------
# 7. Verify, as the last pipeline step and as anyone downstream would
# -----------------------------------------------------------------------------------------------------
# Verification checks WHO signed (the exact workflow identity) and WHICH issuer vouched for it,
# not merely that "some signature exists".
cosign verify "$REF" --certificate-identity "$WORKFLOW_ID" --certificate-oidc-issuer "$OIDC_ISSUER" > /dev/null
cosign verify-attestation "$REF" --type spdxjson \
  --certificate-identity "$WORKFLOW_ID" --certificate-oidc-issuer "$OIDC_ISSUER" > /dev/null
# BuildKit's provenance, readable by anyone with pull access:
docker buildx imagetools inspect "$REF" --format '{{ json .Provenance }}' > provenance.json
echo "signed, attested and verified: $REF"


# -----------------------------------------------------------------------------------------------------
# 8. Enforce at the cluster: the signature means nothing if nothing checks it
# -----------------------------------------------------------------------------------------------------
# Kyverno verifyImages (see policy/kyverno/prod/verify-image-signatures.yaml) admits only images signed by
# WORKFLOW_ID, and with mutateDigest rewrites the tag to the verified digest, so the pod runs exactly what
# was verified. Roll out in Audit, read the reports, then Enforce.
#
# Promotion: a GitOps pull request sets this digest in k8s/overlays/<env>/kustomization.yaml.
# The same digest moves from dev to staging to production; nothing is rebuilt along the way.


# -----------------------------------------------------------------------------------------------------
# Things that break signatures in real life
# -----------------------------------------------------------------------------------------------------
# - Copying an image to another registry with `crane copy` or `docker pull/push` copies the image but NOT its
#   signatures and attestations. Use `cosign copy`, or sign again in the target registry.
# - Re-pushing a tag (or a registry that overwrites tags) does not change a signed digest, but if the registry
#   deletes the old manifest, pods pinned to it fail to pull. Never re-push released tags; set retention.
# - Registries without the OCI referrers API store signatures under a sha256-<digest>.sig style tag;
#   mirrors and cleanup jobs must keep those tags.
# - Verifying a tag instead of a digest proves nothing about what will actually be pulled later.
