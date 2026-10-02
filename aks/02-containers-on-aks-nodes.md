# 02. Containers, seen from an AKS node

**Goal:** open a root shell on an AKS node and find what Kubernetes calls a "container": a Linux process with
namespaces, cgroup limits, a capability set, a seccomp filter and an overlay filesystem built from image layers.

**You need:** the AKS environment from `aks/scripts/create.sh` and `kubectl` signed in through kubelogin. About
40 minutes. No extra Azure cost: the lab runs four small pods on the existing `user` node pool and pulls public
images only (`ghcr.io`, `cgr.dev`).

_Outputs captured on 2 October 2026 on AKS 1.35.8 in Central India. Your digests, IPs and names will differ._

## Why this matters

Every security control you write into a pod spec (`runAsNonRoot`, `capabilities.drop`, `seccompProfile`,
`resources.limits`) ends up as a kernel setting on a node. When a pod is OOMKilled, refuses to start, or behaves
differently from a laptop, the fastest way to the truth is to look at the process on the node. On AKS the node is
an Azure VM that Microsoft builds and patches, but what runs on it is yours to inspect and to get right.

**What you will learn**

- How to get a root shell on an AKS node with `kubectl debug node/...` and what that debug pod is allowed to do
- How containerd, the shim and the pause container fit together, and how to read them with `crictl`
- Where a pod's resources become cgroup v2 files (`memory.max`, `cpu.max`, `cpu.weight`), and what an OOMKill looks like from both sides
- What a pod with no securityContext gets (root, 14 capabilities, no seccomp) compared with the restricted payments-api
- How user namespaces (`hostUsers: false`) map root in a container to an unprivileged uid on the node
- Where image layers live on the node and how they become a container's root filesystem

## 1. Deploy payments-api and a plain pod on one node

The lab uses the published payments-api image by digest. GHCR serves it anonymously, so the nodes pull it without
a secret. `aks/manifests/02/payments-api.yaml` keeps the hardened securityContext from `k8s/base` and adds a CPU
limit, so you can see both memory and CPU limits on the node. `plain-pod.yaml` sets nothing at all, and uses
`podAffinity` to land on the same node as payments-api, so one node shell sees both.

```bash
source aks/.lab.env
kubectl create namespace lab-b-node
kubectl apply -n lab-b-node -f aks/manifests/02/payments-api.yaml
kubectl apply -n lab-b-node -f aks/manifests/02/plain-pod.yaml
kubectl rollout status -n lab-b-node deploy/payments-api
kubectl get pods -n lab-b-node -o wide
```

```output
namespace/lab-b-node created
deployment.apps/payments-api created
pod/plain created
deployment "payments-api" successfully rolled out
NAME                            READY   STATUS    RESTARTS   AGE   IP             NODE                           NOMINATED NODE   READINESS GATES
payments-api-544db98bcb-shq2g   1/1     Running   0          56s   10.244.2.196   aks-user-25795745-vmss000001   <none>           <none>
plain                           1/1     Running   0          7s    10.244.2.31    aks-user-25795745-vmss000001   <none>           <none>
```

**What you are seeing:** both pods run on `aks-user-25795745-vmss000001`, instance 1 of the `user` node pool's
VM scale set. The pod IPs come from the overlay range `10.244.0.0/16`, not from the VNet. Without the affinity
rule the scheduler spread them over two nodes on the first try.

## 2. Open a root shell on the node

AKS nodes have no public IP and this cluster has no SSH key. `kubectl debug node/...` asks the API server for a
pod pinned to that node, with the host's PID, network and IPC namespaces and the node's root filesystem mounted at
`/host`. `--profile=sysadmin` makes it privileged, which `crictl` needs to talk to containerd. Always pass
`-n` so the pod lands in your namespace, not in `default`.

```bash
NODE=$(kubectl get pod -n lab-b-node -l app.kubernetes.io/name=payments-api -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$NODE -n lab-b-node --profile=sysadmin --image=cgr.dev/chainguard/wolfi-base -- sleep 3600
DBG=$(kubectl get pods -n lab-b-node -o name | grep node-debugger)
kubectl get $DBG -n lab-b-node -o yaml | grep -E 'privileged|host(PID|Network|IPC)|path: /$'
```

```output
Creating debugging pod node-debugger-aks-user-25795745-vmss000001-6wndx with container debugger on node aks-user-25795745-vmss000001.
      privileged: true
  hostIPC: true
  hostNetwork: true
  hostPID: true
      path: /
```

The rest of the lab runs commands on the node from your own terminal with a small helper. `chroot /host` makes the
node's own binaries (`crictl`, `ctr`, `jq`, `capsh`) available. If you prefer an interactive shell, run
`kubectl debug node/$NODE -n lab-b-node -it --profile=sysadmin --image=cgr.dev/chainguard/wolfi-base -- chroot /host bash`.

```bash
onnode() { kubectl exec -n lab-b-node "$DBG" -- chroot /host sh -c "$1"; }
onnode 'grep PRETTY_NAME /etc/os-release; uname -r; systemctl is-active containerd kubelet; crictl --version; cat /etc/crictl.yaml'
```

```output
PRETTY_NAME="Microsoft Azure Linux 3.0"
6.6.150.1-1.azl3
active
active
crictl version 1.34.0
runtime-endpoint: unix:///run/containerd/containerd.sock
```

**What you are seeing:** a privileged pod is root on the node. Anyone who can create pods like this in any
namespace owns every node, which is why Pod Security `restricted` (or an admission policy) belongs on application
namespaces. The node runs Azure Linux 3.0, and `crictl` is already installed at `/usr/bin/crictl` and pointed at
containerd's socket.

## 3. The node agents: containerd and the kubelet

The kubelet and containerd are plain systemd services. The kubelet's flags show the AKS defaults that shape every pod.

```bash
onnode 'ps -o pid,args -C containerd; systemctl cat kubelet | grep -E "ExecStart=|ExecStartPre=.*imds"'
onnode 'ps -o args= -C kubelet | tr " " "\n" | grep -E "cgroup-driver|container-runtime-endpoint|kube-reserved|eviction-hard|max-pods|protect-kernel"'
```

```output
    PID COMMAND
   2827 /usr/bin/containerd
ExecStartPre=/bin/bash /opt/azure/containers/ensure_imds_restriction.sh
ExecStart=/opt/bin/kubelet \
--container-runtime-endpoint=unix:///run/containerd/containerd.sock
--cgroup-driver=systemd
--eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%,pid.available<2000
--kube-reserved=cpu=100m,memory=2048Mi,pid=1000
--max-pods=250
--protect-kernel-defaults=true
```

**What you are seeing:** the kubelet talks to containerd over a Unix socket (the CRI) and lets systemd own the
cgroup tree. AKS reserves 100m CPU and 2048Mi memory for the node itself on this 2 vCPU, 8 GiB VM, and evicts pods
before free memory drops below 100Mi. The `ensure_imds_restriction.sh` step belongs to the IMDS restriction
feature you meet in lab 03.

## 4. Pods and containers through crictl

`crictl` talks to the same CRI socket the kubelet uses. Filter by the namespace label, because other teams' pods
run on the same node.

```bash
onnode 'crictl pods --namespace lab-b-node; crictl ps --label io.kubernetes.pod.namespace=lab-b-node'
```

```output
POD ID              CREATED              STATE               NAME                                               NAMESPACE           ATTEMPT             RUNTIME
7b0cf37ee1dd1       About a minute ago   Ready               node-debugger-aks-user-25795745-vmss000001-6wndx   lab-b-node          0                   (default)
842ac7b34c845       About a minute ago   Ready               plain                                              lab-b-node          0                   (default)
501fc75511b8b       2 minutes ago        Ready               payments-api-544db98bcb-shq2g                      lab-b-node          0                   (default)
CONTAINER           IMAGE               CREATED              STATE               NAME                ATTEMPT             POD ID              POD                                                NAMESPACE
81cba73d64f7c       7b5a864257d39       About a minute ago   Running             debugger            0                   7b0cf37ee1dd1       node-debugger-aks-user-25795745-vmss000001-6wndx   lab-b-node
6552905b87fd9       7b5a864257d39       About a minute ago   Running             shell               0                   842ac7b34c845       plain                                              lab-b-node
5257bfc159627       fb3c42d8f406e       2 minutes ago        Running             app                 0                   501fc75511b8b       payments-api-544db98bcb-shq2g                      lab-b-node
```

Now inspect the payments-api container. `crictl inspect` returns the OCI runtime spec that containerd handed to
`runc`; `jq` (installed on the node) picks the parts that matter.

```bash
APP=$(onnode 'crictl ps -q --label io.kubernetes.pod.namespace=lab-b-node --name "^app$"')
onnode "crictl inspect $APP | jq '{pid: .info.pid, imageRef: .status.imageRef, cgroupsPath: .info.runtimeSpec.linux.cgroupsPath, user: .info.runtimeSpec.process.user, noNewPrivileges: .info.runtimeSpec.process.noNewPrivileges, capabilities: .info.runtimeSpec.process.capabilities, seccomp: .info.runtimeSpec.linux.seccomp.defaultAction, readonlyRootfs: .info.runtimeSpec.root.readonly, namespaces: [.info.runtimeSpec.linux.namespaces[] | \"\(.type) \(.path // \"(new)\")\"]}'"
```

```output
{
  "pid": 7997,
  "imageRef": "ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd",
  "cgroupsPath": "kubepods-burstable-podc77c7044_090a_4b47_a826_d799ef786bcb.slice:cri-containerd:5257bfc1596271b50f0b737ea29186c85500a535be2586c3dbaa9fab8b2aae9e",
  "user": {
    "additionalGids": [
      65532
    ],
    "gid": 65532,
    "uid": 65532
  },
  "noNewPrivileges": true,
  "capabilities": {},
  "seccomp": "SCMP_ACT_ERRNO",
  "readonlyRootfs": true,
  "namespaces": [
    "pid (new)",
    "ipc /proc/7956/ns/ipc",
    "uts /proc/7956/ns/uts",
    "mount (new)",
    "network /proc/7956/ns/net",
    "cgroup (new)"
  ]
}
```

**What you are seeing:** every line of the pod's securityContext has a kernel-level twin. `runAsUser: 65532`
became uid and gid 65532; `drop: ["ALL"]` became an empty capability set; `allowPrivilegeEscalation: false`
became `noNewPrivileges`; `RuntimeDefault` became a seccomp filter whose default action is "return an error";
`readOnlyRootFilesystem` became a read-only root. The container gets its own PID, mount and cgroup namespaces but
joins the network, IPC and UTS namespaces of PID 7956, the pause container that holds the pod's sandbox.

## 5. One process, two PIDs

Find the process on the host and its parents.

```bash
APP_PID=$(onnode "crictl inspect -o go-template --template '{{.info.pid}}' $APP")
onnode "ps -o pid,ppid,user,args -p $APP_PID; ps -o pid,ppid,user,args --ppid \$(ps -o ppid= -p $APP_PID)"
onnode "grep -E '^(Name|Uid|NSpid):' /proc/$APP_PID/status"
```

```output
    PID    PPID USER     COMMAND
   7997    7932 65532    /usr/bin/payments-api
    PID    PPID USER     COMMAND
   7956    7932 65532    /pause
   7997    7932 65532    /usr/bin/payments-api
Name:	payments-api
Uid:	65532	65532	65532	65532
NSpid:	7997	1
```

**What you are seeing:** to the node, payments-api is PID 7997, a child of `containerd-shim-runc-v2` (PID 7932),
next to `/pause`. `NSpid: 7997 1` says the same process is PID 1 inside its own PID namespace. The shim, not
containerd, is the parent, so restarting containerd does not kill running containers.

Now look from the inside. payments-api ships on `cgr.dev/chainguard/static`, which has no shell:

```bash
kubectl exec -n lab-b-node deploy/payments-api -- sh
```

```output
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "b9dbfd07de4f4c77d52495e650e8eaf4b31af053d6f0b3b010f0f8b7ff8744de": OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

Attach an ephemeral debug container instead. `--target=app` puts it in the app container's PID namespace, and
`--profile=restricted` keeps it inside the pod's restricted settings (it runs as the pod's uid 65532).

```bash
POD=$(kubectl get pod -n lab-b-node -l app.kubernetes.io/name=payments-api -o name)
kubectl debug -n lab-b-node $POD --image=cgr.dev/chainguard/wolfi-base --target=app --profile=restricted -c peek \
  -- sh -c 'id; ps -o pid,user,args; ls /proc/1/root/usr/bin'
kubectl logs -n lab-b-node $POD -c peek
```

```output
Targeting container "app". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
uid=65532(nonroot) gid=65532(nonroot) groups=65532(nonroot)
PID   USER     COMMAND
    1 nonroot  /usr/bin/payments-api
   20 nonroot  sh -c id; ps -o pid,user,args; ls /proc/1/root/usr/bin
   27 nonroot  ps -o pid,user,args
payments-api
```

**What you are seeing:** inside the namespace the service is PID 1 and the only other processes are the debug
shell's. `/proc/1/root` shows the app container's filesystem: `/usr/bin` holds one file. This is how you debug a
distroless image without adding a shell to it. Ephemeral containers stay in the pod spec until the pod is replaced.

## 6. Namespaces, compared with the host

```bash
onnode "ls -l /proc/$APP_PID/ns | awk 'NR>1{print \$9, \$10, \$11}'; echo '--- host (PID 1)'; ls -l /proc/1/ns | awk 'NR>1{print \$9, \$10, \$11}'"
```

```output
cgroup -> cgroup:[4026532471]
ipc -> ipc:[4026532467]
mnt -> mnt:[4026532469]
net -> net:[4026532399]
pid -> pid:[4026532470]
pid_for_children -> pid:[4026532470]
time -> time:[4026531834]
time_for_children -> time:[4026531834]
user -> user:[4026531837]
uts -> uts:[4026532466]
--- host (PID 1)
cgroup -> cgroup:[4026531835]
ipc -> ipc:[4026531839]
mnt -> mnt:[4026531841]
net -> net:[4026531840]
pid -> pid:[4026531836]
pid_for_children -> pid:[4026531836]
time -> time:[4026531834]
time_for_children -> time:[4026531834]
user -> user:[4026531837]
uts -> uts:[4026531838]
```

**What you are seeing:** cgroup, ipc, mnt, net, pid and uts differ from the host, so the container has its own
view of those. `time` and `user` have the same inode numbers as the host. The same user namespace means uid 65532
in the container is uid 65532 on the node, and uid 0 in a container would be root on the node. Step 10 changes that.

## 7. Resources become cgroup v2 files

The pod asked for `cpu: 50m, memory: 64Mi` and is limited to `cpu: 250m, memory: 128Mi`. The kubelet uses the
systemd cgroup driver, so the path is a chain of `.slice` units ending in the container's `.scope`.

```bash
onnode 'stat -fc %T /sys/fs/cgroup'
CG=$(onnode "cut -d: -f3 /proc/$APP_PID/cgroup"); echo $CG
onnode "cd /sys/fs/cgroup$CG && grep -H . memory.max memory.swap.max memory.oom.group cpu.max cpu.weight"
```

```output
cgroup2fs
/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-podc77c7044_090a_4b47_a826_d799ef786bcb.slice/cri-containerd-5257bfc1596271b50f0b737ea29186c85500a535be2586c3dbaa9fab8b2aae9e.scope
memory.max:134217728
memory.swap.max:0
memory.oom.group:1
cpu.max:25000 100000
cpu.weight:11
```

Repeat for the plain pod, which set no resources:

```bash
PLAIN=$(onnode 'crictl ps -q --label io.kubernetes.pod.namespace=lab-b-node --label io.kubernetes.pod.name=plain')
PLAIN_PID=$(onnode "crictl inspect -o go-template --template '{{.info.pid}}' $PLAIN")
onnode "cat /proc/$PLAIN_PID/cgroup"
CG=$(onnode "cut -d: -f3 /proc/$PLAIN_PID/cgroup")
onnode "cd /sys/fs/cgroup$CG && grep -H . memory.max cpu.max cpu.weight"
kubectl get pods -n lab-b-node -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'
```

```output
0::/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod6dbbf17e_94e1_4b10_8555_9bfe510c25d5.slice/cri-containerd-6552905b87fd9f0aca7dd140834c594e6873cf24b2ac9dd0023972d5b6ead6dc.scope
memory.max:max
cpu.max:max 100000
cpu.weight:1
POD                                                QOS
node-debugger-aks-user-25795745-vmss000001-6wndx   BestEffort
payments-api-544db98bcb-shq2g                      Burstable
plain                                              BestEffort
```

**What you are seeing:** the node uses cgroup v2 (`cgroup2fs`). The 128Mi limit is `memory.max` = 134217728
bytes, and swap is off. The 250m CPU limit is `cpu.max` = 25000 microseconds of CPU time every 100000, a hard
quota the kernel enforces by throttling. The 50m request is a relative weight (`cpu.weight`), which only matters
when CPUs are contended. The kubelet passed `cpu_shares: 51` for that request; runc on this node converts shares to
weight with a non-linear formula, which is why the number is 11 and not a round fraction. The plain pod is
BestEffort: no memory ceiling of its own (`max`), no CPU quota and the lowest weight. It is also among the first
pods the kubelet evicts under memory pressure, because any usage is above its zero request. The reference
Deployment in `k8s/base` sets no CPU limit on purpose, so it gets `max 100000` and is never throttled; it keeps the
memory limit, because memory cannot be throttled, only reclaimed or killed.

## 8. Break it: an OOMKill, from both sides

`oom-pod.yaml` runs Python that allocates 10 MiB every half second under a 64Mi limit.

```bash
kubectl apply -n lab-b-node -f aks/manifests/02/oom-pod.yaml
sleep 30
kubectl logs -n lab-b-node memory-hog
kubectl get pod -n lab-b-node memory-hog -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
```

```output
allocated 10 MiB
allocated 20 MiB
allocated 30 MiB
allocated 40 MiB
allocated 50 MiB
allocated 60 MiB
{"terminated":{"containerID":"containerd://c44d2f7a9f1f16bb3f6922e7c02215d9618db819fc89f254817b5f52d91f74ea","exitCode":137,"finishedAt":"2026-10-02T14:14:06Z","reason":"OOMKilled","startedAt":"2026-10-02T14:14:03Z"}}
```

Now the node's side. The kernel logs the kill, and containerd records the OOM event it passed to the kubelet.

```bash
onnode 'dmesg -T | grep -E "oom-kill:constraint|Memory cgroup out of memory|memory.oom.group" | head -3 | cut -c1-400'
onnode 'journalctl -u containerd --since "-15 min" --no-pager | grep TaskOOM'
```

```output
[Fri Oct  2 14:14:07 2026] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=cri-containerd-c44d2f7a9f1f16bb3f6922e7c02215d9618db819fc89f254817b5f52d91f74ea.scope,mems_allowed=0,oom_memcg=/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-poda8b8a570_9d92_4702_aac3_9264b667146c.slice,task_memcg=/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-poda8b8a570_9d92_4702_aac
[Fri Oct  2 14:14:07 2026] Memory cgroup out of memory: Killed process 11342 (python) total-vm:86512kB, anon-rss:64640kB, file-rss:6144kB, shmem-rss:0kB, UID:65532 pgtables:192kB oom_score_adj:992
[Fri Oct  2 14:14:07 2026] Tasks in /kubepods.slice/kubepods-burstable.slice/kubepods-burstable-poda8b8a570_9d92_4702_aac3_9264b667146c.slice/cri-containerd-c44d2f7a9f1f16bb3f6922e7c02215d9618db819fc89f254817b5f52d91f74ea.scope are going to be killed due to memory.oom.group set
Oct 02 14:14:06 aks-user-25795745-vmss000001 containerd[2827]: time="2026-10-02T14:14:06.821383123Z" level=info msg="TaskOOM event container_id:\"c44d2f7a9f1f16bb3f6922e7c02215d9618db819fc89f254817b5f52d91f74ea\""
```

**What you are seeing:** the last log line said 60 MiB; the next 10 MiB allocation pushed the memory charged to
the container (`anon-rss:64640kB` plus page cache and kernel memory) past `memory.max`. The kernel's memory cgroup, not Kubernetes, killed the process with
SIGKILL, so the exit code is 128 + 9 = 137. `memory.oom.group: 1` kills every process in the container together,
so a half-dead container cannot linger. The constraint is `CONSTRAINT_MEMCG`: the node had plenty of free memory,
only this container ran out. The fix is never "remove the limit": measure the real peak (`kubectl top`, or
`memory.peak` in the cgroup), set the limit above it with headroom, and fix leaks in the code.

## 9. Default pod against restricted pod

Compare the security state of the two long-running processes.

```bash
for P in $APP_PID $PLAIN_PID; do
  onnode "ps -o pid=,user=,args= -p $P; grep -E '^(Uid|CapEff|NoNewPrivs|Seccomp):' /proc/$P/status; cat /proc/$P/attr/current; echo"
done
onnode "capsh --decode=00000000a80425fb"
kubectl get --raw /api/v1/nodes/$NODE/proxy/configz | jq '.kubeletconfig | {seccompDefault}'
```

```output
   7997 65532    /usr/bin/payments-api
Uid:	65532	65532	65532	65532
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
cri-containerd.apparmor.d (enforce)

   8396 root     sleep infinity
Uid:	0	0	0	0
CapEff:	00000000a80425fb
NoNewPrivs:	0
Seccomp:	0
cri-containerd.apparmor.d (enforce)

0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
{
  "seccompDefault": false
}
```

**What you are seeing:**

| | payments-api (restricted) | plain (nothing set) |
|---|---|---|
| uid on the node | 65532 | 0 (root, same user namespace as the host) |
| Effective capabilities | none | 14, including `cap_net_raw`, `cap_setuid`, `cap_dac_override` |
| `NoNewPrivs` | 1: setuid binaries cannot raise privileges | 0 |
| `Seccomp` | 2 (filter mode, containerd's default profile) | 0 (no filter: every syscall reaches the kernel) |
| AppArmor | containerd default profile, enforce | containerd default profile, enforce |

The plain pod gets no seccomp filter because the AKS kubelet runs with `seccompDefault: false`: a pod that does
not ask for `RuntimeDefault` runs `Unconfined`. AppArmor's default profile applies to both. The difference is
entirely what the pod spec asked for, which is why the Pod Security `restricted` level requires
`runAsNonRoot`, `drop: ["ALL"]`, `allowPrivilegeEscalation: false` and a seccomp profile.

## 10. Root inside, nobody outside: user namespaces

Some images must run as root inside the container. A user namespace keeps that root away from the node.
`userns-pod.yaml` is the plain pod with `hostUsers: false`.

```bash
kubectl apply -n lab-b-node -f aks/manifests/02/userns-pod.yaml
kubectl wait -n lab-b-node --for=condition=Ready pod/userns
kubectl exec -n lab-b-node userns -- sh -c 'id -u; cat /proc/self/uid_map'
U=$(onnode 'crictl ps -q --label io.kubernetes.pod.namespace=lab-b-node --label io.kubernetes.pod.name=userns')
U_PID=$(onnode "crictl inspect -o go-template --template '{{.info.pid}}' $U")
onnode "ps -o pid,user,args -p $U_PID; grep -E '^Uid:' /proc/$U_PID/status; ls -l /proc/$U_PID/ns/user /proc/1/ns/user"
```

```output
pod/userns created
pod/userns condition met
0
         0 1360199680      65536
    PID USER     COMMAND
  11823 1360199+ sleep infinity
Uid:	1360199680	1360199680	1360199680	1360199680
lrwxrwxrwx 1 root       root       0 Oct  2 14:11 /proc/1/ns/user -> user:[4026531837]
lrwxrwxrwx 1 1360199680 1360199680 0 Oct  2 14:14 /proc/11823/ns/user -> user:[4026532547]
```

**What you are seeing:** inside, the process is uid 0. On the node it is uid 1360199680, the start of a private
block of 65536 ids that the kubelet gave this pod. Its capabilities only count inside its own user namespace, so a
container escape lands as an unprivileged user. This works with no cluster setting on AKS 1.33 or later with Azure
Linux 3.0 or Ubuntu 24.04 nodes; this node is 1.35.8 on Azure Linux 3.0.

## 11. Image layers on the node

containerd keeps two copies of an image: the compressed blobs as pulled (the content store) and the unpacked
layers (snapshots). The kubelet and `crictl` see the image config; `ctr` sees the registry objects.

```bash
onnode 'crictl images | grep -E "IMAGE|ghcr.io/sathpal"'
onnode "crictl inspecti $(kubectl get pod -n lab-b-node -l app.kubernetes.io/name=payments-api -o jsonpath='{.items[0].spec.containers[0].image}') | jq '{size: .status.size, uid: .status.uid.value, entrypoint: .info.imageSpec.config.Entrypoint, diff_ids: .info.imageSpec.rootfs.diff_ids}'"
onnode 'ctr -n k8s.io images ls | grep ghcr.io/sathpal | awk "{print \$1, \$2}"'
```

```output
IMAGE                                                                                 TAG                                              IMAGE ID            SIZE
ghcr.io/sathpal/regulated-k8s-reference/payments-api                                  <none>                                           fb3c42d8f406e       3.61MB
{
  "size": "3605360",
  "uid": "65532",
  "entrypoint": [
    "/usr/bin/payments-api"
  ],
  "diff_ids": [
    "sha256:f4aefcbfe66901de891d856560ebd7a26c215503574a77003abf067afd54321a",
    "sha256:dd2f156d8f27bec6a9e3d868e273924b4f126d53d0599b2e9bb39684179d0916"
  ]
}
ghcr.io/sathpal/regulated-k8s-reference/payments-api@sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd application/vnd.oci.image.index.v1+json
```

Walk from the index the pod named, to the amd64 manifest, to the layer blobs on disk:

```bash
onnode 'IDX=sha256:ff5e2e64bbe2544d8015b1fa0da152353cc34a75c480e457328b19afca3483dd
M=$(ctr -n k8s.io content get $IDX | jq -r ".manifests[] | select(.platform.architecture==\"amd64\") | .digest"); echo $M
ctr -n k8s.io content get $M | jq "{config: .config.digest, layers: [.layers[] | {digest, size}]}"'
onnode 'ls -l /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/bb8fa58ec978821768266f0c728f5deffbceba0afcd8f819e906150f6ff268f1'
```

```output
sha256:d7db00774679f651d9351db91333f8cf10b1405e230dc75232da0ef9fb3e7c54
{
  "config": "sha256:fb3c42d8f406ef558e4ad6dc727ed6d167fb5a4985a4b7ce0f9d3e76dadcec39",
  "layers": [
    {
      "digest": "sha256:bb8fa58ec978821768266f0c728f5deffbceba0afcd8f819e906150f6ff268f1",
      "size": 607648
    },
    {
      "digest": "sha256:81563292c3c9b170a4d83f22048fa79e609f0ebdaec7b4a3e2455987d708080d",
      "size": 2994465
    }
  ]
}
-r--r--r-- 1 root root 607648 Oct  2 14:08 /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/bb8fa58ec978821768266f0c728f5deffbceba0afcd8f819e906150f6ff268f1
```

Finally, the container's root filesystem is an overlay mount that stacks those unpacked layers:

```bash
onnode "grep ' / / ' /proc/$APP_PID/mountinfo | cut -d' ' -f5,6; grep ' / / ' /proc/$APP_PID/mountinfo | tr ',' '\n' | grep dir="
onnode 'S=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots; find $S/296/fs -type f; ls $S/295/fs | tr "\n" " "; echo; du -sh $S/295/fs $S/296/fs $S/297/fs'
onnode 'du -sh /var/lib/containerd/io.containerd.content.v1.content /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs; crictl images -q | wc -l; crictl images | grep coredns'
```

```output
/ ro,relatime
lowerdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/296/fs:/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/295/fs
upperdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/297/fs
workdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/297/work
/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/296/fs/usr/bin/payments-api
bin dev etc home lib lib64 opt proc root run sbin sys tmp usr var 
5.5M	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/295/fs
6.7M	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/296/fs
8.0K	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/297/fs
6.2G	/var/lib/containerd/io.containerd.content.v1.content
13G	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
89
mcr.microsoft.com/oss/v2/kubernetes/coredns                                           v1.11.3-32                                       dd8ed7acb9ba7       29.6MB
mcr.microsoft.com/oss/v2/kubernetes/coredns                                           v1.12.1-25                                       8268d82d6cb03       32.7MB
mcr.microsoft.com/oss/v2/kubernetes/coredns                                           v1.13.1-20                                       b1b16649b9a06       34.7MB
mcr.microsoft.com/oss/v2/kubernetes/coredns                                           v1.14.3-11                                       b5f67887b4d3d       34.5MB
```

**What you are seeing:** the pod referenced a multi-platform index; containerd picked the amd64 manifest, whose
config digest `fb3c42d8f406e...` is the IMAGE ID `crictl` shows. The manifest lists two compressed layers (607,648
and 2,994,465 bytes); `diff_ids` are the digests of the same layers uncompressed. Snapshot 295 is the
`cgr.dev/chainguard/static` base (`/etc/passwd`, CA certificates, tzdata, no shell), snapshot 296 is the one file
the Dockerfile's `COPY` added, and 297 is the container's private writable layer, mounted read-only here because
of `readOnlyRootFilesystem`. The snapshot numbers on your node will differ. The node holds 89 images (6.2G of
blobs, 13G unpacked), and 78 of them come from `mcr.microsoft.com`: four CoreDNS versions sit on a user node that
runs no CoreDNS pod, because AKS bakes system images into the node image so that scaling and upgrades do not wait
for pulls. Everything other pods pulled lands here too. The kubelet garbage-collects images when the disk passes
85% (`--image-gc-high-threshold=85`).

## On AKS specifically

- **Node access is through the Kubernetes API.** AKS nodes have no public IP. Microsoft documents
  `kubectl debug node/...` with `chroot /host` as the way in, and `az aks machine list` to find node private IPs
  for SSH from inside the VNet. This cluster was created with `--no-ssh-key`, so the debug pod is the only door,
  and it is guarded by Kubernetes RBAC (here, Azure RBAC through Entra ID).
- **Container runtime:** Linux node pools use containerd (Kubernetes 1.19 and later). This node runs containerd
  2.2.4, `runc`, the systemd cgroup driver and cgroup v2 on Azure Linux 3.0.
- **Seccomp default:** the kubelet does not apply a seccomp profile unless the pod asks (`seccompDefault: false`
  above). AKS can set `seccompDefault: RuntimeDefault` per node pool through custom node configuration, which is a
  preview feature (`KubeletDefaultSeccompProfilePreview`). AKS supports only `RuntimeDefault` and `Unconfined` as
  default profiles; custom seccomp profiles are not supported. Set `seccompProfile: RuntimeDefault` in the pod spec
  instead, as payments-api does.
- **AppArmor:** enabled by default on the node OS; Azure Linux 3.0 supports it from the November 7, 2025 VHD
  release. Pods without an AppArmor profile get containerd's default (`cri-containerd.apparmor.d`, seen above).
- **User namespaces:** need Kubernetes 1.33 or later and Azure Linux 3.0 or Ubuntu 24.04 nodes; then
  `hostUsers: false` works without any cluster setting. Not available on Windows node pools.
- **Reserved resources:** on Kubernetes 1.29 and later AKS reserves the lesser of `20 MB x max pods + 50 MB` and
  25% of memory, plus a 100Mi eviction threshold. With `--max-pods=250` on an 8 GiB VM the 25% cap wins, which
  is the `memory=2048Mi` in the kubelet flags.

## In the conversation

**Why it matters in production.** A pod spec is a request; the node is where it becomes true or false. When a team
says "we run as non-root", the proof is `Uid:` and `CapEff:` in `/proc/<pid>/status` on the node, and on AKS any
pod that does not ask for seccomp runs without it. Memory limits are enforced by the kernel's memory cgroup, so an
OOMKill is a sizing or leak problem in the container, not a Kubernetes fault. Knowing where to look cuts a support
call from hours to minutes.

**A short story.** "On our AKS cluster I opened a node with `kubectl debug` and put two pods side by side. Our
payments service, built on a Chainguard static image, was uid 65532 with no capabilities and seccomp in filter
mode. A pod with an empty securityContext on the same node was root on the host, with 14 capabilities and no
seccomp filter at all, because the AKS kubelet defaults to unconfined. That image user matters too: on AKS,
`runAsNonRoot: true` once rejected a Chainguard image with 'image has non-numeric user (nonroot), cannot verify
user is non-root'. We changed the Dockerfile to `USER 65532`, and on the node the image config now shows uid 65532,
which the kubelet can check."

**Follow-up questions to expect**

- *Why did the container get exit code 137 and not an error from the app?* The kernel's memory cgroup killed it
  with SIGKILL when resident memory passed `memory.max` (128 + 9 = 137). The app never saw it coming, which is why
  the last log line was "allocated 60 MiB". `kubectl describe` shows `Reason: OOMKilled`, and `dmesg` on the node
  shows `CONSTRAINT_MEMCG`.
- *Should every container have a CPU limit?* A CPU limit becomes `cpu.max`, a hard quota that throttles even when
  the node is idle. The reference Deployment sets a CPU request for scheduling and a memory limit for safety, but no
  CPU limit, so it gets `cpu.max: max`. Teams that need strict tenancy add CPU limits on purpose and watch
  throttling metrics.
- *Is a container a security boundary?* It shares the node's kernel. The restricted settings shrink what a process
  can ask the kernel (no capabilities, a syscall filter, no privilege escalation), and a user namespace makes root
  inside an unprivileged uid outside, but a kernel bug is still shared. For a separate kernel per pod, AKS offers
  Pod Sandboxing (lab 03).
- *How do you debug an image with no shell?* `kubectl debug <pod> --target=<container>` adds an ephemeral
  container in the same PID namespace; `/proc/1/root` then shows the app's filesystem. On the node, `crictl
  inspect` and `/proc/<pid>` answer the rest.

## If something looks different

- `kubectl debug node/...` stays `Pending` or is refused: an admission policy (Pod Security `baseline` or
  `restricted` on the namespace, Kyverno or Azure Policy) blocks privileged pods. Run it in a namespace without
  those labels, or ask the platform team; that refusal is the policy working.
- `crictl inspect` prints `pid: 0`: the container exited. Use `crictl ps -a` and pick a running container.
- `cpu.weight` shows a different number for the same request: the conversion from CPU shares depends on the `runc`
  version in the node image. The request still sets the relative weight; only the scale differs.
- `hostUsers: false` fails with an error about user namespaces: the node pool runs an older Kubernetes version or
  OS (Ubuntu 22.04 or Azure Linux 2.0). Check `kubectl get nodes -o wide`.

## Clean up

```bash
kubectl delete namespace lab-b-node
```

This removes the node debug pod, the pods and the Deployment. The pulled images stay in the node's cache until the
kubelet's image garbage collection or the next node image upgrade removes them.

## Checkpoint

1. A pod spec has `resources.limits.cpu: 500m`. What do you expect in `cpu.max` on the node?
   _Hint: the period is 100000 microseconds; the quota is the limit's share of one CPU per period._
2. A pod with no securityContext runs on this cluster. Which of uid, capabilities, `NoNewPrivs` and seccomp do
   you expect, and which kubelet setting explains the seccomp value?
   _Hint: compare step 9 and the `configz` output._
3. Why does restarting containerd not restart running containers?
   _Hint: look at the parent PID of payments-api in step 5._

## Further reading

- [Connect to AKS cluster nodes (learn.microsoft.com)](https://learn.microsoft.com/azure/aks/node-access)
- [Secure container access: user namespaces, AppArmor, seccomp on AKS](https://learn.microsoft.com/azure/aks/secure-container-access)
- [Node resource reservations in AKS](https://learn.microsoft.com/azure/aks/node-resource-reservations)
- [About cgroup v2 (kubernetes.io)](https://kubernetes.io/docs/concepts/architecture/cgroups/)
- [User namespaces (kubernetes.io)](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)
- [Restrict a container's syscalls with seccomp (kubernetes.io)](https://kubernetes.io/docs/tutorials/security/seccomp/)
- [Debugging Kubernetes nodes with crictl (kubernetes.io)](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/)
- [Debugging distroless images (Chainguard Academy)](https://edu.chainguard.dev/chainguard/containers/troubleshooting/debugging-distroless-images/)
