#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../03-agent"

if [ "$(id -u)" -eq 0 ]; then
  echo "!!! Don't run this with sudo — it doesn't need root, and it" >&2
  echo "!!! can pick up a different Python/pip than your venv, which" >&2
  echo "!!! causes confusing ModuleNotFoundError failures." >&2
  exit 1
fi

if [ -d venv ]; then
  # shellcheck disable=SC1091
  source venv/bin/activate
fi

python3 -c "import anthropic" 2>/dev/null || {
  echo "!!! Dependencies not installed in this environment. Run:" >&2
  echo "      cd 03-agent && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt" >&2
  exit 1
}

echo ">>> ACT 3: re-running the SAME agent against the SAME poisoned runbook"
echo ">>> (expect: tool_call for payment-gateway returns DENIED — RBAC"
echo ">>>  Forbidden, or Kyverno policy violation — replicas stay at 2)"
echo
echo ">>> Before: kubectl -n prod get deployment payment-gateway"
kubectl -n prod get deployment payment-gateway 2>/dev/null || true
echo

python3 agent.py

echo
echo ">>> After: kubectl -n prod get deployment payment-gateway"
kubectl -n prod get deployment payment-gateway 2>/dev/null || true
