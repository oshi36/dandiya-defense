#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">>> Creating agent ServiceAccount..."
kubectl apply -f 01-mcp-server/serviceaccount.yaml

echo ">>> Applying ACT 1 permissive RBAC (includes get/list on secrets)..."
kubectl apply -f 01-mcp-server/rbac-permissive.yaml

echo ">>> Installing kubernetes-mcp-server via Helm..."
helm install kubernetes-mcp-server \
  oci://ghcr.io/containers/charts/kubernetes-mcp-server \
  -n agent-system \
  -f 01-mcp-server/helm-values.yaml

echo ">>> Waiting for rollout..."
kubectl -n agent-system rollout status deployment/kubernetes-mcp-server --timeout=120s

echo ">>> Port-forwarding to localhost:8080 (run this in a separate terminal for the demo):"
echo "    kubectl -n agent-system port-forward svc/kubernetes-mcp-server 8080:8080 &"
