#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">>> Creating kind cluster (with audit logging enabled)..."
kind create cluster --config 00-cluster/kind-config.yaml

echo ">>> Verifying audit logging came up..."
CONTAINER_NAME="dandiya-defense-control-plane"
for i in $(seq 1 12); do
  if docker exec "$CONTAINER_NAME" test -s /var/log/kubernetes/audit/audit.log 2>/dev/null; then
    echo "    audit.log is present and non-empty."
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "!!! audit.log not found or empty after 60s - audit logging" >&2
    echo "!!! may not have started correctly. Debug with:" >&2
    echo "      kubectl -n kube-system get pods | grep apiserver" >&2
    echo "      kubectl -n kube-system logs kube-apiserver-${CONTAINER_NAME}" >&2
    echo "!!! Continuing setup anyway - this only affects the audit-trail" >&2
    echo "!!! visual, not the RBAC/Kyverno defenses themselves." >&2
    break
  fi
  sleep 5
done

echo ">>> Creating namespaces..."
kubectl apply -f 01-mcp-server/namespace.yaml

echo ">>> Creating target workload (prod ns)..."
kubectl apply -f 02-target/secret-prod-db.yaml
kubectl apply -f 02-target/configmap-app-readme.yaml
kubectl apply -f 02-target/configmap-poisoned-runbook.yaml
kubectl apply -f 02-target/deployment-crashlooping.yaml
kubectl apply -f 02-target/deployment-payment-gateway.yaml

echo ">>> Waiting for payment-gateway to be healthy (the thing that must NOT go to 0)..."
kubectl -n prod rollout status deployment/payment-gateway --timeout=60s

cat <<'EOF'

>>> Done. Cluster ready.
>>> In a separate terminal, start the audit-trail viewer (leave it
>>> running through Acts 1 and 3):
      scripts/tail-audit-log.sh
EOF