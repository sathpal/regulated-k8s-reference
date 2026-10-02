# 06. CI/CD into AKS: pipeline push and GitOps pull

**Goal:** deliver payments-api to AKS two ways, both real: a GitHub Actions pipeline that signs in to Azure with no
stored secret, builds in ACR, gates, signs with a Key Vault key and deploys a digest with automatic rollback; and
GitOps with the AKS Flux extension, where Git is the only way to change what runs.

**You need:** lab 00, this repository on GitHub, and the `gh` CLI. About 45 minutes.

_Outputs captured on 2026-10-02 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

Most production incidents start with a change. A delivery path for a regulated customer has to prove four things on
every release: who built it, that it passed the checks, that exactly that artifact was deployed, and that a bad release
undoes itself. It also has to do that without long-lived cloud credentials sitting in a CI system, which is one of the
most common findings in cloud security reviews.

**What you will learn**
- OIDC federation from GitHub Actions to Azure: no client secret, and the trust pinned to one repository and branch.
- Least privilege for a pipeline: four role assignments, the narrowest one scoped to a single namespace.
- Build, scan, sign (Key Vault key) and deploy the same digest, and roll back automatically when readiness fails.
- GitOps with the Flux extension: drift correction, promotion by commit, and why Git should own rollback.

## 1. The pipeline's identity: federated, not secret

```bash
source aks/.lab.env
az identity create -g $RG -n id-gha-deploy -l $LOC
az identity federated-credential create -g $RG --identity-name id-gha-deploy -n github-main \
  --issuer https://token.actions.githubusercontent.com \
  --subject "repo:<owner>/<repo>:ref:refs/heads/main" \
  --audiences api://AzureADTokenExchange
```

GitHub issues the job a short-lived OIDC token; Entra ID exchanges it for an Azure token only if the issuer, subject
and audience match this record exactly. Nothing to rotate, nothing to leak.

The first run failed here, and it is worth seeing why:

```output
Federated token details:
 issuer - https://token.actions.githubusercontent.com
 subject claim - repo:sathpal@528147/regulated-k8s-reference@1401826803:ref:refs/heads/main
 audience - api://AzureADTokenExchange
##[error]AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:sathpal@528147/regulated-k8s-reference@1401826803:ref:refs/heads/main'.
```

**What you are seeing:** GitHub presented the subject with **immutable IDs** for the owner and the repository
(`sathpal@528147`, `regulated-k8s-reference@1401826803`), not just the names. That means a deleted and recreated
repository, or a renamed owner, cannot inherit the trust. The federated credential must use the exact subject the
token carries, so read it from a failed run, as here, rather than guessing:

```bash
az identity federated-credential update -g $RG --identity-name id-gha-deploy -n github-main \
  --issuer https://token.actions.githubusercontent.com \
  --subject "repo:sathpal@528147/regulated-k8s-reference@1401826803:ref:refs/heads/main" \
  --audiences api://AzureADTokenExchange
```

## 2. Least privilege for the pipeline

```bash
PID=$(az identity show -g $RG -n id-gha-deploy --query principalId -o tsv)
az role assignment create --assignee-object-id $PID --assignee-principal-type ServicePrincipal --role "Contributor" --scope $(az acr show -n $ACR --query id -o tsv)
az role assignment create --assignee-object-id $PID --assignee-principal-type ServicePrincipal --role "Key Vault Crypto User" --scope "$(az keyvault show -n $KV --query id -o tsv)/keys/cosign-signing"
az role assignment create --assignee-object-id $PID --assignee-principal-type ServicePrincipal --role "Azure Kubernetes Service Cluster User Role" --scope $(az aks show -g $RG -n $AKS --query id -o tsv)
az role assignment create --assignee-object-id $PID --assignee-principal-type ServicePrincipal --role "Azure Kubernetes Service RBAC Writer" --scope "$(az aks show -g $RG -n $AKS --query id -o tsv)/namespaces/cicd-payments"
```

```output
  Contributor                                   Microsoft.ContainerRegistry/registries/acrregk8s1e1193
  Key Vault Crypto User                         Microsoft.KeyVault/vaults/kv-regk8s-1e1193/keys/cosign-signing
  Azure Kubernetes Service Cluster User Role    Microsoft.ContainerService/managedClusters/aks-handson
  Azure Kubernetes Service RBAC Writer          Microsoft.ContainerService/managedClusters/aks-handson/namespaces/cicd-payments
```

**What you are seeing:** each role is scoped to one resource. Contributor on the **registry only** (ACR Tasks builds
need it); Crypto User on **one key**, not the vault; Cluster User only lets it fetch a kubeconfig; and the only
in-cluster permission is Writer on **one namespace**. The namespace itself is created by the platform team
([aks/manifests/06/namespace.yaml](manifests/06/namespace.yaml)), so the pipeline cannot create namespaces, read
secrets elsewhere, or touch cluster-scoped objects. The IDs go to GitHub as repository **variables**, not secrets,
because they are not secret:

```bash
gh variable set AZURE_CLIENT_ID -b "$(az identity show -g $RG -n id-gha-deploy --query clientId -o tsv)"
gh variable set AZURE_TENANT_ID -b "$(az account show --query tenantId -o tsv)"
gh variable set AZURE_SUBSCRIPTION_ID -b "$(az account show --query id -o tsv)"
gh variable set AKS_RG -b $RG; gh variable set AKS_NAME -b $AKS; gh variable set ACR_NAME -b $ACR; gh variable set KV_NAME -b $KV
```

## 3. The pipeline

[.github/workflows/aks-deploy.yml](../.github/workflows/aks-deploy.yml), in order: `azure/login` with OIDC;
`az acr build` (unit tests run inside the build stage); scan gate with grype (`--only-fixed --fail-on high`);
`cosign sign --key azurekms://…/cosign-signing` by digest and `cosign verify` with the public key; `kubelogin`;
deploy the **digest** with kustomize; `kubectl rollout status`; on failure `rollout undo`; smoke test through the Service.

```bash
gh workflow run aks-deploy
```

The second failure, in the build:

```output
Step 9/14 : RUN --mount=type=cache,target=/root/.cache/go-build     go test ./... &&     CGO_ENABLED=0 go build ...
the --mount option requires BuildKit. Refer to https://docs.docker.com/go/buildkit/ to learn how to build images with BuildKit enabled
```

**What you are seeing:** `az acr build` (an ACR Tasks quick build) uses the legacy Docker builder, not BuildKit, so
BuildKit-only syntax such as cache and secret mounts fails. The fix chosen here was portability: drop the cache mount
(ACR Tasks keeps no cache between runs anyway), so one Dockerfile builds identically with BuildKit locally and in CI
and with ACR Tasks. If you need BuildKit features, build with `docker buildx` in the pipeline and push to ACR.

A third, small one: `azure/use-kubelogin` needs `GITHUB_TOKEN` in its environment to look up the latest release.
Then the run went green:

```output
run: success
  Run azure/login@v2: success
  Build in ACR (unit tests run inside the build stage): success
  Scan gate and signature: success
  Run azure/use-kubelogin@v1: success
  Deploy the digest to AKS and wait for it: success
  Smoke test through the Service: success

built acrregk8s1e1193.azurecr.io/payments-api@sha256:329c75f0ad69e9529968c716625625892f0e953b36314c2386882cc20656097e (tag 6bca1e2bfded-4)
No vulnerabilities found
signature verified: acrregk8s1e1193.azurecr.io/payments-api@sha256:329c75f0ad69e9529968c716625625892f0e953b36314c2386882cc20656097e
serviceaccount/payments-api created
service/payments-api created
deployment.apps/payments-api created
```

```bash
kubectl -n cicd-payments get deploy,pods -o wide
```

```output
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES
deployment.apps/payments-api   3/3     3            3           43s   app          acrregk8s1e1193.azurecr.io/payments-api@sha256:329c75f0ad69e9529968c716625625892f0e953b36314c2386882cc20656097e

NAME                                READY   STATUS    RESTARTS   AGE   IP             NODE
pod/payments-api-68b874f6c4-2q6ph   1/1     Running   0          44s   10.244.2.191   aks-user-25795745-vmss000001
pod/payments-api-68b874f6c4-f5pv5   1/1     Running   0          44s   10.244.1.90    aks-user-25795745-vmss000000
pod/payments-api-68b874f6c4-x9mqh   1/1     Running   0          44s   10.244.1.208   aks-user-25795745-vmss000000
```

**What you are seeing:** the running image is the exact digest the pipeline built, scanned and signed; no tag is
involved anywhere between build and runtime. Pod IPs come from the overlay range (`10.244.x.x`), not the VNet.

## 4. A bad release undoes itself

```bash
gh workflow run aks-deploy -f simulate_bad_release=true     # readiness of the new version never passes
```

```output
deployment.apps/payments-api configured
Waiting for deployment "payments-api" rollout to finish: 1 out of 3 new replicas have been updated...
error: deployment "payments-api" exceeded its progress deadline
##[error]rollout did not become ready: rolling back
Warning: resource deployments/payments-api was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations.
deployment.apps/payments-api rolled back
deployment "payments-api" successfully rolled out
running after rollback: acrregk8s1e1193.azurecr.io/payments-api@sha256:329c75f0ad69e9529968c716625625892f0e953b36314c2386882cc20656097e
##[error]Process completed with exit code 1.
```

**What you are seeing:** `maxUnavailable: 0` kept all three old pods serving while one new pod failed readiness;
after `progressDeadlineSeconds` (120) Kubernetes marked the rollout failed, the pipeline ran `rollout undo`, and the
run ended red so a human looks at it. Note kubectl's warning: `rollout undo` changes the cluster but not the
configuration that was applied, so the next `kubectl apply` could reintroduce the bad version. That is the strongest
argument for the next section: in GitOps, rollback is a revert in Git.

## 5. GitOps with the AKS Flux extension

```bash
az extension add -n k8s-configuration; az extension add -n k8s-extension
az k8s-configuration flux create -g $RG -c $AKS -t managedClusters -n payments-gitops \
  --namespace flux-system --scope cluster \
  -u https://github.com/sathpal/regulated-k8s-reference --branch main --interval 1m \
  --kustomization name=payments path=./aks/manifests/06/gitops prune=true sync_interval=1m
```

```bash
az k8s-configuration flux show -g $RG -c $AKS -t managedClusters -n payments-gitops \
  --query "{state:provisioningState, compliance:complianceState, statuses:statuses[].{kind:kind,name:name,compliance:complianceState}}"
kubectl get pods -n flux-system
```

```output
{
  "compliance": "Compliant",
  "state": "Succeeded",
  "statuses": [
    {
      "compliance": "Compliant",
      "kind": "GitRepository",
      "name": "payments-gitops"
    },
    {
      "compliance": "Compliant",
      "kind": "Kustomization",
      "name": "payments-gitops-payments"
    }
  ]
}
NAME                                       READY   STATUS    RESTARTS   AGE
fluxconfig-agent-7976f768c7-mlshb          2/2     Running   0          9m21s
fluxconfig-controller-6c94db9f9f-ktfkd     2/2     Running   0          9m22s
helm-controller-5cd58946f9-7dzrr           1/1     Running   0          9m22s
kustomize-controller-7fd85cc855-sqw5h      1/1     Running   0          9m21s
notification-controller-85488545f4-kgc2b   1/1     Running   0          9m22s
source-controller-6fc7879859-dfqj6         1/1     Running   0          9m22s
```

**What you are seeing:** the extension installed Flux's controllers and Azure-specific agents (`fluxconfig-*`) that
report compliance back to Azure, so the state is visible in the portal and to Azure Policy. The source controller pulls
the repository every minute; the kustomize controller applies
[aks/manifests/06/gitops](manifests/06/gitops/kustomization.yaml). No pipeline holds cluster credentials for this path.

**Drift correction.** Somebody "fixes" production by hand:

```bash
kubectl -n gitops-payments delete svc payments-api      # at 20:32:40
```

```output
service "payments-api" deleted from gitops-payments namespace
Service back at 20:33:40:
NAME           CREATED                MANAGED-BY
payments-api   2026-10-02T15:03:39Z   payments-gitops-payments
```

**What you are seeing:** within one reconciliation interval Flux recreated the Service from Git. Manual changes do not
survive; the label shows which Flux kustomization owns the object.

**Promotion by commit.** The pipeline already built, scanned and signed digest `329c75f0…`. Promote it by changing one
line in Git:

```bash
sed -i '' 's|sha256:3ae4d0ae8666dd67152979425620e30cd43a42018752180a1dc1b4f6fde98469|sha256:329c75f0ad69e9529968c716625625892f0e953b36314c2386882cc20656097e|' aks/manifests/06/gitops/kustomization.yaml
git commit -am "Promote payments-api to build 6bca1e2bfded-4" && git push
```

```output
pushed 86a0a4c at 20:34:02
Flux applied the new digest at 20:34:26, 27s after the push
deployment "payments-api" successfully rolled out
rolled out 51s after the push
```

**What you are seeing:** the commit is the change record (who, what, when, reviewed by whom), the deployment followed
in under a minute, and rolling back is `git revert` of that commit, which keeps Git and the cluster in agreement.

## On AKS specifically

- **Workload identity federation** works the same for GitHub Actions, Azure DevOps and other OIDC issuers; the subject
  format is set by the issuer, so copy it from a real token rather than from documentation examples.
- **ACR Tasks** (`az acr build`) builds in Azure, so build agents need no Docker daemon; quick builds use the legacy
  builder, so BuildKit-only Dockerfile syntax will not work there.
- **The Flux extension** (`microsoft.flux`) is installed and upgraded by Azure, reports compliance to Azure Resource
  Manager, and can be deployed at scale with Azure Policy. Argo CD is the common alternative and is installed with Helm.
- **Push vs pull:** the pipeline path needs cluster credentials in CI (here, a narrowly scoped federated identity); the
  GitOps path keeps them in the cluster. Many regulated customers use both: CI builds, signs and opens a promotion pull
  request; GitOps deploys.

## In the conversation

**Why it matters:** a delivery path is only as trustworthy as its weakest credential and its rollback story. Federated
identity removes the credential; digest-pinned deploys remove the ambiguity; readiness gates plus automatic rollback, or
a Git revert, make a bad release a non-event.

**A real example:** "When I wired GitHub Actions to AKS, the first run failed at login. The token's subject used immutable
repository and owner IDs, not just names, so my federated credential didn't match. I read the exact subject from the
failed run and fixed it. The next failure was ACR Tasks rejecting a BuildKit cache mount, because quick builds use the
legacy builder. Once green, I shipped a deliberately broken release: readiness kept the old pods serving, the rollout hit
its deadline, and the pipeline rolled back by itself. Then I moved the same app to Flux: a hand-deleted Service came back
in a minute, and a promotion commit was live in 51 seconds."

**Follow-up questions to expect**
- *Why variables, not secrets, for the Azure IDs?* Client, tenant and subscription IDs are identifiers, not credentials.
  The credential is the short-lived OIDC token, which only GitHub can mint for this repository and branch.
- *How would you add a production approval?* A GitHub environment with required reviewers, and a federated credential
  whose subject is that environment, so only approved jobs can get the production identity.
- *Where does signature verification happen?* In the pipeline (verify after sign) and again at admission with Kyverno
  using the same public key (lab 08), so an unsigned image cannot run even if someone bypasses the pipeline.
- *Pipeline or GitOps?* Both: CI builds, scans, signs and proposes; Git records the decision; Flux applies it.

## If something looks different

- **`AADSTS700213` at login:** the federated credential's subject does not match the token; copy it from the error.
- **`the --mount option requires BuildKit`:** you are building with ACR Tasks quick builds; remove BuildKit-only syntax
  or build with buildx.
- **Flux shows `NonCompliant`:** run `kubectl get gitrepositories,kustomizations -n flux-system` and read the message;
  a wrong `path` or a kustomize error is the usual cause.
- **The pipeline is denied in the cluster:** check the Writer role is scoped to the namespace you deploy to and that the
  namespace exists (the pipeline cannot create it).

## Clean up

```bash
az k8s-configuration flux delete -g $RG -c $AKS -t managedClusters -n payments-gitops --yes
kubectl delete ns cicd-payments gitops-payments
az identity delete -g $RG -n id-gha-deploy
```

## Checkpoint

1. What stops another repository from using this pipeline's Azure identity?
   _Hint: the federated credential's issuer, audience and exact subject, including immutable repository IDs._
2. After `kubectl rollout undo`, why might the next `kubectl apply` bring the bad version back?
   _Hint: undo changes the cluster, not the applied configuration; in GitOps, revert the commit instead._
3. Which single role would you remove to stop the pipeline deploying anywhere except its namespace?
   _Hint: it already only has Writer on one namespace; Cluster User grants no in-cluster permissions._

## Further reading

- [Use GitHub Actions to connect to Azure with OpenID Connect](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)
- [GitOps with Flux v2 on AKS](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-flux2)
- [ACR Tasks overview](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
- [Use Kubernetes RBAC with Azure RBAC on AKS](https://learn.microsoft.com/azure/aks/manage-azure-rbac)
- [Deployments: rolling update and rollback](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
