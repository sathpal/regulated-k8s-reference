# 07. Running production workloads on AKS

**Goal:** run payments-api and patient-api from `k8s/base` on AKS the way a production platform does, then prove
each guardrail: node pools and taints, zone spread, requests and QoS, probes, a PodDisruptionBudget during a real
node drain under load, the cluster autoscaler, the HPA, a rolling update and a bad release under load, a planned
maintenance window and what a node image upgrade will do.

**You need:** the environment from lab 00. About 2 hours. Extra cost: the cluster autoscaler adds a third
Standard_D2s_v5 node to the `user` pool (twice in this lab), and each stays at least 10 minutes after it is no
longer needed; the maintenance configuration and everything else are free.

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

A Deployment that works in a demo is not a production workload. In production, nodes are drained for upgrades
every week, zones fail, traffic doubles, and releases go wrong; the manifests decide whether users notice. On AKS,
Azure runs the control plane, builds the node images and owns the VM scale sets, but the settings that keep a
service up during all of that (pools and taints, spread, requests, probes, budgets, rollout strategy, maintenance
windows) are yours.

**What you will learn**

- Why AKS separates system and user node pools, and how a taint and a toleration decide where pods land
- How topologySpreadConstraints place replicas across availability zones, and how to see replicas per zone
- What requests, limits and QoS classes do on a node, and how probes gate traffic
- How a PodDisruptionBudget paces a node drain while traffic keeps flowing, and how the cluster autoscaler reacts
- How the HPA scales on CPU, and how `maxUnavailable: 0` with readiness makes a rolling update and a bad release
  invisible to clients, with `kubectl rollout undo` as the way back
- How a planned maintenance window and node surge settings shape the upgrades Azure does for you, and which
  signals you get for free

## 1. Build the images in ACR

There is no local Docker in this setup. ACR Tasks builds in Azure from your source folder: `az acr build` uploads
the build context (only the files the `.dockerignore` allowlist lets through), runs the Dockerfile on an ACR agent
and pushes the result. `--build-arg VERSION` sets the version the app reports on `/version`. These are
development builds: lab 09 runs them, and step 2 shows why the regulated namespaces in this lab take the release
images instead.

```bash
source aks/.lab.env
az acr build -r $ACR -t labs/c/payments-api:1 --build-arg VERSION=1 apps/payments-api
az acr build -r $ACR -t labs/c/payments-api:2 --build-arg VERSION=2 apps/payments-api
az acr build -r $ACR -t labs/c/patient-api:1 --build-arg VERSION=1 apps/patient-api
```

```output
WARNING: Sending context (4.549 KiB) to registry: acrregk8s1e1193...
WARNING: Queued a build with ID: cuh
...
Step 9/14 : RUN go test ./... &&     CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/payments-api .
ok  	github.com/sathpal/regulated-k8s-reference/apps/payments-api	0.008s
...
1: digest: sha256:105a36fd8b877ebc1f5e7aed4a924deca93a172e254cfed39db870105bc0af20 size: 738
2026/10/02 14:17:14 Successfully pushed image: acrregk8s1e1193.azurecr.io/labs/c/payments-api:1
...
- image:
    registry: acrregk8s1e1193.azurecr.io
    repository: labs/c/payments-api
    tag: "1"
    digest: sha256:105a36fd8b877ebc1f5e7aed4a924deca93a172e254cfed39db870105bc0af20
  runtime-dependency:
    registry: cgr.dev
    repository: chainguard/static
    tag: latest
    digest: sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
  buildtime-dependency:
  - registry: cgr.dev
    repository: chainguard/go
    tag: latest
    digest: sha256:b9a6c30f787d3c609265c04b2f546334009edc5e5f28c40a0bdede809ac82618

Run ID: cuh was successful after 1m24s
...
Step 7/16 : RUN python -m unittest -v test_app
...
Ran 5 tests in 0.016s

OK
```

**What you are seeing:** the unit tests run inside the build, so a failing test fails the image. ACR records the
exact base image digests it pulled as runtime and build-time dependencies, which is the link that ACR's base image
update triggers use. ACR Tasks runs the classic Docker builder, not BuildKit, which is why this repo's Dockerfiles
avoid BuildKit-only syntax such as `RUN --mount`.

```bash
for i in labs/c/payments-api:1 labs/c/payments-api:2 labs/c/patient-api:1; do
  printf '%s ' $i; az acr repository show -n $ACR --image $i --query digest -o tsv
done
```

```output
labs/c/payments-api:1 sha256:105a36fd8b877ebc1f5e7aed4a924deca93a172e254cfed39db870105bc0af20
labs/c/payments-api:2 sha256:22b7a8282b06bca6359ee30342e3b5debb3b456a8fff621542cd3656fb67f06a
labs/c/patient-api:1 sha256:d3c8767259cacc9b23e90cd63e832dcd75edad0b7d6d2e846408de551729a6c3
```

## 2. Deploy both services from `k8s/base`

`aks/manifests/07/payments` and `aks/manifests/07/patients` are kustomizations over the unchanged `k8s/base`
manifests. Each adds a namespace labelled as regulated data (`data-classification: pci` or `phi`) with the Pod
Security `restricted` labels, a `lab: c` label on the pods, and an image pinned by digest. payments-api also gets
two NetworkPolicies so the in-namespace load generator used below may call it (`allow-loadgen.yaml`); the base
policies allow only the ingress controller's namespace.

```bash
kubectl apply -k aks/manifests/07/payments
kubectl apply -k aks/manifests/07/patients
kubectl rollout status deploy/payments-api -n lab-c-payments
kubectl rollout status deploy/patient-api -n lab-c-patients
kubectl get pods -n lab-c-payments -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image'
```

```output
namespace/lab-c-payments created
serviceaccount/payments-api created
service/payments-api created
deployment.apps/payments-api created
poddisruptionbudget.policy/payments-api created
horizontalpodautoscaler.autoscaling/payments-api created
networkpolicy.networking.k8s.io/default-deny created
networkpolicy.networking.k8s.io/loadgen-egress created
networkpolicy.networking.k8s.io/payments-api-allow created
networkpolicy.networking.k8s.io/payments-api-allow-loadgen created
namespace/lab-c-patients created
...
deployment "payments-api" successfully rolled out
deployment "patient-api" successfully rolled out
POD                            READY   NODE                           IMAGE
payments-api-b88764c67-jx65j   true    aks-user-25795745-vmss000001   ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd
payments-api-b88764c67-k24sl   true    aks-user-25795745-vmss000000   ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd
payments-api-b88764c67-z9cmp   true    aks-user-25795745-vmss000000   ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd
```

**What you are seeing:** each service arrives as a set: ServiceAccount without a token, Deployment, Service,
PodDisruptionBudget, HorizontalPodAutoscaler and NetworkPolicies. The rest of this lab exercises each of them.

Why GHCR and not the ACR builds from step 1? On the cluster used for these outputs, the repo's Kyverno policies
(`policy/kyverno/cluster`) were installed. In namespaces labelled `pci` or `phi` they admit images only from the release path
`ghcr.io/sathpal/regulated-k8s-reference` or from `cgr.dev/chainguard`, never `:latest`, and only with requests,
a memory limit, a readiness probe and a classification label. Ask the API server, without changing anything,
whether the ACR build could replace the running payments-api:

```bash
kubectl set image deploy/payments-api -n lab-c-payments app=$ACR.azurecr.io/labs/c/payments-api:1 --dry-run=server
```

```output
error: failed to patch image update to pod template: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Deployment/lab-c-payments/payments-api was blocked due to the following policies

restrict-image-registries:
  autogen-allowed-registries: 'validation error: Images must come from ghcr.io/sathpal/regulated-k8s-reference/* or cgr.dev/chainguard/*. rule autogen-allowed-registries failed at path /spec/template/spec/containers/0/image/'
```

That is why the kustomizations deploy the release images that the repo's GitHub pipeline built, scanned, signed and
published to GHCR, by digest: release `e3be349` of each service, and in step 9 the next release, `6bca1e2`.
GHCR serves them anonymously, so the nodes need no pull secret. The load generator and the other helper pods in
this lab are written to pass the same policies (pinned `cgr.dev` digests, a readiness probe, a classification
label). That the platform refuses a perfectly good image from the wrong place is the point: admission policy is how
"only released, approved artifacts run in production" becomes enforceable.

> **About the outputs in steps 3 to 8.** They were captured on a first run of this lab, before the Kyverno policies
> were installed on the shared cluster, when the same manifests ran the ACR builds from step 1 (you will see
> `acrregk8s1e1193.azurecr.io/labs/c/payments-api:1` in one event in step 8). Pod names and placement therefore
> differ from the listing above. Steps 9 to 11 were captured with the GHCR release images. Nothing in steps 3 to 8
> depends on which registry the image came from.

## 3. System and user node pools

AKS needs at least one **system** node pool for the cluster's own add-ons (CoreDNS, metrics-server, the
workload identity webhook). This cluster keeps application pods off it with the taint
`CriticalAddonsOnly=true:NoSchedule`; your workloads run on the **user** pool.

```bash
az aks nodepool list -g $RG --cluster-name $AKS --query '[].{name:name, mode:mode, vmSize:vmSize, count:count, autoscale:enableAutoScaling, min:minCount, max:maxCount, zones:join(`,`, availabilityZones || `[]`), taints:join(`,`, nodeTaints || `[]`)}' -o table
kubectl get nodes -L kubernetes.azure.com/mode,kubernetes.azure.com/agentpool,topology.kubernetes.io/zone
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key,EFFECT:.spec.taints[*].effect'
```

```output
Name    Mode    VmSize           Count    Autoscale    Zones    Taints                              Min    Max
------  ------  ---------------  -------  -----------  -------  ----------------------------------  -----  -----
system  System  Standard_D2s_v5  1        False                 CriticalAddonsOnly=true:NoSchedule
user    User    Standard_D2s_v5  2        True         1,2,3                                        2      3
NAME                             STATUS   ROLES    AGE   VERSION   MODE     AGENTPOOL   ZONE
aks-system-11091932-vmss000000   Ready    <none>   21m   v1.35.8   system   system      0
aks-user-25795745-vmss000000     Ready    <none>   16m   v1.35.8   user     user        centralindia-1
aks-user-25795745-vmss000001     Ready    <none>   16m   v1.35.8   user     user        centralindia-2
NODE                             TAINTS               EFFECT
aks-system-11091932-vmss000000   CriticalAddonsOnly   NoSchedule
aks-user-25795745-vmss000000     <none>               <none>
aks-user-25795745-vmss000001     <none>               <none>
```

Where do the add-ons run, and why may they run there?

```bash
kubectl get pods -n kube-system -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,CONTROLLER:.metadata.ownerReferences[0].kind' --sort-by=.spec.nodeName | grep -v DaemonSet
kubectl get deploy coredns -n kube-system -o jsonpath='{range .spec.template.spec.tolerations[*]}{.key}{" "}{.operator}{" "}{.effect}{"\n"}{end}'
```

```output
POD                                                    NODE                             CONTROLLER
coredns-5d474ff6db-pzj7n                               aks-system-11091932-vmss000000   ReplicaSet
metrics-server-85768b658b-2zq9v                        aks-system-11091932-vmss000000   ReplicaSet
coredns-autoscaler-6769f8f9b-hf4tt                     aks-system-11091932-vmss000000   ReplicaSet
azure-wi-webhook-controller-manager-57659bf5fd-kgml7   aks-system-11091932-vmss000000   ReplicaSet
konnectivity-agent-autoscaler-57c596c6fd-999bm         aks-system-11091932-vmss000000   ReplicaSet
metrics-server-85768b658b-xtdkq                        aks-system-11091932-vmss000000   ReplicaSet
azure-wi-webhook-controller-manager-57659bf5fd-77rbg   aks-system-11091932-vmss000000   ReplicaSet
coredns-5d474ff6db-8wxcf                               aks-system-11091932-vmss000000   ReplicaSet
cilium-operator-78c649f57-z749w                        aks-system-11091932-vmss000000   ReplicaSet
konnectivity-agent-58d95bdb54-hj8rn                    aks-user-25795745-vmss000000     ReplicaSet
konnectivity-agent-58d95bdb54-xm758                    aks-user-25795745-vmss000001     ReplicaSet
node-role.kubernetes.io/master  NoSchedule
CriticalAddonsOnly Exists
node.kubernetes.io/unreachable Exists NoExecute
node.kubernetes.io/not-ready Exists NoExecute
```

**What you are seeing:** the system node shows zone `0` because the system pool was created without zones; the
user pool spans zones 1 to 3. CoreDNS carries a toleration for `CriticalAddonsOnly` (the permission to run on the
tainted node) and a preferred node affinity for `kubernetes.azure.com/mode=system` (the attraction). Your pods have
neither, so they can only land on user nodes. DaemonSets (Cilium, CNS, CSI drivers) run on every node, and are
filtered out above.

Now try to put an application pod on the system pool on purpose. `pin-to-system.yaml` has a `nodeSelector` for
`kubernetes.azure.com/mode: system` but no toleration.

```bash
kubectl apply -f aks/manifests/07/pin-to-system.yaml
kubectl get pod pin-to-system -n lab-c-payments
kubectl events -n lab-c-payments --for pod/pin-to-system
kubectl delete pod pin-to-system -n lab-c-payments
```

```output
pod/pin-to-system created
NAME            READY   STATUS    RESTARTS   AGE
pin-to-system   0/1     Pending   0          9s
LAST SEEN   TYPE      REASON              OBJECT              MESSAGE
18s         Warning   FailedScheduling    Pod/pin-to-system   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
8s          Normal    NotTriggerScaleUp   Pod/pin-to-system   pod didn't trigger scale-up: 1 node(s) didn't match Pod's node affinity/selector
pod "pin-to-system" deleted from lab-c-payments namespace
```

**What you are seeing:** the scheduler checks every node: the system node is refused by the taint, the two user
nodes by the selector. The cluster autoscaler also declines: the only autoscaled pool (`user`) does not match the
selector, and the system pool is not autoscaled. A taint is a "keep out" sign; only a matching toleration lets a pod
past it. Keeping applications off the system pool means a runaway workload cannot starve CoreDNS or
metrics-server, and the system pool can stay small.

## 4. Zone spread

The base Deployment spreads replicas with two `topologySpreadConstraints`: by `topology.kubernetes.io/zone`, then
by `kubernetes.io/hostname`, both `maxSkew: 1` and `whenUnsatisfiable: ScheduleAnyway` (a preference, so a zone
outage never leaves pods Pending). Count replicas per zone:

```bash
kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=payments-api -o wide
for ns in lab-c-payments lab-c-patients; do
  kubectl get pods -n $ns -l lab=c -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' \
    | sort | uniq -c | sed "s/^/$ns /"
done
```

```output
NAME                            READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
payments-api-69f47d8f74-8fkzh   1/1     Running   0          23s   10.244.1.144   aks-user-25795745-vmss000000   <none>           <none>
payments-api-69f47d8f74-k5f7s   1/1     Running   0          23s   10.244.2.139   aks-user-25795745-vmss000001   <none>           <none>
payments-api-69f47d8f74-wthds   1/1     Running   0          23s   10.244.2.56    aks-user-25795745-vmss000001   <none>           <none>
lab-c-payments    1 centralindia-1
lab-c-payments    2 centralindia-2
lab-c-patients    1 centralindia-1
lab-c-patients    2 centralindia-2
```

**What you are seeing:** three replicas over two zones, so the best possible skew is 2 and 1. The user pool can
use zones 1, 2 and 3, but it has only two nodes, so only two zones hold capacity. Losing zone 2 would take two of
three replicas at once; spread is only as good as the nodes behind it. Step 8 adds a node in zone 3. The `MC_` resource group holds the scale set that makes this real:

```bash
NRG=$(az aks show -g $RG -n $AKS --query nodeResourceGroup -o tsv)
az vmss list -g $NRG --query '[].{name:name, sku:sku.name, capacity:sku.capacity, zones:join(`,`, zones || `[]`)}' -o table
```

```output
Name                      Sku              Capacity    Zones
------------------------  ---------------  ----------  -------
aks-system-11091932-vmss  Standard_D2s_v5  1
aks-user-25795745-vmss    Standard_D2s_v5  3           1,2,3
```

(Captured after step 8, so the user scale set already shows 3 instances.) One zonal scale set per pool spans the
three zones; Azure decides which zone each new instance goes to.

## 5. Requests, limits and QoS

The base sets a CPU request (50m) and a memory request (64Mi) for scheduling, a memory limit (128Mi) to protect the
node, and no CPU limit, to avoid throttling.

```bash
kubectl get pods -n lab-c-payments -o custom-columns='POD:.metadata.name,QOS:.status.qosClass,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.containers[0].resources.limits.memory'
kubectl get nodes -l kubernetes.azure.com/mode=user -o custom-columns='NODE:.metadata.name,CPU_CAP:.status.capacity.cpu,CPU_ALLOC:.status.allocatable.cpu,MEM_CAP:.status.capacity.memory,MEM_ALLOC:.status.allocatable.memory'
N=$(kubectl get pods -n lab-c-payments -o jsonpath='{.items[0].spec.nodeName}')
kubectl describe node $N | sed -n '/Non-terminated Pods/,/Events/p' | grep -E 'Namespace|lab-c|Allocated|Resource|cpu |memory '
kubectl top nodes
kubectl top pods -n lab-c-payments
```

```output
POD                             QOS         CPU_REQ   MEM_REQ   CPU_LIM   MEM_LIM
payments-api-69f47d8f74-8fkzh   Burstable   50m       64Mi      <none>    128Mi
payments-api-69f47d8f74-k5f7s   Burstable   50m       64Mi      <none>    128Mi
payments-api-69f47d8f74-wthds   Burstable   50m       64Mi      <none>    128Mi
NODE                           CPU_CAP   CPU_ALLOC   MEM_CAP     MEM_ALLOC
aks-user-25795745-vmss000000   2         1900m       8135132Ki   5935580Ki
aks-user-25795745-vmss000001   2         1900m       8135132Ki   5935580Ki
  Namespace                   Name                                                CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age
  lab-c-patients              patient-api-66dfb95c95-m6rch                        50m (2%)      0 (0%)      64Mi (1%)        128Mi (2%)     64s
  lab-c-payments              payments-api-69f47d8f74-8fkzh                       50m (2%)      0 (0%)      64Mi (1%)        128Mi (2%)     73s
Allocated resources:
  Resource           Requests     Limits
  cpu                519m (27%)   1940m (102%)
  memory             962Mi (16%)  9752Mi (168%)
NAME                             CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
aks-system-11091932-vmss000000   102m         5%       1476Mi          25%
aks-user-25795745-vmss000000     111m         5%       1153Mi          19%
aks-user-25795745-vmss000001     127m         6%       1183Mi          20%
NAME                            CPU(cores)   MEMORY(bytes)
payments-api-69f47d8f74-8fkzh   1m           1Mi
payments-api-69f47d8f74-k5f7s   1m           1Mi
payments-api-69f47d8f74-wthds   1m           1Mi
```

**What you are seeing:**

- **QoS class** follows from the numbers: requests below limits make payments-api `Burstable`. Requests equal to
  limits for every resource make a pod `Guaranteed` (the load generator in step 7 is one); no requests at all make
  it `BestEffort`. Under node memory pressure the kubelet evicts `BestEffort` first and `Guaranteed` last.
- **Allocatable is less than capacity.** Each 2 vCPU, 8 GiB VM offers 1900m CPU and about 5.66 GiB to pods; AKS
  reserves the rest for the kubelet, the OS and an eviction threshold.
- **Requests are what the scheduler counts** (27% of this node's CPU is requested), not what pods use (5% in
  `kubectl top`). Limits can add up past 100% because they are ceilings, not reservations. The autoscaler (step 8)
  also works from requests, which is why honest requests matter for cost.
- `kubectl top` works out of the box: AKS runs metrics-server on the system pool (step 3).

## 6. Probes

```bash
kubectl describe pod -n lab-c-payments -l app.kubernetes.io/name=payments-api | grep -E '^\s+(Liveness|Readiness|Startup):' | sort -u
```

```output
    Liveness:   http-get http://:http/healthz delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:  http-get http://:http/readyz delay=0s timeout=1s period=5s #success=1 #failure=2
    Startup:    http-get http://:http/healthz delay=0s timeout=1s period=2s #success=1 #failure=30
```

**What you are seeing:** three questions, three probes. **Startup** (up to 30 x 2 s) holds the other two off while
the app starts, so a slow start is not mistaken for a hang. **Readiness** decides whether the pod's IP is in the
Service's EndpointSlice; two failures in a row take it out of traffic without restarting it. **Liveness** restarts
the container after three failures in 30 s. payments-api turns `/readyz` to 503 when it receives SIGTERM, waits
`DRAIN_SECONDS` (5) for endpoints to update, then stops accepting connections. That is what makes the evictions
in the next step invisible to clients. Liveness checks `/healthz`, which stays up during the drain, so a
draining pod is never killed early.

## 7. A node drain with a PodDisruptionBudget, under load

The PDB says `minAvailable: 2` for three replicas, so at most one payments-api pod may be voluntarily disrupted
at a time. Drain the user node that holds two payments-api replicas, while a load generator calls the Service.

> **Shared cluster note.** This step cordons and drains one user node. The drain is limited to this lab's pods
> (`--pod-selector lab=c`) because other teams' unmanaged pods on the node would block a full drain (shown below).
> On your own cluster you can drop the selector.

First pick the node and cordon it, so nothing new (including the load generator) lands there:

```bash
NODE=$(kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=payments-api -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
echo $NODE
kubectl cordon $NODE
kubectl get nodes -l kubernetes.azure.com/mode=user
```

```output
aks-user-25795745-vmss000000
node/aks-user-25795745-vmss000000 cordoned
NAME                           STATUS                     ROLES    AGE   VERSION
aks-user-25795745-vmss000000   Ready,SchedulingDisabled   <none>   20m   v1.35.8
aks-user-25795745-vmss000001   Ready                      <none>   20m   v1.35.8
```

(The pod names differ from steps 4 and 5 because the pods were recreated in between, when the `lab: c` label was
added to the pod template.)

Start the load generator. `load.py` (in a ConfigMap) runs two threads that each call `GET /version` every 0.2 s
over a new connection, for 120 s, and counts every non-200 answer, refusal, reset or timeout as a failure. The Job
pod sets requests equal to limits, so it is QoS `Guaranteed`.

```bash
kubectl create configmap loadgen-script -n lab-c-payments --from-file=aks/manifests/07/load.py
kubectl apply -f aks/manifests/07/load-job.yaml
kubectl wait pod -l app.kubernetes.io/name=loadgen -n lab-c-payments --for=condition=Ready
kubectl get pod -n lab-c-payments -l app.kubernetes.io/name=loadgen -o wide
```

```output
configmap/loadgen-script created
job.batch/load created
pod/load-m5n4d condition met
NAME         READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
load-m5n4d   1/1     Running   0          3s    10.244.2.171   aks-user-25795745-vmss000001   <none>           <none>
```

What would a plain drain do on a shared node? Ask the API server without changing anything:

```bash
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --dry-run=server
```

```output
node/aks-user-25795745-vmss000000 already cordoned (server dry run)
error: unable to drain node "aks-user-25795745-vmss000000" due to error: cannot delete cannot delete Pods that declare no controller (use --force to override): lab-b-vm/alpine, lab-b-vm/node-debugger-aks-user-25795745-vmss000000-cbs5h, lab-b-vm/toolbox, lab-b-vm/wolfi, lab-d-secure/hardened, lab-d-secure/kv-reader, lab-d-secure/ns-reader, continuing command...
```

**What you are seeing:** bare pods (no Deployment, Job or other controller) block a drain, because evicting them
would lose them for good. `--force` would delete them. Node image upgrades drain nodes too, so a bare pod in
production is an upgrade problem waiting to happen.

Now the real drain of this lab's pods, with a watch on the PDB in a second terminal:

```bash
# terminal 2
kubectl get pdb -n lab-c-payments -w
```

```bash
time kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --pod-selector lab=c --timeout=5m
```

```output
node/aks-user-25795745-vmss000000 already cordoned
evicting pod lab-c-payments/payments-api-6876d4f7fd-df28m
evicting pod lab-c-patients/patient-api-5b54fcd8dc-4gmfj
evicting pod lab-c-payments/payments-api-6876d4f7fd-8m4zr
error when evicting pods/"payments-api-6876d4f7fd-df28m" -n "lab-c-payments" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod lab-c-payments/payments-api-6876d4f7fd-df28m
error when evicting pods/"payments-api-6876d4f7fd-df28m" -n "lab-c-payments" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/payments-api-6876d4f7fd-8m4zr evicted
pod/patient-api-5b54fcd8dc-4gmfj evicted
evicting pod lab-c-payments/payments-api-6876d4f7fd-df28m
error when evicting pods/"payments-api-6876d4f7fd-df28m" -n "lab-c-payments" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
...
evicting pod lab-c-payments/payments-api-6876d4f7fd-df28m
pod/payments-api-6876d4f7fd-df28m evicted
node/aks-user-25795745-vmss000000 drained
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --pod-selector  0.32s user 0.15s system 0% cpu 2:11.41 total
```

```output
NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
payments-api   2               N/A               1                     3m56s
payments-api   2               N/A               0                     3m59s
...
payments-api   2               N/A               1                     6m1s
payments-api   2               N/A               0                     6m2s
```

The drain took 2 minutes 11 seconds (it ended at 14:26:31). The load generator's log:

```bash
kubectl logs job/load -n lab-c-payments | tail -4
```

```output
14:25:51 progress total=996 ok=996 failed=0 v1=996
14:26:01 progress total=1086 ok=1086 failed=0 v1=1086
14:26:04 SUMMARY total=1086 ok=1086 failed=0 v1=1086
```

**What you are seeing:**

- kubectl drain uses the Eviction API, and the API server refuses an eviction that would break a PDB (HTTP 429,
  shown as "Cannot evict pod as it would violate the pod's disruption budget"). The first payments-api eviction
  used the one allowed disruption; the second was refused and retried every 5 s for about two minutes.
- Why two minutes, not seconds? The replacement pod had nowhere to go: the other user node lacked free CPU, so it
  stayed Pending until the cluster autoscaler added a third node (step 8). Only when the replacement was Ready did
  the PDB allow one disruption again (`ALLOWED DISRUPTIONS 1` at 6m1s), and the second eviction went through. A
  drain is paced by how fast replacements become Ready, which is why node upgrades take longer on a full cluster.
- 1,086 requests from 14:24:01 to 14:26:04, 0 failed: through the first eviction, the two minutes on two replicas
  and the replacement joining. The generator was set to 120 s, so it stopped 27 s before the last eviction; run
  it with a longer `DURATION` (for example `sed 's/"120"/"300"/' aks/manifests/07/load-job.yaml`) to cover the
  whole drain.

Uncordon the node. Pods do not move back on their own; the next rollout or scale event rebalances them.

```bash
kubectl uncordon $NODE
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool
```

```output
node/aks-user-25795745-vmss000000 uncordoned
NAME                             STATUS   ROLES    AGE     VERSION   ZONE             AGENTPOOL
aks-system-11091932-vmss000000   Ready    <none>   30m     v1.35.8   0                system
aks-user-25795745-vmss000000     Ready    <none>   26m     v1.35.8   centralindia-1   user
aks-user-25795745-vmss000001     Ready    <none>   26m     v1.35.8   centralindia-2   user
aks-user-25795745-vmss000002     Ready    <none>   4m24s   v1.35.8   centralindia-3   user
```

## 8. The cluster autoscaler adds a node

The drain in step 7 left one schedulable user node, and it was full. Pods that do not fit stay `Pending`, and the
cluster autoscaler (which AKS runs in the managed control plane, not as a pod you can see) reacts to exactly that.
Look at what happened, from the pod, the autoscaler and Azure.

```bash
kubectl events -n lab-c-payments --for pod/payments-api-6876d4f7fd-tm8wm | grep -E 'REASON|FailedScheduling|Scheduled|Pulled'
kubectl get events -A --field-selector reason=TriggeredScaleUp -o custom-columns=NS:.metadata.namespace,TIME:.lastTimestamp,OBJ:.involvedObject.name,MSG:.message
kubectl get nodes -o custom-columns='NODE:.metadata.name,CREATED:.metadata.creationTimestamp,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
kubectl get node aks-user-25795745-vmss000002 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.type}={.status} since {.lastTransitionTime}{"\n"}{end}'
```

```output
LAST SEEN               TYPE      REASON             OBJECT                              MESSAGE
4m57s                   Warning   FailedScheduling   Pod/payments-api-6876d4f7fd-tm8wm   0/3 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable. no new claims to deallocate, preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
4m14s (x2 over 4m16s)   Warning   FailedScheduling   Pod/payments-api-6876d4f7fd-tm8wm   0/4 nodes are available: 1 Insufficient cpu, 1 node(s) were unschedulable, 2 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/4 nodes are available: 1 No preemption victims found for incoming pod, 3 Preemption is not helpful for scheduling.
3m16s                   Normal    Scheduled          Pod/payments-api-6876d4f7fd-tm8wm   Successfully assigned lab-c-payments/payments-api-6876d4f7fd-tm8wm to aks-user-25795745-vmss000002
2m59s                   Normal    Pulled             Pod/payments-api-6876d4f7fd-tm8wm   Successfully pulled image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1" in 14.532s (14.532s including waiting). Image size: 3589071 bytes.
NS             TIME                   OBJ                            MSG
lab-a-images   2026-10-02T14:24:16Z   grype-patient-api-prod-4n9mp   pod triggered scale-up: [{aks-user-25795745-vmss 2->3 (max: 3)}]
NODE                             CREATED                ZONE
aks-system-11091932-vmss000000   2026-10-02T13:58:44Z   0
aks-user-25795745-vmss000000     2026-10-02T14:03:15Z   centralindia-1
aks-user-25795745-vmss000001     2026-10-02T14:03:21Z   centralindia-2
aks-user-25795745-vmss000002     2026-10-02T14:25:01Z   centralindia-3
Ready=True since 2026-10-02T14:25:28Z
```

**What you are seeing:**

- The scheduler's story, in order: one node cordoned (`unschedulable`), one tainted (system), one out of CPU. Then
  a fourth node appears, still carrying its startup taints (`2 node(s) had untolerated taint(s)`), and finally the
  pod is scheduled there and pulls its 3.6 MB image in 14.5 s.
- The autoscaler records a `TriggeredScaleUp` event on the pod that tipped the decision. On this shared cluster
  that was another team's pending pod, hit by the same shortage four seconds before ours; one scale-up served
  both. The message names the scale set and the step: `2->3 (max: 3)`.
- From that decision (14:24:16) to a `Ready` node (14:25:28) took 72 seconds: Azure created a VM in the scale
  set, it booted the AKS node image, joined the cluster and became Ready. The new node landed in
  `centralindia-3`, the zone that had no node yet.

Where did patient-api end up after the drain and the new node? Kubernetes 1.35 copies the node's zone and region
labels onto each pod when it is bound (the `PodTopologyLabels` admission plugin, beta and on by default), so the
pod itself says where it runs:

```bash
kubectl get pods -n lab-c-patients -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
```

```output
POD                            NODE                           ZONE
patient-api-5b54fcd8dc-4bxp9   aks-user-25795745-vmss000002   centralindia-3
patient-api-5b54fcd8dc-s8nsc   aks-user-25795745-vmss000001   centralindia-2
patient-api-5b54fcd8dc-stvdf   aks-user-25795745-vmss000001   centralindia-2
```

The evicted replica went to the new node in zone 3; the two that never moved are both in zone 2, and zone 1 has
none. Spread constraints act only when a pod is scheduled. The next rollout (or `kubectl rollout restart`) would
place three new pods one per zone; until then, a zone 2 outage takes two of three replicas.

The autoscaler publishes its own view in a ConfigMap:

```bash
kubectl get configmap cluster-autoscaler-status -n kube-system -o jsonpath='{.data.status}'
```

```output
autoscalerStatus: Running
clusterWide:
  health:
    ...
    nodeCounts:
      registered:
        ready: 4
        total: 4
    status: Healthy
  scaleDown:
    status: NoCandidates
  scaleUp:
    lastTransitionTime: "2026-10-02T14:29:02Z"
    status: NoActivity
nodeGroups:
- health:
    cloudProviderTarget: 3
    maxSize: 3
    minSize: 2
    nodeCounts:
      registered:
        ready: 3
        total: 3
    status: Healthy
  name: aks-user-25795745-vmss
  scaleDown:
    status: NoCandidates
  scaleUp:
    backoffInfo: {}
    status: NoActivity
time: 2026-10-02 14:29:22.999645779 +0000 UTC
```

**What you are seeing:** one node group per autoscaled pool, named after its scale set, with the min and max you
set (`--min-count 2 --max-count 3`). `cloudProviderTarget: 3` is the scale set capacity the autoscaler asked
Azure for (the `Capacity 3` in step 4). `scaleDown: NoCandidates` means no node is currently unneeded.

**When does the third node go away?** The autoscaler removes a node only after it has been unneeded for
`scale-down-unneeded-time` (10 minutes by default), where unneeded means its pods' requests are below
`scale-down-utilization-threshold` (0.5) and they fit elsewhere; it also waits `scale-down-delay-after-add`
(10 minutes) after any scale-up. So a node added at 14:25 can leave at the earliest around 14:35, and only once
the cluster is quiet enough. Requests (not real usage) drive this decision, and pods that cannot move keep a node
alive: a PDB with no allowed disruptions, or `kube-system` pods while `skip-nodes-with-system-pods` is `true`
(the default, and this cluster's setting). These timings are part of
the cluster's autoscaler profile (`az aks show --query autoScalerProfile`), shared by all pools.

In this run the third node stayed for 70 minutes, because other teams' workloads kept the cluster busy. The node's
events show how it left:

```bash
kubectl get events -n default --field-selector involvedObject.name=aks-user-25795745-vmss000002 \
  -o custom-columns=TIME:.lastTimestamp,REASON:.reason,SOURCE:.source.component,MSG:.message
```

```output
TIME                   REASON               SOURCE                            MSG
2026-10-02T15:34:49Z   ScaleDown            cluster-autoscaler                marked the node as toBeDeleted/unschedulable
2026-10-02T15:34:58Z   NodeNotSchedulable   kubelet                           Node aks-user-25795745-vmss000002 status is now: NodeNotSchedulable
2026-10-02T15:37:07Z   NodeNotReady         node-controller                   Node aks-user-25795745-vmss000002 status is now: NodeNotReady
2026-10-02T15:37:13Z   DeletingNode         cloud-node-lifecycle-controller   Deleting node aks-user-25795745-vmss000002 because it does not exist in the cloud provider
2026-10-02T15:37:18Z   RemovingNode         node-controller                   Node aks-user-25795745-vmss000002 event: Removing Node aks-user-25795745-vmss000002 from Controller
```

**What you are seeing:** the autoscaler taints the node so nothing new lands there, evicts its pods (they reschedule
on the other nodes, respecting PDBs), and asks Azure to delete the VM from the scale set; the cloud node manager
then removes the Node object once the VM is gone. About two and a half minutes from decision to removal.

**A deliberate scale-up.** With the pool back at two nodes, `capacity.yaml` creates three pods that each request a
whole CPU. (Captured after step 11, while its ten payments-api replicas still held their CPU requests.)

```bash
kubectl describe nodes -l kubernetes.azure.com/mode=user | grep -E '^Name:|^\s+cpu\s'
kubectl apply -f aks/manifests/07/capacity.yaml
kubectl get events -n lab-c-payments --field-selector involvedObject.kind=Pod \
  -o custom-columns=TIME:.lastTimestamp,REASON:.reason,OBJ:.involvedObject.name,MSG:.message | grep capacity
```

```output
Name:               aks-user-25795745-vmss000000
  cpu                1249m (65%)   5230m (275%)
Name:               aks-user-25795745-vmss000001
  cpu                1286m (67%)   2192m (115%)
deployment.apps/capacity created
<nil>                  FailedScheduling    capacity-5d4dbd6759-jl2hx       0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
2026-10-02T15:43:14Z   TriggeredScaleUp    capacity-5d4dbd6759-jl2hx       pod triggered scale-up: [{aks-user-25795745-vmss 2->3 (max: 3)}]
...
2026-10-02T15:43:15Z   NotTriggerScaleUp   capacity-5d4dbd6759-mv7gt       pod didn't trigger scale-up: 1 max node group size reached
...
2026-10-02T15:43:15Z   NotTriggerScaleUp   capacity-5d4dbd6759-q7hvn       pod didn't trigger scale-up: 1 max node group size reached
```

```bash
kubectl get configmap cluster-autoscaler-status -n kube-system -o jsonpath='{.data.status}' | sed -n '/^nodeGroups/,$p'
```

```output
nodeGroups:
- health:
    cloudProviderTarget: 3
    maxSize: 3
    minSize: 2
    nodeCounts:
      registered:
        notStarted: 0
        ready: 2
        total: 2
      unregistered: 0
    status: Healthy
  name: aks-user-25795745-vmss
  ...
  scaleUp:
    backoffInfo: {}
    lastTransitionTime: "2026-10-02T15:43:12Z"
    status: InProgress
time: 2026-10-02 15:43:15.44813593 +0000 UTC
```

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,CREATED:.metadata.creationTimestamp,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=capacity -o wide
kubectl delete deploy capacity -n lab-c-payments
```

```output
NODE                             CREATED                ZONE
aks-system-11091932-vmss000000   2026-10-02T13:58:44Z   0
aks-user-25795745-vmss000000     2026-10-02T14:03:15Z   centralindia-1
aks-user-25795745-vmss000001     2026-10-02T14:03:21Z   centralindia-2
aks-user-25795745-vmss000003     2026-10-02T15:43:52Z   centralindia-3
NAME                        READY   STATUS    RESTARTS   AGE    IP            NODE                           NOMINATED NODE   READINESS GATES
capacity-5d4dbd6759-jl2hx   1/1     Running   0          111s   10.244.3.21   aks-user-25795745-vmss000003   <none>           <none>
capacity-5d4dbd6759-mv7gt   0/1     Pending   0          111s   <none>        <none>                         <none>           <none>
capacity-5d4dbd6759-q7hvn   0/1     Pending   0          111s   <none>        <none>                         <none>           <none>
deployment.apps "capacity" deleted from lab-c-payments namespace
```

**What you are seeing:** neither user node had a free CPU (about 650m and 610m left), so all three pods were
Pending. The autoscaler simulated them on a new node, found that one fits a fresh D2s_v5, and raised the scale set
from 2 to 3 (`cloudProviderTarget: 3` while `registered` is still 2, status `InProgress`). For the other two it
answered `max node group size reached`: the pool's `--max-count 3` is a hard budget, so they stay Pending. The VM
registered 38 seconds after the decision and was Ready at 15:44:26, 72 seconds after it, the same as the first
scale-up. The new instance is `vmss000003`: scale set instance numbers are not reused. Deleting the
Deployment lets the autoscaler remove the node again after its 10-minute timers.
## 9. A rolling update under load

Release `6bca1e2` replaces `e3be349` while the load generator from step 7 runs for 120 s. The Deployment uses
`maxSurge: 1` and `maxUnavailable: 0`: one new pod is added, and an old pod is removed only after the new one is
Ready (and has stayed Ready for `minReadySeconds: 5`).

```bash
kubectl delete job load -n lab-c-payments --ignore-not-found
kubectl apply -f aks/manifests/07/load-job.yaml
kubectl wait pod -l app.kubernetes.io/name=loadgen -n lab-c-payments --for=condition=Ready
kubectl set image deploy/payments-api -n lab-c-payments \
  app=ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:5f67a5b2960c71d7f8fa589a44a1758a3416da87cac40ce686dcecdb0d040e16
time kubectl rollout status deploy/payments-api -n lab-c-payments
```

```output
deployment.apps/payments-api image updated
Waiting for deployment "payments-api" rollout to finish: 1 out of 3 new replicas have been updated...
...
Waiting for deployment "payments-api" rollout to finish: 2 out of 3 new replicas have been updated...
...
Waiting for deployment "payments-api" rollout to finish: 1 old replicas are pending termination...
...
deployment "payments-api" successfully rolled out
kubectl rollout status deploy/payments-api -n lab-c-payments  0.28s user 0.10s system 1% cpu 25.936 total
```

A pod watch in a second terminal (`kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=payments-api -w`)
shows the order for the first replacement:

```output
payments-api-644f9985dd-djg65   0/1     Pending             0          0s
payments-api-644f9985dd-djg65   0/1     ContainerCreating   0          0s
payments-api-644f9985dd-djg65   0/1     Running             0          3s
payments-api-644f9985dd-djg65   1/1     Running             0          4s
payments-api-b88764c67-jx65j    1/1     Terminating         0          2m
payments-api-644f9985dd-l8qpm   0/1     Pending             0          0s
...
payments-api-b88764c67-jx65j    0/1     Completed           0          2m5s
```

Then the load generator's verdict and the Deployment's history:

```bash
kubectl wait --for=condition=complete job/load -n lab-c-payments --timeout=200s
kubectl logs job/load -n lab-c-payments
kubectl rollout history deploy/payments-api -n lab-c-payments
kubectl get rs -n lab-c-payments -l app.kubernetes.io/name=payments-api \
  -o custom-columns='RS:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' \
  | sed 's#ghcr.io/sathpal/regulated-k8s-reference/##'
```

```output
15:30:55 progress total=97 ok=97 failed=0 ve3be349=97
15:31:05 progress total=194 ok=194 failed=0 v6bca1e2=12 ve3be349=182
15:31:15 progress total=290 ok=290 failed=0 v6bca1e2=50 ve3be349=240
15:31:25 progress total=387 ok=387 failed=0 v6bca1e2=125 ve3be349=262
15:31:35 progress total=482 ok=482 failed=0 v6bca1e2=220 ve3be349=262
...
15:32:48 SUMMARY total=1154 ok=1154 failed=0 v6bca1e2=892 ve3be349=262
deployment.apps/payments-api
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

RS                        DESIRED   READY    IMAGE
payments-api-644f9985dd   3         3        payments-api@sha256:5f67a5b2960c71d7f8fa589a44a1758a3416da87cac40ce686dcecdb0d040e16
payments-api-b88764c67    0         <none>   payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd
```

**What you are seeing:**

- The rollout took 26 seconds. Each old pod got `Terminating` only after its replacement showed `1/1`, and it took
  about 5 seconds to finish (`Completed`): that is payments-api failing its readiness, waiting `DRAIN_SECONDS`, then
  closing, so the EndpointSlice dropped it before it stopped answering.
- 1,154 requests, 0 failed. The version counters show the traffic moving: from 15:31:05 both versions answered,
  and after 15:31:25 only `6bca1e2` did. Each request opened a new connection, as a browser or a service without
  connection reuse would.
- A rollout is a new ReplicaSet scaled up while the old one is scaled down. The old ReplicaSet stays at 0 replicas
  (up to `revisionHistoryLimit: 5`), which is what makes an instant rollback possible.

## 10. A bad release, contained and rolled back

`FAIL_READINESS=true` makes payments-api start normally but answer 503 on `/readyz`, like a release with a broken
dependency. Run the load for 200 s this time, then ship the bad release.

```bash
kubectl delete job load -n lab-c-payments
sed 's/value: "120"/value: "200"/' aks/manifests/07/load-job.yaml | kubectl apply -f -
kubectl wait pod -l app.kubernetes.io/name=loadgen -n lab-c-payments --for=condition=Ready
kubectl set env deploy/payments-api -n lab-c-payments FAIL_READINESS=true
time kubectl rollout status deploy/payments-api -n lab-c-payments
kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=payments-api
BAD=$(kubectl get pods -n lab-c-payments -l app.kubernetes.io/name=payments-api --no-headers | awk '$2=="0/1"{print $1; exit}')
kubectl events -n lab-c-payments --for pod/$BAD | grep -E 'REASON|Unhealthy'
kubectl get deploy payments-api -n lab-c-payments -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
```

```output
deployment.apps/payments-api env updated
Waiting for deployment "payments-api" rollout to finish: 1 out of 3 new replicas have been updated...
error: deployment "payments-api" exceeded its progress deadline
kubectl rollout status deploy/payments-api -n lab-c-payments  0.27s user 0.09s system 0% cpu 2:00.71 total
NAME                            READY   STATUS    RESTARTS   AGE
payments-api-644f9985dd-9zbhk   1/1     Running   0          4m24s
payments-api-644f9985dd-djg65   1/1     Running   0          4m40s
payments-api-644f9985dd-l8qpm   1/1     Running   0          4m31s
payments-api-7d588699b4-xx7ld   0/1     Running   0          2m2s
LAST SEEN             TYPE      REASON      OBJECT                              MESSAGE
14s (x25 over 2m2s)   Warning   Unhealthy   Pod/payments-api-7d588699b4-xx7ld   Readiness probe failed: HTTP probe failed with statuscode: 503
Available	True	MinimumReplicasAvailable
Progressing	False	ProgressDeadlineExceeded
```

**What you are seeing:** the new pod started (no crash, no restarts) but never became Ready, so with
`maxSurge: 1` and `maxUnavailable: 0` the rollout could not remove a single old pod. All three good pods kept
serving. After `progressDeadlineSeconds: 120`, `kubectl rollout status` exited with an error; that non-zero exit is
what a pipeline uses to trigger an automatic rollback. The Deployment says both things at once: `Available`
(users are fine) and not `Progressing` (the release failed).

Roll back to the previous revision, then read the load generator's verdict:

```bash
kubectl rollout undo deploy/payments-api -n lab-c-payments
time kubectl rollout status deploy/payments-api -n lab-c-payments
kubectl rollout history deploy/payments-api -n lab-c-payments
kubectl wait --for=condition=complete job/load -n lab-c-payments --timeout=200s
kubectl logs job/load -n lab-c-payments | sed -n '1,2p;$p'
```

```output
deployment.apps/payments-api rolled back
deployment "payments-api" successfully rolled out
kubectl rollout status deploy/payments-api -n lab-c-payments  0.27s user 0.09s system 51% cpu 0.711 total
deployment.apps/payments-api
REVISION  CHANGE-CAUSE
1         <none>
3         <none>
4         <none>

15:33:35 progress total=96 ok=96 failed=0 v6bca1e2=96
15:33:45 progress total=194 ok=194 failed=0 v6bca1e2=194
15:36:47 SUMMARY total=1929 ok=1929 failed=0 v6bca1e2=1929
```

**What you are seeing:** the rollback finished in under a second, because nothing had to start: the good
ReplicaSet was still at full size, and undo only scaled the bad one to zero. Revision 2 (the good template)
became revision 4; revision 3 is the bad release, kept for the post-mortem. Over the whole incident, 1,929 requests
and 0 failures. The bad release never received a single request, because a pod that is not Ready is not in the
Service's EndpointSlice. Readiness plus `maxUnavailable: 0` turns a broken release into a stalled rollout instead of
an outage.

## 11. The HPA scales on CPU

The base HPA keeps payments-api between 3 and 10 replicas, targeting 70% of the CPU request (70% of 50m, so 35m per
pod on average). metrics-server supplies the numbers. `cpu-load-job.yaml` runs three load pods, each with eight
threads calling `/version` as fast as they can for 5 minutes.

```bash
kubectl delete job load -n lab-c-payments
kubectl get hpa payments-api -n lab-c-payments
kubectl top pods -n lab-c-payments
kubectl apply -f aks/manifests/07/cpu-load-job.yaml
# terminal 2
kubectl get hpa payments-api -n lab-c-payments -w
```

```output
NAME           REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
payments-api   Deployment/payments-api   cpu: 4%/70%   3         10        3          7m54s
NAME                            CPU(cores)   MEMORY(bytes)
payments-api-644f9985dd-9zbhk   2m           6Mi
payments-api-644f9985dd-djg65   2m           5Mi
payments-api-644f9985dd-l8qpm   2m           5Mi
job.batch/cpu-load created
```

```output
NAME           REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
payments-api   Deployment/payments-api   cpu: 4%/70%   3         10        3          7m59s
payments-api   Deployment/payments-api   cpu: 38%/70%   3         10        3          8m32s
payments-api   Deployment/payments-api   cpu: 184%/70%   3         10        3          9m2s
payments-api   Deployment/payments-api   cpu: 184%/70%   3         10        6          9m17s
payments-api   Deployment/payments-api   cpu: 231%/70%   3         10        8          9m32s
payments-api   Deployment/payments-api   cpu: 231%/70%   3         10        10         9m47s
payments-api   Deployment/payments-api   cpu: 147%/70%   3         10        10         10m
payments-api   Deployment/payments-api   cpu: 91%/70%    3         10        10         10m
payments-api   Deployment/payments-api   cpu: 79%/70%    3         10        10         11m
```

A few minutes in, while the load runs:

```bash
kubectl top pods -n lab-c-payments
kubectl describe hpa payments-api -n lab-c-payments | sed -n '/Metrics:/,/Conditions:/p;/ScalingLimited/p'
kubectl get events -n lab-c-payments --field-selector reason=SuccessfulRescale -o custom-columns=TIME:.lastTimestamp,MSG:.message
```

```output
NAME                            CPU(cores)   MEMORY(bytes)
cpu-load-46pf6                  250m         9Mi
cpu-load-67lm8                  249m         9Mi
cpu-load-gr9hl                  249m         9Mi
payments-api-644f9985dd-44nwc   41m          6Mi
payments-api-644f9985dd-45bwr   38m          6Mi
...
payments-api-644f9985dd-m978s   41m          7Mi
Metrics:                                               ( current / target )
  resource cpu on pods  (as a percentage of request):  79% (39m) / 70%
Min replicas:                                          3
Max replicas:                                          10
Deployment pods:                                       10 current / 10 desired
Conditions:
  ScalingLimited  True    TooManyReplicas   the desired replica count is more than the maximum replica count
TIME                   MSG
2026-10-02T15:38:11Z   New size: 6; reason: cpu resource utilization (percentage of request) above target
2026-10-02T15:38:26Z   New size: 8; reason: cpu resource utilization (percentage of request) above target
2026-10-02T15:38:41Z   New size: 10; reason: cpu resource utilization (percentage of request) above target
```

When the load ends (15:42:11), the HPA waits before it removes pods:

```bash
kubectl get events -n lab-c-payments --field-selector reason=SuccessfulRescale -o custom-columns=TIME:.lastTimestamp,MSG:.message
for p in $(kubectl get pods -n lab-c-payments -l job-name=cpu-load -o name); do kubectl logs -n lab-c-payments $p | tail -1; done
```

```output
TIME                   MSG
2026-10-02T15:38:11Z   New size: 6; reason: cpu resource utilization (percentage of request) above target
2026-10-02T15:38:26Z   New size: 8; reason: cpu resource utilization (percentage of request) above target
2026-10-02T15:38:41Z   New size: 10; reason: cpu resource utilization (percentage of request) above target
2026-10-02T15:47:57Z   New size: 4; reason: All metrics below target
2026-10-02T15:48:58Z   New size: 3; reason: All metrics below target
15:42:11 SUMMARY total=143629 ok=143627 failed=2 v6bca1e2=143627 gaierror=2
15:42:11 SUMMARY total=144863 ok=144861 failed=2 v6bca1e2=144861 gaierror=2
15:42:11 SUMMARY total=139060 ok=139060 failed=0 v6bca1e2=139060
```

**What you are seeing:**

- **Scale-up is fast and stepwise.** From 3 to 10 replicas in 30 seconds, in 15-second steps (the HPA
  controller's default sync period). The steps are smaller than the ratio suggests (184% would justify 8 pods at
  once): while pods are not ready or have no metrics yet, the HPA assumes they use 0% during a scale-up, which
  damps the response.
- **10 is a ceiling, not the answer.** At 10 replicas the average was still 79% of the request, and the HPA reported
  `TooManyReplicas`: it wanted more than `maxReplicas`. The `maxReplicas` value is a cost and blast-radius budget;
  set it from load tests, and make sure the node pool can hold it (10 x 50m is small here; the autoscaler adds nodes
  when it is not).
- **Scale-down is deliberately slow.** The HPA's default scale-down stabilization window is 5 minutes: it uses the
  highest recommendation of the last 5 minutes, so a short dip does not drop pods that a returning spike needs.
  Load ended at 15:42:11; the first pods went at 15:47:57.
- **The load pods were capped at 250m each** (their CPU limit), so this test measures 750m of client CPU, not
  payments-api's limit. Requests are what the HPA divides by: with a 50m request, 39m of real use is already 79%.
- **4 of 427,552 requests failed, and not in payments-api.** `gaierror` is Python's DNS lookup error: each request
  resolved `payments-api` again over a new connection, about 1,400 lookups a second against CoreDNS. Real clients
  reuse connections and cache lookups; a load test that does not is also a DNS load test.
- All ten replicas ran on the two remaining user nodes (zones 1 and 2): the zone 3 node had been removed by the
  autoscaler minutes earlier (step 8), and `ScheduleAnyway` spread does not ask for a new node.

## 12. A planned maintenance window for auto-upgrades

This cluster auto-upgrades on two channels (lab 03 step 4): `patch` for Kubernetes patch versions and `NodeImage`
for the node OS image. Without a window, AKS may start those upgrades at any time. A maintenance configuration
named `aksManagedAutoUpgradeSchedule` restricts cluster auto-upgrades to a recurring window; here, Saturdays from
22:00 IST for four hours, every week. (`aksManagedNodeOSUpgradeSchedule` does the same for node OS upgrades, and
`default` covers AKS's weekly releases of control plane components and add-ons.)

```bash
az aks maintenanceconfiguration add -g $RG --cluster-name $AKS --name aksManagedAutoUpgradeSchedule \
  --schedule-type Weekly --day-of-week Saturday --interval-weeks 1 \
  --start-time 22:00 --duration 4 --utc-offset +05:30 -o json
az aks maintenanceconfiguration list -g $RG --cluster-name $AKS \
  --query '[].{name:name, schedule:maintenanceWindow.schedule.weekly, start:maintenanceWindow.startTime, utcOffset:maintenanceWindow.utcOffset, hours:maintenanceWindow.durationHours}' -o json
```

```output
{
  "id": "/subscriptions/<subscription-id>/resourceGroups/rg-aks-handson/providers/Microsoft.ContainerService/managedClusters/aks-handson/maintenanceConfigurations/aksManagedAutoUpgradeSchedule",
  "maintenanceWindow": {
    "durationHours": 4,
    "notAllowedDates": null,
    "schedule": {
      "absoluteMonthly": null,
      "daily": null,
      "relativeMonthly": null,
      "weekly": {
        "dayOfWeek": "Saturday",
        "intervalWeeks": 1
      }
    },
    "startDate": "2026-10-02",
    "startTime": "22:00",
    "utcOffset": "+05:30"
  },
  "name": "aksManagedAutoUpgradeSchedule",
  ...
}
[
  {
    "hours": 4,
    "name": "aksManagedAutoUpgradeSchedule",
    "schedule": {
      "dayOfWeek": "Saturday",
      "intervalWeeks": 1
    },
    "start": "22:00",
    "utcOffset": "+05:30"
  }
]
```

**What you are seeing:** a child resource of the cluster (`.../maintenanceConfigurations/aksManagedAutoUpgradeSchedule`),
not a Kubernetes object. The window is in local time with an explicit UTC offset, so a change advisory board can
read it as written. Four hours is the shortest window the CLI accepts and the minimum Microsoft recommends. An
upgrade that starts inside the window may run past its end; AKS starts no new upgrade work after the window closes
and defers the rest to the next one. `notAllowedDates` can block out freeze periods such as a month-end close.
The window decides *when*; the PDB, readiness probes and surge settings from this lab decide whether anyone
notices.

## 13. Node image upgrades: what AKS would do, without doing it

```bash
az aks nodepool get-upgrades -g $RG --cluster-name $AKS --nodepool-name user \
  --query '{kubernetesVersion:kubernetesVersion, latestNodeImageVersion:latestNodeImageVersion, upgrades:upgrades}' -o json
az aks nodepool show -g $RG --cluster-name $AKS -n user \
  --query '{nodeImageVersion:nodeImageVersion, upgradeSettings:upgradeSettings}' -o json
az aks get-upgrades -g $RG -n $AKS --query 'controlPlaneProfile.upgrades[].kubernetesVersion' -o tsv
```

```output
{
  "kubernetesVersion": "1.35.8",
  "latestNodeImageVersion": "AKSAzureLinux-V3gen2-202609.15.0",
  "upgrades": null
}
{
  "nodeImageVersion": "AKSAzureLinux-V3gen2-202609.15.0",
  "upgradeSettings": {
    "drainTimeoutInMinutes": null,
    "maxSurge": "10%",
    "maxUnavailable": "0",
    "nodeSoakDurationInMinutes": null,
    "undrainableNodeBehavior": "Schedule"
  }
}
1.36.4
1.36.3
1.36.2
1.36.1
1.36.0
```

**What you are seeing:**

- The pool runs the latest node image, so a node image upgrade has nothing to do today. The control plane could
  move to 1.36, which is a minor upgrade; the `patch` channel never does that on its own.
- **How a node image upgrade runs.** AKS adds surge nodes with the new image (`maxSurge: 10%` of 3 nodes rounds up
  to one node), then for each old node: cordon, drain through the Eviction API (so every PDB in step 7 applies),
  and delete. `maxUnavailable: 0` means capacity never drops below the pool size. For production Microsoft
  recommends a higher surge, such as 33%, to finish faster; each surge node is a VM you pay for while it exists.
- **The settings left at `null` use defaults.** `drainTimeoutInMinutes` defaults to 30: if a node's pods are not
  evicted in time (a PDB that can never be satisfied, for example `minAvailable` equal to the replica count), the
  upgrade stops. `nodeSoakDurationInMinutes` (0 by default, at most 30) waits after each drain before moving on,
  which gives your monitoring time to catch a bad node image. `undrainableNodeBehavior: Schedule` deletes a
  blocked node and surges a replacement; `Cordon` leaves it cordoned and labelled
  `kubernetes.azure.com/upgrade-status=Quarantined` for you to inspect.
- The drain in step 7 took 2 minutes for one node because the replacement needed new capacity. Multiply by the
  node count and you have a lower bound for the window length in step 12.

To run one by hand you would use `az aks nodepool upgrade --node-image-only` (with `--max-surge`,
`--drain-timeout` and `--node-soak-duration` if you want to change them). This lab does not, because the cluster
is shared.

## 14. Observability: what you used, and what you would add

Everything in this lab came from three free sources: `kubectl top` (metrics-server), Kubernetes events, and the
autoscaler's status ConfigMap.

```bash
kubectl top nodes
kubectl top pods -n lab-c-patients --containers
```

```output
NAME                             CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
aks-system-11091932-vmss000000   98m          5%       1493Mi          25%
aks-user-25795745-vmss000000     84m          4%       1342Mi          23%
aks-user-25795745-vmss000001     69m          3%       1874Mi          32%
aks-user-25795745-vmss000002     66m          3%       1317Mi          22%
POD                            NAME   CPU(cores)   MEMORY(bytes)
patient-api-5b54fcd8dc-4bxp9   app    1m           10Mi
patient-api-5b54fcd8dc-s8nsc   app    1m           10Mi
patient-api-5b54fcd8dc-stvdf   app    1m           10Mi
```

**What you are seeing:** a snapshot, nothing more: metrics-server holds only the most recent measurements, in
memory. patient-api uses 1m of CPU and 10Mi of memory against requests of 50m and 64Mi, so its requests are
generous; across a fleet, that gap is money the autoscaler spends on nodes. Events are the cluster's short-term
memory: they explained the scheduling, the PDB, the scale-ups and the HPA in steps 3, 7, 8 and 11, but Kubernetes keeps them only
for a limited time (the API server's default is one hour). For production you want metrics and events kept, and
alerts on top:

- **Container insights** sends container logs, Kubernetes events and inventory to a Log Analytics workspace. You
  pay for the data ingested and retained, so the choice of preset matters: the default collects logs and events,
  and a cost-optimized preset collects every five minutes and skips `kube-system`.
- **Azure Monitor managed service for Prometheus** scrapes Prometheus metrics into an Azure Monitor workspace,
  which Azure Managed Grafana can chart. There is no charge for the workspace itself; you pay per samples ingested and
  per query.

This lab enables neither, to keep the cost at zero; `az aks enable-addons --addons monitoring` and
`az aks update --enable-azure-monitor-metrics` are the switches.

## On AKS specifically

- **System pools.** Every cluster needs at least one system node pool. Microsoft recommends the
  `CriticalAddonsOnly=true:NoSchedule` taint to keep application pods off it, and for production at least two
  system nodes (three recommended) on VM sizes with at least 4 vCPUs and 4 GB of memory. This lab's single
  2-vCPU system node is a cost shortcut for a lab, not a pattern.
- **Availability zones.** A zonal node pool's zones are fixed at creation: you can't change the number of zones
  later. AKS balances nodes between the selected zones. Kubernetes 1.29 and later default to zone-redundant (ZRS)
  managed disks for new PVCs; a locally redundant (LRS) disk is bound to its zone, and so is any pod that mounts it.
- **Allocatable.** AKS reserves CPU for the kubelet on a sliding scale (100m on a 2-core VM) and, from Kubernetes
  1.29, memory equal to the lesser of `20 MB x max pods + 50 MB` and 25% of the VM's memory, plus a 100Mi eviction
  threshold. With 250 max pods on an 8 GiB VM that is 2048Mi + 100Mi, exactly the gap between capacity and
  allocatable in step 5.
- **Cluster autoscaler defaults** (cluster-wide profile): scan every 10 s, `scale-down-delay-after-add` 10 min,
  `scale-down-unneeded-time` 10 min, `scale-down-utilization-threshold` 0.5, `max-node-provision-time` 15 min,
  expander `random`, `skip-nodes-with-system-pods` true. Status is in the `cluster-autoscaler-status` ConfigMap.
- **Upgrades.** Cluster auto-upgrade channels are `none`, `patch`, `stable`, `rapid` and `node-image` (legacy);
  node OS channels are `None`, `Unmanaged`, `SecurityPatch` and `NodeImage` (a new image weekly). Node surge
  settings: a percentage `maxSurge` is rounded up to whole nodes, Microsoft recommends 33% for production pools,
  drain timeout defaults to 30 minutes (5 minutes to 24 hours), node soak to 0 (up to 30 minutes), and
  `maxUnavailable` cannot be set on system pools.
- **Planned maintenance.** Three configurations can coexist: `default` (AKS weekly releases),
  `aksManagedAutoUpgradeSchedule` and `aksManagedNodeOSUpgradeSchedule`, with `Daily`, `Weekly`,
  `AbsoluteMonthly` and `RelativeMonthly` schedules. Windows are best effort: work that started may finish after
  the window closes, and nothing new starts until the next window.
- **Pricing tier and SLA.** This cluster is on the Free tier: no financially backed uptime SLA, recommended for
  fewer than 10 nodes. The Standard tier adds an API server SLA of 99.95% with availability zones (99.9% without).
- **Monitoring cost.** Container insights bills Log Analytics ingestion and retention; managed Prometheus has no
  charge for the workspace and bills samples ingested and queried.

## In the conversation

**Why it matters in production.** Availability on AKS is decided less by Azure than by the manifests: Azure can drain
your nodes every week for node images, and the PDB, readiness probe and surge settings decide whether users
notice. Requests drive both scheduling and the autoscaler's bill, so they are a cost decision as much as a
reliability one. And zones only protect you if the pool has nodes in them and the pods are spread across those
nodes. A maintenance window turns "Azure upgraded us at noon" into a planned change.

**A short story.** "On our AKS cluster I drained a user node that held two of three payments-api replicas, with a
PodDisruptionBudget of `minAvailable: 2` and a load generator calling the service. The first eviction went
through; the second was refused with 'Cannot evict pod as it would violate the pod's disruption budget' and
retried for two minutes, because the replacement had no CPU to land on until the cluster autoscaler added a node in
a third zone, 72 seconds from decision to Ready. 1,086 requests during the drain, none failed. Then we shipped the
next release under load: 1,154 requests, 0 failed, done in 26 seconds. A release with a failing readiness check
stalled on its first pod while the old pods served 1,929 requests without a failure, and `kubectl rollout undo`
ended it in under a second. The same cluster refused our development image in the PCI namespace because it did not
come from the release registry, which is exactly what we wanted it to do."

**Follow-up questions to expect**

- *Why `minAvailable: 2` and not 3?* With three replicas, `minAvailable: 3` allows zero voluntary disruptions, so
  every drain waits until its timeout (30 minutes by default on AKS) and the upgrade stops. Two keeps one disruption
  available while never dropping below two serving pods.
- *Why no CPU limit?* A CPU limit throttles a container even when the node is idle. The request reserves the
  share the scheduler counts; the memory limit is the one that protects the node, because memory cannot be
  throttled, only reclaimed by killing.
- *What happens to the system pool during a node image upgrade?* The same surge, cordon and drain, but you cannot
  set `maxUnavailable` on a system pool, and the add-ons there have their own PDBs (CoreDNS, metrics-server,
  konnectivity-agent). That is one reason Microsoft recommends at least two system nodes.
- *How do you know a release is bad before users do?* Readiness gates traffic, and `maxUnavailable: 0` means the
  old pods stay until new ones are Ready, so a broken release stalls instead of serving errors. The progress deadline
  turns the stall into a failed `kubectl rollout status`, which the pipeline answers with `kubectl rollout undo`.
- *Why did the drain take two minutes?* The PDB allows the next eviction only when a replacement is Ready, and the
  replacement waited for a new node. On a pool with spare capacity the same drain finishes in seconds; leaving
  headroom, or a higher `maxSurge`, shortens upgrades.
- *Free tier or Standard tier for production?* Standard: the Free tier has no financially backed SLA and is meant
  for fewer than 10 nodes; Standard adds a 99.95% API server SLA with availability zones.

## If something looks different

- An ACR image is refused in `lab-c-payments` with `admission webhook "validate.kyverno.svc-fail"`: the repo's
  Kyverno policies are installed and apply to namespaces labelled `data-classification=pci` or `phi` (step 2).
  Use the GHCR release digests, as the kustomizations do. Without those policies, both registries work.
- The drain finishes in seconds and the PDB never refuses: the two payments-api replicas were not on the node you
  drained, or the other node had room. The selection command in step 7 picks the node with the most replicas.
- No node is added during the drain: your other user node had spare CPU, so the replacement fit. Use
  `capacity.yaml` (step 8) to force a scale-up; on an idle pool, one pod per node fits and only the third is
  Pending. Delete it afterwards so the node can go.
- The HPA shows `cpu: <unknown>/70%` for the first minute: metrics-server has no sample for new pods yet. On a
  bigger node pool the load pods may not push payments-api to 10 replicas; scale `cpu-load` up or lower the target.

## Clean up

```bash
kubectl delete namespace lab-c-payments lab-c-patients
kubectl get nodes -l kubernetes.azure.com/mode=user   # the autoscaler removes the third node 10+ minutes later
```

Keep the maintenance configuration; it is a sensible default for this cluster. To remove it:
`az aks maintenanceconfiguration delete -g $RG --cluster-name $AKS --name aksManagedAutoUpgradeSchedule`. The images
in ACR stay until you delete the `labs/c/*` repositories.

## Checkpoint

1. A Deployment has three replicas and a PDB with `minAvailable: 3`. What happens during an AKS node image
   upgrade?
   _Hint: allowed disruptions, then the drain timeout in step 13._
2. Your pods are Pending with `Insufficient cpu`, but `kubectl top nodes` shows 5% CPU used. Why, and what do you
   change?
   _Hint: the scheduler and the autoscaler count requests, not usage (steps 5 and 14)._
3. Three replicas run in two zones after a node was added in a third. What makes them use all three?
   _Hint: when are spread constraints evaluated (step 8)?_
4. In step 10, why did the bad release receive no traffic at all, even though its pod was `Running`?
   _Hint: what decides whether a pod's IP is in the EndpointSlice (step 6)?_

## Further reading

- [Manage system node pools in AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/use-system-pools)
- [Configure availability zones in AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/reliability-availability-zones-configure)
- [Use the cluster autoscaler in AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/cluster-autoscaler)
- [Planned maintenance for AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/planned-maintenance)
- [Rolling upgrades of node pools: surge, drain timeout, soak (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/upgrade-aks-node-pools-rolling)
- [Disruptions and PodDisruptionBudgets (kubernetes.io)](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Pod topology spread constraints (kubernetes.io)](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Horizontal Pod Autoscaling (kubernetes.io)](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
