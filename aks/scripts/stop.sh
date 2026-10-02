#!/usr/bin/env bash
# Stop the cluster between sessions: nodes are deallocated, the control plane is kept. Disks and ACR still bill.
set -euo pipefail; cd "$(dirname "$0")/.."; . ./.lab.env
az aks stop -g "$RG" -n "$AKS" && az aks show -g "$RG" -n "$AKS" --query powerState.code -o tsv
