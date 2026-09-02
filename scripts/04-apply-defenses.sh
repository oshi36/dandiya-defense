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
  helm repo add kyverno-helm https://kyverno.github.io/kyverno/ >/dev/null
  helm repo update >/dev/null
  helm install kyverno kyverno-helm/kyverno -n kyverno --create-namespace \
    --wait --timeout 180s
fi
echo ">>> Applying agent-containment Kyverno policy..."
kubectl apply -f 04-defenses/kyverno-contain-agent.yaml

cat <<'EOF'

>>> Falco setup is cluster/environment-specific (kind + the
>>> k8s-audit plugin needs the API server's audit webhook wired up
>>> and Falco deployed with the k8saudit plugin enabled). Do this
>>> as a pre-event setup step, not live — see README.md "Falco
>>> notes" for the outline, and load
>>> 04-defenses/falco-rule.yaml as a custom rules file.

>>> Defenses applied. Re-run scripts/05-run-act3-rerun.sh next.
EOF
