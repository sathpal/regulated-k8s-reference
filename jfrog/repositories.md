# Artifactory repositories for Chainguard (reference)

Three Docker repositories, following Chainguard's Artifactory pull-through guide:

| Key | Type | Purpose |
|---|---|---|
| `cgr-remote` | Remote, URL `https://cgr.dev` | Pull-through cache for Chainguard images. Public images need no credentials; a private Chainguard organization uses a pull token as the remote's username and password. |
| `apps-local` | Local | The bank's own images, pushed by CI only (a CI user with deploy rights; developers read). |
| `docker` | Virtual: `apps-local` + `cgr-remote` | The single address developers, CI and clusters use: `bank.jfrog.io/docker/...` |

What I verified when I ran this against a real JFrog Container Registry (JFrog's free Artifactory edition):

- Images pulled through `cgr-remote` have the same digests as on `cgr.dev`.
- Chainguard's signature, SBOM and provenance verify through Artifactory with `cosign verify` and
  `cosign verify-attestation`, using Chainguard's keyless identity.
- An anonymous push was refused, and so was a push into the Chainguard cache.
- Re-pushing a tag in `apps-local` deleted the old image by default, so a pod pinned to the old digest got
  `MANIFEST_UNKNOWN` when it rescheduled. Deploy by digest, never re-push a released tag, and set retention.
- The remote caches metadata (6 hours by default in the version I used), so a moved upstream tag appears
  after the cache period; digests are unaffected.
- Xray is not part of the free edition; in a licensed Artifactory it scans `apps-local` and `cgr-remote`
  and can block downloads that violate the bank's policies.

Sources: Chainguard Academy, "Artifactory pull-through for Chainguard Containers"
(edu.chainguard.dev/chainguard/containers/registry/pull-through-guides/artifactory-containers-pull-through/).
