# 00. The AKS environment, and why every flag is there

**Goal:** build the cluster, registry and vault every other lab uses, and be able to justify each setting in production terms.

**You need:** an Azure subscription where you can create resource groups and role assignments, the Azure CLI
(2.90 used here), `kubectl`, `kubelogin` and `helm`. About 15 minutes. Cost while running: about USD 0.30 an hour
(three Standard_D2s_v5 nodes in Central India; the Free tier control plane costs nothing). Stop it between sessions
with `aks/scripts/stop.sh`.

_Outputs captured on 2026-10-02 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

Most AKS security and reliability decisions are made at `az aks create` time and are hard or impossible to change
later: the network plugin and dataplane, Entra ID integration, local accounts, workload identity, node OS. A partner
who builds a customer's first cluster with defaults ships those defaults into production. Every flag below is a
decision you should be able to explain.

**What you will learn**
- What each `az aks create` flag buys you, and what it costs to change later.
- Why a tainted system node pool and a separate user node pool are the production shape.
- How kubectl authenticates when local accounts are disabled.
- What Azure manages for you and what you still own.

## 1. Create everything

```bash
cd regulated-k8s-reference
aks/scripts/create.sh        # idempotent; names saved to aks/.lab.env
source aks/.lab.env
```

The script runs, in order: provider registration, `az group create`, `az acr create`, `az aks create`,
`az aks nodepool add`, `az keyvault create`, two role assignments, and `az aks get-credentials` plus
`kubelogin convert-kubeconfig`. The cluster flags:

| Flag | What it does | Why, in production |
|---|---|---|
| `--tier free` | No uptime SLA on the API server | Fine for labs; production uses `standard` for the financially backed SLA |
| `--nodepool-name system --nodepool-taints CriticalAddonsOnly=true:NoSchedule` | A system pool only for cluster add-ons | Your workloads cannot starve CoreDNS, the CNI or the metrics server |
| `--os-sku AzureLinux` | Microsoft's minimal container host OS | Smaller host attack surface, fewer packages to patch on the node itself |
| `--network-plugin azure --network-plugin-mode overlay` | Pods get IPs from a private overlay range, not the VNet | Does not exhaust customer VNet address space, which is a classic bank blocker |
| `--network-dataplane cilium` | eBPF dataplane; also enforces NetworkPolicy | Network policy without a separate engine; better observability |
| `--enable-aad --enable-azure-rbac` | Entra ID sign-in; Kubernetes authorization through Azure role assignments | One identity system, central access reviews, conditional access |
| `--disable-local-accounts` | No static admin kubeconfig exists | No credential that bypasses Entra ID; every action is attributable |
| `--enable-oidc-issuer --enable-workload-identity` | Pods can exchange their service account token for an Entra token | Pods reach Azure (Key Vault, storage) with no stored secrets |
| `--attach-acr` | Grants the cluster's kubelet identity AcrPull on the registry | Image pulls without image pull secrets |
| `--enable-addons azure-keyvault-secrets-provider` | Secrets Store CSI driver for Key Vault | Secrets mounted from the vault, not stored as Kubernetes Secrets |
| `--auto-upgrade-channel patch --node-os-upgrade-channel NodeImage` | Automatic patch upgrades and weekly node images | Patching happens on a schedule, not when someone remembers |
| `--no-ssh-key` | No SSH key is placed on the nodes | Node access goes through `kubectl debug`, which is authorized and logged |

The user pool:

```bash
az aks nodepool add -g $RG --cluster-name $AKS -n user --mode User \
  --node-vm-size Standard_D2s_v5 --os-sku AzureLinux --zones 1 2 3 \
  --node-count 2 --enable-cluster-autoscaler --min-count 2 --max-count 3
```

## 2. What you built

```bash
az aks show -g $RG -n $AKS --query "{version:currentKubernetesVersion, tier:sku.tier, nodeRG:nodeResourceGroup,
  aad:aadProfile.managed, azureRbac:aadProfile.enableAzureRbac, localAccountsDisabled:disableLocalAccounts,
  network:networkProfile.{plugin:networkPlugin,mode:networkPluginMode,dataplane:networkDataplane,policy:networkPolicy,podCidr:podCidr},
  workloadIdentity:securityProfile.workloadIdentity.enabled, upgrade:autoUpgradeProfile}" -o json
```

```output
{
  "aad": true,
  "azureRbac": true,
  "localAccountsDisabled": true,
  "network": {
    "dataplane": "cilium",
    "mode": "overlay",
    "plugin": "azure",
    "podCidr": "10.244.0.0/16",
    "policy": "cilium"
  },
  "nodeRG": "MC_rg-aks-handson_aks-handson_centralindia",
  "tier": "Free",
  "upgrade": {
    "nodeOsUpgradeChannel": "NodeImage",
    "upgradeChannel": "patch"
  },
  "version": "1.35.8",
  "workloadIdentity": true
}
```

**What you are seeing:** the control plane runs in Azure's subscription, not yours; what you own lives in the node
resource group `MC_rg-aks-handson_aks-handson_centralindia` (scale sets, disks, load balancer, managed identities).
`networkPolicy: cilium` came for free with the Cilium dataplane. `localAccountsDisabled: true` means
`az aks get-credentials --admin` will fail: there is no backdoor kubeconfig.

```bash
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool -o wide
```

```output
NAME                             STATUS   ROLES    AGE     VERSION   INTERNAL-IP   OS-IMAGE                    KERNEL-VERSION     CONTAINER-RUNTIME    ZONE             AGENTPOOL
aks-system-11091932-vmss000000   Ready    <none>   6m21s   v1.35.8   10.224.0.4    Microsoft Azure Linux 3.0   6.6.150.1-1.azl3   containerd://2.2.4   0                system
aks-user-25795745-vmss000000     Ready    <none>   110s    v1.35.8   10.224.0.6    Microsoft Azure Linux 3.0   6.6.150.1-1.azl3   containerd://2.2.4   centralindia-1   user
aks-user-25795745-vmss000001     Ready    <none>   104s    v1.35.8   10.224.0.5    Microsoft Azure Linux 3.0   6.6.150.1-1.azl3   containerd://2.2.4   centralindia-2   user
```

**What you are seeing:** node names include the scale set (`vmss000000`); the system node has no zone (`0`)
because that pool was created without zones, while the user nodes landed in zones 1 and 2. The kernel and
containerd version are shared by every pod on a node: that matters in lab 03.

## 3. How kubectl authenticates now

```bash
kubectl config view --minify -o jsonpath='{.users[0].user.exec.command} {.users[0].user.exec.args}{"\n"}'
kubectl auth can-i '*' '*' -A
```

```output
kubelogin ["get-token","--login","azurecli","--server-id","6dae42f8-4368-4678-94ff-3960e28e3630"]
yes
```

**What you are seeing:** kubectl calls `kubelogin`, which gets an Entra ID token from your `az login` session for the
AKS server application (the `--server-id`). `yes` comes from the role assignment "Azure Kubernetes Service RBAC Cluster
Admin" on the cluster, not from a certificate in the kubeconfig. Remove the role assignment and access is gone,
everywhere, immediately.

And the static admin kubeconfig that would bypass all of that:

```bash
az aks get-credentials -g $RG -n $AKS --admin -f /tmp/admin.kubeconfig
```

```output
ERROR: (BadRequest) Getting static credential is not allowed because this cluster is set to disable local accounts. For more details, see https://learn.microsoft.com/en-us/azure/aks/manage-local-accounts-managed-azure-ad
Code: BadRequest
```

**What you are seeing:** with local accounts disabled, Azure refuses to issue the certificate-based admin kubeconfig.
There is no credential that outlives an Entra ID account or skips conditional access.

## 4. The registry and the vault

```bash
az acr show -n $ACR --query "{loginServer:loginServer, sku:sku.name, adminUserEnabled:adminUserEnabled}" -o json
az keyvault show -n $KV --query "{rbac:properties.enableRbacAuthorization, softDelete:properties.enableSoftDelete}" -o json
```

```output
{
  "adminUserEnabled": false,
  "loginServer": "acrregk8s1e1193.azurecr.io",
  "sku": "Basic"
}
{
  "rbac": true,
  "softDelete": true
}
```

**What you are seeing:** the registry's admin user is off (no shared password); access is by Entra identity only.
The vault uses Azure RBAC rather than access policies, so the same role model covers the cluster, the registry and
the vault. A signing key was added for the later labs:

```bash
cosign generate-key-pair --kms "azurekms://$KV.vault.azure.net/cosign-signing"   # needs Key Vault Crypto Officer
```

```output
Public key written to cosign.pub
```

The private key never leaves Key Vault; it is an EC P-256 key with only `sign` and `verify` operations. The public
key is in [aks/keys/cosign-signing.pub](keys/cosign-signing.pub).

## On AKS specifically

- **You own the nodes, Azure owns the control plane.** You pay for VMs, disks, load balancers and IPs; the Free tier
  control plane is free, the Standard tier adds an uptime SLA and is billed per cluster hour.
- **Quota counts stopped VMs.** In this subscription, deallocated VMs still counted against the DSv5 vCPU quota, so the
  quota had to be raised before the node pools fit. Check `az vm list-usage` before a customer workshop, not during it.
- **Some choices are effectively permanent:** network plugin mode, the dataplane and the node resource group name are
  set at creation. Plan them with the customer's network team before the first cluster.

## In the conversation

**Why it matters:** the first cluster a partner builds becomes the template for every cluster after it. Entra ID with
local accounts disabled, workload identity, overlay networking and a tainted system pool are cheap to choose on day
one and expensive to retrofit.

**A real example:** "Before building this environment I checked quota and found that stopped VMs still counted against
the vCPU quota, so I raised it first. Then the first creation failed because my CLI version did not support a flag I
expected (`--ssh-access`); I switched to `--no-ssh-key`, which gives the same result. Both are the kind of thing you want
to find in a rehearsal, not in front of the customer, which is why the whole build is one idempotent script."

**Follow-up questions to expect**
- *Why overlay instead of plain Azure CNI?* Overlay gives pods addresses from a private range, so a large cluster does
  not consume the customer's VNet. Plain Azure CNI gives pods VNet IPs, which helps when something outside must reach
  pods directly.
- *What if someone needs emergency access with Entra ID down?* That is the trade-off of disabling local accounts; plan a
  break-glass Entra account with strong controls instead of a static kubeconfig.
- *Why Free tier?* It is a lab. Production uses Standard for the API server SLA.

## Clean up

```bash
aks/scripts/stop.sh       # between sessions: nodes deallocated, data kept
aks/scripts/destroy.sh    # at the end: deletes the resource group (cluster, registry, vault)
```

## Further reading

- [AKS baseline architecture](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks): the reference design these choices come from
- [Azure CNI Overlay](https://learn.microsoft.com/azure/aks/azure-cni-overlay): overlay networking and its limits
- [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium): the dataplane used here
- [Entra ID integration and Azure RBAC for Kubernetes](https://learn.microsoft.com/azure/aks/manage-azure-rbac): how authorization works without local accounts
- [Workload identity](https://learn.microsoft.com/azure/aks/workload-identity-overview): pods to Azure without secrets
- [System node pools](https://learn.microsoft.com/azure/aks/use-system-pools): why the system pool is separate
