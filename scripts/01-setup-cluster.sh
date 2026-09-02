#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">>> Creating kind cluster..."
kind create cluster --config 00-cluster/kind-config.yaml

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

echo ">>> Done. Cluster ready."
