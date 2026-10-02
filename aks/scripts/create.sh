#!/usr/bin/env bash
# Create the AKS hands-on environment: resource group, ACR, AKS (Entra ID + Azure RBAC, workload identity,
# Azure CNI overlay with Cilium, Azure Linux nodes, system + user node pools across zones), and a Key Vault.
# Idempotent: re-running skips what exists. Names are saved to aks/.lab.env (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
ENVF=.lab.env; [ -f "$ENVF" ] && . "$ENVF"
LOC=${LOC:-centralindia}; RG=${RG:-rg-aks-handson}; AKS=${AKS:-aks-handson}
SUFFIX=${SUFFIX:-$(openssl rand -hex 3)}
ACR=${ACR:-acrregk8s$SUFFIX}; KV=${KV:-kv-regk8s-$SUFFIX}
printf 'LOC=%s\nRG=%s\nAKS=%s\nSUFFIX=%s\nACR=%s\nKV=%s\n' "$LOC" "$RG" "$AKS" "$SUFFIX" "$ACR" "$KV" > "$ENVF"
say() { printf '\n== %s\n' "$*"; }

say "subscription: $(az account show --query name -o tsv)   region: $LOC"
for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.KubernetesConfiguration; do
  az provider register -n "$p" -o none
done

say "resource group and registry"
az group create -n "$RG" -l "$LOC" --tags purpose=aks-handson -o none
az acr show -n "$ACR" -o none 2>/dev/null || az acr create -g "$RG" -n "$ACR" --sku Basic --admin-enabled false -o none

say "AKS control plane + system node pool"
if ! az aks show -g "$RG" -n "$AKS" -o none 2>/dev/null; then
  az aks create -g "$RG" -n "$AKS" -l "$LOC" --tier free \
    --nodepool-name system --node-count 1 --node-vm-size Standard_D2s_v5 --os-sku AzureLinux \
    --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
    --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
    --enable-oidc-issuer --enable-workload-identity \
    --enable-aad --enable-azure-rbac --disable-local-accounts \
    --attach-acr "$ACR" \
    --enable-addons azure-keyvault-secrets-provider \
    --auto-upgrade-channel patch --node-os-upgrade-channel NodeImage \
    --no-ssh-key \
    --tags purpose=aks-handson -o none
fi

say "user node pool across three zones, autoscaling 2 to 3"
az aks nodepool show -g "$RG" --cluster-name "$AKS" -n user -o none 2>/dev/null || \
  az aks nodepool add -g "$RG" --cluster-name "$AKS" -n user --mode User \
    --node-vm-size Standard_D2s_v5 --os-sku AzureLinux --zones 1 2 3 \
    --node-count 2 --enable-cluster-autoscaler --min-count 2 --max-count 3 -o none

say "Key Vault (RBAC authorization)"
az keyvault show -n "$KV" -o none 2>/dev/null || az keyvault create -g "$RG" -n "$KV" -l "$LOC" --enable-rbac-authorization true -o none

say "roles for the signed-in user: cluster admin through Azure RBAC, secrets officer on the vault"
ME=$(az ad signed-in-user show --query id -o tsv)
AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv); KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User --role "Azure Kubernetes Service RBAC Cluster Admin" --scope "$AKS_ID" -o none 2>/dev/null || true
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none 2>/dev/null || true

say "kubeconfig (Entra ID via kubelogin, using the az CLI login)"
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing -o none
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool -o wide
