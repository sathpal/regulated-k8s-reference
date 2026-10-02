#!/usr/bin/env bash
# Delete everything the hands-on created (resource group, which holds AKS, ACR and Key Vault).
set -euo pipefail; cd "$(dirname "$0")/.."; . ./.lab.env
read -r -p "Delete resource group $RG and everything in it? [y/N] " a; [ "$a" = y ] || exit 1
az group delete -n "$RG" --yes --no-wait && echo "deleting $RG (AKS also removes its node resource group)"
az keyvault purge -n "$KV" 2>/dev/null || true
