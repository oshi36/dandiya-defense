#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">>> Removing ACT 1 permissive RBAC..."
kubectl delete -f 01-mcp-server/rbac-permissive.yaml --ignore-not-found

echo ">>> Applying scoped RBAC (write access limited to checkout-service by name)..."
kubectl apply -f 04-defenses/rbac-locked.yaml

echo ">>> Resetting payment-gateway to 2 replicas (Act 1 may have scaled it to 0)..."
kubectl -n prod scale deployment payment-gateway --replicas=2
kubectl -n prod rollout status deployment/payment-gateway --timeout=60s

echo ">>> Applying NetworkPolicy (egress lockdown)..."
kubectl apply -f 04-defenses/networkpolicy.yaml

echo ">>> Installing Kyverno (if not already installed)..."
if ! kubectl get ns kyverno >/dev/null 2>&1; then
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
  helm repo update >/dev/null
  helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
    --wait --timeout 180s
fi
echo ">>> Applying agent-containment Kyverno policy..."
kubectl apply -f 04-defenses/kyverno-contain-agent.yaml

cat <<'EOF'

>>> Audit trail: scripts/tail-audit-log.sh (started separately, in
>>> its own terminal) gives you the "we saw the attempt" proof for
>>> Act 3 - no Falco needed. See README.md "Audit trail" section.
>>> Falco itself is optional/advanced - see README.md "Falco
>>> (optional, advanced)" if you specifically want it on stage.

>>> Defenses applied. Re-run scripts/05-run-act3-rerun.sh next.
EOF