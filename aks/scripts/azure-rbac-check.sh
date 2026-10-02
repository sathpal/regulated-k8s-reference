#!/usr/bin/env bash
# Ask the API server what an Entra ID principal may do, through a SubjectAccessReview.
# With Azure RBAC the authorization webhook needs the principal's object ID in extra.oid,
# which `kubectl auth can-i --as` cannot set, so this script sends the review directly.
# Usage: aks/scripts/azure-rbac-check.sh <object-id> <verb> <resource> [namespace] [api-group]
set -euo pipefail
oid=$1 verb=$2 resource=$3 ns=${4:-} group=${5:-}
kubectl create -o jsonpath='{.status.allowed}{"  "}{.status.reason}{"\n"}' -f - <<YAML
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: "$oid"
  extra:
    oid: ["$oid"]
  resourceAttributes:
    verb: "$verb"
    group: "$group"
    resource: "$resource"
    namespace: "$ns"
YAML
