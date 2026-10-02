# 04. Registry, signing and deploying by digest on AKS

**Goal:** treat the registry as part of the release: see why a tag is only a pointer, make one immutable, bring a
Chainguard image into ACR, understand exactly how AKS nodes are allowed to pull, deploy payments-api by digest,
break a pull on purpose, then sign the deployed digest with a key in Azure Key Vault, attach an SBOM attestation
and verify both.

**You need:** lab 00 (cluster, registry, Key Vault with the `cosign-signing` key, `aks/.lab.env`) and lab 01 (the
image `labs/payments-api:prod`). `az`, `kubectl`, `crane`, `cosign` 3.x and `jq` on your machine; Key Vault Crypto
Officer (or Crypto User) on the vault to sign. About 50 minutes. Cost: step 8 creates a second Basic registry for a
few minutes and deletes it; the SBOM Job runs for about 3 minutes; signing makes a handful of Key Vault operations.

_Outputs captured on 2026-10-02 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

A Kubernetes manifest that says `payments-api:1.0.0` does not say which bytes will run. The tag can be moved,
overwritten or deleted, and every node resolves it again when a pod is rescheduled. A digest names the bytes, a
signature on that digest says who released them, and an attestation says what is inside. On AKS the pull itself is
an Azure identity decision, so a release also depends on which registry the kubelet identity may read.

**What you will learn**
- How ACR shows tags and digests, why an untagged manifest is still there, and what a tag lock does and does not stop.
- That `az acr import` keeps the digest but not the signatures, and two ways to keep verification working.
- How the kubelet's managed identity and the AcrPull role give AKS image pulls without secrets, and what a pull
  from an unattached registry looks like.
- How to sign and attest a digest with cosign and a non-exportable Key Vault key, and where ACR stores the result.
- Where Notation and Azure's Image Integrity fit next to cosign.

## 1. Set up

```bash
cd regulated-k8s-reference
source aks/.lab.env
kubectl apply -f aks/manifests/04/namespace.yaml
export DOCKER_CONFIG=$(mktemp -d)     # an empty Docker config for crane and cosign, removed with the shell
az acr login -n $ACR --expose-token --query accessToken -o tsv 2>/dev/null \
  | crane auth login $ACR.azurecr.io -u 00000000-0000-0000-0000-000000000000 --password-stdin
```

```output
namespace/lab-a-registry created
WARNING! Your credentials are stored unencrypted in '/var/folders/.../config.json'.
Configure a credential helper to remove this warning. See
https://docs.docker.com/go/credential-store/

2026/10/02 20:55:31 logged in via /var/folders/.../config.json
```

**What you are seeing:** `--expose-token` returns a registry token for your own Entra identity instead of calling
`docker login`. It is valid for 3 hours and carries your rights (here push and delete too). The warning is the
reason for the throwaway config directory: the token sits there in plain text until the directory goes. cosign
reads the same `$DOCKER_CONFIG`, so one login serves both tools.

## 2. Tags and digests in ACR

```bash
az acr repository show-tags -n $ACR --repository labs/payments-api --detail --orderby time_desc \
  --query '[].{tag:name, digest:digest, updated:lastUpdateTime}' -o table
az acr manifest list-metadata -r $ACR -n labs/payments-api --orderby time_desc \
  --query '[].{digest:digest, tags:join(`,`, tags || `[]`), size:imageSize}' -o table 2>/dev/null
crane digest $ACR.azurecr.io/labs/payments-api:prod
crane manifest $ACR.azurecr.io/labs/payments-api@sha256:cec49cd996af83a8015e4b3c17a028458b21b6d00853202f4f3312cc276d64e6 | jq -c '{mediaType, layers: (.layers|length)}'
```

```output
Tag           Digest                                                                   Updated
------------  -----------------------------------------------------------------------  ----------------------------
buildkit      sha256:f893b5dc123dadba8d06c3c5c340af13d63c5b35c5569f389c498c57fdea31a4  2026-10-02T14:21:27.1249835Z
latest-bases  sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95  2026-10-02T14:17:55.8966851Z
prod          sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d  2026-10-02T14:16:24.0249023Z
naive         sha256:935a1d6f20861f336675662b9a3087b4e0e1a612680c24a999a2e360eb1ead32  2026-10-02T14:11:57.3673901Z
Digest                                                                   Tags          Size
-----------------------------------------------------------------------  ------------  ---------
sha256:f893b5dc123dadba8d06c3c5c340af13d63c5b35c5569f389c498c57fdea31a4  buildkit      3585131
sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95  latest-bases  3585127
sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d  prod          3585129
sha256:cec49cd996af83a8015e4b3c17a028458b21b6d00853202f4f3312cc276d64e6                3585130
sha256:935a1d6f20861f336675662b9a3087b4e0e1a612680c24a999a2e360eb1ead32  naive         333388077
sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":2}
```

**What you are seeing:** tags are rows that point at digests; manifests are the content. There are five manifests
but four tags: `cec49cd...` is the first `prod` build of the day. When `prod` was pushed again, the tag moved to
`d2315b...` without any warning, and the old manifest stayed behind untagged. It is still complete and pullable by
digest, which is exactly what keeps a pod pinned to it running after the tag moves. It also costs storage until
something deletes it. Four of the manifests are builds of the same source, and nothing in the tag list tells you
that.

## 3. A tag is a pointer: move one

Give the release a version tag, then move it the way a rebuild or a mistaken push would. `az acr import` copies
inside Azure, so it also works as a server-side retag.

```bash
DIGEST=$(az acr manifest show-metadata -r $ACR -n labs/payments-api:prod --query digest -o tsv 2>/dev/null)
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api:prod --image labs/payments-api:1.0.0
az acr manifest show-metadata -r $ACR -n labs/payments-api:1.0.0 --query digest -o tsv 2>/dev/null
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api:latest-bases --image labs/payments-api:1.0.0
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api:latest-bases --image labs/payments-api:1.0.0 --force
az acr manifest show-metadata -r $ACR -n labs/payments-api:1.0.0 --query digest -o tsv 2>/dev/null
```

```output
sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
ERROR: (Conflict) Operation registries-8a819782-be6e-11f1-993e-ee0880be6ca1 failed. Resource /subscriptions/.../registries/acrregk8s1e1193 Tag labs/payments-api:1.0.0 already exists in target registry.
Code: Conflict
sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95
```

**What you are seeing:** `az acr import` refuses to overwrite a tag unless you add `--force`; with it, `1.0.0`
now means a different build. A `docker push` or `az acr build -t ...:1.0.0` would have moved it without asking at
all, as `prod` moved in step 2. Anything deployed as `payments-api:1.0.0` would get the other bytes on its next
pull.

## 4. Lock the release tag, and find the limit of the lock

Put the tag back on the release digest, then lock it: `--write-enabled false` stops updates and
`--delete-enabled false` stops deletion.

```bash
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api@$DIGEST --image labs/payments-api:1.0.0 --force
az acr repository update -n $ACR --image labs/payments-api:1.0.0 --write-enabled false --delete-enabled false -o json
```

```output
{
  "changeableAttributes": {
    "deleteEnabled": false,
    "listEnabled": true,
    "readEnabled": true,
    "writeEnabled": false
  },
  "createdTime": "2026-10-02T14:35:29.3151407Z",
  "digest": "sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d",
  "lastUpdateTime": "2026-10-02T14:36:21.5428174Z",
  "name": "1.0.0",
  "signed": false
}
```

Now try to move it again, first with the same forced import, then with a plain registry push of a tag (what
`docker push` and `crane tag` do):

```bash
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api:latest-bases --image labs/payments-api:1.0.0 --force
az acr repository show -n $ACR --image labs/payments-api:1.0.0 --query '{digest:digest, write:changeableAttributes.writeEnabled}' -o json
crane tag $ACR.azurecr.io/labs/payments-api@$DIGEST 1.0.0
```

```output
{
  "digest": "sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95",
  "write": false
}
Error: PUT https://acrregk8s1e1193.azurecr.io/v2/labs/payments-api/manifests/1.0.0: REGISTRY_DISALLOWED_OPERATION: The operation is disallowed on this registry, repository or image. View troubleshooting steps at https://aka.ms/acr/faq/#why-does-my-pull-or-push-request-fail-with-disallowed-operation-; map[]
```

**What you are seeing:** this is the most useful result in the lab. The registry API refused the tag push with
`REGISTRY_DISALLOWED_OPERATION`, as documented. But the forced `az acr import`, an Azure Resource Manager operation
run by someone with Owner rights, moved the locked tag anyway and left `writeEnabled: false` in place, so the lock
still *looks* intact. (Observed with Azure CLI 2.90 on 2026-10-02; Microsoft's lock article does not mention
import.) A lock is a guardrail against pipelines and people pushing by mistake, not a control against the
registry's administrators. The controls that hold are RBAC (few identities with import or push rights on release
repositories) and deploying by digest, so a moved tag changes nothing that runs.

Restore the release tag and protect the manifest itself from deletion. Tag and manifest attributes are separate, so
the digest needs its own lock:

```bash
az acr repository update -n $ACR --image labs/payments-api:1.0.0 --write-enabled true --delete-enabled true -o none
az acr import -n $ACR --source $ACR.azurecr.io/labs/payments-api@$DIGEST --image labs/payments-api:1.0.0 --force
az acr repository update -n $ACR --image labs/payments-api:1.0.0 --write-enabled false --delete-enabled false \
  --query '{digest:digest, name:name, attrs:changeableAttributes}' -o json
az acr repository update -n $ACR --image labs/payments-api@$DIGEST --delete-enabled false \
  --query '{digest:digest, attrs:changeableAttributes}' -o json
```

```output
{
  "attrs": {
    "deleteEnabled": false,
    "listEnabled": true,
    "readEnabled": true,
    "writeEnabled": false
  },
  "digest": "sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d",
  "name": "1.0.0"
}
{
  "attrs": {
    "deleteEnabled": false,
    "listEnabled": true,
    "readEnabled": true,
    "writeEnabled": true
  },
  "digest": "sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d"
}
```

**What you are seeing:** `1.0.0` points at `d2315b...` again and cannot be pushed over or deleted, and the manifest
cannot be deleted even if someone removes the tag. The manifest stays writable on purpose: signatures in step 9
are separate manifests that refer to it.

## 5. Import a Chainguard image from cgr.dev and compare digests

```bash
az acr import -n $ACR --source cgr.dev/chainguard/static:latest --image chainguard/static:latest
echo "cgr.dev: $(crane digest cgr.dev/chainguard/static:latest)"
echo "ACR:     $(az acr manifest show-metadata -r $ACR -n chainguard/static:latest --query digest -o tsv 2>/dev/null)"
crane manifest $ACR.azurecr.io/chainguard/static:latest | jq -r '.mediaType, (.manifests[] | "\(.platform.os)/\(.platform.architecture) \(.digest)")'
```

```output
cgr.dev: sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
ACR:     sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
application/vnd.oci.image.index.v1+json
linux/amd64 sha256:a40219f3b0c2719e4e4220310e80a2230a4b95881644292c130e3a8e8287fc6c
linux/arm64 sha256:daed076c904e5dc26f5ff87d77aa4cea8b7ca76e906b561915dafe5b086377dc
```

The digest survived the copy, and so did the multi-architecture index. Now check Chainguard's signature on both
copies:

```bash
D=sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
ID=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
ISS=https://token.actions.githubusercontent.com
cosign verify cgr.dev/chainguard/static@$D --certificate-identity=$ID --certificate-oidc-issuer=$ISS | head -c 300; echo
cosign verify $ACR.azurecr.io/chainguard/static@$D --certificate-identity=$ID --certificate-oidc-issuer=$ISS
```

```output
Verification for cgr.dev/chainguard/static@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
...
Error: no signatures found
error during command execution: no signatures found
```

**What you are seeing:** the bytes are identical but the signature did not come along. Chainguard stores it next to
the image in cgr.dev as a separate `sha256-<digest>.sig` manifest, and `az acr import` copied only the image you
named. An admission policy that requires Chainguard's signature would now reject the mirrored copy. Two fixes:

```bash
# 1. Verify the ACR copy, reading the signatures from where they were published.
COSIGN_REPOSITORY=cgr.dev/chainguard/static cosign verify $ACR.azurecr.io/chainguard/static@$D \
  --certificate-identity=$ID --certificate-oidc-issuer=$ISS | head -c 200; echo
# 2. Copy the image together with its signatures and attestations.
cosign copy --force cgr.dev/chainguard/static@$D $ACR.azurecr.io/chainguard/static:latest
cosign verify $ACR.azurecr.io/chainguard/static@$D --certificate-identity=$ID --certificate-oidc-issuer=$ISS \
  | jq -r '.[0].optional.Subject'
```

```output
Verification for acrregk8s1e1193.azurecr.io/chainguard/static@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327 --
The following checks were performed on each of these signatures:
...
Copying cgr.dev/chainguard/static:sha256-a40219f3b0c2719e4e4220310e80a2230a4b95881644292c130e3a8e8287fc6c.sig to acrregk8s1e1193.azurecr.io/chainguard/static:sha256-a40219f3b0c2719e4e4220310e80a2230a4b95881644292c130e3a8e8287fc6c.sig...
...
Copying cgr.dev/chainguard/static@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327 to acrregk8s1e1193.azurecr.io/chainguard/static:latest...
https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
```

**What you are seeing:** `COSIGN_REPOSITORY` points the verifier at another repository for the signatures, which
is handy when you mirror many images and verify against the source. `cosign copy` brought the index, both platform
images, their `.sig` signatures and `.att` attestations (Chainguard's SBOMs and provenance), so the ACR copy now
verifies on its own. The Subject is the Chainguard release workflow that signed this digest. `crane copy`,
`docker pull`/`docker push` and `az acr import` all behave like the import here: same digest, no signatures.

## 6. How AKS pulls from ACR

```bash
az aks show -g $RG -n $AKS --query '{nodeResourceGroup:nodeResourceGroup, kubelet:identityProfile.kubeletidentity}' -o json
KUBELET_OID=$(az aks show -g $RG -n $AKS --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --assignee $KUBELET_OID --all --query '[].{role:roleDefinitionName, scope:scope}' -o table
az vmss list -g MC_${RG}_${AKS}_${LOC} --query '[].{name:name, identities:join(`, `, keys(identity.userAssignedIdentities))}' -o json
AAD_LOGIN_METHOD=azurecli az aks check-acr -g $RG -n $AKS --acr $ACR.azurecr.io
```

```output
{
  "kubelet": {
    "clientId": "55a5dec9-13a3-43f0-bfd0-58026851030b",
    "objectId": "d778a365-b83f-426c-8c00-932af5ddc615",
    "resourceId": "/subscriptions/.../resourcegroups/MC_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-handson-agentpool"
  },
  "nodeResourceGroup": "MC_rg-aks-handson_aks-handson_centralindia"
}
Role     Scope
-------  --------------------------------------------------------------------------------------------------------------------------------------------------
AcrPull  /subscriptions/.../resourceGroups/rg-aks-handson/providers/Microsoft.ContainerRegistry/registries/acrregk8s1e1193
[
  {
    "identities": "/subscriptions/.../MC_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-handson-agentpool, /subscriptions/.../MC_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/azurekeyvaultsecretsprovider-aks-handson",
    "name": "aks-system-11091932-vmss"
  },
  {
    "identities": "/subscriptions/.../MC_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-handson-agentpool, /subscriptions/.../MC_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/azurekeyvaultsecretsprovider-aks-handson",
    "name": "aks-user-25795745-vmss"
  }
]
WARNING: Merged "aks-handson" as current context in /var/folders/.../tmptw6kjdzy
WARNING: Converted kubeconfig to use Azure CLI authentication.
[2026-10-02T14:40:38Z] Checking host name resolution (acrregk8s1e1193.azurecr.io): SUCCEEDED
[2026-10-02T14:40:38Z] Canonical name for ACR (acrregk8s1e1193.azurecr.io): r0922cin-az.centralindia.cloudapp.azure.com.
[2026-10-02T14:40:38Z] ACR location: centralindia
[2026-10-02T14:40:38Z] Checking managed identity...
[2026-10-02T14:40:38Z] Kubelet managed identity client ID: 55a5dec9-13a3-43f0-bfd0-58026851030b
[2026-10-02T14:40:38Z] Validating managed identity existance: SUCCEEDED
[2026-10-02T14:40:38Z] Validating image pull permission: SUCCEEDED
[2026-10-02T14:40:38Z]
Your cluster can pull images from acrregk8s1e1193.azurecr.io!
```

**What you are seeing:** the chain behind a pull with no image pull secret.
- AKS created a user-assigned managed identity, `aks-handson-agentpool`, in the node resource group `MC_...`, and
  attached it to both node pool scale sets (the second identity on the VMSS belongs to the Key Vault CSI add-on).
- `--attach-acr` in lab 00 gave that identity one role, `AcrPull`, scoped to one registry. Nothing else.
- On a pull from ACR, the node obtains a token for that identity and exchanges it at the registry for a registry
  token; containerd pulls with it. No secret is stored in the cluster.
- `az aks check-acr` runs a short-lived `canipull` pod on a node (in the `default` namespace, with host network,
  removed when done) and performs the same DNS lookup, identity check and token exchange.
  `AAD_LOGIN_METHOD=azurecli` makes the temporary kubeconfig that `check-acr` writes use your CLI login; without
  it, kubelogin may wait for a device-code sign-in.

Azure manages the identity, its credentials and the token exchange on the nodes. You own which registries it can
read: every `--attach-acr` is a role assignment you should be able to justify.

## 7. Deploy payments-api by digest and prove it runs

[aks/manifests/04/payments-api.yaml](manifests/04/payments-api.yaml) is a hardened Deployment and Service with an
`__IMAGE__` placeholder.

```bash
sed "s|__IMAGE__|$ACR.azurecr.io/labs/payments-api@$DIGEST|" aks/manifests/04/payments-api.yaml | kubectl apply -f -
kubectl rollout status -n lab-a-registry deploy/payments-api --timeout=180s
kubectl get pods -n lab-a-registry -l app.kubernetes.io/name=payments-api \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,IMAGEID:.status.containerStatuses[0].imageID'
kubectl get events -n lab-a-registry --field-selector reason=Pulled -o custom-columns=POD:.involvedObject.name,MSG:.message
```

```output
deployment.apps/payments-api created
service/payments-api created
Waiting for deployment "payments-api" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "payments-api" rollout to finish: 1 of 2 updated replicas are available...
deployment "payments-api" successfully rolled out
POD                             NODE                           IMAGEID
payments-api-85f8cfdd7c-d9jv5   aks-user-25795745-vmss000000   acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
payments-api-85f8cfdd7c-h99cv   aks-user-25795745-vmss000002   acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
POD                             MSG
payments-api-85f8cfdd7c-d9jv5   Successfully pulled image "acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d" in 568ms (568ms including waiting). Image size: 3589006 bytes.
payments-api-85f8cfdd7c-h99cv   Successfully pulled image "acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d" in 678ms (678ms including waiting). Image size: 3589006 bytes.
```

Call it through a port-forward to the Service:

```bash
kubectl port-forward -n lab-a-registry svc/payments-api 8080:80 >/dev/null &
sleep 2
curl -s localhost:8080/version; echo
curl -s -X POST localhost:8080/v1/payments -H 'Idempotency-Key: lab04-1' \
  -d '{"amount_minor":125000,"currency":"INR","card_number":"4111111111111111"}'; echo
curl -s -i -X POST localhost:8080/v1/payments -H 'Idempotency-Key: lab04-1' \
  -d '{"amount_minor":125000,"currency":"INR","card_number":"4111111111111111"}' | head -1
kill %1
kubectl logs -n lab-a-registry -l app.kubernetes.io/name=payments-api --tail=5 | grep audit
```

```output
{"service":"payments-api","version":"dev"}
{"id":"e7eb6db0b546337c","amount_minor":125000,"currency":"INR","card":"411111******1111","status":"authorized","created_at":"2026-10-02T14:41:26Z"}
HTTP/1.1 200 OK
{"time":"2026-10-02T14:41:26.161663214Z","level":"INFO","msg":"audit","request_id":"97e0f59c36599a4a","method":"GET","path":"/version","status":200,"caller":"","duration_ms":0}
{"time":"2026-10-02T14:41:26.362477669Z","level":"INFO","msg":"audit","request_id":"023542cb76720725","method":"POST","path":"/v1/payments","status":201,"caller":"","duration_ms":0}
{"time":"2026-10-02T14:41:26.602202855Z","level":"INFO","msg":"audit","request_id":"9f5a4a9d0d7d3697","method":"POST","path":"/v1/payments","status":200,"caller":"","duration_ms":0}
```

**What you are seeing:** both replicas, on nodes in zones 1 and 3, run exactly `d2315b...`; the `imageID` the
container runtime reports is the digest you asked for, so there is nothing to resolve later. Each node pulled
3.6 MB in well under a second. The service masks the card number, the retry with the same idempotency key returns
`200` instead of creating a second payment (`201`), and the audit lines carry no card data.

## 8. Break it: pull from a registry the cluster is not allowed to read

Create a second registry, deliberately not attached, and copy the same digest into it.

```bash
OTHER=acrlaba$SUFFIX
az acr create -g $RG -n $OTHER --sku Basic --admin-enabled false --query '{name:name, loginServer:loginServer, sku:sku.name}' -o json
az acr import -n $OTHER --source labs/payments-api@$DIGEST --registry $(az acr show -n $ACR --query id -o tsv) \
  --image labs/payments-api:1.0.0
sed "s|__IMAGE__|$OTHER.azurecr.io/labs/payments-api@$DIGEST|" aks/manifests/04/pull-test-pod.yaml | kubectl apply -f -
kubectl wait -n lab-a-registry pod/pull-test --timeout=90s \
  --for=jsonpath='{.status.containerStatuses[0].state.waiting.reason}'=ImagePullBackOff
kubectl get events -n lab-a-registry --field-selector involvedObject.name=pull-test --sort-by=.lastTimestamp \
  -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message
AAD_LOGIN_METHOD=azurecli az aks check-acr -g $RG -n $AKS --acr $OTHER.azurecr.io
```

```output
{
  "loginServer": "acrlaba1e1193.azurecr.io",
  "name": "acrlaba1e1193",
  "sku": "Basic"
}
pod/pull-test created
pod/pull-test condition met
TYPE      REASON      MESSAGE
Normal    Scheduled   Successfully assigned lab-a-registry/pull-test to aks-user-25795745-vmss000000
Normal    BackOff     Back-off pulling image "acrlaba1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d"
Warning   Failed      Error: ImagePullBackOff
Normal    Pulling     Pulling image "acrlaba1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d"
Warning   Failed      Failed to pull image "acrlaba1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d": failed to pull and unpack image "acrlaba1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d": failed to resolve image: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://acrlaba1e1193.azurecr.io/oauth2/token?scope=repository%3Alabs%2Fpayments-api%3Apull&service=acrlaba1e1193.azurecr.io: 401 Unauthorized
Warning   Failed      Error: ErrImagePull
WARNING: Merged "aks-handson" as current context in /var/folders/.../tmpsesabs6_
WARNING: Converted kubeconfig to use Azure CLI authentication.
...
[2026-10-02T14:46:09Z] Kubelet managed identity client ID: 55a5dec9-13a3-43f0-bfd0-58026851030b
[2026-10-02T14:46:09Z] Validating managed identity existance: SUCCEEDED
[2026-10-02T14:46:09Z] Validating image pull permission: FAILED
[2026-10-02T14:46:09Z] ACR acrlaba1e1193.azurecr.io rejected token exchange: ACR token exchange endpoint returned error status: 401. body: {"errors":[{"code":"UNAUTHORIZED","message":"authentication required, visit https://aka.ms/acr/authorization for more information. CorrelationId: 69598458-2779-41e5-9c5b-e596f3210c5e"}]}
```

**What you are seeing:** the same digest, byte for byte, pulls from one registry and not from the other. Read the
long event from its end: the registry's token endpoint answered `401 Unauthorized`, and the message says
containerd was asking for an *anonymous* token, because the node had no usable credentials for this registry.
`ErrImagePull` turns into `ImagePullBackOff` as the kubelet retries with growing delays (events with the same
timestamp can list in any order). `check-acr` names the cause: the identity exists, but this registry rejected its
token exchange, because the kubelet identity has no role on `acrlaba1e1193`.

The fix is not a change to the pod. Either pull from the registry the cluster trusts, or grant the role with
`az aks update --attach-acr` (a role assignment on the kubelet identity, which this shared cluster does not get in
this lab). Use the attached registry, then remove the extra one:

```bash
kubectl delete pod -n lab-a-registry pull-test
sed "s|__IMAGE__|$ACR.azurecr.io/labs/payments-api@$DIGEST|" aks/manifests/04/pull-test-pod.yaml | kubectl apply -f -
kubectl wait -n lab-a-registry pod/pull-test --for=condition=Ready --timeout=90s
kubectl get pod -n lab-a-registry pull-test
az acr delete -g $RG -n $OTHER --yes
```

```output
pod "pull-test" deleted from lab-a-registry namespace
pod/pull-test created
pod/pull-test condition met
NAME        READY   STATUS    RESTARTS   AGE
pull-test   1/1     Running   0          1s
```

## 9. Sign the deployed digest with a key in Key Vault

The key `cosign-signing` is a non-exportable EC P-256 key in Key Vault. cosign sends Key Vault a digest to sign and gets the
signature back; the private key never leaves the vault. Check that the public key in the repository is the vault's
key, then sign the digest that is running.

```bash
REF=$ACR.azurecr.io/labs/payments-api@$DIGEST
az keyvault key show --vault-name $KV -n cosign-signing --query '{kid:key.kid, kty:key.kty, crv:key.crv, ops:key.keyOps, enabled:attributes.enabled}' -o json
cosign public-key --key azurekms://$KV.vault.azure.net/cosign-signing | diff - aks/keys/cosign-signing.pub && echo "same public key"
cosign sign --key azurekms://$KV.vault.azure.net/cosign-signing -y $REF
az acr manifest list-referrers -r $ACR -n labs/payments-api@$DIGEST -o json 2>/dev/null
cosign verify --key aks/keys/cosign-signing.pub $REF
```

```output
{
  "crv": "P-256",
  "enabled": true,
  "kid": "https://kv-regk8s-1e1193.vault.azure.net/keys/cosign-signing/dabfe9558b63492ebfa5478e3a6b14fa",
  "kty": "EC",
  "ops": [
    "sign",
    "verify"
  ]
}
same public key
Signing artifact...
Pushing signature to: acrregk8s1e1193.azurecr.io/labs/payments-api
{
  "manifests": [
    {
      "annotations": {
        "dev.sigstore.bundle.content": "dsse-envelope",
        "dev.sigstore.bundle.predicateType": "https://sigstore.dev/cosign/sign/v1",
        "org.opencontainers.image.created": "2026-10-02T14:47:29Z"
      },
      "artifactType": "application/vnd.dev.sigstore.bundle.v0.3+json",
      "digest": "sha256:49b3cd412c354d0e1462e84301246d5d945a9365121161b1a43631f60a43f6b4",
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "size": 888
    }
  ]
}

Verification for acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d"},"image":{"docker-manifest-digest":"sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d"},"type":"https://sigstore.dev/cosign/sign/v1"},"optional":{}}]
```

**What you are seeing:**
- cosign 3 wrote the signature as a Sigstore bundle in an OCI manifest whose `subject` is the image digest, and ACR
  returns it through the OCI referrers API (`list-referrers`). No tag was created for it.
- The verifier needs only the public key file. The signed claim names the exact digest
  (`docker-manifest-digest`), so it cannot be moved to other bytes the way a tag can.
- With cosign 3's default settings, the signature was also recorded in the public Rekor transparency log (the
  bundle holds log index 3057151318 and a timestamp authority's countersignature), which `cosign verify` checked
  offline. That gives an independent record of when the key was used, at the price of a public log entry for each
  signature. If that is not acceptable for a private image, cosign 3 needs a signing config without a log, and
  every verifier has to be told to skip the log check.

## 10. Add a signature in the older tag layout

Many verifiers in the field still look for the older layout, a `sha256-<digest>.sig` tag. cosign 3 can still write
it with flags it marks as deprecated. Adding it is a bridge while verifiers catch up, not a second policy.

```bash
cosign sign --key azurekms://$KV.vault.azure.net/cosign-signing --use-signing-config=false --new-bundle-format=false -y $REF
crane ls $ACR.azurecr.io/labs/payments-api
cosign verify --key aks/keys/cosign-signing.pub --new-bundle-format=false $REF 2>/dev/null \
  | jq -c '.[] | {type: .critical.type, logIndex: .optional.Bundle.Payload.logIndex}'
```

```output
...
Signing artifact...
Pushing signature to: acrregk8s1e1193.azurecr.io/labs/payments-api
1.0.0
buildkit
latest-bases
naive
prod
sha256-d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d.sig
{"type":"cosign container image signature","logIndex":3057158259}
```

**What you are seeing:** the legacy signature is a tag that a registry cleanup job or a mirror can delete or skip,
which is the main reason the referrers layout replaced it. Both signatures are by the same Key Vault key on the same
digest, so either kind of verifier passes.

## 11. Attest an SBOM to the digest

An attestation is a signed statement about the image. The usual SBOM tool, syft, has no public image on cgr.dev,
and this lab pulls nothing large to the laptop, so the SBOM comes from the grype image inside the cluster: grype
catalogs the image with syft's catalogers and can write the inventory as CycloneDX. The Job is
[aks/manifests/04/sbom-job.yaml](manifests/04/sbom-job.yaml), hardened like the scanner in lab 01.

```bash
kubectl create secret docker-registry acr-pull -n lab-a-registry --docker-server=$ACR.azurecr.io \
  --docker-username=00000000-0000-0000-0000-000000000000 \
  --docker-password="$(az acr login -n $ACR --expose-token --query accessToken -o tsv 2>/dev/null)"
sed "s|__IMAGE__|$REF|" aks/manifests/04/sbom-job.yaml | kubectl apply -f -
kubectl wait -n lab-a-registry --for=condition=complete job/sbom --timeout=15m
kubectl delete secret acr-pull -n lab-a-registry
kubectl logs -n lab-a-registry job/sbom > payments-api.cdx.json
jq -r '.bomFormat, .specVersion, (.metadata.component | "\(.type) \(.name) \(.version)"), "components=\(.components|length)"' payments-api.cdx.json
jq -r '[.components[].type] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' payments-api.cdx.json
jq -r '.components[] | select(.type=="library") | "\(.name) \(.version) \(.purl)"' payments-api.cdx.json
```

```output
secret/acr-pull created
job.batch/sbom created
job.batch/sbom condition met
secret "acr-pull" deleted
CycloneDX
1.7
container acrregk8s1e1193.azurecr.io/labs/payments-api sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
components=1225
file=1220 library=4 operating-system=1
ca-certificates-bundle 20260909-r2 pkg:apk/wolfi/ca-certificates-bundle@20260909-r2?arch=x86_64&distro=wolfi-20230201&upstream=ca-certificates
stdlib go1.27.1 pkg:golang/stdlib@1.27.1
tzdata 2026e-r0 pkg:apk/wolfi/tzdata@2026e-r0?arch=x86_64&distro=wolfi-20230201
wolfi-baselayout 20230201-r30 pkg:apk/wolfi/wolfi-baselayout@20230201-r30?arch=x86_64&distro=wolfi-20230201
```

The whole image is four packages: three Wolfi packages from the `static` base and the Go standard library compiled
into the binary (the 1,220 `file` entries are mostly time zone files). Attest it to the digest and verify:

```bash
cosign attest --key azurekms://$KV.vault.azure.net/cosign-signing --type cyclonedx --predicate payments-api.cdx.json -y $REF
az acr manifest list-referrers -r $ACR -n labs/payments-api@$DIGEST \
  --query 'manifests[].{artifactType:artifactType, predicateType:annotations."dev.sigstore.bundle.predicateType", digest:digest}' -o table 2>/dev/null
cosign verify-attestation --key aks/keys/cosign-signing.pub --type cyclonedx $REF 2>/dev/null \
  | jq -r '.payload | @base64d | fromjson | .predicateType, .subject[0].digest.sha256,
           ([.predicate.components[] | select(.type=="library") | "\(.name) \(.version)"] | join(", "))'
```

```output
Using payload from: payments-api.cdx.json
Signing artifact...
ArtifactType                                   PredicateType                        Digest
---------------------------------------------  -----------------------------------  -----------------------------------------------------------------------
application/vnd.dev.sigstore.bundle.v0.3+json  https://cyclonedx.org/bom            sha256:2d3d4d523abfb7daf0ce97e8694a9afcd9f231a222d29c2efb270f9a150966fe
application/vnd.dev.sigstore.bundle.v0.3+json  https://sigstore.dev/cosign/sign/v1  sha256:49b3cd412c354d0e1462e84301246d5d945a9365121161b1a43631f60a43f6b4
https://cyclonedx.org/bom
d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
ca-certificates-bundle 20260909-r2, stdlib go1.27.1, tzdata 2026e-r0, wolfi-baselayout 20230201-r30
```

**What you are seeing:** the image now has two referrers, told apart by predicate type: the signature and the
CycloneDX SBOM. `verify-attestation` checked the signature over the in-toto statement and returned it; its subject
is the image digest, so the SBOM cannot be presented as describing another image. An auditor can ask "what is in
the image running in production" and get an answer that is signed, tied to the digest, and fetched from the same
registry the nodes pull from. Here is the repository now, with every kind of manifest it holds:

```bash
az acr manifest list-metadata -r $ACR -n labs/payments-api --orderby time_asc \
  --query "[].{created:createdTime, digest:digest, tags:join(',', tags || \`[]\`)}" -o table 2>/dev/null
```

```output
Created                       Digest                                                                   Tags
----------------------------  -----------------------------------------------------------------------  ---------------------------------------------------------------------------
2026-10-02T14:11:57.2017131Z  sha256:935a1d6f20861f336675662b9a3087b4e0e1a612680c24a999a2e360eb1ead32  naive
2026-10-02T14:14:24.0417305Z  sha256:cec49cd996af83a8015e4b3c17a028458b21b6d00853202f4f3312cc276d64e6
2026-10-02T14:16:23.8009316Z  sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d  1.0.0,prod
2026-10-02T14:17:55.7749113Z  sha256:5dd0e2e2ba72bfe7097ddbcc65236119702808cd1f9d708cff37e254fb63db95  latest-bases
2026-10-02T14:21:26.9798747Z  sha256:f893b5dc123dadba8d06c3c5c340af13d63c5b35c5569f389c498c57fdea31a4  buildkit
2026-10-02T14:47:31.6517293Z  sha256:49b3cd412c354d0e1462e84301246d5d945a9365121161b1a43631f60a43f6b4
2026-10-02T14:48:05.5974381Z  sha256:932af255bc3a5281b6247628d707e9a53b492346739e9de231d644b37d4eb543  sha256-d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d.sig
2026-10-02T15:03:54.5671414Z  sha256:2d3d4d523abfb7daf0ce97e8694a9afcd9f231a222d29c2efb270f9a150966fe
...
```

`49b3cd...` (signature) and `2d3d4d...` (SBOM) look untagged, like the orphaned `cec49cd...` build, but they are
not orphans: they refer to `d2315b...`. A cleanup job that deletes "untagged manifests" without checking referrers
would delete your signatures.

## 12. Verification fails for an unsigned digest; record the signed one

```bash
UNSIGNED=$(az acr manifest show-metadata -r $ACR -n labs/payments-api:latest-bases --query digest -o tsv 2>/dev/null)
cosign verify --key aks/keys/cosign-signing.pub $ACR.azurecr.io/labs/payments-api@$UNSIGNED; echo "exit=$?"
az acr manifest show-metadata -r $ACR -n labs/payments-api:1.0.0 --query '{digest:digest, signed:signed}' -o json 2>/dev/null
echo "$REF" > aks/manifests/04/SIGNED_DIGEST.txt
cat aks/manifests/04/SIGNED_DIGEST.txt
```

```output
Error: no signatures found
error during command execution: no signatures found
exit=10
{
  "digest": "sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d",
  "signed": false
}
acrregk8s1e1193.azurecr.io/labs/payments-api@sha256:d2315b567c8d8497b90ec0ce3607b64c91491bf4e29ed54932a42c7e76d4e49d
```

**What you are seeing:** `latest-bases` is the same source code built from the same base digests, and it is not
signed, so it fails with a non-zero exit code. That is the property an admission policy relies on: being built from
the right commit is not enough; the release process must have signed that digest. ACR's own `signed` field stays
`false` after cosign signs: it does not track cosign or Notation signatures, so do not use it as evidence.
[aks/manifests/04/SIGNED_DIGEST.txt](manifests/04/SIGNED_DIGEST.txt) records the signed reference for lab 08, which
enforces this signature at admission with Kyverno. Its tag `1.0.0` is locked and the manifest cannot be deleted.

## 13. Notation and ACR referrers, the Azure-native alternative

Microsoft documents a second signing system for ACR: Notation (Notary Project) with the `notation-azure-kv` plugin
and an X.509 certificate in Key Vault. The signing call is
`notation sign --signature-format cose --id $KEY_ID --plugin azure-kv $IMAGE`, where `$KEY_ID` is the certificate's
key ID; verification uses a trust store and a trust policy that names the trusted certificate subject. Since
Notation 1.2.0 the signature is stored with the OCI referrers tag schema by default, and ACR also supports the OCI
Referrers API (except in registries encrypted with customer-managed keys), which is what `list-referrers` used in
step 9.

On AKS, the managed verifier is Image Integrity, built on Ratify, Azure Policy and Gatekeeper. It is in preview,
supports only Notation, and only audits. For enforcement of cosign signatures today, a policy engine such as Kyverno
does the verification (lab 08). Pick one signing system per platform, and make sure admission verifies the one you
picked: a signature that nothing checks is decoration.

## On AKS specifically

- `--attach-acr` assigns the `AcrPull` role to the kubelet managed identity of the agent pools. `az aks update
  --attach-acr` creates that role assignment with the permissions of the person running it; Microsoft lists Owner
  (or a classic subscription administrator role) as the prerequisite. It is not supported for ACR registries with
  ABAC repository permissions; those need the `Container Registry Repository Reader` role assigned directly.
- `az aks check-acr` is Microsoft's first troubleshooting step for pulls from ACR. For a private registry outside
  Azure, AKS documentation points to image pull secrets instead.
- ACR locks are attributes on tags, manifests or repositories (`write-enabled`, `delete-enabled`, `read-enabled`,
  `list-enabled`). Tag and manifest attributes are set separately. `acr purge --include-locked` can unlock and
  delete locked artifacts if it has the rights. An Azure resource lock (`az lock`) on the registry does not protect
  images; it only covers management operations such as deleting the registry.
- `az acr import` needs no Docker, copies every platform of a multi-architecture image, keeps the digest, and is
  limited to 50 manifests per imported image. The importing identity needs the
  `Container Registry Data Importer and Data Reader` role.
- A retention policy that deletes untagged manifests exists only on Premium and is in preview. Microsoft warns not
  to enable it if anything pulls by digest, and it skips manifests with `delete-enabled` false.
- Tokens from `az acr login` are valid for 3 hours. Basic, Standard and Premium all support non-Entra tokens with
  scope maps, which are the better choice for a read-only credential limited to one repository.

## In the conversation

**Why it matters in production.** The registry is where "what we tested" and "what runs" either stay the same thing
or drift apart. Tags drift: they get re-pushed by rebuilds, moved by imports, and orphaned images get cleaned up.
Deploying by digest makes every node run the bytes that were tested, now and on every reschedule, and a signature
on that digest lets the cluster refuse anything the release process did not approve. On AKS the pull permission is
an Azure role on a managed identity, so registry access is reviewed the same way as any other access.

**A story from real work.** On JFrog Artifactory I saw a release tag re-pushed, and Artifactory deleted the image
the tag used to point to. A pod pinned to the old image then failed to pull when it was rescheduled. The fix was to
deploy by digest and set retention so released digests are kept. In this lab I saw the Azure version of the same lesson: a tag locked with `--write-enabled false` refused a
registry push, as documented, but a forced `az acr import` by an Owner moved it anyway and left the lock flag
showing. Locks help, but the digest is what you can trust.

**Follow-up questions to expect.**
- *If you lock tags, why also deploy by digest?* Because the lock is not absolute (step 4) and because a tag is
  resolved again on every pull. The digest in the manifest is what the kubelet asks for and what containerd
  reports back as `imageID`, so there is nothing left to resolve.
- *How does AKS pull from ACR without a secret?* The kubelet uses the agent pool's user-assigned managed identity,
  which has `AcrPull` on the registry; the credential provider on each node exchanges its token with ACR.
  `az aks check-acr` tests that chain from a real node, as in steps 6 and 8.
- *Why keep the signing key in Key Vault instead of using keyless signing?* Keyless is simpler in public CI. A bank
  often wants its own key, non-exportable, with every signing operation authorized by Azure RBAC and logged by
  Key Vault. The verifier needs only the public key.
- *How do you mirror Chainguard images into ACR without breaking verification?* Use `cosign copy`, which brings the
  signatures and attestations, or verify the mirror against the source repository with `COSIGN_REPOSITORY`.
  `az acr import` and `crane copy` keep the digest but drop the signatures.
- *Do you send private signatures to the public Rekor log?* cosign 3 does by default, as here. It gives an
  independent timestamped record but publishes an entry per signature. For private images I decide that
  explicitly with the customer and, if needed, sign with a configuration that has no public log.

## If something looks different

- `cosign sign` fails with an authorization error from Key Vault: your identity needs a role that allows the
  `sign` key operation (Key Vault Crypto User or Crypto Officer) on the vault, and `az login` must be current.
- `cosign` or `crane` hangs on macOS: Docker Desktop's credential helper is being called. Use the empty
  `DOCKER_CONFIG` from step 1.
- `az aks check-acr` prints a device code, or ends with a Python traceback and `KeyError: 'serverVersion'`: the
  temporary kubeconfig could not sign in. Run it with `AAD_LOGIN_METHOD=azurecli` as in step 6.

## Clean up

```bash
kubectl delete namespace lab-a-registry
az acr show -n acrlaba$SUFFIX -o none 2>/dev/null && az acr delete -g $RG -n acrlaba$SUFFIX --yes
rm -f payments-api.cdx.json
# labs/payments-api:1.0.0, its signatures and its SBOM stay: lab 08 verifies this digest.
# To remove them later, unlock the tag and the manifest first:
#   az acr repository update -n $ACR --image labs/payments-api:1.0.0 --write-enabled true --delete-enabled true
#   az acr repository update -n $ACR --image labs/payments-api@$DIGEST --delete-enabled true
#   az acr repository delete -n $ACR --repository labs/payments-api --yes
```

## Checkpoint

1. A Deployment uses `payments-api:1.0.0`, the tag is locked, and yet one replica runs different code after a node
   upgrade. How could that happen, and what change prevents it?
   _Hint: step 4, and what the kubelet does with a tag on every new pull._
2. A security team copies all base images into ACR with `az acr import`, and the signature policy starts rejecting
   them. Give two fixes.
   _Hint: step 5; one fix moves the signatures, the other moves the verifier._
3. A pod shows `ImagePullBackOff` with `401 Unauthorized` from `*.azurecr.io/oauth2/token`. Which Azure objects do
   you check, in which order?
   _Hint: step 6: the kubelet identity, its role assignments, then `az aks check-acr` for that registry._

## Further reading

- [Integrate ACR with AKS](https://learn.microsoft.com/azure/aks/cluster-container-registry-integration)
- [Lock images in Azure Container Registry](https://learn.microsoft.com/azure/container-registry/container-registry-image-lock)
- [Import container images into ACR](https://learn.microsoft.com/azure/container-registry/container-registry-import-images)
- [Sign container images with Notation and Azure Key Vault](https://learn.microsoft.com/azure/container-registry/container-registry-tutorial-sign-build-push)
- [Retention policy for untagged manifests](https://learn.microsoft.com/azure/container-registry/container-registry-retention-policy)
- [Signing containers with cosign](https://docs.sigstore.dev/cosign/signing/signing_with_containers/)
- [Verifying Chainguard images and metadata signatures with cosign](https://edu.chainguard.dev/chainguard/containers/security-and-compliance/verifying-chainguard-images-and-metadata-signatures-with-cosign/)
- [Kubernetes images: tags, digests and pull policy](https://kubernetes.io/docs/concepts/containers/images/)
