#!/usr/bin/env bash
set -euo pipefail; cd "$(dirname "$0")/.."; . ./.lab.env
az aks start -g "$RG" -n "$AKS" && kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool
