#!/usr/bin/env bash
set -euo pipefail

# Tails the kind control-plane node's raw Kubernetes audit log,
# filtered to just the agent identity's writes to payment-gateway
# and checkout-service — exactly the events this demo cares about.
# No Falco, no webhook, no extra service to keep alive.
#
# Run this in its own terminal, started before Act 1 (or Act 3),
# and leave it running through the whole segment.
#
# Requires `jq` on your host (not in the container) —
# apt install jq / brew install jq.

CLUSTER_NAME="${CLUSTER_NAME:-dandiya-defense}"
CONTAINER_NAME="${CLUSTER_NAME}-control-plane"

echo ">>> Tailing audit log from ${CONTAINER_NAME}, filtered to the demo's identity/resources..."
echo ">>> (Ctrl-C to stop; this does not affect the cluster)"
echo

docker exec "${CONTAINER_NAME}" tail -F /var/log/kubernetes/audit/audit.log 2>/dev/null \
  | jq -c '
      select(
        (.user.username // "") == "system:serviceaccount:agent-system:k8s-mcp-server"
        and (.objectRef.resource // "") == "deployments"
        and ((.objectRef.name // "") == "payment-gateway" or (.objectRef.name // "") == "checkout-service")
      )
    ' \
  | jq -r '
      "\(.stageTimestamp)  verb=\(.verb)  name=\(.objectRef.name)  subresource=\(.objectRef.subresource // "-")  allowed=\(.annotations["authorization.k8s.io/decision"] // "unknown")  reason=\(.annotations["authorization.k8s.io/reason"] // "-")"
    '