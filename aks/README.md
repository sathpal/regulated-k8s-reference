# AKS hands-on: every topic, done for real on Azure Kubernetes Service

Ten labs that take the two services in this repository (the bank's `payments-api` and the hospital's `patient-api`)
from a Dockerfile to a secured, observable, automatically delivered workload on AKS. Every command was run on a real
cluster and every output in the pages is the real output, including the failures and what fixed them.

| Lab | Topic | What you prove |
|---|---|---|
| [00](00-environment.md) | The environment | Why each `az aks create` flag matters: Entra ID with no local accounts, workload identity, Cilium overlay, tainted system pool, zones |
| [01](01-images-and-multistage.md) | Docker images and multi-stage builds | Naive vs multi-stage in ACR Tasks: 317.9 MB and 1,258 findings vs 3.4 MB and 0; tests run inside the build; ACR Tasks and BuildKit |
| [02](02-containers-on-aks-nodes.md) | Containers | From a node shell: the container's process, namespaces, cgroup v2 limits, an OOM kill from both sides, capabilities, seccomp, user namespaces |
| [03](03-vms-and-aks-nodes.md) | Virtual machines | The scale sets, disks and node image under AKS; one kernel for every pod; what the instance metadata service exposes to a pod, and the fix |
| [04](04-build-sign-deploy.md) | Building and deploying images | Tags vs digests, tag locks, import vs signatures, how the kubelet identity pulls, signing with a Key Vault key, deploy by digest |
| [05](05-architecture.md) | Kubernetes architecture | The managed control plane, the konnectivity tunnel, every kube-system component, and one `kubectl apply` traced end to end through Cilium |
| [06](06-cicd-into-aks.md) | CI/CD into Kubernetes | GitHub Actions to AKS with OIDC and no secrets, scan gate, Key Vault signature, automatic rollback; Flux GitOps with drift correction and promotion by commit |
| [07](07-production.md) | Production on AKS | System and user pools, zones, QoS, a node drain under load with a PodDisruptionBudget, the cluster autoscaler, maintenance windows |
| [08](08-security.md) | Security and best practices | Azure RBAC per namespace, Key Vault secrets via workload identity, Pod Security restricted, Cilium network policy, Kyverno, signed images only |
| [09](09-troubleshooting.md) | Troubleshooting | ImagePullBackOff, CrashLoopBackOff, OOMKilled, Pending, readiness, empty Services, network policy, DNS and Entra login failures, reproduced and fixed |

## Running it

```bash
aks/scripts/create.sh       # about 15 minutes; names saved to aks/.lab.env
source aks/.lab.env
# ... labs in order; each ends with its own clean-up
aks/scripts/stop.sh         # between sessions: nodes deallocated
aks/scripts/start.sh
aks/scripts/destroy.sh      # deletes the resource group
```

Cost: about USD 0.30 an hour with three Standard_D2s_v5 nodes running (Free tier control plane), and about USD 2.50 a
day stopped (disks and registry). Lab 06 needs the repository on GitHub and the `gh` CLI.

## A 15-minute walkthrough

When presenting this work live, five moments carry most of the story:

1. **Lab 01, the comparison table.** Same app, two Dockerfiles: size, findings and user, all measured in Azure.
2. **Lab 02, `/proc/1/status` from the node.** What "non-root, no capabilities, seccomp on" looks like to the kernel.
3. **Lab 06, the bad release.** The pipeline ships a release whose readiness fails; old pods keep serving and the pipeline
   rolls back by itself. Then the Flux promotion: a one-line commit, live in under a minute.
4. **Lab 08, admission.** A signed image admitted, an unsigned one refused, and a pod reading a Key Vault secret that does
   not exist anywhere in Kubernetes.
5. **Lab 09, one failure diagnosed.** The event, the evidence, the fix, and how it would have been caught earlier.
