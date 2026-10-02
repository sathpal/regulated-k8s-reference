# 09. Troubleshooting on AKS

**Goal:** reproduce the failures that fill most AKS support queues, one at a time, in your own namespace: read
the signal Kubernetes and Azure give you, find the cause, fix it, and end with a triage flow you can run under
pressure.

**You need:** the environment from lab 00, the images from lab 07 step 1 (`labs/c/payments-api:1` and
`labs/c/patient-api:1` in your ACR). About 60 minutes. Extra cost: step 2 creates a second Basic container
registry for about ten minutes and deletes it; everything else runs as small pods on the existing `user` pool.

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

Most incidents on a managed Kubernetes service are not platform outages. They are a wrong tag, a missing role
assignment, a probe on the wrong port, a selector typo or a policy doing exactly what it was told. Each one shows a
specific signal in `kubectl get`, events, logs or an `az` command, and the time to recovery depends on knowing
which signal to read first. Knowing what Azure owns (the control plane, node images, the kubelet identity) and what
you own (manifests, images, policies, role assignments) decides whether you fix it yourself or open a ticket.

**What you will learn**

- How to tell a wrong tag from a registry the cluster is not allowed to pull from, and how `az aks check-acr` proves it
- How CrashLoopBackOff, OOMKilled, Pending and a failing readiness probe look in status, events and logs
- Why "the pod runs but the Service does not answer" is usually an empty EndpointSlice or a NetworkPolicy
- How to check DNS from inside a pod, and what a default-deny policy does to it
- What an Entra ID login failure looks like through kubelogin, reproduced safely on a copy of the kubeconfig
- A triage order, and what to collect before opening an Azure support request

## 1. A known-good baseline

Every failure below starts from a working payments-api (two replicas) and a small client pod with `curl`. The
namespace enforces the Pod Security `restricted` profile, so every manifest here carries a hardened
securityContext. `app.yaml` uses `ACR_NAME` as a placeholder; `sed` puts your registry in.

```bash
source aks/.lab.env
kubectl apply -f aks/manifests/09/namespace.yaml
sed "s/ACR_NAME/$ACR/g" aks/manifests/09/app.yaml | kubectl apply -f -
kubectl apply -f aks/manifests/09/client.yaml
kubectl rollout status deploy/payments-api -n lab-c-trouble
kubectl wait pod/client -n lab-c-trouble --for=condition=Ready
kubectl get pods -n lab-c-trouble -o wide
kubectl exec -n lab-c-trouble client -- curl -s -m 3 http://payments-api/version
kubectl get endpointslices -n lab-c-trouble -l kubernetes.io/service-name=payments-api
```

```output
namespace/lab-c-trouble created
deployment.apps/payments-api created
service/payments-api created
pod/client created
deployment "payments-api" successfully rolled out
pod/client condition met
NAME                            READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
client                          1/1     Running   0          3s    10.244.3.175   aks-user-25795745-vmss000002   <none>           <none>
payments-api-7498d98764-4h2t5   1/1     Running   0          6s    10.244.3.69    aks-user-25795745-vmss000002   <none>           <none>
payments-api-7498d98764-n9d8t   1/1     Running   0          6s    10.244.1.179   aks-user-25795745-vmss000000   <none>           <none>
{"service":"payments-api","version":"1"}
NAME                 ADDRESSTYPE   PORTS   ENDPOINTS                  AGE
payments-api-xfrsd   IPv4          8080    10.244.3.69,10.244.1.179   64s
```

**What you are seeing:** the healthy picture you compare everything else against. Both replicas are `1/1 Running`,
the Service's EndpointSlice lists both pod IPs on port 8080, and a request from inside the namespace returns
version 1. Pod IPs come from the overlay range `10.244.0.0/16`; nodes are instances of the `user` pool's VM scale
set in the `MC_` resource group.

## 2. ImagePullBackOff: a tag that does not exist

`kubectl set image` starts a rollout to a tag nobody pushed. The Deployment uses `maxUnavailable: 0`, so the old
pods keep serving while the new one fails.

```bash
kubectl set image deploy/payments-api -n lab-c-trouble app=$ACR.azurecr.io/labs/c/payments-api:1.0.1
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api
POD=$(kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api --no-headers | awk '/ImagePull|ErrImage/{print $1; exit}')
kubectl events -n lab-c-trouble --for pod/$POD
az acr repository show-tags -n $ACR --repository labs/c/payments-api -o tsv
```

```output
NAME                            READY   STATUS             RESTARTS   AGE
payments-api-7498d98764-4h2t5   1/1     Running            0          89s
payments-api-7498d98764-n9d8t   1/1     Running            0          89s
payments-api-fcfb6cbf7-fw2jv    0/1     ImagePullBackOff   0          19s
LAST SEEN          TYPE      REASON      OBJECT                             MESSAGE
20s                Normal    Scheduled   Pod/payments-api-fcfb6cbf7-fw2jv   Successfully assigned lab-c-trouble/payments-api-fcfb6cbf7-fw2jv to aks-user-25795745-vmss000002
19s                Normal    BackOff     Pod/payments-api-fcfb6cbf7-fw2jv   Back-off pulling image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1"
19s                Warning   Failed      Pod/payments-api-fcfb6cbf7-fw2jv   Error: ImagePullBackOff
5s (x2 over 20s)   Normal    Pulling     Pod/payments-api-fcfb6cbf7-fw2jv   Pulling image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1"
5s (x2 over 20s)   Warning   Failed      Pod/payments-api-fcfb6cbf7-fw2jv   Failed to pull image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1": [rpc error: code = NotFound desc = failed to pull and unpack image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1": failed to resolve image: acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1: not found, failed to pull and unpack image "acrregk8s1e1193.azurecr.io/labs/c/payments-api:1.0.1": failed to resolve image: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://acrregk8s1e1193.azurecr.io/oauth2/token?scope=repository%3Alabs%2Fc%2Fpayments-api%3Apull&service=acrregk8s1e1193.azurecr.io: 401 Unauthorized]
5s (x2 over 20s)   Warning   Failed      Pod/payments-api-fcfb6cbf7-fw2jv   Error: ErrImagePull
1
2
```

**What you are seeing:** `ErrImagePull` is one failed attempt; `ImagePullBackOff` is the kubelet waiting longer
between attempts. The message holds two errors. The first, `code = NotFound ... not found`, came from the attempt
with the kubelet identity's credentials: the registry answered, and the tag is not there. The second, `401
Unauthorized` on the anonymous token, is containerd's fallback without credentials and is noise here. Read the first
error. The registry lists tags `1` and `2`, so the fix is the tag, not the cluster.

```bash
kubectl rollout undo deploy/payments-api -n lab-c-trouble
kubectl rollout status deploy/payments-api -n lab-c-trouble
```

```output
deployment.apps/payments-api rolled back
deployment "payments-api" successfully rolled out
```

## 3. ImagePullBackOff: a registry the cluster may not pull from

Now the image exists, but in a registry the kubelet identity has no role on. To reproduce it, create a second
Basic registry, copy the image into it with `az acr import` (a server-side copy, nothing is pulled to your machine)
and point the Deployment there.

```bash
ACR2=acrlabc$SUFFIX
az acr create -g $RG -n $ACR2 --sku Basic --admin-enabled false -o none
az acr import -n $ACR2 --source $ACR.azurecr.io/labs/c/payments-api:1 --image labs/c/payments-api:1
kubectl set image deploy/payments-api -n lab-c-trouble app=$ACR2.azurecr.io/labs/c/payments-api:1
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api
POD=$(kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api --no-headers | awk '/ImagePull|ErrImage/{print $1; exit}')
kubectl events -n lab-c-trouble --for pod/$POD | grep 'Failed to pull'
```

```output
NAME                            READY   STATUS             RESTARTS   AGE
payments-api-7498d98764-4h2t5   1/1     Running            0          5m3s
payments-api-7498d98764-n9d8t   1/1     Running            0          5m3s
payments-api-b4bd89554-7qnwn    0/1     ImagePullBackOff   0          16s
2s (x2 over 16s)   Warning   Failed      Pod/payments-api-b4bd89554-7qnwn   Failed to pull image "acrlabc1e1193.azurecr.io/labs/c/payments-api:1": failed to pull and unpack image "acrlabc1e1193.azurecr.io/labs/c/payments-api:1": failed to resolve image: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://acrlabc1e1193.azurecr.io/oauth2/token?scope=repository%3Alabs%2Fc%2Fpayments-api%3Apull&service=acrlabc1e1193.azurecr.io: 401 Unauthorized
```

**What you are seeing:** this time there is no `NotFound`, only `401 Unauthorized`. The kubelet had no credential
that this registry accepts, so even the token request failed. Same status in `kubectl get pods`, different cause.

`az aks check-acr` runs a short-lived pod on a node that uses the node's own kubelet identity to try the same
token exchange, so it tests exactly what the kubelet will do. On a cluster with Entra ID it fetches a fresh
kubeconfig that uses device-code login; set `AAD_LOGIN_METHOD=azurecli` so kubelogin reuses your `az login`
instead of waiting at a device-code prompt (see "If something looks different").

```bash
AAD_LOGIN_METHOD=azurecli az aks check-acr -g $RG -n $AKS --acr $ACR.azurecr.io
AAD_LOGIN_METHOD=azurecli az aks check-acr -g $RG -n $AKS --acr $ACR2.azurecr.io
KUBELET_ID=$(az aks show -g $RG -n $AKS --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --assignee $KUBELET_ID --all --query '[].{role:roleDefinitionName, scope:scope}' -o table
```

```output
[2026-10-02T14:35:26Z] Checking host name resolution (acrregk8s1e1193.azurecr.io): SUCCEEDED
[2026-10-02T14:35:26Z] Canonical name for ACR (acrregk8s1e1193.azurecr.io): r0922cin-az.centralindia.cloudapp.azure.com.
[2026-10-02T14:35:26Z] ACR location: centralindia
[2026-10-02T14:35:26Z] Checking managed identity...
[2026-10-02T14:35:26Z] Kubelet managed identity client ID: 55a5dec9-13a3-43f0-bfd0-58026851030b
[2026-10-02T14:35:26Z] Validating managed identity existance: SUCCEEDED
[2026-10-02T14:35:26Z] Validating image pull permission: SUCCEEDED
[2026-10-02T14:35:26Z]
Your cluster can pull images from acrregk8s1e1193.azurecr.io!
...
[2026-10-02T14:36:55Z] Checking host name resolution (acrlabc1e1193.azurecr.io): SUCCEEDED
[2026-10-02T14:36:55Z] Canonical name for ACR (acrlabc1e1193.azurecr.io): r0922cin-az.centralindia.cloudapp.azure.com.
[2026-10-02T14:36:55Z] ACR location: centralindia
[2026-10-02T14:36:55Z] Checking managed identity...
[2026-10-02T14:36:55Z] Kubelet managed identity client ID: 55a5dec9-13a3-43f0-bfd0-58026851030b
[2026-10-02T14:36:55Z] Validating managed identity existance: SUCCEEDED
[2026-10-02T14:36:55Z] Validating image pull permission: FAILED
[2026-10-02T14:36:55Z] ACR acrlabc1e1193.azurecr.io rejected token exchange: ACR token exchange endpoint returned error status: 401. body: {"errors":[{"code":"UNAUTHORIZED","message":"authentication required, visit https://aka.ms/acr/authorization for more information. CorrelationId: 2fb5120a-af76-4132-9c90-d9fd0af9122c"}]}

Role     Scope
-------  --------------------------------------------------------------------------------------------------------------------------------------------------
AcrPull  /subscriptions/<subscription-id>/resourceGroups/rg-aks-handson/providers/Microsoft.ContainerRegistry/registries/acrregk8s1e1193
```

**What you are seeing:** DNS works and the kubelet identity exists for both registries; only the pull permission
differs. The role list explains why: the kubelet identity (the user-assigned identity `aks-handson-agentpool` in
the `MC_` resource group) holds `AcrPull` on the first registry only, which `--attach-acr` granted when the
cluster was created. The ACR `CorrelationId` is what Azure support asks for if a pull fails and the roles look
right. The fix is a role assignment, made with your own Azure permissions (Microsoft documents Owner or an
equivalent administrator role on the subscription): `az aks update -g $RG -n $AKS --attach-acr $ACR2`. This lab does not run it, because it changes the shared
cluster's identity; roll back and delete the extra registry instead.

```bash
kubectl rollout undo deploy/payments-api -n lab-c-trouble
kubectl rollout status deploy/payments-api -n lab-c-trouble
az acr delete -g $RG -n $ACR2 --yes
```

```output
deployment.apps/payments-api rolled back
deployment "payments-api" successfully rolled out
```

## 4. CrashLoopBackOff: a bad configuration value

payments-api reads its listen port from `PORT`. A value that is not a port number makes it exit at start.

```bash
kubectl set env deploy/payments-api -n lab-c-trouble PORT=eighty
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api
POD=$(kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api --no-headers | awk '/CrashLoop|Error/{print $1; exit}')
kubectl logs -n lab-c-trouble $POD --previous
kubectl describe pod -n lab-c-trouble $POD | grep -E 'State|Reason|Exit Code|Restart Count|PORT'
kubectl events -n lab-c-trouble --for pod/$POD | tail -2
```

```output
NAME                            READY   STATUS             RESTARTS     AGE
payments-api-6f75f544b7-4jp48   0/1     CrashLoopBackOff   1 (7s ago)   8s
payments-api-7498d98764-4h2t5   1/1     Running            0            5m58s
payments-api-7498d98764-n9d8t   1/1     Running            0            5m58s
{"time":"2026-10-02T14:37:30.510958411Z","level":"INFO","msg":"started","version":"1","addr":":eighty","uid":65532}
{"time":"2026-10-02T14:37:30.5115939Z","level":"ERROR","msg":"server failed","err":"listen tcp: lookup tcp/eighty: unknown port"}
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Restart Count:  1
      PORT:  eighty
5s (x3 over 17s)   Normal    Started     Pod/payments-api-6f75f544b7-4jp48   Container started
2s (x5 over 15s)   Warning   BackOff     Pod/payments-api-6f75f544b7-4jp48   Back-off restarting failed container app in pod payments-api-6f75f544b7-4jp48_lab-c-trouble(923d9372-e6e7-40f4-98af-426057eb37f4)
```

**What you are seeing:** CrashLoopBackOff is not an error in itself; it is the kubelet waiting longer before each
restart of a container that keeps exiting. The cause is in the logs of the previous run (`--previous`), because
the current container may not have started yet. `Exit Code: 1` means the app chose to exit; compare 137 in the
next step. Note the log line `"msg":"started"` before the failure: the app logs that it started before the
listener is bound, so "it said started" is not proof that it listens. The old pods kept serving the whole time.

```bash
kubectl rollout undo deploy/payments-api -n lab-c-trouble
```

## 5. OOMKilled: a memory limit that is too small

`oom.yaml` allocates 256 MiB inside a 64 MiB memory limit. It uses the patient-api image only because that
image has a Python interpreter. Lab 02 shows the same event from the node's cgroup files; here you read it from
the API.

```bash
sed "s/ACR_NAME/$ACR/g" aks/manifests/09/oom.yaml | kubectl apply -f -
kubectl get pod oom -n lab-c-trouble
kubectl get pod oom -n lab-c-trouble -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq .
kubectl logs oom -n lab-c-trouble --previous
```

```output
pod/oom created
NAME   READY   STATUS      RESTARTS     AGE
oom    0/1     OOMKilled   1 (4s ago)   5s
{
  "containerID": "containerd://2afa8caa3f405e0dba196f9c9e9b2b512d2e1110623186094c61da064a7920b4",
  "exitCode": 137,
  "finishedAt": "2026-10-02T14:37:55Z",
  "reason": "OOMKilled",
  "startedAt": "2026-10-02T14:37:55Z"
}
unable to retrieve container logs for containerd://2afa8caa3f405e0dba196f9c9e9b2b512d2e1110623186094c61da064a7920b4
```

**What you are seeing:** exit code 137 is 128 + 9: the kernel sent SIGKILL because the container's memory cgroup
passed its limit. The program never printed `allocated`, and there are no logs to read, which is typical: an
OOMKill gives the app no chance to say anything. The status will move to CrashLoopBackOff as restarts continue.
The fix is either a higher limit (after measuring with `kubectl top pod`) or a fix for the leak; a restart loop
does not fix either. This is different from a node-pressure eviction, where the kubelet evicts whole pods
(lowest QoS first) because the node itself runs short.

```bash
kubectl delete pod oom -n lab-c-trouble
```

## 6. Pending: a request no node can satisfy

`pending.yaml` asks for 3 CPUs. A Standard_D2s_v5 node has 2 vCPUs, of which 1900m are allocatable.

```bash
kubectl apply -f aks/manifests/09/pending.yaml
kubectl get pod too-big -n lab-c-trouble
kubectl events -n lab-c-trouble --for pod/too-big
kubectl get nodes -l kubernetes.azure.com/mode=user -o custom-columns='NODE:.metadata.name,CPU_ALLOCATABLE:.status.allocatable.cpu'
```

```output
pod/too-big created
NAME      READY   STATUS    RESTARTS   AGE
too-big   0/1     Pending   0          12s
LAST SEEN   TYPE      REASON              OBJECT        MESSAGE
12s         Warning   FailedScheduling    Pod/too-big   0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient cpu. no new claims to deallocate, preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
3s          Normal    NotTriggerScaleUp   Pod/too-big   pod didn't trigger scale-up: 1 max node group size reached
NAME                           CPU_ALLOCATABLE
aks-user-25795745-vmss000000   1900m
aks-user-25795745-vmss000001   1900m
aks-user-25795745-vmss000002   1900m
```

**What you are seeing:** two components answer. The scheduler (`FailedScheduling`) says why no existing node fits:
the system node has a taint this pod does not tolerate, and the three user nodes lack CPU. The cluster autoscaler
(`NotTriggerScaleUp`) says why it will not add a node: when this was captured the `user` pool was already at its
maximum of 3 nodes, so it reported `max node group size reached`. Below the maximum it would still not add a node: the autoscaler simulates the
pending pod on a new node of the pool's VM size, and 3 CPUs do not fit on 2 vCPUs. More nodes of the same size
never help; the fix is a smaller request or a node pool with
bigger VMs. `kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml` shows the autoscaler's view
of each node group (lab 07 step 8).

```bash
kubectl delete pod too-big -n lab-c-trouble
```

## 7. Readiness never passes: the probe checks the wrong port

The app listens on 8080. A readiness probe on 9090 never succeeds, so the new pod never becomes Ready.

```bash
kubectl patch deploy/payments-api -n lab-c-trouble --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":9090}]'
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api -o wide
POD=$(kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api --no-headers | awk '$2=="0/1"{print $1; exit}')
kubectl events -n lab-c-trouble --for pod/$POD | grep -E 'REASON|Unhealthy'
kubectl get endpointslices -n lab-c-trouble -l kubernetes.io/service-name=payments-api \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" pod="}{.targetRef.name}{"\n"}{end}'
```

```output
deployment.apps/payments-api patched
NAME                            READY   STATUS    RESTARTS   AGE     IP             NODE                           NOMINATED NODE   READINESS GATES
payments-api-7498d98764-4h2t5   1/1     Running   0          6m57s   10.244.3.69    aks-user-25795745-vmss000002   <none>           <none>
payments-api-7498d98764-n9d8t   1/1     Running   0          6m57s   10.244.1.179   aks-user-25795745-vmss000000   <none>           <none>
payments-api-7d7d55d587-8wwvl   0/1     Running   0          5s      10.244.1.33    aks-user-25795745-vmss000000   <none>           <none>
LAST SEEN         TYPE      REASON      OBJECT                              MESSAGE
3s (x3 over 5s)   Warning   Unhealthy   Pod/payments-api-7d7d55d587-8wwvl   Readiness probe failed: Get "http://10.244.1.33:9090/readyz": dial tcp 10.244.1.33:9090: connect: connection refused
10.244.3.69 ready=true pod=payments-api-7498d98764-4h2t5
10.244.1.179 ready=true pod=payments-api-7498d98764-n9d8t
10.244.1.33 ready=false pod=payments-api-7d7d55d587-8wwvl
```

**What you are seeing:** `Running` with `0/1` READY means the process is up but the readiness check fails. The
event names the exact URL the kubelet probed, which shows the wrong port at a glance. The EndpointSlice still lists
the new pod, with `ready=false`, so the Service sends it no traffic. Because readiness never passes, the rollout
cannot continue; after `progressDeadlineSeconds` (120 here) the Deployment says so.

```bash
kubectl rollout status deploy/payments-api -n lab-c-trouble --timeout=10s
kubectl get deploy payments-api -n lab-c-trouble \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
kubectl rollout undo deploy/payments-api -n lab-c-trouble
```

```output
error: deployment "payments-api" exceeded its progress deadline
Available	True	MinimumReplicasAvailable	Deployment has minimum availability.
Progressing	False	ProgressDeadlineExceeded	ReplicaSet "payments-api-7d7d55d587" has timed out progressing.
deployment.apps/payments-api rolled back
```

**What you are seeing:** `Available=True` and `Progressing=False` together: users were never affected, but the
release failed. `kubectl rollout status` exits non-zero, which is the signal a pipeline uses to roll back on its
own. A liveness probe on a wrong port would be worse: the kubelet would restart a healthy container forever.

## 8. No pods at all: admission refused them

Sometimes `kubectl get pods` shows nothing, and the Deployment sits at `0/1`. The error is on the ReplicaSet,
because the ReplicaSet controller is the client whose create request was refused. Here a plain `kubectl create
deployment` with no securityContext meets this namespace's Pod Security `restricted` label.

```bash
kubectl create deployment psa-demo -n lab-c-trouble --image=cgr.dev/chainguard/busybox:latest -- sleep 3600
kubectl get deploy psa-demo -n lab-c-trouble
kubectl get pods -n lab-c-trouble -l app=psa-demo
RS=$(kubectl get rs -n lab-c-trouble -l app=psa-demo -o jsonpath='{.items[0].metadata.name}')
kubectl events -n lab-c-trouble --for replicaset/$RS | tail -1
```

```output
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "busybox" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "busybox" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "busybox" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "busybox" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/psa-demo created
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
psa-demo   0/1     0            0           2s
No resources found in lab-c-trouble namespace.
0s          Warning   FailedCreate   ReplicaSet/psa-demo-5dc589cf94   (combined from similar events): Error creating: pods "psa-demo-5dc589cf94-c9qk7" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "busybox" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "busybox" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "busybox" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "busybox" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**What you are seeing:** the API server accepted the Deployment (with a warning, because the `warn` label is set)
and refused every pod. The message lists each field to add. A policy engine refuses pods the same way. While these
labs were written, the repo's Kyverno policies (`policy/kyverno/cluster`) were installed on the shared cluster for
another lab, and they apply to namespaces labelled `data-classification=pci` or `phi`. A Deployment in such a
namespace with an image from ACR got this, also on its ReplicaSet:

```output
Warning   FailedCreate   ReplicaSet/payments-api-6876d4f7fd   Error creating: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/lab-c-payments/payments-api-6876d4f7fd-fhqmw was blocked due to the following policies

restrict-image-registries:
  allowed-registries: 'validation error: Images must come from ghcr.io/sathpal/regulated-k8s-reference/* or cgr.dev/chainguard/*. rule allowed-registries failed at path /spec/containers/0/image/'
```

The webhook name tells you which admission controller refused (`validate.kyverno.svc-fail`), and the policy and
rule names tell you whom to talk to. Do not edit labels to get around such a policy; change the workload or ask the
policy owner for an exception.

```bash
kubectl delete deploy psa-demo -n lab-c-trouble
```

## 9. The Service answers nobody: a selector typo

`service-typo.yaml` creates a second Service whose selector says `payment-api` instead of `payments-api`.

```bash
kubectl apply -f aks/manifests/09/service-typo.yaml
kubectl get endpointslices -n lab-c-trouble
kubectl exec -n lab-c-trouble client -- curl -sS -m 3 http://payments-typo/version
kubectl describe svc payments-typo -n lab-c-trouble | grep -E 'Selector|Endpoints'
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payment-api
```

```output
service/payments-typo created
NAME                  ADDRESSTYPE   PORTS     ENDPOINTS                              AGE
payments-api-xfrsd    IPv4          8080      10.244.3.69,10.244.1.179,10.244.1.33   9m5s
payments-typo-rkbpr   IPv4          <unset>   <unset>                                2s
curl: (7) Failed to connect to payments-typo:80 after 160 ms: Could not connect to server
command terminated with exit code 7
Selector:                 app.kubernetes.io/name=payment-api
Endpoints:
No resources found in lab-c-trouble namespace.
```

**What you are seeing:** the Service exists and has a ClusterIP, so DNS resolves it, but its EndpointSlice is
empty. With nothing behind the IP, Cilium (which replaces kube-proxy on this cluster) rejects the connection at
once, so curl fails in 160 ms instead of timing out. Running the Service's own selector through
`kubectl get pods -l` proves the mismatch. (The third address in `payments-api-xfrsd` is the pod from step 7,
still terminating after the rollback.) Fix the selector and the endpoints appear:

```bash
kubectl patch svc payments-typo -n lab-c-trouble -p '{"spec":{"selector":{"app.kubernetes.io/name":"payments-api"}}}'
kubectl get endpointslices -n lab-c-trouble -l kubernetes.io/service-name=payments-typo
kubectl exec -n lab-c-trouble client -- curl -sS -m 3 http://payments-typo/version
kubectl delete svc payments-typo -n lab-c-trouble
```

```output
service/payments-typo patched
NAME                  ADDRESSTYPE   PORTS   ENDPOINTS                  AGE
payments-typo-rkbpr   IPv4          8080    10.244.3.69,10.244.1.179   13s
{"service":"payments-api","version":"1"}
service "payments-typo" deleted from lab-c-trouble namespace
```

## 10. A NetworkPolicy blocks traffic

This cluster runs Azure CNI powered by Cilium, which enforces Kubernetes NetworkPolicy. Apply a default deny for
the whole namespace, in both directions, and call the service again by name and by ClusterIP.

```bash
kubectl apply -f aks/manifests/09/netpol-deny.yaml
SVC_IP=$(kubectl get svc payments-api -n lab-c-trouble -o jsonpath='{.spec.clusterIP}')
kubectl exec -n lab-c-trouble client -- curl -sS -m 5 http://payments-api/version
kubectl exec -n lab-c-trouble client -- curl -sS -m 5 http://$SVC_IP/version
```

```output
networkpolicy.networking.k8s.io/default-deny created
curl: (28) Resolving timed out after 5001 milliseconds
command terminated with exit code 28
curl: (28) Connection timed out after 5001 milliseconds
command terminated with exit code 28
```

**What you are seeing:** two different failures from one policy. By name, curl never gets past DNS: egress to
CoreDNS on port 53 is denied too, so the first symptom of a default deny is often "DNS is broken". By IP, the
packets are dropped silently, so the client waits for its timeout. A timeout (not a refusal) is the fingerprint
of a policy drop; compare the instant refusal in step 9.

`netpol-allow.yaml` adds the two rules the call needs: egress from the client to CoreDNS and to payments-api on
8080, and ingress to payments-api from the client. To prove both sides matter, apply them, then remove the
ingress rule and try again.

```bash
kubectl apply -f aks/manifests/09/netpol-allow.yaml
kubectl exec -n lab-c-trouble client -- curl -sS -m 5 http://payments-api/version
kubectl delete networkpolicy payments-api-ingress -n lab-c-trouble
kubectl exec -n lab-c-trouble client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://payments-api/version
kubectl apply -f aks/manifests/09/netpol-allow.yaml
kubectl exec -n lab-c-trouble client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://payments-api/version
kubectl get networkpolicy -n lab-c-trouble
kubectl get pods -n lab-c-trouble -l app.kubernetes.io/name=payments-api
```

```output
networkpolicy.networking.k8s.io/client-egress created
networkpolicy.networking.k8s.io/payments-api-ingress created
{"service":"payments-api","version":"1"}
networkpolicy.networking.k8s.io "payments-api-ingress" deleted from lab-c-trouble namespace
curl: (28) Connection timed out after 5001 milliseconds
000
command terminated with exit code 28
networkpolicy.networking.k8s.io/client-egress unchanged
networkpolicy.networking.k8s.io/payments-api-ingress created
200
NAME                   POD-SELECTOR                          AGE
client-egress          app.kubernetes.io/name=client         7s
default-deny           <none>                                31s
payments-api-ingress   app.kubernetes.io/name=payments-api   6s
NAME                            READY   STATUS    RESTARTS   AGE
payments-api-7498d98764-4h2t5   1/1     Running   0          9m58s
payments-api-7498d98764-n9d8t   1/1     Running   0          9m58s
```

**What you are seeing:** with a default deny on both directions, a call needs an egress rule on the caller and an
ingress rule on the target; with either missing, the packets drop. The payments-api pods stayed `1/1 Ready`
throughout: the kubelet probes them from the node itself, and those probes kept passing under the default deny.
To see which policy dropped a flow you need flow logs; on AKS that is Hubble through Advanced
Container Networking Services, which this cluster does not enable. Without it, `kubectl get networkpolicy` and a
careful read of the selectors is the tool.

## 11. DNS from inside a pod

The client image (`cgr.dev/chainguard/curl:latest-dev`) has `curl` and a shell but no `nslookup`, so `curl -v`
does the lookups: it prints the address it resolved before it connects.

```bash
kubectl exec -n lab-c-trouble client -- cat /etc/resolv.conf
kubectl exec -n lab-c-trouble client -- sh -c 'curl -sv -m 3 -o /dev/null http://payments-api/version 2>&1 | grep -E "Trying|HTTP/1.1 [0-9]"'
kubectl exec -n lab-c-trouble client -- sh -c 'curl -sv -m 3 -o /dev/null http://payments-api.lab-c-trouble.svc.cluster.local./version 2>&1 | grep -E "resolved|IPv4|HTTP/1.1 [0-9]"'
kubectl exec -n lab-c-trouble client -- curl -sS -m 3 http://payments-apii/version
kubectl exec -n lab-c-trouble client -- sh -c 'curl -sv -m 4 -o /dev/null https://mcr.microsoft.com/v2/ 2>&1 | grep -E "resolved|IPv4|timed out"'
kubectl get svc kube-dns -n kube-system
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
kubectl get configmap -n kube-system | grep coredns
```

```output
search lab-c-trouble.svc.cluster.local svc.cluster.local cluster.local 2xmdylujbvhudped0v5qep5f5d.rx.internal.cloudapp.net
nameserver 10.0.0.10
options ndots:5
*   Trying 10.0.108.33:80...
< HTTP/1.1 200 OK
* Host payments-api.lab-c-trouble.svc.cluster.local.:80 was resolved.
* IPv4: 10.0.108.33
< HTTP/1.1 200 OK
curl: (6) Could not resolve host: payments-apii
command terminated with exit code 6
* Host mcr.microsoft.com:443 was resolved.
* IPv4: 150.171.69.10, 150.171.70.10
* Connection timed out after 4000 milliseconds
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
kube-dns   ClusterIP   10.0.0.10    <none>        53/UDP,53/TCP   45m
NAME                       READY   STATUS    RESTARTS   AGE   IP             NODE                             NOMINATED NODE   READINESS GATES
coredns-5d474ff6db-8wxcf   1/1     Running   0          41m   10.244.0.245   aks-system-11091932-vmss000000   <none>           <none>
coredns-5d474ff6db-pzj7n   1/1     Running   0          43m   10.244.0.59    aks-system-11091932-vmss000000   <none>           <none>
coredns                                                1      45m
coredns-autoscaler                                     1      41m
coredns-custom                                         0      45m
```

**What you are seeing:**

- `nameserver 10.0.0.10` is the `kube-dns` Service, backed by two CoreDNS pods on the system node pool. The last
  search domain is the Azure-provided internal DNS suffix of the nodes' virtual network.
- `ndots:5` means any name with fewer than five dots is tried with each search suffix first. `payments-api`
  resolves on the first suffix; an external name such as `mcr.microsoft.com` is tried against all four suffixes
  before it is sent as is, which is extra latency. A trailing dot (`...cluster.local.`) makes a name absolute and
  skips the search list.
- `Could not resolve host` (exit 6) is a DNS answer of "no such name"; compare `Resolving timed out` (exit 28) in
  step 10, which is DNS traffic being dropped.
- `mcr.microsoft.com` resolved (DNS egress is allowed) but the connection timed out: the client's egress policy
  allows only DNS and payments-api. DNS working does not mean the network path works.
- AKS manages the `coredns` ConfigMap; you can't change the main CoreDNS configuration. Custom zones, forwarders
  and logging go into `coredns-custom` (keys ending in `.server` or `.override`), which is empty here.

## 12. Authentication: what a missing Entra login looks like

kubectl on this cluster gets its token from `kubelogin`, which in `azurecli` mode asks the Azure CLI. To see a
missing login without touching your real setup, use a copy of the kubeconfig and an empty Azure CLI config
directory: `AZURE_CONFIG_DIR` points the Azure CLI at a different profile store, which has no accounts and no
token cache.

```bash
T=$(mktemp -d)
kubectl config view --minify --flatten > $T/config
mkdir -p $T/az
AZURE_CONFIG_DIR=$T/az KUBECONFIG=$T/config kubectl get pods -n lab-c-trouble
```

```output
Error: failed to get token: AzureCLICredential: ERROR: Please run 'az login' to setup account.

Unable to connect to the server: getting credentials: exec: executable kubelogin failed with exit code 1
```

**What you are seeing:** the failure happens before any request reaches the API server. `Unable to connect to the
server: getting credentials: exec: executable kubelogin failed` is kubectl's wording for "the credential plugin
failed", and the line above it is kubelogin's own reason. An expired Azure CLI session fails at the same step,
with the reason from `az` in that first line. The fix is on the client: `az login`. In `azurecli` mode kubelogin keeps no token cache of its own (the Azure
CLI manages the tokens); `kubelogin remove-cache-dir` matters for modes such as device code that do cache.

Two related failures you have already seen in these labs:

- **A kubeconfig still in device-code mode.** When `az aks check-acr` (step 3) ran without
  `AAD_LOGIN_METHOD=azurecli`, its fresh kubeconfig asked for a device-code sign-in and gave up:

  ```output
  To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code <code> to authenticate.
  Error: failed to get token: DeviceCodeCredential: server response error:
   context deadline exceeded
  Unable to connect to the server: getting credentials: exec: executable kubelogin failed with exit code 1 (Client.Timeout exceeded while awaiting headers)
  ```

  `kubelogin convert-kubeconfig -l azurecli` switches a kubeconfig to the Azure CLI login.
- **A static admin credential.** `az aks get-credentials --admin` fails with "Getting static credential is not
  allowed because this cluster is set to disable local accounts" (lab 00, step 3). That refusal is the point of
  disabling local accounts.

Authentication can succeed while authorization fails. Impersonating a non-Entra user shows how the Azure RBAC
webhook answers, and `kubectl auth whoami` shows who you really are:

```bash
kubectl get pods -n lab-c-trouble --as=nobody@example.com
kubectl auth whoami
```

```output
Error from server (Forbidden): pods is forbidden: User "nobody@example.com" cannot list resource "pods" in API group "" in the namespace "lab-c-trouble": Azure does not have opinion for this non AAD user. If you are an AAD user, please set Extra:oid parameter for impersonated user in the kubeconfig
ATTRIBUTE    VALUE
Username     <your-object-id>
Groups       [<group-id> system:authenticated]
Extra: oid   [<your-object-id>]
```

**What you are seeing:** `Forbidden` comes from the API server, so the token was fine and the request reached
authorization. With Azure RBAC, the decision is made by Azure against role assignments on the cluster, keyed by
the Entra object ID (`Extra: oid`); a user with no role on the cluster gets `Forbidden` the same way. Your
username is an object ID, not an email address, which matters when you read audit logs.

## 13. Triage flow, and what to collect before opening a support request

Work from the outside in, and stop at the first layer that explains the symptom:

1. **Client and identity.** Does `kubectl auth whoami` work? If not, it is kubelogin, `az login` or network
   access to the API server (step 12), not the workload.
2. **Platform state.** Is the cluster and every node pool `Succeeded` and `Running`, and is the API server ready?
3. **Nodes.** `kubectl get nodes`: all `Ready`? Any `SchedulingDisabled` (an upgrade or a drain in progress)?
4. **The workload's controller.** `kubectl get deploy,rs` and the ReplicaSet's events: no pods at all means
   admission (step 8) or quota.
5. **The pod's status.** `Pending` (step 6), `ImagePullBackOff` (steps 2 and 3), `CrashLoopBackOff` (step 4),
   `OOMKilled` (step 5), `Running` but `0/1` (step 7). Read `kubectl events --for pod/<name>` and
   `kubectl logs --previous`.
6. **The Service.** Does the EndpointSlice list ready addresses (step 9)?
7. **The network.** NetworkPolicy (step 10), then DNS (step 11), then egress to the outside.

```bash
az aks show -g $RG -n $AKS --query '{provisioningState:provisioningState, powerState:powerState.code, version:currentKubernetesVersion, sku:sku.tier, nodeResourceGroup:nodeResourceGroup, id:id}' -o json
az aks nodepool list -g $RG --cluster-name $AKS --query '[].{name:name, state:provisioningState, power:powerState.code, count:count, nodeImage:nodeImageVersion}' -o table
kubectl get --raw='/readyz?verbose' | tail -2
```

```output
{
  "id": "/subscriptions/<subscription-id>/resourcegroups/rg-aks-handson/providers/Microsoft.ContainerService/managedClusters/aks-handson",
  "nodeResourceGroup": "MC_rg-aks-handson_aks-handson_centralindia",
  "powerState": "Running",
  "provisioningState": "Succeeded",
  "sku": "Free",
  "version": "1.35.8"
}
Name    State      Power    Count    NodeImage
------  ---------  -------  -------  --------------------------------
system  Succeeded  Running  1        AKSAzureLinux-V3gen2-202609.15.0
user    Succeeded  Running  3        AKSAzureLinux-V3gen2-202609.15.0
[+]shutdown ok
readyz check passed
```

**What you are seeing:** the platform view. `provisioningState` other than `Succeeded` (for example `Failed`
after an upgrade) is Azure's side to explain, and `az aks operation show-latest -g $RG -n $AKS` shows the last
operation with its error. If all of this is healthy, the problem is almost always in what you deployed.

**Before you open an Azure support request, collect:**

- The cluster resource ID (above), region, Kubernetes version, node image version and pricing tier. The Free tier
  has no financially backed uptime SLA; that shapes what support can promise.
- The exact time window in UTC, and what changed just before it (a release, an upgrade, a policy, a role
  assignment).
- The failing `az` command with `--debug`, or the error and its correlation ID (like the ACR `CorrelationId` in
  step 3, or `az aks operation show-latest`).
- For workloads: `kubectl get events -A --field-selector type=Warning`, `kubectl describe` of the failing pod or
  node, `kubectl logs --previous`, and `kubectl get nodes -o wide`.
- What "Diagnose and solve problems" on the cluster's Azure portal page reports; it runs the same detectors
  support starts with.

## On AKS specifically

- **Registry access is a role assignment.** `--attach-acr` gives the kubelet managed identity `AcrPull` on the
  registry, using the permissions of whoever runs the command (Owner or an equivalent administrator role on the
  subscription, per the docs). `az aks check-acr` tests that identity from a node. Microsoft's image pull
  troubleshooting guide notes that a wrong image name can also surface as `401`, because the kubelet always tries
  an anonymous pull as well; read the first error.
- **Authentication is Entra ID plus kubelogin.** kubelogin supports several login modes (device code, Azure CLI,
  interactive, service principal, managed identity, workload identity). `az aks get-credentials` writes a
  device-code kubeconfig; `kubelogin convert-kubeconfig -l azurecli` switches it to your `az login`. With local
  accounts disabled there is no certificate-based fallback.
- **CoreDNS is managed.** The main CoreDNS configuration is not yours to change; your additions go into the
  `coredns-custom` ConfigMap in `kube-system`, followed by a restart of the `coredns` Deployment.
- **Network policy is enforced by Cilium.** With Azure CNI powered by Cilium, NetworkPolicy needs no separate
  engine. Flow-level visibility (Hubble) comes with Advanced Container Networking Services, a paid add-on.
- **Diagnostics are built in.** "Diagnose and solve problems" in the portal runs AKS detectors for the cluster,
  node pools, networking and identity without installing anything.

## In the conversation

**Why it matters in production.** On a managed cluster the platform rarely breaks; what breaks is the contract
between the workload and the platform: the tag, the registry role, the probe, the selector, the policy. Each
failure has a precise signal, and reading the right one first is the difference between a five-minute fix and an
escalation. Knowing where Azure's responsibility ends (control plane, node images, the kubelet identity) also tells
you when to open a ticket and what to put in it.

**A short story.** "Two pull failures in this lab showed the same `ImagePullBackOff`. One said `NotFound`, the
other only `401 Unauthorized`. The first was a tag nobody had pushed; the second was a registry the kubelet
identity had no `AcrPull` on, which `az aks check-acr` confirmed in one line. On the same day, `az aks check-acr`
itself stalled at a device-code prompt on our Entra-only cluster, because it writes a fresh kubeconfig in
device-code mode; `AAD_LOGIN_METHOD=azurecli` fixed it. I have also seen the 'not found' case in production
without anyone pushing a bad tag: an Artifactory repository deleted an older image when a tag was re-pushed, and a
pod pinned to it failed to pull on reschedule. Deploying by digest and setting retention rules closed that gap."

**Follow-up questions to expect**

- *ImagePullBackOff: how do you tell a wrong tag from missing permissions in under a minute?* Read the first
  error in the pod's events: `NotFound` means the registry answered and the reference is wrong; only `401
  Unauthorized` means the kubelet's identity was refused. `az aks check-acr` confirms the second case.
- *A pod is Running but gets no traffic. Where do you look?* READY first (`0/1` is a readiness failure, step 7),
  then the Service's EndpointSlice (empty means a selector problem, step 9), then NetworkPolicy (timeouts, step 10).
- *What does CrashLoopBackOff tell you?* Only that the container keeps exiting and the kubelet is backing off.
  The cause is in `kubectl logs --previous` and the exit code: 1 is the app, 137 is SIGKILL (often OOM).
- *Developers say "DNS is broken" after a security change. What do you check?* Whether a default-deny egress
  policy now blocks port 53 to CoreDNS. `Resolving timed out` is dropped DNS traffic; `Could not resolve host` is
  a real negative answer.
- *When do you open an Azure support request?* When the platform state is wrong (a failed provisioning state,
  nodes stuck `NotReady`, an API server that does not answer) or a managed component misbehaves. With the resource
  ID, UTC time window, correlation IDs and the events listed in step 13.

## If something looks different

- `az aks check-acr` prints a device-code prompt and then `KeyError: 'serverVersion'`: the temporary kubeconfig
  it downloads uses device-code login. With Azure CLI 2.90 the command converts `~/.kube/config` instead of that
  temporary file. Run it with `AAD_LOGIN_METHOD=azurecli`.
- `kubectl` warns that `v1 Endpoints is deprecated`: use EndpointSlices, as this lab does.
- Pods in your namespace are refused by `validate.kyverno.svc-fail`: a policy from another lab is still installed
  (step 8). Check `kubectl get clusterpolicy`.
- The Pending pod's autoscaler event gives a different reason than `max node group size reached`: your `user`
  pool was below its maximum, so the autoscaler explains why a new node would not fit the pod either.

## Clean up

```bash
kubectl delete namespace lab-c-trouble
rm -rf "$T"
az acr show -n acrlabc$SUFFIX -o none 2>/dev/null && az acr delete -g $RG -n acrlabc$SUFFIX --yes
```

The last line only matters if you skipped the delete in step 3.

## Checkpoint

1. Two pods show `ImagePullBackOff`. One event says `not found`, the other only `401 Unauthorized`. What do you
   check for each?
   _Hint: one is the image reference, the other is the kubelet identity's role on the registry (step 3)._
2. `curl` to a Service fails in 160 ms in one namespace and after 5 seconds in another. What do you suspect in
   each?
   _Hint: compare a Service without endpoints (step 9) with a dropped packet (step 10)._
3. A Deployment shows `0/3` and `kubectl get pods` returns nothing. Where is the error?
   _Hint: who creates the pods, and where does that controller record failures (step 8)?_

## Further reading

- [Authenticate with ACR from AKS, including check-acr (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/cluster-container-registry-integration)
- [Troubleshoot AKS image pull errors (learn.microsoft.com)](https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster)
- [Use kubelogin to authenticate in AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/kubelogin-authentication)
- [Customize CoreDNS for AKS (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/coredns-custom)
- [AKS diagnose and solve problems (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/aks-diagnostics)
- [Debug pods (kubernetes.io)](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Debugging DNS resolution (kubernetes.io)](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Pod Security Admission (kubernetes.io)](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
