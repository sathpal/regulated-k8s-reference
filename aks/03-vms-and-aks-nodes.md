# 03. Virtual machines under AKS

**Goal:** find the Azure virtual machines behind an AKS cluster, see what they share with every pod on them (one
kernel, one metadata service, one managed identity), and decide when a workload needs a separate VM, a dedicated
node pool or a Pod Sandboxing pod VM.

**You need:** the AKS environment from `aks/scripts/create.sh`, the Azure CLI signed in to the subscription that
holds it, and lab 02 for the node shell technique. About 30 minutes. No extra Azure cost: the lab only reads Azure
resources and runs three small pods; Pod Sandboxing is explained, not deployed.

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

On AKS the "managed" part is the control plane. The nodes are ordinary Azure VMs in your subscription: you pay for
them, they run one shared Linux kernel for every pod scheduled on them, and they can reach the Azure Instance
Metadata Service and the node's managed identities unless you stop them. Isolation, patching and cost decisions
are made at the VM level, so you need to see the VMs to make them.

**What you will learn**

- Where AKS puts the VMs (the node resource group `MC_...`), and how node pools map to VM scale sets
- How to read VM size, OS disk, node image version and upgrade channels with `az` and `kubectl`
- Why every pod on a node shares one kernel, and what that means for isolation
- What a pod can learn from the instance metadata service (IMDS), and how to block it with a NetworkPolicy
- When to use a separate VM, a dedicated node pool or Pod Sandboxing, and what you pay for

## 1. The node resource group

`az aks show` names a second resource group that AKS creates and manages. Everything with a VM, a disk or a NIC
lives there.

```bash
source aks/.lab.env
NRG=$(az aks show -g $RG -n $AKS --query nodeResourceGroup -o tsv); echo $NRG
az group show -n $NRG --query managedBy -o tsv
az resource list -g $NRG --query "[].{Name:name, Kind:type}" -o table
```

```output
MC_rg-aks-handson_aks-handson_centralindia
/subscriptions/<subscription-id>/resourcegroups/rg-aks-handson/providers/Microsoft.ContainerService/managedClusters/aks-handson
Name                                      Kind
----------------------------------------  ------------------------------------------------
9bd2d093-2f4b-41a0-b06b-48cc576b52ba      Microsoft.Network/publicIPAddresses
kubernetes                                Microsoft.Network/loadBalancers
azurekeyvaultsecretsprovider-aks-handson  Microsoft.ManagedIdentity/userAssignedIdentities
aks-handson-agentpool                     Microsoft.ManagedIdentity/userAssignedIdentities
aks-agentpool-24085649-nsg                Microsoft.Network/networkSecurityGroups
aks-vnet-24085649                         Microsoft.Network/virtualNetworks
aks-system-11091932-vmss                  Microsoft.Compute/virtualMachineScaleSets
aks-user-25795745-vmss                    Microsoft.Compute/virtualMachineScaleSets
```

**What you are seeing:** `managedBy` points at the cluster: the AKS resource provider owns this group and
reconciles it, so manual edits here get overwritten or break upgrades. It holds one VM scale set per node pool,
the VNet and NSG AKS created (this cluster did not bring its own), the Standard Load Balancer named `kubernetes`
with its outbound public IP, and two user-assigned managed identities: the kubelet identity
(`aks-handson-agentpool`) and the Key Vault CSI add-on identity. The control plane is not here; it runs in a
Microsoft subscription.

## 2. Node pools are VM scale sets

```bash
az aks nodepool list -g $RG --cluster-name $AKS --query "[].{name:name, mode:mode, vmSize:vmSize, count:count, min:minCount, max:maxCount, zones:join(',', availabilityZones || ['-']), osSku:osSku, osDiskType:osDiskType, osDiskSizeGB:osDiskSizeGb, nodeImage:nodeImageVersion}" -o table
az vmss list -g $NRG --query "[].{name:name, sku:sku.name, capacity:sku.capacity, zones:join(',', zones || ['-']), orchestration:orchestrationMode, image:virtualMachineProfile.storageProfile.imageReference.id, osDisk:virtualMachineProfile.storageProfile.osDisk.managedDisk.storageAccountType, caching:virtualMachineProfile.storageProfile.osDisk.caching}" -o json
```

```output
Name    Mode    VmSize           Count    Zones    OsSku       OsDiskType    OsDiskSizeGB    NodeImage                         Min    Max
------  ------  ---------------  -------  -------  ----------  ------------  --------------  --------------------------------  -----  -----
system  System  Standard_D2s_v5  1        -        AzureLinux  Managed       128             AKSAzureLinux-V3gen2-202609.15.0
user    User    Standard_D2s_v5  3        1,2,3    AzureLinux  Managed       128             AKSAzureLinux-V3gen2-202609.15.0  2      3
[
  {
    "caching": "ReadOnly",
    "capacity": 1,
    "image": "/subscriptions/109a5e88-712a-48ae-9078-9ca8b3c81345/resourceGroups/AKS-AzureLinux/providers/Microsoft.Compute/galleries/AKSAzureLinux/images/V3gen2/versions/202609.15.0",
    "name": "aks-system-11091932-vmss",
    "orchestration": "Uniform",
    "osDisk": "Premium_LRS",
    "sku": "Standard_D2s_v5",
    "zones": "-"
  },
  {
    "caching": "ReadOnly",
    "capacity": 3,
    "image": "/subscriptions/109a5e88-712a-48ae-9078-9ca8b3c81345/resourceGroups/AKS-AzureLinux/providers/Microsoft.Compute/galleries/AKSAzureLinux/images/V3gen2/versions/202609.15.0",
    "name": "aks-user-25795745-vmss",
    "orchestration": "Uniform",
    "osDisk": "Premium_LRS",
    "sku": "Standard_D2s_v5",
    "zones": "1,2,3"
  }
]
```

Map the scale set instances to Kubernetes nodes:

```bash
az vmss list-instances -g $NRG -n aks-user-25795745-vmss --query "[].{instance:instanceId, computerName:osProfile.computerName, zone:join(',', zones || ['-']), state:provisioningState, osDisk:storageProfile.osDisk.name}" -o table
kubectl get nodes -L kubernetes.azure.com/agentpool,topology.kubernetes.io/zone,node.kubernetes.io/instance-type,kubernetes.azure.com/node-image-version
kubectl get node aks-user-25795745-vmss000000 -o jsonpath='{.spec.providerID}{"\n"}'
```

```output
Instance    ComputerName                  Zone    State      OsDisk
----------  ----------------------------  ------  ---------  -------------------------------------------------------------------------------
0           aks-user-25795745-vmss000000  1       Succeeded  aks-user-25795745-vmaks-user-25795745-vmsOS__1_c9b05a3aa6894621a46f6bae52b9da2b
1           aks-user-25795745-vmss000001  2       Succeeded  aks-user-25795745-vmaks-user-25795745-vmsOS__1_efa7a5b5d770409ca0e29900739ffe64
2           aks-user-25795745-vmss000002  3       Succeeded  aks-user-25795745-vmaks-user-25795745-vmsOS__1_2b4a6cea33e6439dbb6f3500a4df2136
NAME                             STATUS   ROLES    AGE   VERSION   AGENTPOOL   ZONE             INSTANCE-TYPE     NODE-IMAGE-VERSION
aks-system-11091932-vmss000000   Ready    <none>   43m   v1.35.8   system      0                Standard_D2s_v5   AKSAzureLinux-V3gen2-202609.15.0
aks-user-25795745-vmss000000     Ready    <none>   39m   v1.35.8   user        centralindia-1   Standard_D2s_v5   AKSAzureLinux-V3gen2-202609.15.0
aks-user-25795745-vmss000001     Ready    <none>   39m   v1.35.8   user        centralindia-2   Standard_D2s_v5   AKSAzureLinux-V3gen2-202609.15.0
aks-user-25795745-vmss000002     Ready    <none>   17m   v1.35.8   user        centralindia-3   Standard_D2s_v5   AKSAzureLinux-V3gen2-202609.15.0
azure:///subscriptions/<subscription-id>/resourceGroups/mc_rg-aks-handson_aks-handson_centralindia/providers/Microsoft.Compute/virtualMachineScaleSets/aks-user-25795745-vmss/virtualMachines/0
```

**What you are seeing:** each node pool is one Uniform VM scale set. The node name is the scale set's computer
name, and `spec.providerID` is the Azure resource ID of the instance, which is how the cloud provider code maps a
node to a VM. The `user` pool spreads instances over zones 1, 2 and 3; the `system` pool was created without zones
(zone `0`). The cluster autoscaler grew the user pool from 2 to its maximum of 3 while other workloads were
running; it changes the scale set's capacity, not Kubernetes objects. The image is not a Marketplace image but a
version in Microsoft's `AKSAzureLinux` compute gallery, the same build the node label calls
`AKSAzureLinux-V3gen2-202609.15.0`.

## 3. VM size, OS disk and what the kubelet keeps for itself

```bash
az vm list-skus -l $LOC --size Standard_D2s_v5 --resource-type virtualMachines --query "[0].capabilities[?contains('vCPUs MemoryGB MaxResourceVolumeMB EphemeralOSDiskSupported HyperVGenerations MaxDataDiskCount', name)].{name:name, value:value}" -o table
kubectl get node aks-user-25795745-vmss000001 -o json | jq '{capacity: (.status.capacity | {cpu, memory, pods}), allocatable: (.status.allocatable | {cpu, memory, pods})}'
```

```output
Name                      Value
------------------------  -------
MaxResourceVolumeMB       0
vCPUs                     2
HyperVGenerations         V1,V2
MemoryGB                  8
MaxDataDiskCount          4
EphemeralOSDiskSupported  False
{
  "capacity": {
    "cpu": "2",
    "memory": "8135132Ki",
    "pods": "250"
  },
  "allocatable": {
    "cpu": "1900m",
    "memory": "5935580Ki",
    "pods": "250"
  }
}
```

**What you are seeing:** a `Standard_D2s_v5` has 2 vCPUs, 8 GB and no local temporary disk
(`MaxResourceVolumeMB 0`), so it cannot host an ephemeral OS disk. AKS therefore gave each node a managed Premium
SSD OS disk of 128 GB, the default P10 tier for VM sizes with 1 to 7 vCPUs, with read-only host caching. Container
images, logs and `emptyDir` volumes all live on that disk (`kubeletDiskType: OS`). Of the 8135132Ki of memory, pods
can request 5935580Ki: the difference is exactly 2048Mi kube-reserved plus the 100Mi eviction threshold. CPU loses
100m. Size nodes for allocatable, not for the VM's label.

## 4. Node image version and how nodes get patched

The node OS is replaced, not patched in place, on this cluster. Three settings decide when.

```bash
az aks show -g $RG -n $AKS --query autoUpgradeProfile -o json
az aks nodepool get-upgrades -g $RG --cluster-name $AKS --nodepool-name user --query "{kubernetesVersion:kubernetesVersion, latestNodeImageVersion:latestNodeImageVersion}" -o json
az aks nodepool show -g $RG --cluster-name $AKS -n user --query upgradeSettings -o json
az aks get-upgrades -g $RG -n $AKS -o table
```

```output
{
  "nodeOsUpgradeChannel": "NodeImage",
  "upgradeChannel": "patch"
}
{
  "kubernetesVersion": "1.35.8",
  "latestNodeImageVersion": "AKSAzureLinux-V3gen2-202609.15.0"
}
{
  "drainTimeoutInMinutes": null,
  "maxSurge": "10%",
  "maxUnavailable": "0",
  "nodeSoakDurationInMinutes": null,
  "undrainableNodeBehavior": "Schedule"
}
Name     ResourceGroup    MasterVersion    Upgrades
-------  ---------------  ---------------  --------------------------------------
default  rg-aks-handson   1.35.8           1.36.0, 1.36.1, 1.36.2, 1.36.3, 1.36.4
```

**What you are seeing:** two independent channels. `upgradeChannel: patch` moves the cluster (control plane, then
node pools) to the newest patch of 1.35 when AKS releases one; it never jumps to 1.36. `nodeOsUpgradeChannel:
NodeImage` moves nodes to a newly patched Azure Linux VHD, which AKS ships weekly. The pool already runs the latest
image (`202609.15.0`), so there is nothing to do today. When a new image arrives, AKS adds surge nodes (10% of
the pool, rounded up to whole nodes, so one node here), cordons and drains an old node, reimages it with the new
image, moves on to the next, and removes the extra node at the end, so capacity never drops (`maxUnavailable: 0`).
Microsoft recommends 33% surge for production pools. Your PodDisruptionBudgets and readiness probes decide whether that drain is invisible to users. To trigger it by
hand you would run `az aks nodepool upgrade --node-image-only -g $RG --cluster-name $AKS -n user`; this lab does
not, because other workloads share the cluster.

## 5. One kernel per node, whatever the image says

`two-distros.yaml` starts a Wolfi pod and an Alpine pod on the same node. Then compare with the node itself.

```bash
kubectl create namespace lab-b-vm
kubectl apply -n lab-b-vm -f aks/manifests/03/two-distros.yaml
kubectl wait -n lab-b-vm --for=condition=Ready pod/wolfi pod/alpine
kubectl get pods -n lab-b-vm -l lab=kernel -o wide
for p in wolfi alpine; do echo "--- pod $p"; kubectl exec -n lab-b-vm $p -- sh -c 'uname -r; grep PRETTY_NAME /etc/os-release; cat /proc/sys/kernel/random/boot_id'; done
```

```output
namespace/lab-b-vm created
pod/wolfi created
pod/alpine created
pod/wolfi condition met
pod/alpine condition met
NAME     READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
alpine   1/1     Running   0          21s   10.244.1.171   aks-user-25795745-vmss000000   <none>           <none>
wolfi    1/1     Running   0          88s   10.244.1.192   aks-user-25795745-vmss000000   <none>           <none>
--- pod wolfi
6.6.150.1-1.azl3
PRETTY_NAME="Wolfi"
33b62eff-50cd-41e2-9f35-031a80fdedcd
--- pod alpine
6.6.150.1-1.azl3
PRETTY_NAME="Alpine Linux v3.22"
33b62eff-50cd-41e2-9f35-031a80fdedcd
```

Now the node, with the debug pod technique from lab 02:

```bash
NODE=$(kubectl get pod -n lab-b-vm wolfi -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -n lab-b-vm --profile=sysadmin --image=cgr.dev/chainguard/wolfi-base -- sleep 3600
DBG=$(kubectl get pods -n lab-b-vm -o name | grep node-debugger)
onnode() { kubectl exec -n lab-b-vm "$DBG" -- chroot /host sh -c "$1"; }
onnode 'uname -r; grep PRETTY_NAME /etc/os-release; cat /proc/sys/kernel/random/boot_id'
```

```output
Creating debugging pod node-debugger-aks-user-25795745-vmss000000-cbs5h with container debugger on node aks-user-25795745-vmss000000.
6.6.150.1-1.azl3
PRETTY_NAME="Microsoft Azure Linux 3.0"
33b62eff-50cd-41e2-9f35-031a80fdedcd
```

The kernel also shows through where namespaces do not reach:

```bash
kubectl exec -n lab-b-vm alpine -- sh -c 'grep MemTotal /proc/meminfo; nproc; wc -l < /proc/modules; dmesg 2>&1 | head -1'
onnode 'grep MemTotal /proc/meminfo; nproc; wc -l < /proc/modules'
```

```output
MemTotal:        8135132 kB
2
67
dmesg: klogctl: Operation not permitted
MemTotal:        8135132 kB
2
67
```

**What you are seeing:** three userlands (Wolfi, Alpine, Azure Linux) and one kernel: same version string and the
same `boot_id`, which is generated once per boot of a kernel. A container image carries libraries and binaries,
never a kernel. The pods see the node's memory, CPU count and 67 loaded kernel modules; reading the kernel log is
refused only because the container lacks `CAP_SYSLOG`. A kernel vulnerability reachable from one pod is reachable
from all of them, which is the line between a container and a VM.

| | Container on a shared node | Separate VM (or a node per tenant) |
|---|---|---|
| Kernel | Shared with every pod on the node | Its own kernel, behind the hypervisor |
| Isolation mechanism | Namespaces, cgroups, capabilities, seccomp, AppArmor | Hardware virtualization (Hyper-V on Azure) |
| A kernel exploit reaches | The node and every pod on it | That VM |
| Node identity and IMDS | Shared unless blocked (next steps) | Per VM |
| Start time and density | Seconds, many per node | Minutes, one OS per VM |

## 6. What a pod can read from the instance metadata service

Every Azure VM can call IMDS at `169.254.169.254`. On AKS, pods can too, unless something blocks them. The
`toolbox` pod runs as uid 65532 with no capabilities, which shows that no privilege is needed.

```bash
kubectl apply -n lab-b-vm -f aks/manifests/03/toolbox.yaml
kubectl wait -n lab-b-vm --for=condition=Ready pod/toolbox
kubectl exec -n lab-b-vm toolbox -- curl -s -m 5 -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" \
  | jq '{name, vmScaleSetName, vmSize, zone, resourceGroupName, subscriptionId, image: .storageProfile.imageReference.id, kubeletIdentity: (.tagsList[] | select(.name=="aks-managed-kubeletIdentityClientID") | .value), imdsRestriction: (.tagsList[] | select(.name=="aks-managed-enable-imds-restriction") | .value)}'
```

```output
pod/toolbox created
pod/toolbox condition met
{
  "name": "aks-user-25795745-vmss_0",
  "vmScaleSetName": "aks-user-25795745-vmss",
  "vmSize": "Standard_D2s_v5",
  "zone": "1",
  "resourceGroupName": "MC_rg-aks-handson_aks-handson_centralindia",
  "subscriptionId": "<subscription-id>",
  "image": "/subscriptions/109a5e88-712a-48ae-9078-9ca8b3c81345/resourceGroups/AKS-AzureLinux/providers/Microsoft.Compute/galleries/AKSAzureLinux/images/V3gen2/versions/202609.15.0",
  "kubeletIdentity": "55a5dec9-13a3-43f0-bfd0-58026851030b",
  "imdsRestriction": "false"
}
```

**What you are seeing:** an unprivileged pod learned the subscription ID, the node resource group, the scale set,
the zone, the exact node image and, from the AKS tags, the client ID of the kubelet's managed identity. The
`aks-managed-enable-imds-restriction` tag is `false`: this cluster does not block pod access to IMDS.

## 7. Why that matters: the node's identities

IMDS also serves OAuth 2.0 tokens for the managed identities assigned to the VM. Microsoft's IMDS restriction page
states the risk directly: without the restriction, pods can "acquire OAuth 2.0 tokens for authorization by a
managed identity". Check which identities the node VMs carry and what they can do.

```bash
az vmss show -g $NRG -n aks-user-25795745-vmss --query "keys(identity.userAssignedIdentities)" -o tsv | awk -F/ '{print $NF}'
for id in aks-handson-agentpool azurekeyvaultsecretsprovider-aks-handson; do
  echo "--- $id"
  az role assignment list --assignee $(az identity show -g $NRG -n $id --query principalId -o tsv) --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
done
```

```output
aks-handson-agentpool
azurekeyvaultsecretsprovider-aks-handson
--- aks-handson-agentpool
Role     Scope
-------  --------------------------------------------------------------------------------------------------------------------------------------------------
AcrPull  /subscriptions/<subscription-id>/resourceGroups/rg-aks-handson/providers/Microsoft.ContainerRegistry/registries/acrregk8s1e1193
--- azurekeyvaultsecretsprovider-aks-handson
```

**What you are seeing:** both identities are attached to every VM in the user pool, so every pod on those VMs sits
next to them. The kubelet identity can pull every image in the registry; the Key Vault add-on identity has no role
yet, but the day someone grants it `Key Vault Secrets User` on a vault for convenience, every pod in the cluster
can reach for those secrets. This is why application pods should use Microsoft Entra Workload ID (a federated token
per service account) and never the node's identity, and why the node identities should keep the narrowest roles.

## 8. Block IMDS for a namespace (and break DNS on the way)

A namespace owner can block IMDS without touching the cluster. The first attempt allows egress anywhere except
`169.254.169.254`:

```bash
cat aks/manifests/03/deny-imds-naive.yaml | grep -A6 egress:
kubectl apply -n lab-b-vm -f aks/manifests/03/deny-imds-naive.yaml
kubectl exec -n lab-b-vm toolbox -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
kubectl exec -n lab-b-vm toolbox -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://cgr.dev/v2/
```

```output
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
networkpolicy.networking.k8s.io/deny-imds created
000
curl: (28) Connection timed out after 5001 milliseconds
command terminated with exit code 28
curl: (28) Resolving timed out after 5001 milliseconds
000
command terminated with exit code 28
```

IMDS is blocked, but so is the internet: the second call failed at "Resolving". With Azure CNI powered by
Cilium, an `ipBlock` cannot select pod or node IPs, so `0.0.0.0/0` does not cover the CoreDNS pods. Allow DNS to
CoreDNS explicitly:

```bash
diff aks/manifests/03/deny-imds-naive.yaml aks/manifests/03/deny-imds.yaml | grep '^>'
kubectl apply -n lab-b-vm -f aks/manifests/03/deny-imds.yaml
kubectl exec -n lab-b-vm toolbox -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
kubectl exec -n lab-b-vm toolbox -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://cgr.dev/v2/
```

```output
> # Egress for every pod in the namespace: DNS through CoreDNS, and anywhere outside the cluster
> # except the Azure instance metadata service (IMDS).
>     - to:                       # CoreDNS: with Cilium, ipBlock does not match pods inside the cluster
>         - namespaceSelector:
>             matchLabels:
>               kubernetes.io/metadata.name: kube-system
>           podSelector:
>             matchLabels:
>               k8s-app: kube-dns
>       ports:
>         - { port: 53, protocol: UDP }
>         - { port: 53, protocol: TCP }
networkpolicy.networking.k8s.io/deny-imds configured
000
curl: (28) Connection timed out after 5001 milliseconds
command terminated with exit code 28
401
```

**What you are seeing:** IMDS still times out, and the registry answers (`401` is the registry asking for a token,
which proves the connection works). A namespace policy is a good second layer, but it covers only namespaces that
have it. The cluster-wide control is the AKS IMDS restriction feature (below), which also covers namespaces
nobody remembered.

## 9. Pricing what you just looked at

The Azure Retail Prices API returns list prices without signing in. Pay-as-you-go Linux price for one node, and
the price of its OS disk, in Central India:

```bash
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'centralindia'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Consumption'" \
  | jq -r '.Items[] | select(.productName=="Virtual Machines Dsv5 Series") | [.skuName, .retailPrice, .unitOfMeasure, .currencyCode] | @tsv'
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Storage'%20and%20armRegionName%20eq%20'centralindia'%20and%20skuName%20eq%20'P10%20LRS'" \
  | jq -r '.Items[] | select(.productName=="Premium SSD Managed Disks" and .meterName=="P10 LRS Disk") | [.meterName, .retailPrice, .unitOfMeasure] | @tsv'
curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Azure%20Kubernetes%20Service'%20and%20armRegionName%20eq%20'centralindia'%20and%20skuName%20eq%20'Standard'" \
  | jq -r '.Items[] | [.meterName, .retailPrice, .unitOfMeasure] | @tsv'
```

```output
Standard_D2s_v5 Spot	0.018665	1 Hour	USD
Standard_D2s_v5 Low Priority	0.0202	1 Hour	USD
Standard_D2s_v5	0.101	1 Hour	USD
P10 LRS Disk	19.71	1/Month
Standard Long Term Support	0.6	1 Hour
Standard Uptime SLA	0.1	1 Hour
```

**What you are seeing:** at list price a node costs USD 0.101 per hour, about USD 73.73 for a 730-hour month, plus
USD 19.71 a month for its P10 OS disk. This cluster ran 4 nodes during the lab: about USD 295 a month of VMs and
USD 79 of disks, before the load balancer, its public IP and outbound data, which are billed separately. The
control plane on the Free tier costs nothing. The Standard tier, which adds the financially backed API server SLA,
lists at USD 0.10 per cluster hour, about USD 73 a month. Stopping the cluster (`aks/scripts/stop.sh`) deallocates
the VMs and stops the VM charge; disks keep billing. Spot capacity is about a fifth of the price, for workloads
that tolerate eviction.

## 10. Choosing the isolation boundary

Nothing is created here; the decision is the lesson.

| Need | Choice on AKS | What it costs you |
|---|---|---|
| Different VM size, GPU, zone layout or OS for some workloads | A dedicated **user node pool** with a taint and matching tolerations and node selector | More VMs; shared kernel per pool still applies within the pool |
| Keep regulated workloads (PCI, PHI) off nodes that run anything else | A dedicated node pool per data class, plus NetworkPolicy and admission policy | Lower bin-packing density; a separate scale set to patch |
| Run untrusted or tenant code in the same cluster with its own kernel | **Pod Sandboxing** (`runtimeClassName: kata-vm-isolation`) on an Azure Linux pool created with `--workload-runtime KataVmIsolation` | Each pod is a lightweight VM sized from its limits; some features are unsupported (below) |
| Hostile tenants, separate admins, separate control plane | **Separate clusters** (or a plain VM for a single service) | A control plane, node pools and operations per tenant |

Microsoft's guidance for hostile multitenant workloads is that "for true security when running hostile
multitenant workloads, only trust a hypervisor", and that Pod Sandboxing "doesn't isolate the AKS control plane,
storage or data paths, or actions performed by users with cluster-admin access".

## On AKS specifically

- **Node resource group:** created and managed by the AKS resource provider (`managedBy` is the cluster). It holds
  the scale sets, disks, NICs, the VNet when AKS creates it, the load balancer and the node identities. The control
  plane is not in your subscription.
- **OS disk:** if the VM size supports an ephemeral OS disk and you do not ask for a managed one, AKS uses
  ephemeral; otherwise it uses a managed disk sized by vCPU count (1 to 7 vCPUs get P10, 128 GB). Microsoft
  recommends ephemeral OS disks whenever possible. D2s_v5 has no temp storage, so it gets a managed disk. The OS
  disk size cannot change after the pool is created.
- **Node OS upgrade channels:** `None`, `Unmanaged` (the OS's own nightly updates), `SecurityPatch` (AKS-tested
  security-only patches, sometimes live without reimage), and `NodeImage` (a new VHD weekly, with security and bug
  fixes, applied by reimaging with surge). `NodeImage` is the default for new clusters since API version
  2023-06-01. Use separate maintenance windows: `aksManagedAutoUpgradeSchedule` for Kubernetes versions and
  `aksManagedNodeOSUpgradeSchedule` for node images, each at least four hours.
- **Cluster upgrade channels:** `none`, `patch`, `stable` (latest patch of minor N-1), `rapid` (latest minor), and
  the legacy `node-image`. Auto-upgrade does the control plane first, then the pools one at a time.
- **IMDS restriction (preview):** `az aks create|update --enable-imds-restriction` blocks IMDS for pods that do not
  use host networking; existing nodes need a reimage (`az aks upgrade --node-image-only`) to start blocking. It
  needs the `aks-preview` extension, the `IMDSRestrictionPreview` feature flag and the OIDC issuer, and it cannot
  be enabled with some add-ons (Container Insights, Azure Policy, application routing, Flux and others). The node
  enforces it with an iptables rule written by `ensure_imds_restriction.sh` before the kubelet starts, the script
  seen in lab 02. Host-network pods keep access.
- **Pod Sandboxing:** Kata Containers on Azure Linux, with each pod in a lightweight VM using Microsoft Hyper-V and
  the Cloud Hypervisor VMM. The Microsoft Learn pages (updated September 2026) carry no preview label, unlike IMDS
  restriction. Requires Kubernetes 1.27 or later, Azure CLI 2.80.0 or later, the
  `Microsoft.Network/AllowBringYourOwnPublicIpAddress` feature registered, an Azure Linux node pool with
  `--workload-runtime KataVmIsolation`, and a Generation 2 VM size that supports nested virtualization. Not
  supported: Ubuntu and Windows, Arm64, FIPS or Trusted Launch on that pool, host networking, and Defender for
  Containers assessment of Kata pods. Each pod VM's memory comes from the pod's memory limit (512Mi if none) and
  fractional CPU limits round up to a whole vCPU.
- **Pricing tiers:** Free (no financially backed SLA, recommended for fewer than 10 nodes), Standard (uptime SLA
  of 99.95% with availability zones, 99.9% without), Premium (Standard plus Long Term Support). Agent nodes are
  billed as normal VMs, and VM reservations apply to them.

## In the conversation

**Why it matters in production.** On AKS, "managed Kubernetes" means a managed control plane; the nodes are your
VMs, your cost and your blast radius. Every pod on a node shares one kernel and, by default, can reach the
instance metadata service and the node's managed identities. A regulated workload needs that boundary chosen on
purpose: a dedicated pool, a sandbox, or a separate cluster. Most of the bill is VMs and disks, so node size and
count are the first cost lever.

**A short story.** "When I walked a team through their AKS nodes, an unprivileged pod running as uid 65532 read
the subscription ID, the node resource group and the kubelet identity's client ID from the metadata service in one
`curl`. That identity had AcrPull on the registry. We added a namespace NetworkPolicy to block 169.254.169.254, and
the first version broke DNS, because with Cilium an ipBlock of 0.0.0.0/0 does not cover pods inside the cluster.
The fixed policy allows CoreDNS explicitly. The cluster-wide fix is the IMDS restriction feature plus Workload ID
for every application identity."

**Follow-up questions to expect**

- *Can I SSH to an AKS node?* Only from inside the VNet and only if the pool has an SSH key; this cluster was
  created with `--no-ssh-key`. The supported path is `kubectl debug node/...`, which is controlled by Kubernetes
  RBAC and leaves an audit trail in the API server.
- *How do nodes get OS patches?* With `NodeImage`, AKS publishes a new VHD weekly and rolls it out with surge: an
  extra VM joins, an old node is cordoned, drained and reimaged, and the extra VM leaves at the end. PodDisruptionBudgets, readiness probes and
  `maxUnavailable: 0` keep that invisible to users, and a maintenance window decides when it happens.
- *Is a dedicated node pool enough for PCI scope?* It separates kernels between data classes, which is often what
  assessors ask for, but the control plane, the network and the cluster's identities are still shared. Combine it
  with taints, admission policy that pins workloads to the pool, NetworkPolicy and Workload ID, or use a separate
  cluster when the scope must be separate.
- *Why not run every pod in Pod Sandboxing?* Each sandboxed pod is a small VM with its own memory sized from its
  limit, so density drops, and some features (host networking, Defender assessment of those pods) are not
  supported. Use it for code you do not trust, not as a default.

## If something looks different

- `curl` to IMDS from a pod times out before you add any policy: someone enabled IMDS restriction or a
  cluster-wide `CiliumClusterwideNetworkPolicy`. Check the `aks-managed-enable-imds-restriction` tag from a
  host-network context or ask the platform team.
- `az vmss list` shows no scale sets: the pool uses Virtual Machines node pools instead of scale sets. Use
  `az aks machine list -g $RG --cluster-name $AKS --nodepool-name user`.
- `EphemeralOSDiskSupported` is `True` and `osDiskType` is `Ephemeral`: your VM size has local storage (for
  example a `D2ds_v5`), and AKS chose an ephemeral OS disk. There is no OS disk charge in that case.
- The pod count on your node differs: other workloads share the cluster. Filter by namespace, as the commands do.

## Clean up

```bash
kubectl delete namespace lab-b-vm
```

The lab created nothing in Azure.

## Checkpoint

1. Two pods on the same node print the same `boot_id`. What does that prove, and what would change with
   `runtimeClassName: kata-vm-isolation`?
   _Hint: `boot_id` is generated once per running kernel._
2. A pod in a namespace with no NetworkPolicy calls `169.254.169.254`. Name two things it can learn and one thing
   it can obtain.
   _Hint: steps 6 and 7._
3. Your user pool runs `Standard_D2s_v5` nodes. How much memory can pods request on each node, and where does
   the rest go?
   _Hint: compare capacity and allocatable in step 3._

## Further reading

- [Core concepts: control plane, nodes and node pools (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/core-aks-concepts)
- [Autoupgrade node OS images](https://learn.microsoft.com/azure/aks/auto-upgrade-node-os-image)
- [Storage concepts: managed and ephemeral OS disks](https://learn.microsoft.com/azure/aks/concepts-storage)
- [Block pod access to the IMDS endpoint (preview)](https://learn.microsoft.com/azure/aks/imds-restriction)
- [Azure Instance Metadata Service](https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service)
- [Pod Sandboxing with AKS](https://learn.microsoft.com/azure/aks/use-pod-sandboxing)
- [Free, Standard and Premium pricing tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)
- [Azure CNI powered by Cilium (limitations, ipBlock)](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
