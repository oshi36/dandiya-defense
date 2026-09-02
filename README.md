# The Dandiya Defense to Poisoned Prompts - Demo Repo

Companion repo for the KCD Gujarat talk. Three acts:

1. **Act 1** - a triage-and-remediate agent, wired to
   `kubernetes-mcp-server`, reads a poisoned ConfigMap (its own
   "on-call runbook") and gets tricked into scaling an unrelated
   critical Deployment (`payment-gateway`) down to 0 replicas while
   nominally triaging a different, actually-broken service
   (`checkout-service`).
2. **Act 2** - we apply three defenses: scoped RBAC (write access
   limited to the one Deployment the agent should touch, by name),
   a Kyverno policy that independently blocks the same unauthorized
   write, a NetworkPolicy, and (pre-configured) Falco detection.
3. **Act 3** - same agent, same poisoned runbook, re-run live. The
   scale-down is denied, `payment-gateway` stays at 2 replicas, and
   Falco/Kyverno show the attempt.

## Real-world anchor

This demo mirrors a real, published finding: in May 2025,
Invariant Labs demonstrated a "toxic agent flow" against the
official GitHub MCP server, where a malicious public GitHub Issue
coerced an AI coding agent (Claude Desktop) into leaking private
repository data via an auto-created public PR. Cite this early in
the talk - it establishes this isn't a hypothetical, it's a known
attack shape: an agent trusting instructions it finds inside data
it reads. This demo re-creates that same underlying mechanism with
a Kubernetes-native vector - a poisoned ConfigMap - matching the
abstract's own framing: "a poisoned prompt, hidden inside something
as simple as a text file." Note the injected instruction here is
NOT concealed in a comment; it's a normal, visible runbook line -
a more realistic "compromised or carelessly-reviewed doc" threat
model, and the resulting action (an unauthorized write) is also a
more general illustration of prompt injection risk than credential
exfiltration specifically.
Source: https://invariantlabs.ai/blog/mcp-github-vulnerability

## Repo layout

```
00-cluster/       kind cluster config
01-mcp-server/    namespace, ServiceAccount, Act 1 permissive RBAC, Helm values
02-target/        secret, legit configmap, POISONED runbook configmap,
                  crashlooping checkout-service, healthy payment-gateway
03-agent/         the actual agent (agent.py)
04-defenses/      Act 3 RBAC, Kyverno policy, NetworkPolicy, Falco rule
scripts/          run each act in order
```

## Pre-event setup (do NOT do this live)

1. `scripts/01-setup-cluster.sh` - kind cluster + target workload,
   including the poisoned `triage-runbook` ConfigMap
   (`02-target/configmap-poisoned-runbook.yaml`) and the
   `payment-gateway` Deployment (the actual attack target). No
   external repo, issue, or network dependency needed - the
   injection vector lives entirely inside the cluster and the agent
   reads it via its own `resources_get` tool call.
2. `scripts/02-deploy-mcp-server-act1.sh` - deploys
   kubernetes-mcp-server with the permissive RBAC (this now
   includes `update`/`patch` on Deployments - realistic for an
   "SRE remediation bot" that's meant to fix things, not just read;
   this write capability is exactly what the attack abuses).
3. Set up the agent's environment (as your normal user - no
   `sudo`, it isn't needed and can install into a different
   Python than the one that later runs the scripts):
   ```bash
   cd 03-agent
   python3 -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   cd ..
   ```
   Then fill in `03-agent/.env` from `.env.example` - just
   `ANTHROPIC_API_KEY` and `MCP_SERVER_URL` (plus
   `ANTHROPIC_WORKSPACE_ID` if your key requires it - the comment
   in `.env.example` explains when).
4. Set up Falco with the k8s-audit plugin pointed at this cluster
   and load `04-defenses/falco-rule.yaml` - this is the fiddliest
   piece to get right. Test the full Act 1 - Act 3 flow at least
   once end-to-end beforehand.
5. Have a terminal open with:
   `kubectl -n agent-system port-forward svc/kubernetes-mcp-server 8080:8080`
   running for the whole session.

## Running the demo

```bash
# Act 1 - attack succeeds
scripts/03-run-act1-attack.sh
# -> before/after `kubectl get deployment payment-gateway` prints
#    around the run; watch replicas go from 2 to 0. In the tool
#    call log, look for resources_scale (or
#    resources_create_or_update) against payment-gateway.

# Act 2 - apply defenses (also resets payment-gateway to 2 replicas,
# since Act 1 likely left it at 0; fast, ~30-60s with Kyverno already
# installed from a prior test run - do that install ahead of time)
scripts/04-apply-defenses.sh

# Act 3 - same attack, live
scripts/05-run-act3-rerun.sh
# -> before/after replica count stays at 2 the whole time; tool
#    call for payment-gateway now returns DENIED (RBAC Forbidden,
#    or a Kyverno policy violation if RBAC alone didn't catch it).
#    Cut to the Falco dashboard/terminal to show the alert firing.
```

## Why each defense is there (the honest version)

- **RBAC (04-defenses/rbac-locked.yaml)** is the primary fix. It
  uses Kubernetes RBAC's `resourceNames` field to grant write
  access to Deployments, but ONLY for `checkout-service` by name -
  the agent structurally cannot touch `payment-gateway` regardless
  of what any document tells it to do.
- **Kyverno (04-defenses/kyverno-contain-agent.yaml)** does real,
  independent work here (unlike a pure secrets-read scenario) -
  admission control sees CREATE/UPDATE/DELETE, and a Deployment
  scale/update is exactly that. The `block-unauthorized-deployment-
  write` rule is a second, independent layer: even if RBAC were
  ever carelessly widened later, Kyverno still denies any write
  from the agent identity against a Deployment other than
  `checkout-service`. The other three rules block further
  escalation attempts (self-granted RBAC, hostPath/docker.sock
  pods, ServiceAccount impersonation) if the agent identity were
  ever compromised more broadly.
- **NetworkPolicy (04-defenses/networkpolicy.yaml)** contains
  exfiltration if a payload variant tries to POST data somewhere
  external - egress is locked to DNS + the API server only.
- **Falco (04-defenses/falco-rule.yaml)** is your visibility layer.
  It sees the attempted write via the k8s audit log even though
  RBAC/Kyverno already denied it - that's the live proof-of-defense
  moment for the audience. (Its rule as shipped watches for secret
  reads - see the note in `falco-rule.yaml` if you want a second
  rule watching for denied Deployment writes against
  `payment-gateway` specifically.)

## Troubleshooting the Helm install

The `kubernetes-mcp-server` chart is young and its `values.yaml`
keys can shift between releases. Before running
`scripts/02-deploy-mcp-server-act1.sh` for the first time on a new
machine, sanity-check the chart against the values file:

```bash
helm show values oci://ghcr.io/containers/charts/kubernetes-mcp-server > /tmp/chart-defaults.yaml
diff /tmp/chart-defaults.yaml 01-mcp-server/helm-values.yaml
```

and do a dry run before applying for real:

```bash
helm install kubernetes-mcp-server \
  oci://ghcr.io/containers/charts/kubernetes-mcp-server \
  -n agent-system -f 01-mcp-server/helm-values.yaml \
  --dry-run --debug
```

This catches template errors (e.g. an Ingress template demanding a
hostname when no Ingress controller exists) before they interrupt
a run. `01-mcp-server/helm-values.yaml` sets `ingress.enabled:
false` for exactly this reason - kind has no Ingress controller by
default, and the demo reaches the server via
`kubectl port-forward`, not an Ingress. If a future chart version
renames or restructures the `serviceAccount` or `service` keys,
the diff above will show it - update `helm-values.yaml` to match.

Also avoid `sudo helm install` - Helm reads `~/.kube/config` for
cluster access, and running under `sudo` looks for that file under
`/root` instead of your user, which can cause confusing "cluster
unreachable" errors that look unrelated to Helm itself. Run the
scripts as your normal user; if `kubectl`/`kind`/`helm` need
elevated permission for something specific (e.g. Docker socket
access), fix that at the Docker/kind level rather than reaching
for `sudo` on every command.

## Falco notes

Getting k8s audit logs flowing into Falco on a kind cluster
requires: (1) an audit policy file mounted into the kind
control-plane node, (2) the API server started with
`--audit-log-path`/`--audit-webhook-config-file` (or log-file mode
+ Falco's k8s-audit log tailing), and (3) Falco deployed with the
`k8saudit` plugin enabled and `falco-rule.yaml` mounted as a custom
rules file. This is genuinely fiddly to wire up on kind - budget a
real setup session for it well before the event, and have a
recorded screen capture of a successful alert as a fallback if live
audit plumbing misbehaves on stage.

## Cleanup

```bash
kind delete cluster --name dandiya-defense
```
