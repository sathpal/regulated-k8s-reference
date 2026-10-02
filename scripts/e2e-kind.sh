#!/usr/bin/env bash
# End to end on a throwaway kind cluster, the same path a release takes to production:
#   build (tests run inside the build) -> load -> Kyverno + policies -> deploy both overlays ->
#   smoke test -> prove admission refuses bad workloads -> rehearse a failed release and the rollback.
# Needs docker, kind, kubectl, helm. Usage: scripts/e2e-kind.sh   (KEEP=1 keeps the cluster)
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=${CLUSTER:-regulated-ref}
REPO=ghcr.io/sathpal/regulated-k8s-reference
APPS=(payments-api patient-api)
step() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAILED: %s\033[0m\n' "$*"; exit 1; }

step "1. Build both images (unit tests run inside the build stage)"
for app in "${APPS[@]}"; do
  docker build -q --build-arg VERSION=e2e -t "$REPO/$app:e2e" "apps/$app"
  printf '%-14s %s  user=%s\n' "$app" "$(docker image inspect "$REPO/$app:e2e" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1048576}')" \
    "$(docker image inspect "$REPO/$app:e2e" --format '{{.Config.User}}')"
done

step "2. Cluster"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 3m
for app in "${APPS[@]}"; do kind load docker-image "$REPO/$app:e2e" --name "$CLUSTER" >/dev/null; done
kubectl config use-context "kind-$CLUSTER" >/dev/null
kubectl get nodes -o wide

step "3. Admission control: Kyverno and the cluster policies"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 10m >/dev/null
kubectl apply -f policy/kyverno/cluster/
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=180s

step "4. Deploy the bank and healthcare overlays"
kubectl apply -k k8s/overlays/e2e
kubectl -n bank-payments rollout status deploy/payments-api --timeout=180s
kubectl -n health-records rollout status deploy/patient-api --timeout=180s
kubectl get pods -A -l 'data-classification in (pci,phi)' \
  -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,READY:.status.containerStatuses[0].ready,USER:.spec.securityContext.runAsUser

step "5. Smoke test through the Services"
kubectl -n bank-payments port-forward svc/payments-api 18080:80 >/dev/null 2>&1 & PF1=$!
kubectl -n health-records port-forward svc/patient-api 18081:80 >/dev/null 2>&1 & PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
for i in $(seq 1 20); do curl -sf localhost:18080/readyz >/dev/null && curl -sf localhost:18081/readyz >/dev/null && break; sleep 1; done
PAY=$(curl -sf -X POST localhost:18080/v1/payments -H 'Idempotency-Key: e2e-1' -H 'X-Caller: e2e' \
  -d '{"amount_minor":125000,"currency":"INR","card_number":"4111111111111111"}')
echo "payment:  $PAY"
echo "$PAY" | grep -q '411111\*\*\*\*\*\*1111' || fail "card number not masked"
REC=$(curl -sf localhost:18081/v1/patients/p-1001 -H 'X-User: clerk.ana' -H 'X-User-Role: records-clerk')
echo "patient:  $REC"
echo "$REC" | grep -q notes && fail "clerk received clinical notes"
CODE=$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/v1/patients/p-1001)
echo "no role:  HTTP $CODE"; [ "$CODE" = 403 ] || fail "anonymous read was not refused"
echo "audit:    $(kubectl -n health-records logs deploy/patient-api --tail=50 | grep '"msg": "audit"' | tail -1)"

step "6. Admission refuses what policy forbids"
expect_denied() { # description manifest
  if out=$(echo "$2" | kubectl apply -f - 2>&1); then fail "$1 was admitted"; fi
  printf '%-34s refused: %s\n' "$1" "$(echo "$out" | grep -oE 'violates PodSecurity "restricted[^"]*"|allowed-registries|require-pinned-image|requests-limits-probes|classification-label' | sort -u | tr '\n' ' ')"
}
pod() { # name image label  -> a pod that passes Pod Security restricted, so only Kyverno can refuse it
cat <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: bank-payments, labels: { data-classification: "$3" } }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: app
      image: $2
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
      readinessProbe: { tcpSocket: { port: 8080 }, periodSeconds: 5 }
YAML
}
expect_denied "root pod (no security context)" "$(printf 'apiVersion: v1\nkind: Pod\nmetadata: { name: root-pod, namespace: bank-payments, labels: { data-classification: pci } }\nspec:\n  containers: [ { name: app, image: %s/payments-api:e2e } ]\n' "$REPO")"
expect_denied "image from Docker Hub" "$(pod hub-image python:3.13-slim pci)"
expect_denied "moving :latest tag" "$(pod latest-tag cgr.dev/chainguard/python:latest pci)"
expect_denied "no data-classification label" "$(pod no-label "$REPO/payments-api:e2e" "")"

step "7. A bad release is contained, then rolled back"
kubectl -n bank-payments set env deploy/payments-api FAIL_READINESS=true >/dev/null
if kubectl -n bank-payments rollout status deploy/payments-api --timeout=45s >/dev/null 2>&1; then fail "bad release became ready"; fi
kubectl -n bank-payments get deploy payments-api -o jsonpath='during the bad release: {.status.availableReplicas} of {.spec.replicas} replicas still available{"\n"}'
curl -sf -X POST localhost:18080/v1/payments -H 'Idempotency-Key: e2e-2' -d '{"amount_minor":500,"currency":"INR","card_number":"5555555555554444"}' >/dev/null \
  && echo "payments still served during the bad release" || fail "outage during the bad release"
kubectl -n bank-payments rollout undo deploy/payments-api
kubectl -n bank-payments rollout status deploy/payments-api --timeout=120s
kubectl -n bank-payments rollout history deploy/payments-api | tail -4

step "PASS"
if [ "${KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null && echo "cluster deleted"; fi
