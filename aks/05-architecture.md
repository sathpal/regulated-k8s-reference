# 05. Kubernetes architecture on AKS

**Goal:** map the Kubernetes architecture onto a real AKS cluster: what Azure runs for you in the managed control
plane, what runs in `kube-system` on your nodes, and what happens, component by component, when you run one
`kubectl apply`.

**You need:** the AKS environment from `aks/scripts/create.sh`, `kubectl` signed in through kubelogin, and lab 02
for the node shell technique. About 40 minutes. No extra Azure cost: two small payments-api pods and a client pod.

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

When something breaks in a cluster, the first question is which component owns the failure: the API server, the
scheduler, a controller, the kubelet, the container runtime, DNS or the dataplane. On AKS part of that chain is
invisible to you by design, and the rest runs as pods you can read but should not change. Knowing which is which
tells you where to look, what to fix yourself, and when to open a support case.

**What you will learn**

- What the managed control plane is, what you can see of it (version, health checks, leases) and what you cannot
- How `kubectl` reaches the API server (Entra ID token through kubelogin) and how the API server reaches your nodes (konnectivity)
- What each component in `kube-system` does on AKS
- The path of one `kubectl apply`: API calls, controllers, scheduler, kubelet, containerd, Service, EndpointSlice, CoreDNS and Cilium
- Control plane pricing tiers and upgrade channels, and what they change

## 1. The control plane you do not see

```bash
source aks/.lab.env
az aks show -g $RG -n $AKS --query "{fqdn:fqdn, kubernetesVersion:kubernetesVersion, currentKubernetesVersion:currentKubernetesVersion, sku:sku, supportPlan:supportPlan, upgradeChannel:autoUpgradeProfile.upgradeChannel, nodeOsUpgradeChannel:autoUpgradeProfile.nodeOsUpgradeChannel, privateCluster:apiServerAccessProfile.enablePrivateCluster, authorizedIpRanges:apiServerAccessProfile.authorizedIpRanges, aadManaged:aadProfile.managed, azureRbac:aadProfile.enableAzureRbac, localAccountsDisabled:disableLocalAccounts}" -o json
```

```output
{
  "aadManaged": true,
  "authorizedIpRanges": null,
  "azureRbac": true,
  "currentKubernetesVersion": "1.35.8",
  "fqdn": "aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io",
  "kubernetesVersion": "1.35",
  "localAccountsDisabled": true,
  "nodeOsUpgradeChannel": "NodeImage",
  "privateCluster": null,
  "sku": {
    "name": "Base",
    "tier": "Free"
  },
  "supportPlan": "KubernetesOfficial",
  "upgradeChannel": "patch"
}
```

The API server is a public endpoint behind that FQDN. Ask it directly:

```bash
kubectl get --raw /version | jq '{gitVersion, goVersion, platform, minCompatibilityMinor}'
kubectl get --raw '/readyz?verbose' | grep -E 'etcd|informer-sync|shutdown|passed'
kubectl get pods -A --no-headers | grep -cE 'etcd|kube-apiserver|kube-scheduler|kube-controller-manager'
```

```output
{
  "gitVersion": "v1.35.8",
  "goVersion": "go1.26.7",
  "platform": "linux/amd64",
  "minCompatibilityMinor": "34"
}
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]poststarthook/crd-informer-synced ok
[+]shutdown ok
readyz check passed
```
```output
0
```

**What you are seeing:** `kubernetesVersion: 1.35` is what was asked for (a minor version alias) and
`currentKubernetesVersion: 1.35.8` is what runs; the `patch` channel keeps moving it to the newest 1.35 patch. The
API server's own readiness check reports that its etcd is healthy, but no pod in any namespace is an etcd, API
server, scheduler or controller manager. They run in a Microsoft-managed environment, not on your nodes and not in
your subscription.

They still leave traces. Leader election writes Lease objects into `kube-system`:

```bash
kubectl get leases -n kube-system -o custom-columns='LEASE:.metadata.name,HOLDER:.spec.holderIdentity' | grep -vE 'cilium|^disk-csi|^file-csi'
```

```output
LEASE                                            HOLDER
apiserver-ostalbnxf6hknuxwc5354lutla             apiserver-ostalbnxf6hknuxwc5354lutla_4d9fb092-e447-4111-b31d-aa218c14bab1
apiserver-tcuph6fxah7edtkf4xggro4kci             apiserver-tcuph6fxah7edtkf4xggro4kci_536531a1-e75b-4ef3-92ab-4b5045e33700
cloud-controller-manager                         cloud-controller-manager-7b85695944-pdjf2_72c23864-510b-46d1-b69b-0c42c60cd391
external-attacher-leader-disk-csi-azure-com      csi-azuredisk-controller-5d4b5db558-smsn4
external-resizer-disk-csi-azure-com              csi-azuredisk-controller-5d4b5db558-smsn4
external-resizer-file-csi-azure-com              csi-azurefile-controller-5b7cf45865-hlfml
external-snapshotter-leader-disk-csi-azure-com   csi-azuredisk-controller-5d4b5db558-smsn4
external-snapshotter-leader-file-csi-azure-com   csi-azurefile-controller-5b7cf45865-hlfml
kube-controller-manager                          kube-controller-manager-v2-57667fddbb-clmqf_1f25e619-8c7f-4e4a-b477-9fa224a0e1e1
kube-scheduler                                   kube-scheduler-v2-f694dd7cd-7bb8v_ee2da771-471a-4e32-b04c-42c4b6b8f831
kubelet-serving-csr-approver                     kubelet-serving-csr-approver-5645d79bfd-qx4wl_edf9760d-47a1-4b75-a8ea-1f86ef208668
snapshot-controller-leader                       csi-snapshot-controller-7bd77d8fc7-5drjz
```

**What you are seeing:** two API server instances, and pod-style names for the scheduler, the controller manager,
the cloud controller manager, the Azure Disk and Azure Files CSI controllers, the snapshot controller and a CSR
approver for kubelet serving certificates. These are the hosted control plane's components, run by AKS. Their
pods exist somewhere you cannot list; only the leases they renew in your etcd are visible. Run the command again
later: on this cluster, 30 minutes afterwards the `kube-scheduler`, `kube-controller-manager` and
`cloud-controller-manager` leases had new holders (`kube-scheduler-v2-f694dd7cd-wmzs4`, for example). The hosted
components were rescheduled and a standby took over leadership, and nothing in the cluster noticed.

## 2. How kubectl reaches the API server

```bash
kubectl config view --minify -o json | jq '{server: .clusters[0].cluster.server, exec: (.users[0].user.exec | {command, args})}'
dig +short $(az aks show -g $RG -n $AKS --query fqdn -o tsv)
kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes
kubectl get svc -n default kubernetes
kubectl auth whoami
```

```output
{
  "server": "https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443",
  "exec": {
    "command": "kubelogin",
    "args": [
      "get-token",
      "--login",
      "azurecli",
      "--server-id",
      "6dae42f8-4368-4678-94ff-3960e28e3630"
    ]
  }
}
20.207.101.26
NAME         ADDRESSTYPE   PORTS   ENDPOINTS       AGE
kubernetes   IPv4          443     20.207.101.26   68m
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   10.0.0.1     <none>        443/TCP   68m
ATTRIBUTE    VALUE
Username     <object-id>
Groups       [<object-id> system:authenticated]
Extra: oid   [<object-id>]
```

(Entra object IDs replaced with `<object-id>`.)

**What you are seeing:** the kubeconfig holds no secret. For every request, `kubectl` runs `kubelogin get-token
--login azurecli`, which asks the Azure CLI's signed-in session for an Entra ID token whose audience is
`6dae42f8-4368-4678-94ff-3960e28e3630`, the AKS server application that is the same in every tenant. The API
server validates the token, maps you to your Entra object ID and groups, and asks Azure RBAC whether that identity
may do what you asked; there is no Kubernetes user or client certificate involved (`disableLocalAccounts: true`).
The FQDN resolves to `20.207.101.26`, and the in-cluster `kubernetes` Service (`10.0.0.1`) points pods at the same
address.

## 3. How the API server reaches your nodes

The control plane lives outside your VNet, yet `kubectl logs`, `kubectl exec` and the node proxy work. The
konnectivity agents build that path from the inside:

```bash
kubectl get deploy konnectivity-agent -n kube-system -o json | jq '{args: .spec.template.spec.containers[0].args, priorityClass: .spec.template.spec.priorityClassName}'
kubectl get networkpolicy konnectivity-agent -n kube-system -o jsonpath='{.spec}{"\n"}'
```

```output
{
  "args": [
    "--proxy-server-host=aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io",
    "--proxy-server-port=443",
    "--health-server-port=8082",
    "--keepalive-time=30s",
    "--agent-key=/certs/client.key",
    "--agent-cert=/certs/client.crt",
    "--ca-cert=/certs/ca.crt",
    "--sync-forever=true",
    "--agent-identifiers=default-route=true",
    "--alpn-proto=konnectivity",
    "-v=2"
  ],
  "priorityClass": "system-node-critical"
}
{"egress":[{}],"podSelector":{"matchLabels":{"app":"konnectivity-agent"}},"policyTypes":["Egress"]}
```

Use the tunnel: read a kubelet's live configuration through the API server's node proxy.

```bash
NODE=$(kubectl get nodes -l kubernetes.azure.com/agentpool=user -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw /api/v1/nodes/$NODE/proxy/configz | jq '.kubeletconfig | {cgroupDriver, seccompDefault, maxPods, kubeReserved, containerRuntimeEndpoint}'
```

```output
{
  "cgroupDriver": "systemd",
  "seccompDefault": false,
  "maxPods": 250,
  "kubeReserved": {
    "cpu": "100m",
    "memory": "2048Mi",
    "pid": "1000"
  },
  "containerRuntimeEndpoint": "unix:///run/containerd/containerd.sock"
}
```

**What you are seeing:** each agent dials out to the API server's FQDN on 443 with a client certificate and the
ALPN protocol `konnectivity`, and keeps the connection open. When the API server needs a node (this `configz`
call, logs, exec, port-forward, or calling the metrics-server APIService), it sends the request back down one of
those tunnels. Nodes need no inbound rule from the internet and the API server needs no route into the VNet; the
only egress the tunnel needs is TCP 443 to `*.hcp.centralindia.azmk8s.io`. The agents run at
`system-node-critical` priority, and AKS gives them an allow-all egress NetworkPolicy so a default-deny policy
cannot cut the tunnel.

## 4. kube-system on AKS

```bash
kubectl get ds -n kube-system -o custom-columns='DAEMONSET:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady,NODE-SELECTOR:.spec.template.spec.nodeSelector' | grep -vE 'win'
kubectl get deploy -n kube-system -o custom-columns='DEPLOYMENT:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[*].image'
kubectl get ds -n kube-system kube-proxy
```

```output
DAEMONSET                                  DESIRED   READY   NODE-SELECTOR
aks-secrets-store-csi-driver               4         4       <none>
aks-secrets-store-provider-azure           4         4       map[kubernetes.io/os:linux]
azure-cns                                  4         4       <none>
azure-ip-masq-agent                        4         4       <none>
cilium                                     4         4       <none>
cloud-node-manager                         4         4       <none>
csi-azuredisk-node                         4         4       <none>
csi-azurefile-node                         4         4       <none>
DEPLOYMENT                            READY   IMAGE
azure-wi-webhook-controller-manager   2       mcr.microsoft.com/oss/v2/azure/workload-identity/webhook:v1.5.1-20
cilium-operator                       1       mcr.microsoft.com/containernetworking/cilium/operator-generic:v1.18.12-260901
coredns                               2       mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20
coredns-autoscaler                    1       mcr.microsoft.com/oss/v2/kubernetes/autoscaler/cluster-proportional-autoscaler:v1.9.0-21
konnectivity-agent                    2       mcr.microsoft.com/oss/v2/kubernetes/apiserver-network-proxy/agent:v0.32.1-14
konnectivity-agent-autoscaler         1       mcr.microsoft.com/oss/v2/kubernetes/autoscaler/cluster-proportional-autoscaler:v1.9.0-23
metrics-server                        2       mcr.microsoft.com/oss/v2/kubernetes/autoscaler/addon-resizer:v1.8.23-30,mcr.microsoft.com/oss/v2/kubernetes/metrics-server:v0.8.0-21
Error from server (NotFound): daemonsets.apps "kube-proxy" not found
```

**What you are seeing:** DaemonSets run one pod per node (4 nodes here: 1 system, 3 user); Deployments run the
cluster-wide services. The `-windows` and `-win` DaemonSets exist with 0 pods because the cluster has no Windows
nodes.

| Component | Kind | What it does on this cluster |
|---|---|---|
| `coredns` + `coredns-autoscaler` | Deployment | Cluster DNS at `10.0.0.10`; the autoscaler sizes CoreDNS replicas to the cluster |
| `konnectivity-agent` + autoscaler | Deployment | The tunnel from step 3 |
| `metrics-server` | Deployment | Serves the `metrics.k8s.io` API that `kubectl top` and the HPA read; an addon-resizer container sizes it |
| `cilium` | DaemonSet | The eBPF dataplane: pod networking, Service load balancing (there is no `kube-proxy`), NetworkPolicy enforcement |
| `cilium-operator` | Deployment | Cluster-wide Cilium housekeeping, such as security identities |
| `azure-cns` | DaemonSet | Azure Container Networking Service: pod IP address management for Azure CNI overlay (Cilium runs with `ipam: delegated-plugin`) |
| `azure-ip-masq-agent` | DaemonSet | SNAT rules, so pod traffic leaving the overlay uses the node's IP |
| `cloud-node-manager` | DaemonSet | Node half of the Azure cloud provider: node addresses, zone labels, `providerID` (the controller half is the hosted `cloud-controller-manager`) |
| `csi-azuredisk-node`, `csi-azurefile-node` | DaemonSet | Mount Azure Disks and Azure Files into pods (the attach and provision controllers are hosted) |
| `aks-secrets-store-csi-driver`, `aks-secrets-store-provider-azure` | DaemonSet | The Key Vault add-on: mount Key Vault secrets as files |
| `azure-wi-webhook-controller-manager` | Deployment | Workload identity webhook: injects the projected token and Azure environment variables into pods that opt in |

There is no `ama-*` or `omsagent` pod: Container Insights is not enabled on this cluster. The node side, the
kubelet and containerd, are systemd services on each VM (lab 02), not pods.

## 5. One kubectl apply, traced through the API

`aks/manifests/05/payments-api.yaml` holds a Deployment with 2 replicas and a ClusterIP Service. `-v=6` prints
every HTTP call `kubectl` makes.

```bash
kubectl create namespace lab-b-arch
kubectl apply -n lab-b-arch -f aks/manifests/05/payments-api.yaml -v=6 2>&1 | grep -E 'round_trippers|created'
```

```output
I1002 19:57:45.479746   75649 round_trippers.go:632] "Response" verb="GET" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/openapi/v3?timeout=32s" status="200 OK" milliseconds=919
...
I1002 19:57:45.777118   75649 round_trippers.go:632] "Response" verb="GET" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/apis/apps/v1/namespaces/lab-b-arch/deployments/payments-api" status="404 Not Found" milliseconds=241
I1002 19:57:46.080994   75649 round_trippers.go:632] "Response" verb="GET" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/api/v1/namespaces/lab-b-arch" status="200 OK" milliseconds=303
I1002 19:57:46.351844   75649 round_trippers.go:632] "Response" verb="POST" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/apis/apps/v1/namespaces/lab-b-arch/deployments?fieldManager=kubectl-client-side-apply&fieldValidation=Strict" status="201 Created" milliseconds=270
deployment.apps/payments-api created
I1002 19:57:46.588970   75649 round_trippers.go:632] "Response" verb="GET" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/api/v1/namespaces/lab-b-arch/services/payments-api" status="404 Not Found" milliseconds=236
I1002 19:57:46.649765   75649 round_trippers.go:632] "Response" verb="GET" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/api/v1/namespaces/lab-b-arch" status="200 OK" milliseconds=60
I1002 19:57:46.921054   75649 round_trippers.go:632] "Response" verb="POST" url="https://aks-handso-rg-aks-handson-547d1e-i16l4cfl.hcp.centralindia.azmk8s.io:443/api/v1/namespaces/lab-b-arch/services?fieldManager=kubectl-client-side-apply&fieldValidation=Strict" status="201 Created" milliseconds=270
service/payments-api created
```

**What you are seeing:** `kubectl apply` is a client-side diff. It downloads the OpenAPI schema, asks for the
Deployment (`404 Not Found`, so it does not exist), and then creates it with a `POST`; the same for the Service.
Each call is a round trip from your laptop to the API server in Central India; most took 240 to 300 ms. When the
`POST` returns `201 Created`, the object is stored in etcd and nothing else has happened yet: no ReplicaSet, no
pod, no node choice. Everything after this is done by controllers that watch the API.

## 6. Controllers, the scheduler and the kubelet, through events

```bash
kubectl rollout status -n lab-b-arch deploy/payments-api
kubectl get events -n lab-b-arch --sort-by=.metadata.creationTimestamp -o custom-columns='OBJECT:.involvedObject.kind,NAME:.involvedObject.name,REASON:.reason,REPORTER:.reportingComponent,MESSAGE:.message'
```

```output
deployment "payments-api" successfully rolled out
OBJECT       NAME                            REASON              REPORTER                MESSAGE
Pod          payments-api-6cbf8b48b6-n2mxz   Scheduled           default-scheduler       Successfully assigned lab-b-arch/payments-api-6cbf8b48b6-n2mxz to aks-user-25795745-vmss000001
Deployment   payments-api                    ScalingReplicaSet   deployment-controller   Scaled up replica set payments-api-6cbf8b48b6 from 0 to 2
ReplicaSet   payments-api-6cbf8b48b6         SuccessfulCreate    replicaset-controller   Created pod: payments-api-6cbf8b48b6-n2mxz
ReplicaSet   payments-api-6cbf8b48b6         SuccessfulCreate    replicaset-controller   Created pod: payments-api-6cbf8b48b6-j4gc4
Pod          payments-api-6cbf8b48b6-j4gc4   Scheduled           default-scheduler       Successfully assigned lab-b-arch/payments-api-6cbf8b48b6-j4gc4 to aks-user-25795745-vmss000002
Pod          payments-api-6cbf8b48b6-n2mxz   Unhealthy           kubelet                 Readiness probe failed: Get "http://10.244.2.129:8080/readyz": dial tcp 10.244.2.129:8080: connect: connection refused
Pod          payments-api-6cbf8b48b6-n2mxz   Pulled              kubelet                 Container image "ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd" already present on machine and can be accessed by the pod
Pod          payments-api-6cbf8b48b6-n2mxz   Created             kubelet                 Container created
Pod          payments-api-6cbf8b48b6-n2mxz   Started             kubelet                 Container started
Pod          payments-api-6cbf8b48b6-j4gc4   Pulling             kubelet                 Pulling image "ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd"
Pod          payments-api-6cbf8b48b6-j4gc4   Created             kubelet                 Container created
Pod          payments-api-6cbf8b48b6-j4gc4   Pulled              kubelet                 Successfully pulled image "ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd" in 5.884s (5.884s including waiting). Image size: 3605360 bytes.
Pod          payments-api-6cbf8b48b6-j4gc4   Started             kubelet                 Container started
```

**What you are seeing:** the chain of owners. The deployment controller (in the hosted controller manager) created
a ReplicaSet and scaled it to 2; the ReplicaSet controller created two Pod objects with no node; the scheduler
(also hosted) bound each to a node, here two different nodes in two zones; then each node's kubelet took over.
Events are second-granular and come from different components, so the sort order is approximate. One node already
had the image from lab 02 (`already present on machine`), the other pulled 3,605,360 bytes from GHCR in 5.9
seconds. The single `Readiness probe failed ... connection refused` is the kubelet probing before the Go server
had bound port 8080; the next probe passed. That is why readiness, not "container started", decides when a pod
gets traffic.

## 7. The same pod, seen by the kubelet and containerd

Open a node shell (lab 02, step 2) on the node of one replica, in this lab's namespace. Pick the replica whose
events said `Pulling` if you want to see the image pull in the logs; here it is the first one.

```bash
POD=$(kubectl get pods -n lab-b-arch -l app.kubernetes.io/name=payments-api -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl get pod -n lab-b-arch $POD -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -n lab-b-arch --profile=sysadmin --image=cgr.dev/chainguard/wolfi-base -- sleep 1800
DBG=$(kubectl get pods -n lab-b-arch -o name | grep node-debugger)
onnode() { kubectl exec -n lab-b-arch "$DBG" -- chroot /host sh -c "$1"; }
onnode "crictl pods --namespace lab-b-arch --name $POD; crictl ps --label io.kubernetes.pod.namespace=lab-b-arch --name app"
```

```output
Creating debugging pod node-debugger-aks-user-25795745-vmss000002-l4hm6 with container debugger on node aks-user-25795745-vmss000002.
POD ID              CREATED             STATE               NAME                            NAMESPACE           ATTEMPT             RUNTIME
34b2416d16d78       3 minutes ago       Ready               payments-api-6cbf8b48b6-j4gc4   lab-b-arch          0                   (default)
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              POD                             NAMESPACE
21007734a4b8b       fb3c42d8f406e       2 minutes ago       Running             app                 0                   34b2416d16d78       payments-api-6cbf8b48b6-j4gc4   lab-b-arch
```

The kubelet and containerd logs show the CRI calls in order:

```bash
SANDBOX=$(onnode "crictl pods -q --namespace lab-b-arch --name $POD")
APP=$(onnode "crictl ps -q --pod $SANDBOX")
IP=$(kubectl get pod -n lab-b-arch $POD -o jsonpath='{.status.podIP}')
onnode "journalctl -u kubelet --since '-1 hour' --no-pager | grep $POD | grep -E 'SyncLoop ADD|Observed pod startup' | sed -E 's/^.*\] //' | cut -c1-200"
onnode "journalctl -u containerd --since '-1 hour' --no-pager | grep -E 'RunPodSandbox|PullImage|CreateContainer|StartContainer' | grep -E '$POD|ghcr.io/sathpal|$SANDBOX|$APP' | grep -v returns | sed -E 's/^.*msg=//' | cut -c1-160"
onnode "crictl inspectp $SANDBOX | jq '{state: .status.state, ip: .status.network.ip, pauseImage: .info.image}'; ls /etc/cni/net.d/; ip route | grep '$IP '"
```

```output
"SyncLoop ADD" source="api" pods=["lab-b-arch/payments-api-6cbf8b48b6-j4gc4"]
"Observed pod startup duration" pod="lab-b-arch/payments-api-6cbf8b48b6-j4gc4" podStartSLOduration=1.564990654 podStartE2EDuration="7.449842111s" totalImagesPullingTime="5.884851457s" totalInitContain
"RunPodSandbox for name:\"payments-api-6cbf8b48b6-j4gc4\" uid:\"16ab39e1-f877-47a8-b366-e2703d4d014a\" namespace:\"lab-b-arch\""
"PullImage \"ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd\""
"CreateContainer within sandbox \"34b2416d16d78bc4bf21488c1d27279681693cd5702dee9882999d89ee0ebdb2\" for container name:\"app\""
"StartContainer for \"21007734a4b8b2973fb9002869980a48f748e0ed0fc1437d1818718938e53d65\""
{
  "state": "SANDBOX_READY",
  "ip": "10.244.3.158",
  "pauseImage": "mcr.microsoft.com/oss/v2/kubernetes/pause:3.6"
}
05-cilium.conflist
10.244.3.158 dev lxcbea71ac9d655 proto kernel scope link
```

**What you are seeing:** the kubelet's watch delivered the pod (`SyncLoop ADD source="api"`). It then drove
containerd through the Container Runtime Interface: `RunPodSandbox` (the pause container plus a network namespace,
wired by the CNI plugin in `05-cilium.conflist`, which gave it `10.244.3.158` and a host-side `lxc...` interface),
`PullImage`, `CreateContainer`, `StartContainer`. The kubelet measured 7.4 s end to end, 5.9 s of it pulling.
Every step here runs on your VM; none of it involves the control plane until the kubelet reports status back.

## 8. Service, EndpointSlice, CoreDNS and Cilium

```bash
kubectl get pods -n lab-b-arch -l app.kubernetes.io/name=payments-api -o wide
kubectl get svc -n lab-b-arch payments-api
kubectl get endpointslice -n lab-b-arch -l kubernetes.io/service-name=payments-api -o json \
  | jq '.items[0] | {managedBy: .metadata.labels["endpointslice.kubernetes.io/managed-by"], ports, endpoints: [.endpoints[] | {addresses, ready: .conditions.ready, nodeName, zone, targetRef: .targetRef.name}]}'
```

```output
NAME                            READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
payments-api-6cbf8b48b6-j4gc4   1/1     Running   0          22s   10.244.3.158   aks-user-25795745-vmss000002   <none>           <none>
payments-api-6cbf8b48b6-n2mxz   1/1     Running   0          22s   10.244.2.129   aks-user-25795745-vmss000001   <none>           <none>
NAME           TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
payments-api   ClusterIP   10.0.93.254   <none>        80/TCP    23s
{
  "managedBy": "endpointslice-controller.k8s.io",
  "ports": [
    {
      "name": "http",
      "port": 8080,
      "protocol": "TCP"
    }
  ],
  "endpoints": [
    {
      "addresses": [
        "10.244.2.129"
      ],
      "ready": true,
      "nodeName": "aks-user-25795745-vmss000001",
      "zone": "centralindia-2",
      "targetRef": "payments-api-6cbf8b48b6-n2mxz"
    },
    {
      "addresses": [
        "10.244.3.158"
      ],
      "ready": true,
      "nodeName": "aks-user-25795745-vmss000002",
      "zone": "centralindia-3",
      "targetRef": "payments-api-6cbf8b48b6-j4gc4"
    }
  ]
}
```

Now call it by name from another pod. The client is the `toolbox` pod from lab 03 (curl with a shell).

```bash
kubectl apply -n lab-b-arch -f aks/manifests/03/toolbox.yaml
kubectl wait -n lab-b-arch --for=condition=Ready pod/toolbox
kubectl exec -n lab-b-arch toolbox -- cat /etc/resolv.conf
kubectl exec -n lab-b-arch toolbox -- curl -sv http://payments-api/version 2>&1 | head -3
kubectl get svc -n kube-system kube-dns
```

```output
pod/toolbox created
pod/toolbox condition met
search lab-b-arch.svc.cluster.local svc.cluster.local cluster.local 2xmdylujbvhudped0v5qep5f5d.rx.internal.cloudapp.net
nameserver 10.0.0.10
options ndots:5
{"service":"payments-api","version":"e3be3497f1f5062c36ec422a0678310b8fb7bad2"}
*   Trying 10.0.93.254:80...
* Established connection to payments-api (10.0.93.254 port 80) from 10.244.3.62 port 46868 
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
kube-dns   ClusterIP   10.0.0.10    <none>        53/UDP,53/TCP   32m
```

Finally, ask Cilium on the client's node how it handles that ClusterIP:

```bash
CILIUM=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$(kubectl get pod -n lab-b-arch toolbox -o jsonpath='{.spec.nodeName}') -o name)
kubectl exec -n kube-system $CILIUM -c cilium-agent -- cilium-dbg version
kubectl exec -n kube-system $CILIUM -c cilium-agent -- cilium-dbg service list | grep -E '^ID|10.0.93.254|10.0.0.10:53/UDP|10.0.0.1:443'
kubectl get ciliumendpoints -n lab-b-arch
kubectl get cm -n kube-system cilium-config -o json | jq -r '.data | to_entries[] | select(.key|test("^(kube-proxy-replacement|routing-mode|ipam|enable-l7-proxy)$")) | "\(.key)=\(.value)"'
```

```output
Client: 1.18.12 cb98de38f6 2026-08-28T15:38:11-05:00 go version go1.26.7 linux/amd64
Daemon: 1.18.12 cb98de38f6 2026-08-28T15:38:11-05:00 go version go1.26.7 linux/amd64
ID   Frontend               Service Type   Backend                                                
10   10.0.0.1:443/TCP       ClusterIP      1 => 20.207.101.26:443/TCP (active)                    
13   10.0.0.10:53/UDP       ClusterIP      1 => 10.244.0.59:53/UDP (active)                       
16   10.0.93.254:80/TCP     ClusterIP      1 => 10.244.2.129:8080/TCP (active)
NAME                            SECURITY IDENTITY   ENDPOINT STATE   IPV4           IPV6
payments-api-6cbf8b48b6-j4gc4   13183               ready            10.244.3.158   
payments-api-6cbf8b48b6-n2mxz   13183               ready            10.244.2.129   
toolbox                         50910               ready            10.244.3.62    
enable-l7-proxy=false
ipam=delegated-plugin
kube-proxy-replacement=true
routing-mode=native
```

**What you are seeing:** the whole service path, in order.

1. The EndpointSlice controller (hosted) watched the Service selector and the pods' readiness, and wrote both pod
   IPs, their nodes and zones into an EndpointSlice. Only `ready: true` endpoints receive traffic.
2. The pod's `/etc/resolv.conf` points at `10.0.0.10`, the `kube-dns` Service. With `ndots:5` the short name
   `payments-api` is tried as `payments-api.lab-b-arch.svc.cluster.local` first, and CoreDNS answered with the
   ClusterIP `10.0.93.254`.
3. No process listens on `10.0.93.254`. Cilium on the client's node has the Service in an eBPF map (ID 16) and
   rewrote the connection to a backend pod IP on port 8080 before it left the client. `1 =>` is the first
   backend; run the command without the `grep` to see the full list for each frontend. `kube-proxy-replacement=true`
   is why there is no `kube-proxy` DaemonSet and no iptables Service rules.
4. The same map sends `10.0.0.1:443` to `20.207.101.26:443`: in-cluster clients of the API server go to the same
   public endpoint as your laptop.
5. Both payments-api pods share Cilium security identity 13183 because they have the same labels; NetworkPolicy is
   enforced on identities, not IPs.

## 9. Break it: a Service that selects nothing

A one-letter typo in a selector is a common outage. `service-typo.yaml` selects `payment-api`:

```bash
kubectl apply -n lab-b-arch -f aks/manifests/05/service-typo.yaml
sleep 5
kubectl get endpointslice -n lab-b-arch
kubectl exec -n lab-b-arch toolbox -- curl -sS -m 5 http://payments-api-typo/version
```

```output
service/payments-api-typo created
NAME                      ADDRESSTYPE   PORTS     ENDPOINTS                   AGE
payments-api-n6f6b        IPv4          8080      10.244.2.129,10.244.3.158   5m12s
payments-api-typo-zl9vj   IPv4          <unset>   <unset>                     11s
curl: (7) Failed to connect to payments-api-typo:80 after 80 ms: Could not connect to server
command terminated with exit code 7
```

**What you are seeing:** the Service exists, has a ClusterIP and resolves in DNS, so nothing looks wrong at
first glance. Its EndpointSlice is empty, and Cilium rejects the connection at once instead of letting it time
out. "Service exists but connection refused" is almost always an empty EndpointSlice: a wrong selector, no ready
pods, or a wrong `targetPort`. Fix the selector:

```bash
kubectl patch svc payments-api-typo -n lab-b-arch -p '{"spec":{"selector":{"app.kubernetes.io/name":"payments-api"}}}'
kubectl get endpointslice -n lab-b-arch -l kubernetes.io/service-name=payments-api-typo
kubectl exec -n lab-b-arch toolbox -- curl -sS -m 5 http://payments-api-typo/version
```

```output
service/payments-api-typo patched
NAME                      ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
payments-api-typo-zl9vj   IPv4          8080    10.244.3.158,10.244.2.129   23s
{"service":"payments-api","version":"e3be3497f1f5062c36ec422a0678310b8fb7bad2"}
```

## 10. Metrics and DNS configuration

```bash
kubectl top pod -n lab-b-arch
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl get cm -n kube-system coredns -o jsonpath='{.data.Corefile}' | head -18
```

```output
NAME                                               CPU(cores)   MEMORY(bytes)   
node-debugger-aks-user-25795745-vmss000002-l4hm6   0m           25Mi            
payments-api-6cbf8b48b6-j4gc4                      1m           1Mi             
payments-api-6cbf8b48b6-n2mxz                      1m           2Mi             
toolbox                                            1m           0Mi             
NAME                     SERVICE                      AVAILABLE   AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   True        35m
.:53 {
    errors
    ready
    health {
      lameduck 5s
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
      fallthrough in-addr.arpa ip6.arpa
      ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
    import custom/*.override
```

**What you are seeing:** `kubectl top` goes to the API server, which forwards `metrics.k8s.io` to the
metrics-server Service in your cluster (an aggregated API, reached through the konnectivity tunnel), which in turn
scraped each kubelet. CoreDNS answers `cluster.local` from the Kubernetes API and forwards everything else to the
node's resolver (Azure DNS). AKS owns this Corefile and reconciles it; your changes go into the `coredns-custom`
ConfigMap, which the `import custom/*` lines load.

## On AKS specifically

- **Managed control plane:** Azure runs `kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager` and
  `cloud-controller-manager` in both AKS Automatic and AKS Standard. You see the API, its health endpoints and the
  leases; you cannot reach etcd or the components' flags. AKS-managed objects in your cluster carry the label
  `kubernetes.azure.com/managedby: aks`.
- **Pricing tiers:** Free has no financially backed SLA and is recommended for fewer than 10 nodes (it supports up
  to 1,000); Standard adds an uptime SLA of 99.95% for the API server with availability zones and 99.9% without,
  and up to 5,000 nodes; Premium is Standard plus Long Term Support, and must be enabled together with the
  `AKSLongTermSupport` plan. Switch with `az aks update --tier free|standard`. In regions with zones the control
  plane is spread across zones regardless of your node pools.
- **Cluster upgrade channels:** `none` (the default for AKS Standard if you set nothing), `patch` (this cluster),
  `stable` (latest patch of minor N-1), `rapid` (latest minor) and the legacy `node-image`. Auto-upgrade upgrades the
  control plane first, then node pools one by one, and only to GA versions. Schedule it with the
  `aksManagedAutoUpgradeSchedule` maintenance window, at least four hours long. AKS Automatic is fixed to `stable`.
- **Authentication:** with managed Entra ID integration, kubelogin requests tokens for the AKS server application
  `6dae42f8-4368-4678-94ff-3960e28e3630`; in `azurecli` mode it reuses the Azure CLI's token cache and writes none of
  its own. With local accounts disabled, there is no static admin kubeconfig to leak.
- **Control plane to node path:** with konnectivity the nodes need egress to `*.hcp.<region>.azmk8s.io` on TCP
  443, and firewalls must not strip the ALPN extension. The older UDP 1194 and TCP 9000 tunnel ports are not needed
  on clusters with the konnectivity agent.
- **Dataplane:** clusters created with `--network-dataplane cilium` do not run `kube-proxy`. With Cilium, a
  NetworkPolicy `ipBlock` cannot select pod or node IPs (lab 03 hits this), and only label exclusions may be changed
  in `cilium-config`.

## In the conversation

**Why it matters in production.** On AKS you own everything from the API request inward to your nodes, and Azure
owns the control plane. That split decides the runbook: a `201 Created` with no pods points at controllers or
admission, a `Pending` pod at the scheduler or capacity, `ContainerCreating` at the node (image pull, CNI, CSI),
and "connection refused" to a Service at the EndpointSlice. The free tier has no SLA on the API server, so
production clusters run on Standard. Knowing that the API server reaches nodes through konnectivity also explains
why a firewall that breaks TCP 443 to the control plane breaks `kubectl logs` and `exec` first.

**A short story.** "I traced one `kubectl apply` of our payments service on AKS. kubectl made two `POST` calls and
was done in about two and a half seconds; everything after that was controllers. The deployment and ReplicaSet controllers
and the scheduler run in the hosted control plane, which I could only see as leases, and the scheduler put the two
replicas in two zones. On the node that had never seen the image, containerd pulled 3.6 MB from GHCR in 5.9
seconds and the pod was running 7.4 seconds after it was created. Then I broke it with a one-letter selector typo:
the Service resolved, the EndpointSlice was empty, and Cilium refused the connection in 80 ms. Patching the
selector fixed it without touching the pods."

**Follow-up questions to expect**

- *Can I see etcd or the API server logs on AKS?* Not as pods. You can query the API server's health endpoints
  (`/readyz?verbose` reports its etcd check), see the control plane's leases, and send control plane logs
  (`kube-apiserver`, `kube-audit`, `kube-scheduler` and others) to Log Analytics with Azure diagnostic settings.
  etcd is never directly reachable.
- *What happens to running pods if the control plane is unavailable?* The kubelet and containerd keep running
  what they already have, and Cilium keeps forwarding with the Service maps it already holds. You cannot change
  anything, new pods are not scheduled, and controllers do not react to failures until the API server is back. That
  is the case for the Standard tier's SLA in production.
- *Why is there no kube-proxy?* This cluster uses Azure CNI powered by Cilium, which replaces kube-proxy with eBPF
  Service maps (`kube-proxy-replacement=true`). Step 8 shows the map entry that turns `10.0.93.254:80` into a pod
  IP on 8080.
- *How do you troubleshoot "connection refused" to a Service?* Check the EndpointSlice first. Empty means the
  selector matches no ready pods; then check pod labels, readiness probes and `targetPort`. Step 9 is that exact
  failure.

## If something looks different

- `kubectl get leases -n kube-system` shows other holders or more API server leases: the hosted control plane
  scales and moves; names and counts change over time and between tiers.
- `kubectl exec ... cilium-dbg` returns `executable file not found`: older Cilium images name the binary `cilium`.
  Try `cilium service list`.
- Your apply shows `PATCH` instead of `POST`: the objects already existed, so `kubectl apply` sent a patch.
  Delete the namespace and run step 5 again to see the creation path.
- `kubectl top` fails with `Metrics API not available`: metrics-server is still starting or its APIService is not
  `Available`; check `kubectl get apiservice v1beta1.metrics.k8s.io`.

## Clean up

```bash
kubectl delete namespace lab-b-arch
```

## Checkpoint

1. `kubectl apply` returned `deployment.apps/payments-api created`, but no pod appears. Which components would you
   check, in which order?
   _Hint: follow the events in step 6 from the deployment controller onwards._
2. Why can `kubectl exec` fail while `kubectl get pods` works?
   _Hint: one only needs the API server and etcd; the other needs the path from step 3._
3. A pod calls `http://payments-api` and the TCP connection goes to a pod IP that no DNS record mentions. Which
   component chose that IP, and from which object?
   _Hint: step 8, points 1 and 3._

## Further reading

- [Core Kubernetes concepts for AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/core-aks-concepts)
- [Use kubelogin to authenticate in AKS](https://learn.microsoft.com/azure/aks/kubelogin-authentication)
- [Outbound network and FQDN rules for AKS (konnectivity)](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress)
- [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [Free, Standard and Premium pricing tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)
- [Automatically upgrade an AKS cluster](https://learn.microsoft.com/azure/aks/auto-upgrade-cluster)
- [Kubernetes components (kubernetes.io)](https://kubernetes.io/docs/concepts/overview/components/)
- [EndpointSlices (kubernetes.io)](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
