# 08. Security and implementation best practices on AKS

**Goal:** prove each security control on a real AKS cluster, layer by layer. Who can reach the API server and what they may do. How a workload gets a Key Vault secret with no secret stored in Kubernetes. What Pod Security, network policy and admission policy refuse. And how the cluster admits only images signed with a key that never leaves Key Vault.

**You need:** the cluster from `aks/scripts/create.sh` (Entra ID with Azure RBAC, local accounts disabled, OIDC issuer and workload identity, Azure CNI overlay with Cilium, Key Vault Secrets Store CSI add-on, ACR attached). You also need `az`, `kubectl`, `kubelogin`, `helm`, `cosign`, `crane` and `jq` on your machine. The signing step needs the Key Vault key `cosign-signing` and its public half in `aks/keys/cosign-signing.pub`. This lab builds and signs its own image, so it does not depend on another lab's output. Allow about 75 minutes. No paid add-on is turned on. The two ACR Tasks builds and the Key Vault operations are billed at normal usage rates.

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ. Subscription and tenant IDs are masked._

## Why this matters

A regulated cluster is judged on evidence, not on intent. An auditor will ask four things. Who can change the cluster? Where do secrets live? What stops a root container or a lateral connection? How do you know the running image is the one your pipeline built? Each answer should be a control you can show refusing something, plus a command that proves it. This lab builds that evidence on AKS, where Azure owns the control plane and you own everything that runs on it.

**What you will learn**

- How Entra ID, Azure RBAC and disabled local accounts decide who reaches the API server, and how to scope a role to one namespace and test it with a real token.
- How workload identity federation lets a pod read Key Vault through the Secrets Store CSI driver with no Kubernetes Secret and no stored credential.
- What Pod Security `restricted` refuses at admission, what the kubelet refuses at start, and how to read the result in `/proc/1/status`.
- How Cilium enforces a default-deny NetworkPolicy, and where L7 and FQDN policy fit on AKS.
- How Kyverno enforces the repo's policies, and how an ImageValidatingPolicy admits only images signed with the Key Vault key.
- Which Azure-native options (Azure Policy, Image Integrity, Defender for Containers, private API server, node OS auto-upgrade) cover the same ground, and what they cost.

## 1. Who can reach the API server: Entra ID, Azure RBAC, no local accounts

Every command runs from the repo root. Load the lab's names, then set three values used throughout. `AKS_ID` is the Azure resource ID of the cluster, and role assignments are scoped to it or to a namespace under it. `ISSUER` is the cluster's OIDC issuer for workload identity. Then create the first namespace.

```bash
source aks/.lab.env
AKS_ID=$(az aks show -g $RG -n $AKS --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ISSUER=$(az aks show -g $RG -n $AKS --query oidcIssuerProfile.issuerUrl -o tsv)
kubectl create namespace lab-d-secure
```

```output
namespace/lab-d-secure created
```

Now read how the cluster authenticates and authorizes. `aadProfile` shows managed Entra ID integration with Azure RBAC for authorization. `disableLocalAccounts` shows whether the static admin certificate still exists.

```bash
az aks show -g $RG -n $AKS --query "{aad: aadProfile, disableLocalAccounts: disableLocalAccounts}" -o yaml
```

```output
aad:
  adminGroupObjectIDs: null
  clientAppId: null
  enableAzureRbac: true
  managed: true
  serverAppId: null
  serverAppSecret: null
  tenantId: <tenant-id>
disableLocalAccounts: true
```

Now try to get the admin kubeconfig, the classic break-glass file. `--file /dev/null` makes sure nothing is written even if it worked.

```bash
az aks get-credentials -g $RG -n $AKS --admin --file /dev/null
```

```output
ERROR: (BadRequest) Getting static credential is not allowed because this cluster is set to disable local accounts. For more details, see https://learn.microsoft.com/en-us/azure/aks/manage-local-accounts-managed-azure-ad
Code: BadRequest
Message: Getting static credential is not allowed because this cluster is set to disable local accounts. For more details, see https://learn.microsoft.com/en-us/azure/aks/manage-local-accounts-managed-azure-ad
```

**What you are seeing:** the static admin credential is gone. Every `kubectl` call now carries an Entra ID token, which kubelogin gets from your `az` login. Every request is authorized against Azure role assignments. There is no shared certificate that bypasses identity and audit.

List who holds roles on the cluster. `--include-inherited` adds assignments made higher up, such as at subscription level.

```bash
az role assignment list --scope $AKS_ID --include-inherited \
  --query "[].{principal:principalName, role:roleDefinitionName, scope:scope}" -o table
```

```output
Principal                                         Role                                         Scope
------------------------------------------------  -------------------------------------------  -----------------------------------------------------------------------------------------------------------------------
you_example.com#EXT#@<tenant>.onmicrosoft.com     Owner                                        /subscriptions/<subscription-id>
you_example.com#EXT#@<tenant>.onmicrosoft.com     Azure Kubernetes Service RBAC Cluster Admin  /subscriptions/<subscription-id>/resourcegroups/rg-aks-handson/providers/Microsoft.ContainerService/managedClusters/aks-handson
5d7a45a1-267d-4578-8fad-0f1f5482372a              Azure Kubernetes Service Cluster User Role   /subscriptions/<subscription-id>/resourcegroups/rg-aks-handson/providers/Microsoft.ContainerService/managedClusters/aks-handson
```

**What you are seeing:** two kinds of role. "Azure Kubernetes Service RBAC Cluster Admin" is a data-plane role: it decides what you may do inside Kubernetes. "Azure Kubernetes Service Cluster User Role" only lets a principal download the kubeconfig (here the identity `id-gha-deploy` used by the GitHub Actions pipeline). With Entra ID that kubeconfig is empty of credentials, and access inside the cluster still comes from the RBAC roles. Owner at subscription level is a control-plane role. It can create role assignments, so treat it as cluster admin too.

Ask the API server who you are and what you may do.

```bash
kubectl auth whoami
kubectl auth can-i --list -n lab-d-secure
kubectl auth can-i delete nodes
```

```output
ATTRIBUTE    VALUE
Username     <your-object-id>
Groups       [<group-id> system:authenticated]
Extra: oid   [<your-object-id>]
Warning: the list may be incomplete: webhook authorizer does not support user rule resolution
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
...
                                                [/version]          []               [get]
yes
```

**What you are seeing:** your Kubernetes username is your Entra object ID, and `Extra: oid` carries it again for the Azure authorizer. `can-i --list` warns that it is incomplete. Azure RBAC is a webhook authorizer, and Kubernetes cannot list a webhook's rules, so you only see the built-in self-review rules. A direct question such as `can-i delete nodes` goes to the webhook and gets a real answer. With Azure RBAC, ask specific questions instead of reading the list.

## 2. A reader for one namespace only

A support engineer or a dashboard should see one namespace and change nothing. Create a user-assigned managed identity. Then grant it "Azure Kubernetes Service RBAC Reader" with a scope that ends in `/namespaces/lab-d-secure`.

```bash
az identity create -g $RG -n id-lab-d-ns-reader -l $LOC --query "{name:name, clientId:clientId, principalId:principalId}" -o table
READER_OID=$(az identity show -g $RG -n id-lab-d-ns-reader --query principalId -o tsv)
az role assignment create --assignee-object-id $READER_OID --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service RBAC Reader" --scope $AKS_ID/namespaces/lab-d-secure -o none
az role assignment list --scope $AKS_ID/namespaces/lab-d-secure --query "[].{principal:principalName, role:roleDefinitionName}" -o table
```

```output
Name                ClientId                              PrincipalId
------------------  ------------------------------------  ------------------------------------
id-lab-d-ns-reader  0e45cf93-6bd1-45d6-a6e5-61817bdd9605  00dcc720-5846-42ee-afd5-2bafa5652294
Principal                             Role
------------------------------------  ------------------------------------
0e45cf93-6bd1-45d6-a6e5-61817bdd9605  Azure Kubernetes Service RBAC Reader
```

**What you are seeing:** the assignment lives in Azure, not in a Kubernetes RoleBinding. `kubectl -n lab-d-secure get rolebindings` returns "No resources found". Run the cluster-scope listing from step 1 again and this assignment is not in it either. Namespace assignments sit on a child scope, so you list them at that scope.

The usual way to test someone else's permissions is impersonation. Try it.

```bash
kubectl auth can-i get pods -n lab-d-secure --as=$READER_OID
```

```output
no - Azure does not have opinion for this non AAD user. If you are an AAD user, please set Extra:oid parameter for impersonated user in the kubeconfig
```

**What you are seeing:** the answer is "no", but it is the wrong "no". The Azure authorizer identifies principals by the `oid` extra field, and `kubectl --as` cannot set it. Ask the API server directly with a SubjectAccessReview that carries `extra.oid`. The helper `aks/scripts/azure-rbac-check.sh` does exactly that: it sends a SubjectAccessReview and prints `allowed` and the reason.

```bash
while read -r verb resource ns group; do
  printf '%-6s %-12s %-14s ' $verb $resource ${ns:--A}
  aks/scripts/azure-rbac-check.sh $READER_OID $verb $resource "$ns" "$group"
done <<'EOF'
get pods lab-d-secure
list deployments lab-d-secure apps
get configmaps lab-d-secure
get secrets lab-d-secure
create pods lab-d-secure
delete pods lab-d-secure
get pods default
list pods
EOF
```

```output
get    pods         lab-d-secure   true  Access allowed by Azure RBAC Role Assignment 59ae41cff153441994fce848787e000b of Role 7f6c6a51bcf842ba922052d62157d7db to user 00dcc720-5846-42ee-afd5-2bafa5652294
list   deployments  lab-d-secure   true  Access allowed by Azure RBAC Role Assignment 59ae41cff153441994fce848787e000b of Role 7f6c6a51bcf842ba922052d62157d7db to user 00dcc720-5846-42ee-afd5-2bafa5652294
get    configmaps   lab-d-secure   true  Access allowed by Azure RBAC Role Assignment 59ae41cff153441994fce848787e000b of Role 7f6c6a51bcf842ba922052d62157d7db to user 00dcc720-5846-42ee-afd5-2bafa5652294
get    secrets      lab-d-secure   false  User does not have access to the resource in Azure. Update role assignment to allow access.
create pods         lab-d-secure   false  User does not have access to the resource in Azure. Update role assignment to allow access.
delete pods         lab-d-secure   false  User does not have access to the resource in Azure. Update role assignment to allow access.
get    pods         default        false  User does not have access to the resource in Azure. Update role assignment to allow access.
list   pods         -A             false  User does not have access to the resource in Azure. Update role assignment to allow access.
```

**What you are seeing:** the reader can read pods, deployments and config maps in `lab-d-secure`, and nothing else. The reason names the role assignment and the role definition (`7f6c6a51...` is the built-in RBAC Reader). Secrets are refused even inside the namespace. RBAC Reader deliberately excludes Secrets, because reading a service account token would be a path to more privilege. In step 4 you prove the same answers with a real Entra token instead of a review.

## 3. Workload identity: a Key Vault secret with no Kubernetes Secret

A Kubernetes Secret is base64 in etcd, and anyone with `get secrets` can read it. The alternative is to keep the secret in Key Vault and let the pod prove who it is. Here is the chain. The cluster's OIDC issuer signs a service account token. Entra ID trusts that issuer for one exact subject, through a federated credential. Key Vault trusts the managed identity through a role assignment.

Put a test secret in the vault, create the identity, federate it with one service account, and grant it read access to secrets.

```bash
az keyvault secret set --vault-name $KV -n lab-d-db-password --value "lab-d-$(openssl rand -hex 8)" --query "{name:name, version:id}" -o json
az identity create -g $RG -n id-lab-d-kv-reader -l $LOC --query "{name:name, clientId:clientId, principalId:principalId}" -o table
az identity federated-credential create -g $RG --identity-name id-lab-d-kv-reader -n fc-lab-d-secure-kv-reader \
  --issuer "$ISSUER" --subject system:serviceaccount:lab-d-secure:kv-reader --audiences api://AzureADTokenExchange \
  --query "{name:name, issuer:issuer, subject:subject, audiences:audiences}" -o yaml
KV_CLIENT_ID=$(az identity show -g $RG -n id-lab-d-kv-reader --query clientId -o tsv)
az role assignment create --assignee-object-id $(az identity show -g $RG -n id-lab-d-kv-reader --query principalId -o tsv) \
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n $KV --query id -o tsv) -o none
```

```output
{
  "name": "lab-d-db-password",
  "version": "https://kv-regk8s-1e1193.vault.azure.net/secrets/lab-d-db-password/29cae6bfeec94ec889ac8df86a07e8b6"
}
Name                ClientId                              PrincipalId
------------------  ------------------------------------  ------------------------------------
id-lab-d-kv-reader  c752938c-24a7-4209-baab-f7a3953ff28c  302c0135-e07c-42fd-8f1b-61242a20a99f
audiences:
- api://AzureADTokenExchange
issuer: https://centralindia.oic.prod-aks.azure.com/<tenant-id>/3a478d8a-26c7-4d7c-86b7-9eed4739fcfb/
name: fc-lab-d-secure-kv-reader
subject: system:serviceaccount:lab-d-secure:kv-reader
```

Now create the service account, annotated with the identity's client ID, and a SecretProviderClass. `usePodIdentity: "false"` with a `clientID` selects workload identity. There is no `secretObjects` section, so the driver never copies the value into a Kubernetes Secret.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kv-reader
  namespace: lab-d-secure
  annotations:
    azure.workload.identity/client-id: "$KV_CLIENT_ID"
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: kv-lab-d
  namespace: lab-d-secure
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$KV_CLIENT_ID"
    keyvaultName: "$KV"
    tenantId: "$TENANT_ID"
    objects: |
      array:
        - |
          objectName: lab-d-db-password
          objectType: secret
EOF
kubectl apply -f aks/manifests/08/kv-reader-pod.yaml
kubectl -n lab-d-secure wait --for=condition=Ready pod/kv-reader --timeout=120s
```

```output
serviceaccount/kv-reader created
secretproviderclass.secrets-store.csi.x-k8s.io/kv-lab-d created
pod/kv-reader created
pod/kv-reader condition met
```

`aks/manifests/08/kv-reader-pod.yaml` is a hardened busybox pod (uid 65532, read-only root filesystem, no capabilities). It carries the label `azure.workload.identity/use: "true"` and mounts a `csi` volume that points at `kv-lab-d`. Now look for the secret in the pod and in Kubernetes.

```bash
kubectl -n lab-d-secure exec kv-reader -- ls -lL /mnt/secrets/
kubectl -n lab-d-secure exec kv-reader -- cat /mnt/secrets/lab-d-db-password; echo
kubectl -n lab-d-secure exec kv-reader -- grep /mnt/secrets /proc/mounts
kubectl -n lab-d-secure get secrets
kubectl -n lab-d-secure get secretproviderclasspodstatuses -o jsonpath='{.items[0].status}' | jq .
```

```output
total 4
-rw-r--r--    1 root     root            22 Oct  2 14:15 lab-d-db-password
lab-d-b3b3bfc51e83bc77
tmpfs /mnt/secrets tmpfs ro,relatime 0 0
No resources found in lab-d-secure namespace.
{
  "mounted": true,
  "objects": [
    {
      "id": "secret/lab-d-db-password",
      "version": "29cae6bfeec94ec889ac8df86a07e8b6"
    }
  ],
  "podName": "kv-reader",
  "secretProviderClassName": "kv-lab-d",
  "targetPath": "/var/lib/kubelet/pods/fdea3a93-212f-4777-98a3-8d24f898b657/volumes/kubernetes.io~csi/kv/mount"
}
```

**What you are seeing:** the value is a file on a read-only tmpfs inside the pod, so it lives in memory on that node only. The namespace has no Secret object at all. The SecretProviderClassPodStatus records which Key Vault object and version were mounted, never the value. That record is the audit trail for "this pod got version 29cae6... of this secret". Rotation is off on this cluster (`enableSecretRotation: false` in the add-on config). A changed secret reaches the pod only when the pod restarts, unless you turn rotation on.

Now look at what the workload identity webhook added to the pod.

```bash
kubectl -n lab-d-secure exec kv-reader -- env | grep ^AZURE_ | sort
kubectl -n lab-d-secure get pod kv-reader -o jsonpath='{range .spec.volumes[*]}{.name}{"  "}{.projected.sources[*].serviceAccountToken}{"\n"}{end}'
kubectl -n lab-d-secure exec kv-reader -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | jq -R 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | {iss, sub, aud, iat: (.iat|todate), exp: (.exp|todate)}'
```

```output
AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
AZURE_CLIENT_ID=c752938c-24a7-4209-baab-f7a3953ff28c
AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
AZURE_TENANT_ID=<tenant-id>
kv  
kube-api-access-7w79z  {"expirationSeconds":3607,"path":"token"}
azure-identity-token  {"audience":"api://AzureADTokenExchange","expirationSeconds":3600,"path":"azure-identity-token"}
{
  "iss": "https://centralindia.oic.prod-aks.azure.com/<tenant-id>/3a478d8a-26c7-4d7c-86b7-9eed4739fcfb/",
  "sub": "system:serviceaccount:lab-d-secure:kv-reader",
  "aud": [
    "api://AzureADTokenExchange"
  ],
  "iat": "2026-10-02T14:14:57Z",
  "exp": "2026-10-02T15:14:57Z"
}
```

**What you are seeing:** the mutating webhook (`azure-wi-webhook-controller-manager` in kube-system) injected four `AZURE_*` variables. It also added a second projected service account token, `azure-identity-token`, with audience `api://AzureADTokenExchange` and a one-hour lifetime. Azure SDKs read these variables and swap the token for an Entra token. The `iss`, `sub` and `aud` claims are exactly what the federated credential matches. Only the claims are printed here: the token itself is a credential for the next hour.

Break it on purpose. Give a second service account the same client ID annotation and mount the same SecretProviderClass.

```bash
kubectl -n lab-d-secure create serviceaccount other-app
kubectl -n lab-d-secure annotate serviceaccount other-app azure.workload.identity/client-id=$KV_CLIENT_ID
sed -e 's/name: kv-reader$/name: kv-wrong-sa/' -e 's/serviceAccountName: kv-reader/serviceAccountName: other-app/' \
  aks/manifests/08/kv-reader-pod.yaml | kubectl apply -f -
sleep 40; kubectl -n lab-d-secure get pod kv-wrong-sa
kubectl -n lab-d-secure get events --field-selector involvedObject.name=kv-wrong-sa,reason=FailedMount -o jsonpath='{.items[-1:].message}'
```

```output
serviceaccount/other-app created
serviceaccount/other-app annotated
pod/kv-wrong-sa created
NAME          READY   STATUS              RESTARTS   AGE
kv-wrong-sa   0/1     ContainerCreating   0          41s
MountVolume.SetUp failed for volume "kv" : rpc error: code = Unknown desc = failed to mount secrets store objects for pod lab-d-secure/kv-wrong-sa, err: rpc error: code = Unknown desc = failed to mount objects, error: failed to get objectType:secret, objectName:lab-d-db-password, objectVersion:: ClientAssertionCredential authentication failed.
POST https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token
--------------------------------------------------------------------------------
RESPONSE 401: 401 Unauthorized
--------------------------------------------------------------------------------
{
  "error": "invalid_client",
  "error_description": "AADSTS700213: No matching federated identity record found for presented assertion subject 'system:serviceaccount:lab-d-secure:other-app'. Check your federated identity credential Subject, Audience and Issuer against the presented assertion. ...",
...
```

**What you are seeing:** knowing the client ID is not enough. Entra ID refuses the exchange because the token's subject is `other-app`, and the identity only trusts `kv-reader` in `lab-d-secure`. The pod never starts, because the volume cannot mount. This is the property you want: a namespace admin cannot borrow another team's identity by copying an annotation. Clean up the broken pod.

```bash
kubectl -n lab-d-secure delete pod kv-wrong-sa; kubectl -n lab-d-secure delete serviceaccount other-app
```

```output
pod "kv-wrong-sa" deleted from lab-d-secure namespace
serviceaccount "other-app" deleted from lab-d-secure namespace
```

## 4. Prove the namespace reader with a real Entra token

The same federation works for the Kubernetes API. Federate the reader identity from step 2 with a service account `ns-reader`, and run a pod as it (`aks/manifests/08/ns-reader-pod.yaml` is the same hardened busybox, without the CSI volume).

```bash
az identity federated-credential create -g $RG --identity-name id-lab-d-ns-reader -n fc-lab-d-secure-ns-reader \
  --issuer "$ISSUER" --subject system:serviceaccount:lab-d-secure:ns-reader --audiences api://AzureADTokenExchange -o none
READER_CLIENT_ID=$(az identity show -g $RG -n id-lab-d-ns-reader --query clientId -o tsv)
kubectl -n lab-d-secure create serviceaccount ns-reader
kubectl -n lab-d-secure annotate serviceaccount ns-reader azure.workload.identity/client-id=$READER_CLIENT_ID
kubectl apply -f aks/manifests/08/ns-reader-pod.yaml
kubectl -n lab-d-secure wait --for=condition=Ready pod/ns-reader --timeout=90s
```

```output
serviceaccount/ns-reader created
serviceaccount/ns-reader annotated
pod/ns-reader created
pod/ns-reader condition met
```

Copy the pod's projected token and exchange it at Entra ID for a token whose audience is the AKS server application (`6dae42f8-4368-4678-94ff-3960e28e3630`, the same ID kubelogin uses everywhere). This is the client-credentials flow with a JWT assertion instead of a client secret.

```bash
SA_TOKEN=$(kubectl -n lab-d-secure exec ns-reader -- cat /var/run/secrets/azure/tokens/azure-identity-token)
ENTRA_TOKEN=$(curl -s https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token \
  -d grant_type=client_credentials -d client_id=$READER_CLIENT_ID \
  -d scope=6dae42f8-4368-4678-94ff-3960e28e3630/.default \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  -d client_assertion=$SA_TOKEN | jq -r .access_token)
echo $ENTRA_TOKEN | jq -R 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | {aud, appid, oid, iat: (.iat|todate), exp: (.exp|todate)}'
```

```output
{
  "aud": "6dae42f8-4368-4678-94ff-3960e28e3630",
  "appid": "0e45cf93-6bd1-45d6-a6e5-61817bdd9605",
  "oid": "00dcc720-5846-42ee-afd5-2bafa5652294",
  "iat": "2026-10-02T14:36:55Z",
  "exp": "2026-10-03T14:41:55Z"
}
```

Call the API server with only that token. `kreader` is a throwaway function that ignores your kubeconfig and sends the bearer token.

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(mktemp); kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > $CA
kreader() { kubectl --kubeconfig=/dev/null --server=$SERVER --certificate-authority=$CA --token=$ENTRA_TOKEN "$@"; }
kreader auth whoami
kreader get pods -n lab-d-secure
kreader get secrets -n lab-d-secure
kreader get pods -n default
kreader delete pod kv-reader -n lab-d-secure
```

```output
ATTRIBUTE    VALUE
Username     00dcc720-5846-42ee-afd5-2bafa5652294
Groups       [system:authenticated]
Extra: oid   [00dcc720-5846-42ee-afd5-2bafa5652294]
NAME        READY   STATUS    RESTARTS   AGE
kv-reader   1/1     Running   0          2m21s
ns-reader   1/1     Running   0          15s
Error from server (Forbidden): secrets is forbidden: User "00dcc720-5846-42ee-afd5-2bafa5652294" cannot list resource "secrets" in API group "" in the namespace "lab-d-secure": User does not have access to the resource in Azure. Update role assignment to allow access.
Error from server (Forbidden): pods is forbidden: User "00dcc720-5846-42ee-afd5-2bafa5652294" cannot list resource "pods" in API group "" in the namespace "default": User does not have access to the resource in Azure. Update role assignment to allow access.
Error from server (Forbidden): pods "kv-reader" is forbidden: User "00dcc720-5846-42ee-afd5-2bafa5652294" cannot delete resource "pods" in API group "" in the namespace "lab-d-secure": User does not have access to the resource in Azure. Update role assignment to allow access.
```

**What you are seeing:** the API server authenticated the managed identity by its object ID and enforced the namespace-scoped role. It may list pods in `lab-d-secure`. It is refused Secrets, other namespaces and deletes, exactly as the SubjectAccessReviews predicted. Two details matter in production. This identity never had "Cluster User Role", because that role only gates downloading a kubeconfig, not the API. And the Entra token is valid for about 24 hours (compare `iat` and `exp` above), against one hour for the projected token. A leaked Entra token is the longer-lived risk, so keep exchanges inside the workload. Close the shell or `unset ENTRA_TOKEN SA_TOKEN` when you are done.

## 5. Pod Security `restricted`: refuse root at admission

Pod Security Admission is built into Kubernetes and on by default in AKS. You turn it on per namespace with labels. Check first with a server-side dry run, which warns about existing pods that would violate the level. Then enforce.

```bash
kubectl label --dry-run=server --overwrite ns lab-d-secure pod-security.kubernetes.io/enforce=restricted
kubectl label ns lab-d-secure pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
kubectl -n lab-d-secure run root-shell --image=cgr.dev/chainguard/wolfi-base:latest -- sleep 3600
```

```output
namespace/lab-d-secure labeled (server dry run)
namespace/lab-d-secure labeled
Error from server (Forbidden): pods "root-shell" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "root-shell" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "root-shell" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "root-shell" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "root-shell" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**What you are seeing:** the dry run printed no warnings, so the pods already in the namespace comply. A pod written the quick way, with no securityContext, is refused with four reasons. Now try a pod that is hardened in every way except that it asks for uid 0 (`aks/manifests/08/root-pod.yaml`), and then the fully hardened one.

```bash
kubectl apply -f aks/manifests/08/root-pod.yaml
kubectl apply -f aks/manifests/08/hardened-pod.yaml
kubectl -n lab-d-secure wait --for=condition=Ready pod/hardened --timeout=90s
```

```output
Error from server (Forbidden): error when creating "aks/manifests/08/root-pod.yaml": pods "root-pod" is forbidden: violates PodSecurity "restricted:latest": runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), runAsUser=0 (pod must not set runAsUser=0)
pod/hardened created
pod/hardened condition met
```

Prove what the hardened pod actually got from the kernel. `/proc/1/status` is the container's main process as the kernel sees it.

```bash
kubectl -n lab-d-secure exec hardened -- grep -E '^(Uid|Gid|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):' /proc/1/status
kubectl -n lab-d-secure exec hardened -- touch /etc/hacked
kubectl -n lab-d-secure exec hardened -- touch /tmp/ok && echo "/tmp is writable"
kubectl -n lab-d-secure exec hardened -- grep ' / ' /proc/mounts | cut -c1-40
```

```output
Uid:	65532	65532	65532	65532
Gid:	65532	65532	65532	65532
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
touch: /etc/hacked: Read-only file system
command terminated with exit code 1
/tmp is writable
overlay / overlay ro,relatime,lowerdir=/
```

**What you are seeing:** all four user IDs (real, effective, saved, filesystem) are 65532. Every capability set is empty, including the bounding set, so even a setuid binary could not gain one. `NoNewPrivs: 1` is `allowPrivilegeEscalation: false`. `Seccomp: 2` means filter mode, the RuntimeDefault profile. The root filesystem is mounted `ro`, so a write to `/etc` fails. The only writable path is the 16 MiB `emptyDir` mounted at `/tmp`.

Break it at the next layer. Admission checks the pod spec, not the image. Remove the explicit uid and use `wolfi-base`, whose image user is root (uid 0).

```bash
sed -e 's/name: hardened/name: image-root/' -e '/runAsUser: 65532/d' -e '/runAsGroup: 65532/d' \
  -e 's|chainguard/busybox|chainguard/wolfi-base|' aks/manifests/08/hardened-pod.yaml | kubectl apply -f -
sleep 12; kubectl -n lab-d-secure get pod image-root
kubectl -n lab-d-secure get events --field-selector involvedObject.name=image-root,reason=Failed -o jsonpath='{.items[-1:].message}{"\n"}'
kubectl -n lab-d-secure delete pod image-root
```

```output
pod/image-root created
NAME         READY   STATUS                       RESTARTS   AGE
image-root   0/1     CreateContainerConfigError   0          17s
Error: container has runAsNonRoot and image will run as root (pod: "image-root_lab-d-secure(2d4c737d-a634-405d-a0d0-d462c2aef9e6)", container: app)
pod "image-root" deleted from lab-d-secure namespace
```

**What you are seeing:** Pod Security admitted the pod, because the spec says `runAsNonRoot: true`. The kubelet then read the image's user, found uid 0 and refused to start the container. The same check fails for an image whose user is a name such as `nonroot`: the kubelet cannot prove a name is non-root. That is why this repo's Dockerfiles say `USER 65532`, not `USER nonroot`.

## 6. Network policy enforced by Cilium

This cluster uses Azure CNI powered by Cilium, which enforces Kubernetes NetworkPolicy with no extra engine. Create a namespace with a small web server (`aks/manifests/08/web.yaml`: Chainguard nginx on 8080 and a Service). Then define `probe`, which runs a throwaway curl pod with a given label.

```bash
kubectl create ns lab-d-net
kubectl apply -f aks/manifests/08/web.yaml
kubectl -n lab-d-net rollout status deploy/web --timeout=120s
probe() { kubectl -n lab-d-net run "$1" -l "$2" --rm -i --restart=Never --quiet --image=cgr.dev/chainguard/curl:latest \
  -- -sS -m 5 -o /dev/null -w '%{http_code}\n' "$3"; }
probe client-a access=web http://web:8080/
probe client-b role=other http://web:8080/
```

```output
namespace/lab-d-net created
deployment.apps/web created
service/web created
Waiting for deployment "web" rollout to finish: 0 of 1 updated replicas are available...
deployment "web" successfully rolled out
200
200
```

**What you are seeing:** with no policy, any pod can reach any pod. Now apply a default deny for both directions (`aks/manifests/08/netpol-default-deny.yaml`, an empty `podSelector` with `policyTypes: [Ingress, Egress]`).

```bash
kubectl apply -f aks/manifests/08/netpol-default-deny.yaml
probe client-a access=web http://web:8080/
```

```output
networkpolicy.networking.k8s.io/default-deny created
000
curl: (28) Resolving timed out after 5001 milliseconds
pod lab-d-net/client-a terminated (Error)
```

**What you are seeing:** the request never left the pod. Egress deny also blocks DNS, so the name `web` cannot resolve. This is the most common surprise with default deny. Now apply `aks/manifests/08/netpol-allow.yaml`, which has three policies. One allows DNS to kube-dns for every pod. One lets `app=web` accept traffic on 8080 only from pods labelled `access=web`. One lets `access=web` pods send to `app=web` on 8080.

```bash
kubectl apply -f aks/manifests/08/netpol-allow.yaml
kubectl -n lab-d-net get networkpolicy
probe client-a access=web http://web:8080/
probe client-b role=other http://web:8080/
probe client-a access=web https://learn.microsoft.com/
```

```output
networkpolicy.networking.k8s.io/allow-dns created
networkpolicy.networking.k8s.io/web-allow-from-clients created
networkpolicy.networking.k8s.io/clients-allow-to-web created
NAME                     POD-SELECTOR   AGE
allow-dns                <none>         2s
clients-allow-to-web     access=web     1s
default-deny             <none>         30s
web-allow-from-clients   app=web        1s
200
000
curl: (28) Connection timed out after 5001 milliseconds
pod lab-d-net/client-b terminated (Error)
000
curl: (28) Connection timed out after 5001 milliseconds
pod lab-d-net/client-a terminated (Error)
```

**What you are seeing:** the labelled client gets 200. The unlabelled client resolves the name (DNS is allowed) but its packets are dropped, so curl times out instead of being refused. Even the allowed client cannot reach the internet, because nothing allows egress beyond `app=web` and DNS. The policies select pods by label, so a new replica of `web` is covered the moment it starts.

See it from Cilium's side. The agent on the web pod's node lists each endpoint with its labels, whether policy is enforced, and its numeric Cilium identity.

```bash
NODE=$(kubectl -n lab-d-net get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
CILIUM=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name)
kubectl -n kube-system exec $CILIUM -c cilium-agent -- cilium-dbg endpoint list -o json | jq -r '.[]
  | select(any(.status.labels["security-relevant"][]?; test("namespace=lab-d-(net|secure)$")))
  | [.id, (.status.labels["security-relevant"][] | select(test("pod.namespace|k8s:app=|access="))),
     .status.policy.realized["policy-enabled"], .status.identity.id] | @tsv'
```

```output
506	k8s:io.kubernetes.pod.namespace=lab-d-secure	none	31953
1420	k8s:io.kubernetes.pod.namespace=lab-d-secure	none	7404
1480	k8s:app=web	k8s:io.kubernetes.pod.namespace=lab-d-net	both	63519
2680	k8s:io.kubernetes.pod.namespace=lab-d-secure	none	34772
```

**What you are seeing:** the `web` endpoint enforces policy in `both` directions. The three pods in `lab-d-secure` on this node show `none`: no policy selects them, so they are open. Cilium enforces in eBPF on the node and matches traffic by identity, which it derives from labels, not by IP address. This command only reads state from the agent. Do not change anything in kube-system.

## 7. Kyverno and the repo's admission policies

Pod Security covers the pod's privileges. Organisation rules need a policy engine: approved registries, pinned images, required labels, resources and probes. Install Kyverno with Helm into its own namespace. Its pods do not tolerate the `CriticalAddonsOnly` taint, so they land on the `user` nodes.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update kyverno
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --version 3.9.1 --wait --timeout 6m
kubectl -n kyverno get pods -o wide | awk '{print $1, $2, $3, $7}'
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.metadata.annotations}{"\n"}'
```

```output
...
⚠️  WARNING: Setting the admission controller replica count below 2 means Kyverno is not running in high availability mode.
...
⚠️  WARNING: The legacy kyverno.io policy types are deprecated and will be removed in a future release. Migrate to their policies.kyverno.io replacements:
    - ClusterPolicy / Policy → ValidatingPolicy, MutatingPolicy, GeneratingPolicy, ImageValidatingPolicy (and their namespaced variants)
...
NAME READY STATUS NODE
kyverno-admission-controller-86cbbb5545-xjpgc 1/1 Running aks-user-25795745-vmss000001
kyverno-background-controller-5546cb5b76-vqnnh 1/1 Running aks-user-25795745-vmss000001
kyverno-cleanup-controller-f947f9769-qhmkh 1/1 Running aks-user-25795745-vmss000001
kyverno-reports-controller-79d68cccbb-qwp7q 1/1 Running aks-user-25795745-vmss000001
{"admissions.enforcer/disabled":"true"}
```

**What you are seeing:** four controllers, one replica each. That is fine for a lab. Production runs two or more admission controller replicas, as the chart's own warning says, because the webhooks fail closed (`failurePolicy: Fail`). The chart sets `admissions.enforcer/disabled: "true"` on its webhooks, so the AKS Admissions Enforcer leaves Kyverno's webhook configuration alone. Kyverno 1.19 also warns that the `kyverno.io/v1` policy kinds are deprecated.

Apply the repo's four ClusterPolicies. They match only Pods in namespaces labelled `data-classification` `pci` or `phi`, so they do not touch anyone else's workloads.

```bash
kubectl apply -f policy/kyverno/cluster/
kubectl get clusterpolicy
```

```output
Warning: kyverno.io/v1 ClusterPolicy is deprecated and will be removed in a future release; migrate to ValidatingPolicy, MutatingPolicy, GeneratingPolicy or ImageValidatingPolicy (policies.kyverno.io), see https://kyverno.io/docs/guides/migration-to-cel/
clusterpolicy.kyverno.io/disallow-latest-tag created
clusterpolicy.kyverno.io/require-data-classification created
clusterpolicy.kyverno.io/require-resources-and-probes created
clusterpolicy.kyverno.io/restrict-image-registries created
...
NAME                           ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-latest-tag            true        true         True    8s    Ready
require-data-classification    true        true         True    7s    Ready
require-resources-and-probes   true        true         True    7s    Ready
restrict-image-registries      true        true         True    6s    Ready
```

Create a PCI namespace with Pod Security `restricted`, and send it three kinds of bad pod: a quick `kubectl run`, a pod that is hardened but breaks the house rules (`aks/manifests/08/pci-bad-pod.yaml`), and a fully compliant pod whose image comes from ACR. `az acr import` copies Chainguard busybox into the ACR for that last test, with no local Docker.

```bash
az acr import -n $ACR --source cgr.dev/chainguard/busybox:latest --image labs/d/busybox:1 --force
kubectl create ns lab-d-pci
kubectl label ns lab-d-pci data-classification=pci pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
kubectl -n lab-d-pci run naive --image=cgr.dev/chainguard/busybox:latest -- sleep 3600
kubectl apply -f aks/manifests/08/pci-bad-pod.yaml
sed "s|cgr.dev/chainguard/busybox@DIGEST|$ACR.azurecr.io/labs/d/busybox:1|" aks/manifests/08/pci-good-pod.yaml | kubectl apply -f -
```

```output
namespace/lab-d-pci created
namespace/lab-d-pci labeled
Error from server (Forbidden): pods "naive" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "naive" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "naive" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "naive" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "naive" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
Error from server: error when creating "aks/manifests/08/pci-bad-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/lab-d-pci/quick-test was blocked due to the following policies 

disallow-latest-tag:
  require-pinned-image: 'validation error: Use a version tag or a digest, never :latest or no tag. rule require-pinned-image failed at path /spec/containers/0/image/'
require-data-classification:
  classification-label: 'validation error: Label the workload data-classification: pci, phi, internal or public. rule classification-label failed at path /metadata/labels/'
require-resources-and-probes:
  requests-limits-probes: 'validation error: Every container needs a CPU and memory request, a memory limit, and a readiness probe. rule requests-limits-probes failed at path /spec/containers/0/readinessProbe/'
Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/lab-d-pci/compliant was blocked due to the following policies 

restrict-image-registries:
  allowed-registries: 'validation error: Images must come from ghcr.io/sathpal/regulated-k8s-reference/* or cgr.dev/chainguard/*. rule allowed-registries failed at path /spec/containers/0/image/'
```

**What you are seeing:** the layers run in order. Pod Security is a built-in admission plugin and refuses `naive` before any webhook sees it. The second pod passes Pod Security, then Kyverno lists every rule it breaks in one message. The third pod is compliant in every way except its registry. The repo's allow-list names GHCR and Chainguard, not this ACR, even though the image inside is the same Chainguard busybox. On AKS you would add your ACR to that list. You would not weaken the rule.

The policies also refuse a Deployment before it creates a ReplicaSet. Kyverno generates matching rules for pod controllers (autogen).

```bash
kubectl -n lab-d-pci create deployment quick --image=cgr.dev/chainguard/busybox:latest -- sleep 3600
```

```output
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "busybox" must set securityContext.allowPrivilegeEscalation=false), ...
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/lab-d-pci/quick was blocked due to the following policies 

disallow-latest-tag:
  autogen-require-pinned-image: 'validation error: Use a version tag or a digest, never :latest or no tag. rule autogen-require-pinned-image failed at path /spec/template/spec/containers/0/image/'
require-data-classification:
  autogen-classification-label: ...
require-resources-and-probes:
  autogen-requests-limits-probes: ...
```

**What you are seeing:** Pod Security only warns on a Deployment. It enforces on the pods, so on its own the Deployment would be accepted and its ReplicaSet would fail quietly. Kyverno refuses the Deployment itself, which is a far better signal in a pipeline. Finally, admit a compliant pod with the image pinned to today's digest, and read the background report.

```bash
DIGEST=$(DOCKER_CONFIG=$(mktemp -d) crane digest cgr.dev/chainguard/busybox:latest)
sed "s|@DIGEST|@$DIGEST|" aks/manifests/08/pci-good-pod.yaml | kubectl apply -f -
kubectl -n lab-d-pci wait --for=condition=Ready pod/compliant --timeout=90s
kubectl -n lab-d-pci get policyreport -o json | jq -r '.items[].results[] | [.policy, .result] | @tsv'
```

```output
pod/compliant created
pod/compliant condition met
disallow-latest-tag	pass
require-data-classification	pass
require-resources-and-probes	pass
restrict-image-registries	pass
```

## 8. Sign an image with a key that never leaves Key Vault

The cosign key `cosign-signing` is a non-exportable EC P-256 key in Key Vault. cosign sends the digest to Key Vault and gets a signature back, so the private key never reaches your machine or the pipeline. Build payments-api twice with ACR Tasks: tag 1 is the release you will sign, tag 2 stands for a build that skipped the pipeline.

```bash
az keyvault key show --vault-name $KV -n cosign-signing --query "{kty:key.kty, crv:key.crv, ops:key.keyOps, exportable:attributes.exportable}" -o json
az acr build -r $ACR -t labs/d/payments-api:1 apps/payments-api 2>&1 | tail -3
az acr build -r $ACR -t labs/d/payments-api:2 apps/payments-api 2>&1 | tail -3
```

```output
{
  "crv": "P-256",
  "exportable": false,
  "kty": "EC",
  "ops": [
    "sign",
    "verify"
  ]
}
...
Run ID: cuu was successful after 1m21s
...
Run ID: cuv was successful after 1m28s
```

Sign the digest of tag 1, never the tag. cosign needs push rights to store the signature next to the image. `az acr login --expose-token` gives a short-lived ACR token, and a throwaway `DOCKER_CONFIG` keeps it out of your Docker settings.

```bash
export DOCKER_CONFIG=$(mktemp -d)
az acr login -n $ACR --expose-token --query accessToken -o tsv 2>/dev/null \
  | cosign login $ACR.azurecr.io -u 00000000-0000-0000-0000-000000000000 --password-stdin
DIGEST=$(az acr repository show -n $ACR --image labs/d/payments-api:1 --query digest -o tsv)
IMAGE=$ACR.azurecr.io/labs/d/payments-api@$DIGEST
cosign sign --key azurekms://$KV.vault.azure.net/cosign-signing -y $IMAGE
cosign public-key --key azurekms://$KV.vault.azure.net/cosign-signing | diff - aks/keys/cosign-signing.pub && echo "same public key"
cosign verify --key aks/keys/cosign-signing.pub $IMAGE 2>&1 | head -6
az acr manifest list-referrers -r $ACR -n labs/d/payments-api@$DIGEST --query "manifests[].{artifactType:artifactType, annotations:annotations}" -o json 2>/dev/null
```

```output
logged in via /var/folders/.../config.json
Signing artifact...
Pushing signature to: acrregk8s1e1193.azurecr.io/labs/d/payments-api
same public key

Verification for acrregk8s1e1193.azurecr.io/labs/d/payments-api@sha256:3ec94ac5cef9f174f870c7b23f239a0ec48a82ee0350f2e8a4412840de9f8639 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key
[
  {
    "annotations": {
      "dev.sigstore.bundle.content": "dsse-envelope",
      "dev.sigstore.bundle.predicateType": "https://sigstore.dev/cosign/sign/v1",
      "org.opencontainers.image.created": "2026-10-02T14:30:52Z"
    },
    "artifactType": "application/vnd.dev.sigstore.bundle.v0.3+json"
  }
]
```

**What you are seeing:** cosign 3 stores the signature as a Sigstore bundle attached to the image digest through the OCI referrers API, not as a `sha256-<digest>.sig` tag. Older cosign versions write the tag form, and the `payments-api` repository in this same registry already holds signatures that way. A verifier has to understand both. The signature was also recorded in the public Rekor transparency log, which cosign checked offline with the bundle's proof. If signatures for private images must not go to a public log, cosign 3 wants a signing config with no transparency log (`--tlog-upload=false` is deprecated and refused with the default config). The verifier then has to be told to skip the log check.

## 9. Admit only signed images from ACR

Use a Kyverno ImageValidatingPolicy (`policies.kyverno.io/v1`, stable since Kyverno 1.18) rather than the deprecated `ClusterPolicy` `verifyImages` rule. The namespaced variant keeps the rule inside `lab-d-signed`. The public key is read from Key Vault when you apply the policy, so it is the public half of the signing key. `mutateDigest` rewrites the tag to the verified digest, so the node pulls exactly what was checked.

```bash
kubectl create ns lab-d-signed
kubectl label ns lab-d-signed pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
PUBKEY=$(cosign public-key --key azurekms://$KV.vault.azure.net/cosign-signing | sed 's/^/            /')
kubectl apply -f - <<EOF
apiVersion: policies.kyverno.io/v1
kind: NamespacedImageValidatingPolicy
metadata:
  name: signed-images-from-acr
  namespace: lab-d-signed
spec:
  validationActions: [Deny]
  webhookConfiguration:
    timeoutSeconds: 15
  evaluation:
    background:
      enabled: false
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  matchImageReferences:
    - glob: "$ACR.azurecr.io/*"
  attestors:
    - name: keyvault
      cosign:
        key:
          data: |
$PUBKEY
  validationConfigurations:
    required: true
    mutateDigest: true
    verifyDigest: true
  validations:
    - expression: >-
        object.spec.containers.all(c, c.image.startsWith("$ACR.azurecr.io/"))
      message: "Images in this namespace must come from $ACR.azurecr.io."
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.keyvault])).all(e, e > 0)
      message: "Every image must carry a cosign signature from the cosign-signing key in Key Vault."
EOF
kubectl -n lab-d-signed get nivpol
```

```output
namespace/lab-d-signed created
namespace/lab-d-signed labeled
namespacedimagevalidatingpolicy.policies.kyverno.io/signed-images-from-acr created
NAME                     AGE   READY
signed-images-from-acr   5s    true
```

`aks/manifests/08/signed-pod.yaml` is payments-api as a hardened pod with `NAME` and `IMAGE` placeholders. `run_pod` fills them in. Try the signed tag first.

```bash
run_pod() { sed -e "s|NAME|$1|" -e "s|IMAGE|$2|" aks/manifests/08/signed-pod.yaml | kubectl apply -f -; }
run_pod signed $ACR.azurecr.io/labs/d/payments-api:1
```

```output
Error from server: error when creating "STDIN": admission webhook "ivpol.mutate.kyverno.svc-fail-finegrained-lab-d-signed-signed-images-from-acr" denied the request: Policy signed-images-from-acr error: failed to update digest: failed to resolve digest for image acrregk8s1e1193.azurecr.io/labs/d/payments-api:1: DefaultAzureCredential: failed to acquire a token.
Attempted credentials:
	EnvironmentCredential: missing environment variable AZURE_TENANT_ID
	WorkloadIdentityCredential: no client ID specified. Check pod configuration or set ClientID in the options
	ManagedIdentityCredential: failed to authenticate a system assigned identity. The endpoint responded with {"error":"invalid_request","error_description":"Multiple user assigned identities exist, please specify the clientId / resourceId of the identity in the token request"}
	AzureCLICredential: fork/exec /bin/sh: permission denied. ...
```

**What you are seeing:** the signed image was refused, and not because of its signature. Kyverno could not log in to ACR to resolve the tag and fetch the signature. Its Azure credential helper tried every source in turn. The managed identity attempt reached the node's instance metadata endpoint. There it found two user-assigned identities on the VMSS (the kubelet identity and the Key Vault add-on identity) and refused to guess. Two lessons. The policy fails closed, which is what you want. And a pod on this cluster can reach the node's identity endpoint unless something blocks it.

Kyverno needs read access to the registry. Its docs offer two routes. One is image pull secrets in the kyverno namespace, for example from a repository-scoped ACR token. That is a long-lived credential stored as a Kubernetes Secret. The other is the cloud credential helpers, which the chart enables by default. The `azure` helper is the DefaultAzureCredential chain you just saw fail, and that chain includes workload identity. This lab gives Kyverno's admission controller a workload identity, the same pattern as step 3, so no secret is stored anywhere. One caveat: on this registry (`roleAssignmentMode: LegacyRegistryPermissions`), AcrPull applies to every repository in it.

```bash
az identity create -g $RG -n id-lab-d-kyverno -l $LOC --query "{name:name, clientId:clientId, principalId:principalId}" -o table
az identity federated-credential create -g $RG --identity-name id-lab-d-kyverno -n fc-kyverno-admission-controller \
  --issuer "$ISSUER" --subject system:serviceaccount:kyverno:kyverno-admission-controller --audiences api://AzureADTokenExchange -o none
az role assignment create --assignee-object-id $(az identity show -g $RG -n id-lab-d-kyverno --query principalId -o tsv) \
  --assignee-principal-type ServicePrincipal --role AcrPull --scope $(az acr show -n $ACR --query id -o tsv) -o none
KYV_CLIENT_ID=$(az identity show -g $RG -n id-lab-d-kyverno --query clientId -o tsv)
helm upgrade kyverno kyverno/kyverno -n kyverno --version 3.9.1 --reuse-values \
  --set admissionController.rbac.serviceAccount.annotations."azure\.workload\.identity/client-id"=$KYV_CLIENT_ID \
  --set-string admissionController.podLabels."azure\.workload\.identity/use"=true --wait --timeout 5m | head -1
kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o json \
  | jq -r '.items[0].spec.containers[0].env[] | select(.name|startswith("AZURE_")) | .name'
```

```output
Name              ClientId                              PrincipalId
----------------  ------------------------------------  ------------------------------------
id-lab-d-kyverno  ba88c218-f285-4aa6-bc2a-5f5b55b2b191  25982fce-eedf-4c98-a249-1f6db1a1b5a8
Release "kyverno" has been upgraded. Happy Helming!
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_FEDERATED_TOKEN_FILE
AZURE_AUTHORITY_HOST
```

Now run the signed tag, the unsigned build, and an image from another registry.

```bash
run_pod signed $ACR.azurecr.io/labs/d/payments-api:1
run_pod unsigned $ACR.azurecr.io/labs/d/payments-api:2
run_pod other cgr.dev/chainguard/static:latest
kubectl -n lab-d-signed get pods -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image'
```

```output
pod/signed created
Error from server: error when creating "STDIN": admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-lab-d-signed-signed-images-from-acr" denied the request: Policy signed-images-from-acr failed: Every image must carry a cosign signature from the cosign-signing key in Key Vault.
Error from server: error when creating "STDIN": admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-lab-d-signed-signed-images-from-acr" denied the request: Policy signed-images-from-acr failed: Images in this namespace must come from acrregk8s1e1193.azurecr.io.
NAME     READY   IMAGE
signed   true    acrregk8s1e1193.azurecr.io/labs/d/payments-api:1@sha256:3ec94ac5cef9f174f870c7b23f239a0ec48a82ee0350f2e8a4412840de9f8639
```

**What you are seeing:** the signed build is admitted, and its image field now ends in `@sha256:3ec9...`. Kyverno pinned the pod to the digest it verified. The unsigned build from the same repository is refused, and so is a perfectly good Chainguard image from outside the ACR.

Now the attack that tags invite: re-point tag `1` at the unsigned build, as a careless re-push or a compromised push credential would.

```bash
az acr import -n $ACR --source $ACR.azurecr.io/labs/d/payments-api:2 --image labs/d/payments-api:1 --force
az acr repository show -n $ACR --image labs/d/payments-api:1 --query digest -o tsv
run_pod retagged $ACR.azurecr.io/labs/d/payments-api:1
kubectl -n lab-d-signed get pods
kubectl -n kyverno logs deploy/kyverno-admission-controller -c kyverno --since=10m | sed 's/\x1b\[[0-9;]*m//g' | grep 'image verification failed' | tail -1 | cut -c1-230
```

```output
sha256:cdd08a23d02339ffeb721f456079d78f8f4723c5dccea2716c45ea1bdf503573
Error from server: error when creating "STDIN": admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-lab-d-signed-signed-images-from-acr" denied the request: Policy signed-images-from-acr failed: Every image must carry a cosign signature from the cosign-signing key in Key Vault.
NAME     READY   STATUS    RESTARTS   AGE
signed   1/1     Running   0          54s
2026-10-02T14:37:01Z ERR github.com/kyverno/kyverno/pkg/image/verifiers/ivpol/cosign/verifier.go:103 > image verification failed error="failed to verify cosign signatures: no signatures found" attestor=keyvault digest=sha256:cdd08
```

**What you are seeing:** tag `:1` now points at the unsigned build (`cdd08a...`), and the same tag that was admitted a minute ago is refused. Verification follows the digest, not the tag. The `signed` pod keeps running on the digest it was pinned to. The admission controller log gives the reason an operator needs: `no signatures found` for that digest. Deploying the signed release by digest still works:

```bash
run_pod by-digest $ACR.azurecr.io/labs/d/payments-api@$DIGEST
kubectl -n lab-d-signed wait --for=condition=Ready pod/by-digest --timeout=60s
kubectl -n lab-d-signed get pods -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image'
```

```output
pod/by-digest created
pod/by-digest condition met
NAME        READY   IMAGE
by-digest   true    acrregk8s1e1193.azurecr.io/labs/d/payments-api@sha256:3ec94ac5cef9f174f870c7b23f239a0ec48a82ee0350f2e8a4412840de9f8639
signed      true    acrregk8s1e1193.azurecr.io/labs/d/payments-api:1@sha256:3ec94ac5cef9f174f870c7b23f239a0ec48a82ee0350f2e8a4412840de9f8639
```

Put the tag back:

```bash
az acr import -n $ACR --source $ACR.azurecr.io/labs/d/payments-api@$DIGEST --image labs/d/payments-api:1 --force
unset DOCKER_CONFIG
```

One limit found while testing: this namespaced policy registered its webhook for Pods only. A Deployment of the unsigned build (`aks/manifests/08/unsigned-deployment.yaml`) was accepted, and the refusal surfaced on its ReplicaSet as a `FailedCreate` event. That is the opposite of the ClusterPolicy autogen behaviour in step 7.

```bash
sed "s|IMAGE|$ACR.azurecr.io/labs/d/payments-api:2|" aks/manifests/08/unsigned-deployment.yaml | kubectl apply -f -
sleep 10; kubectl -n lab-d-signed get deploy,rs -l app=payments-unsigned
kubectl -n lab-d-signed get events --field-selector reason=FailedCreate -o jsonpath='{.items[-1:].message}'; echo
kubectl -n lab-d-signed delete deployment payments-unsigned
```

```output
deployment.apps/payments-unsigned created
NAME                                        DESIRED   CURRENT   READY   AGE
replicaset.apps/payments-unsigned-cddd989   1         0         0       11s
Error creating: admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-lab-d-signed-signed-images-from-acr" denied the request: Policy signed-images-from-acr failed: Every image must carry a cosign signature from the cosign-signing key in Key Vault.
deployment.apps "payments-unsigned" deleted from lab-d-signed namespace
```

**What you are seeing:** the unsigned image still never runs, but the rollout would hang instead of failing at `kubectl apply`. Alert on `FailedCreate`, and let the Deployment's `progressDeadlineSeconds` mark the rollout as failed, as this repo's base Deployment does.

## 10. Azure-native options: what is on, what is off, and why

Read the cluster's current settings for the Azure-managed security features.

```bash
az aks show -g $RG -n $AKS --query "{azurePolicyAddon: addonProfiles.azurepolicy.enabled, defender: securityProfile.defender, imageIntegrity: securityProfile.imageIntegrity, authorizedIpRanges: apiServerAccessProfile.authorizedIpRanges, privateCluster: apiServerAccessProfile.enablePrivateCluster, upgradeChannel: autoUpgradeProfile.upgradeChannel, nodeOsUpgradeChannel: autoUpgradeProfile.nodeOsUpgradeChannel, sku: sku.tier}" -o json
az aks nodepool list -g $RG --cluster-name $AKS --query "[].{name:name, nodeImageVersion:nodeImageVersion}" -o table
```

```output
{
  "authorizedIpRanges": null,
  "azurePolicyAddon": null,
  "defender": null,
  "imageIntegrity": null,
  "nodeOsUpgradeChannel": "NodeImage",
  "privateCluster": null,
  "sku": "Free",
  "upgradeChannel": "patch"
}
Name    NodeImageVersion
------  --------------------------------
system  AKSAzureLinux-V3gen2-202609.15.0
user    AKSAzureLinux-V3gen2-202609.15.0
```

**What you are seeing:** patching is automated. Kubernetes patch releases come through the `patch` channel, and the node OS through `NodeImage`, a new patched Azure Linux image each week. Everything else here is off. The options below are explained, not enabled, in this lab.

- **Azure Policy add-on for AKS.** It runs Gatekeeper (OPA) as an admission webhook. It comes with built-in initiatives such as "Kubernetes cluster pod security baseline standards for Linux-based workloads" and the restricted equivalent. You enable it with `az aks enable-addons --addons azure-policy`, and you assign policy from Azure, so compliance shows up across all clusters in Azure Policy. Assignments can take up to 20 minutes to sync. Microsoft documents that Gatekeeper installed outside the add-on is not supported alongside it. Choose it when central compliance reporting across many clusters matters more than in-cluster YAML policies.
- **Image Integrity (preview).** This is AKS's managed signature check, built on Ratify. Notation is the only supported verifier, Audit is the only supported effect, and the docs say not to use it for production registries or workloads. Notation signing with a Key Vault key is documented for ACR. Today, the Kyverno policy in step 9 is the enforcing option on this cluster.
- **Microsoft Defender for Containers.** It scans registry images and running containers for vulnerabilities without an agent, and detects runtime threats with the Defender sensor (an eBPF DaemonSet) plus Kubernetes audit logs. It is a paid plan priced per vCore of worker nodes, so it is not enabled here.
- **API server access.** This cluster's API server is public, protected by Entra ID. Authorized IP ranges would restrict which source addresses may reach it (up to 200 ranges, not usable with private clusters). On a shared cluster, one wrong list locks everyone out, so it is never enabled here. A private cluster gives the API server a private IP through Private Link. kubectl then has to run from the VNet or a connected network (peering, VPN, ExpressRoute, Bastion), or through `az aks command invoke`. API Server VNet Integration is another option: it projects the API server endpoint into a delegated subnet.
- **Node OS auto-upgrade.** The channels are `None`, `Unmanaged`, `SecurityPatch` and `NodeImage`. `NodeImage` is the default for new clusters and adds no VHD cost. `SecurityPatch` adds the cost of hosting VHDs in the node resource group. Pair either with a maintenance window (`aksManagedNodeOSUpgradeSchedule`) of four hours or more.

## 11. The controls in one table

| Layer | Control | What it stops | Evidence command |
|---|---|---|---|
| Cluster access | Entra ID + Azure RBAC, local accounts disabled | A shared, non-auditable admin kubeconfig | `az aks get-credentials -g $RG -n $AKS --admin --file /dev/null` (BadRequest) |
| Cluster access | RBAC Reader scoped to one namespace | A reader seeing Secrets, other namespaces, or changing anything | `aks/scripts/azure-rbac-check.sh $READER_OID get secrets lab-d-secure` (false) |
| Workload identity | Federated credential bound to one service account | Another service account using the identity by copying its client ID | FailedMount event with `AADSTS700213` for `kv-wrong-sa` |
| Secrets | Key Vault through the Secrets Store CSI driver | Secret values in etcd and in `get secrets` output | `kubectl -n lab-d-secure get secrets` (No resources found) |
| Pod | Pod Security `restricted` | Root, privilege escalation, extra capabilities, no seccomp | `kubectl apply -f aks/manifests/08/root-pod.yaml` (forbidden) |
| Pod | Hardened securityContext as seen by the kernel | Writes to the image filesystem, capability use, setuid escalation | `kubectl -n lab-d-secure exec hardened -- grep -e Uid -e CapEff -e NoNewPrivs -e Seccomp /proc/1/status` |
| Node (kubelet) | `runAsNonRoot` checked against the image user | An image that runs as uid 0 despite a compliant spec | `kubectl -n lab-d-secure get pod image-root` (CreateContainerConfigError) |
| Network | Default deny plus label-based allow (Cilium) | Lateral movement and egress to the internet | `probe client-b role=other http://web:8080/` (timeout) |
| Admission | Kyverno policies from `policy/kyverno/cluster` | `:latest`, unapproved registries, missing labels, resources or probes | `kubectl apply -f aks/manifests/08/pci-bad-pod.yaml` (blocked) |
| Supply chain | ImageValidatingPolicy with the Key Vault public key | Unsigned images, re-pointed tags, other registries | `run_pod unsigned $ACR.azurecr.io/labs/d/payments-api:2` (denied) |
| Supply chain | `mutateDigest` | The tag moving after admission | `kubectl -n lab-d-signed get pod signed -o jsonpath='{.spec.containers[0].image}'` (ends in `@sha256:`) |
| Platform | Cluster `patch` and node OS `NodeImage` auto-upgrade | Known CVEs lingering in Kubernetes and the node OS | `az aks show -g $RG -n $AKS --query autoUpgradeProfile` |

## On AKS specifically

- **Azure RBAC roles.** "Azure Kubernetes Service RBAC Reader" and "RBAC Writer" can be scoped to a namespace (`$AKS_ID/namespaces/<ns>`). Reader cannot view Secrets, because that would expose service account tokens. Writer can read Secrets and run pods as any service account in the namespace, so treat Writer as close to admin for that namespace. New role assignments can take up to five minutes to reach the authorization server. ([Microsoft Entra ID authorization](https://learn.microsoft.com/azure/aks/entra-id-authorization))
- **Local accounts.** Local accounts are enabled by default, and Microsoft calls `--admin` access "a non-auditable backdoor option". After disabling them on an existing cluster, rotate the cluster certificates to revoke any certificates users might already hold. ([Manage local accounts](https://learn.microsoft.com/azure/aks/local-accounts))
- **Kubeconfig roles.** "Cluster User Role" and "Cluster Admin Role" control `listClusterUserCredential` and `listClusterAdminCredential`, that is, who can download a kubeconfig. On Entra ID clusters, the user kubeconfig only prompts a login, and access inside the cluster comes from the Entra identity. ([Limit access to kubeconfig](https://learn.microsoft.com/azure/aks/control-kubeconfig-access))
- **Token audience.** `6dae42f8-4368-4678-94ff-3960e28e3630` is the AKS server application, the token audience for every kubelogin method. It is the same in all environments. ([kubelogin](https://learn.microsoft.com/azure/aks/kubelogin-authentication))
- **Workload identity.** Only pods labelled `azure.workload.identity/use: "true"` are mutated. A managed identity can hold at most 20 federated identity credentials. A new federated credential takes a few seconds to propagate. Workload identity replaces pod-managed identity, which is deprecated. ([Workload identity overview](https://learn.microsoft.com/azure/aks/workload-identity-overview), [CSI driver identity access](https://learn.microsoft.com/azure/aks/csi-secrets-store-identity-access))
- **Secrets Store CSI add-on.** Syncing to a Kubernetes Secret (`secretObjects`) is optional. Rotation polls every two minutes by default once it is enabled with `--enable-secret-rotation`. On this cluster it is disabled. ([CSI configuration options](https://learn.microsoft.com/azure/aks/csi-secrets-store-configuration-options))
- **Pod Security Admission** is enabled by default in AKS. Microsoft recommends Azure Policy when you need enterprise-wide policy. ([Use Pod Security Admission](https://learn.microsoft.com/azure/aks/use-psa))
- **Cilium.** Azure CNI powered by Cilium enforces Kubernetes NetworkPolicy and L3/L4 CiliumNetworkPolicy. FQDN filtering and L7 (HTTP, gRPC, Kafka) policies need Advanced Container Networking Services, which is a paid offering billed per node per hour. NetworkPolicy cannot use `ipBlock` to allow node or pod IPs, and pods with `hostNetwork: true` are not subject to policy. ([Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium), [FQDN filtering](https://learn.microsoft.com/azure/aks/container-network-security-fqdn-filtering-concepts), [L7 policy](https://learn.microsoft.com/azure/aks/container-network-security-l7-policy-concepts))
- **Azure Policy add-on.** It extends Gatekeeper v3 and runs on Linux node pools only. It checks in with Azure Policy every 15 minutes. Azure Policy itself has no charge on Azure resources. ([Azure Policy for Kubernetes](https://learn.microsoft.com/azure/governance/policy/concepts/policy-for-kubernetes), [Use Azure Policy on AKS](https://learn.microsoft.com/azure/aks/use-azure-policy))
- **Image Integrity** is preview, Audit only, with Notation as the only verifier, and it is not meant for production registries. ([Image Integrity](https://learn.microsoft.com/azure/aks/image-integrity))
- **Defender for Containers** is billed as part of Defender for Cloud and priced on the vCores of the worker nodes. ([Defender for Containers](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction))
- **API server access.** Authorized IP ranges allow up to 200 ranges and take up to two minutes to apply. Updating them replaces the whole list. They cannot be combined with a private cluster. ([Authorized IP ranges](https://learn.microsoft.com/azure/aks/api-server-authorized-ip-ranges), [Private clusters](https://learn.microsoft.com/azure/aks/private-clusters))
- **Node OS channels.** `NodeImage` ships a patched VHD weekly with no extra VHD cost and is the default for new clusters. `SecurityPatch` adds the cost of hosting VHDs in the node resource group. Microsoft recommends maintenance windows of four hours or more. ([Node OS auto-upgrade](https://learn.microsoft.com/azure/aks/auto-upgrade-node-os-image))
- **ACR tokens.** Repository-scoped ACR tokens are available in every service tier, including Basic. The same page says repository-scoped permissions cannot be assigned to a Microsoft Entra identity this way, and points to the registry's ABAC mode instead. This registry runs in `LegacyRegistryPermissions` mode, which is why Kyverno's AcrPull here covers the whole registry. ([Repository-scoped permissions](https://learn.microsoft.com/azure/container-registry/container-registry-repository-scoped-permissions))
- **Kyverno on AKS.** The Helm chart sets the `admissions.enforcer/disabled` annotation for you. `ClusterPolicy` (`kyverno.io/v1`) is deprecated in 1.19 and planned for removal in 1.20. The repo's `policy/kyverno` policies will need migrating to ValidatingPolicy and ImageValidatingPolicy. ([Platform notes](https://kyverno.io/docs/installation/platform-notes/), [Policy types](https://kyverno.io/docs/policy-types/overview/))

## In the conversation

**Why it matters in production.** Security on AKS is shared. Azure runs and patches the control plane, offers identity, policy and scanning services, and patches node images on a channel you choose. Everything inside the cluster is yours: who gets which role, where secrets live, how pods run, what they can talk to and which images they may run. Each layer here is cheap on its own and catches a different mistake. A good platform makes the safe path the default and leaves evidence for every refusal. The question to ask of any control is "show me it refusing something", and every row in the table above answers it with a command.

**A story from this lab.** "When I added signature verification for our ACR, the first image that failed was the signed one. Kyverno could not log in to the registry. Its Azure credential chain fell through to the node's metadata endpoint and found two identities on the VMSS. It refused to guess, and the policy failed closed. I gave Kyverno's admission controller its own workload identity with AcrPull instead of a pull secret, and then the results were what we wanted. The signed build was admitted and pinned to its digest. The unsigned build from the same repository was refused. And when I re-pointed the release tag at the unsigned build, the same tag was refused too, because verification follows the digest. It is the same reason I insist on deploying by digest. In an earlier setup, a registry deleted the old image when a tag was re-pushed, and a pinned pod could not be rescheduled."

**Questions to expect**

- *Why not keep the admin kubeconfig for emergencies?* Because it is a shared certificate that bypasses Entra ID and per-user audit; Microsoft's own docs call it a non-auditable backdoor. Here `--admin` returns BadRequest. Break-glass is an Entra group holding "RBAC Cluster Admin", with alerting on its use.
- *Why the CSI driver instead of Kubernetes Secrets?* A Secret is base64 in etcd, readable by anyone with `get secrets` and copied into every backup. With the CSI driver, the value lives in Key Vault, with its own RBAC and audit, and in a tmpfs on one node while the pod runs. The pod authenticates with a one-hour token and no stored credential. The trade-off: a secret consumed as an environment variable needs the optional sync to a Secret, and rotation reaches files only when rotation is enabled.
- *What happens when Kyverno is down?* Its webhooks fail closed, so pods in matched namespaces cannot be created until it is back. That is why it runs with several replicas in production. Kyverno's default excludes kube-system, and the AKS Admissions Enforcer annotation keeps AKS from rewriting Kyverno's webhooks.
- *Kyverno or Azure Policy?* Azure Policy gives one compliance view across many clusters and subscriptions, with Gatekeeper as the engine. Kyverno gives policy as plain YAML or CEL in the repo, tested with `kyverno test` in CI, plus enforcing cosign verification today. They are separate admission webhooks, so one cluster can run both: Azure Policy for the baseline and reporting, Kyverno for workload rules. Image Integrity, the managed signature option, is still preview and audit-only.
- *How do you roll out signature enforcement without an outage?* Start with `validationActions: [Audit]` and read the policy reports. Sign everything the pipeline builds, including base-image bumps, then switch to Deny one namespace at a time. Mirror images with `cosign copy`, not `crane copy`, because a plain copy drops the signatures.

## If something looks different

- **The SubjectAccessReview returns `false` right after you create the role assignment.** Azure role assignments can take up to five minutes to reach the AKS authorization server. Wait and run it again.
- **The CSI volume fails with `AADSTS700213`.** The federated credential's issuer, subject or audience does not match the token. Check the namespace and service account name in `--subject`, and that `$ISSUER` ends with a slash exactly as `az aks show` prints it.
- **Kyverno still reports `DefaultAzureCredential` after the Helm upgrade.** The admission controller pod must be recreated with the `azure.workload.identity/use` label. Check that the `AZURE_*` variables are in its spec, and wait a minute for the AcrPull assignment.
- **The allowed client times out as well.** Policies apply within seconds, but the `allow-dns` rule must match your DNS pods. On AKS that means `k8s-app: kube-dns` in kube-system. Run `kubectl -n kube-system get pods -l k8s-app=kube-dns`.

## Clean up

Delete the namespaces and the test secret. Kyverno, the repo's ClusterPolicies, the three managed identities and their role assignments can stay for later labs. The commented lines remove them if you are finished. The images in ACR can stay.

```bash
kubectl delete namespace lab-d-secure lab-d-net lab-d-pci lab-d-signed
az keyvault secret delete --vault-name $KV -n lab-d-db-password -o none
az keyvault secret purge --vault-name $KV -n lab-d-db-password   # may need a few seconds after the delete
# helm uninstall kyverno -n kyverno && kubectl delete namespace kyverno
# kubectl delete -f policy/kyverno/cluster/
# for id in id-lab-d-ns-reader id-lab-d-kv-reader id-lab-d-kyverno; do
#   az role assignment delete --assignee $(az identity show -g $RG -n $id --query principalId -o tsv)
#   az identity delete -g $RG -n $id
# done
```

## Checkpoint

1. The reader identity can list pods in `lab-d-secure`. Why can it not read Secrets there, and how would you give a CI job read access to one Key Vault secret without granting Secrets at all?
   _Hint: think about what a service account token in a Secret would let it do, and repeat step 3 with a different service account._
2. A pod passed Pod Security admission and still never started. Which component refused it, and what single line in a Dockerfile prevents it?
   _Hint: the kubelet compares `runAsNonRoot` with the image's user, and it can only trust a number._
3. Tag `:1` was admitted, then refused a minute later with no change to the policy. What changed, and why did the running pod keep working?
   _Hint: look at what `mutateDigest` wrote into the pod's image field._

## Further reading

- [Use Microsoft Entra ID authorization for the Kubernetes API](https://learn.microsoft.com/azure/aks/entra-id-authorization)
- [Workload identity on AKS](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Connect your Azure identity to the Key Vault Secrets Store CSI driver](https://learn.microsoft.com/azure/aks/csi-secrets-store-identity-access)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [Kyverno ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Signing containers with cosign](https://docs.sigstore.dev/cosign/signing/signing_with_containers/)
- [Enforcing policies on Chainguard containers with Kyverno](https://edu.chainguard.dev/chainguard/containers/security-and-compliance/enforcement/kyverno/)
