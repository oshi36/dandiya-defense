# The Dandiya Defense to Poisoned Prompts - Demo Repo

Companion repo for the KCD Gujarat talk. Three acts, plus a bonus
comparison:

1. **Act 1** - a naive automation (`naive_agent.py`, no LLM) reads
   a poisoned ConfigMap (its own "on-call runbook"), mechanically
   parses an instruction out of it, and scales an unrelated
   critical Deployment (`payment-gateway`) down to 0 replicas - no
   judgment applied, just pattern -> action. This represents a very
   common real-world pattern (ChatOps bots, "runbook-as-code"
   executors) - not every automation you deploy is a reasoning
   agent.
2. **Act 2** - we apply three defenses: scoped RBAC (write access
   limited to the one Deployment the agent should touch, by name),
   a Kyverno policy that independently blocks the same unauthorized
   write, and a NetworkPolicy.
3. **Act 3** - same naive automation, same poisoned runbook,
   re-run live. The scale-down is denied, `payment-gateway` stays
   at 2 replicas, and the audit trail shows the attempt.


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
03-agent/         naive_agent.py (Act 1/3 - deterministic), agent.py (bonus - Claude reasoning)
04-defenses/      Act 3 RBAC, Kyverno policy, NetworkPolicy
scripts/          run each act in order
```

## Initial setup

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
4. Verify the audit-log-tail path works: `jq` is installed on your
   host, `scripts/tail-audit-log.sh` prints lines when you run Act
   1. No Falco install needed - see "Audit trail" below. Test the
   full Act 1 - Act 2 - Act 3 flow at least once end-to-end
   beforehand.
5. Have a terminal open with:
   `kubectl -n agent-system port-forward svc/kubernetes-mcp-server 8080:8080`
   running for the whole session.

## Running the demo

```bash
# Act 1 - attack succeeds (naive automation, no LLM)
scripts/03-run-act1-attack.sh
# -> before/after `kubectl get deployment payment-gateway` prints
#    around the run; watch replicas go from 2 to 0. In the log,
#    look for the resources_create_or_update call against
#    payment-gateway succeeding.

# Act 2 - apply defenses (also resets payment-gateway to 2 replicas,
# since Act 1 likely left it at 0; fast, ~30-60s with Kyverno already
# installed from a prior test run - do that install ahead of time)
scripts/04-apply-defenses.sh

# Act 3 - same attack, live
scripts/05-run-act3-rerun.sh
# -> before/after replica count stays at 2 the whole time; the
#    resources_create_or_update call now returns DENIED (RBAC
#    Forbidden, or a Kyverno policy violation if RBAC alone didn't
#    catch it). Cut to the tail-audit-log.sh terminal to show the
#    attempt logged.
```

![Demo Flow](https://github.com/oshi36/dandiya-defense/blob/master/image.png)

## Why each defense is there?

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
- **The audit trail (`scripts/tail-audit-log.sh`)** is your
  visibility layer. It reads the raw Kubernetes audit log directly
  - no Falco required - and shows the attempted write even though
  RBAC/Kyverno already denied it. That's the live proof-of-defense
  moment for the audience. Falco is an optional, more elaborate
  alternative that consumes this same audit stream - see "Falco
  (optional, advanced)" below if you specifically want it on stage.

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

## Audit trail - recommended approach (no Falco)

`00-cluster/kind-config.yaml` now enables Kubernetes audit logging
directly to a file on the control-plane node (see
`00-cluster/audit-policy.yaml`) - no Falco, no webhook, no extra
service to install or keep alive. This is the lowest-risk way to
show "we see the attempt in the audit trail even though it was
denied," which is all the talk actually needs from this layer.

Recreate your cluster after pulling this update (the audit flags
are set at cluster-creation time via kubeadm patches, so an
existing cluster won't pick them up):
```bash
kind delete cluster --name dandiya-defense
scripts/01-setup-cluster.sh
```

Then, in its own terminal, started before Act 1 or Act 3 and left
running through the segment:
```bash
scripts/tail-audit-log.sh
```
Requires `jq` on your host machine (`apt install jq` /
`brew install jq`) - not inside the cluster. Each line shows verb,
target name, and the RBAC `allowed`/`reason` - in Act 1 you'll see
`allowed=allow`, in Act 3 `allowed=forbid` for the same call
against `payment-gateway`. This is the single most reliable piece
of this whole repo to get working, and it's worth leaning on
instead of Falco unless you specifically want Falco on stage.

### Verify it's working before you rely on it live

```bash
docker exec dandiya-defense-control-plane ls -la /var/log/kubernetes/audit/
```
You should see `audit.log` with a non-zero, growing size. If it's
missing or empty, check the API server came up correctly:
```bash
kubectl -n kube-system get pods | grep apiserver
kubectl -n kube-system logs kube-apiserver-dandiya-defense-control-plane
```
A mount or flag typo in `kind-config.yaml` usually shows up here as
a CrashLoopBackOff or an explicit flag-parsing error in these logs.

### Reading the raw log directly (manual, no filtering)

Useful for debugging, or if you want to show the actual raw audit
entries rather than the filtered/formatted script output:
```bash
# Last 20 entries, pretty-printed
docker exec dandiya-defense-control-plane tail -n 20 /var/log/kubernetes/audit/audit.log | jq .

# Live, unfiltered tail
docker exec dandiya-defense-control-plane tail -F /var/log/kubernetes/audit/audit.log | jq .

# Just this demo's agent identity, any resource/verb
docker exec dandiya-defense-control-plane tail -F /var/log/kubernetes/audit/audit.log \
  | jq 'select(.user.username == "system:serviceaccount:agent-system:k8s-mcp-server")'

# Just the payment-gateway Deployment specifically, with the
# allow/deny decision picked out
docker exec dandiya-defense-control-plane tail -F /var/log/kubernetes/audit/audit.log \
  | jq 'select(.objectRef.name == "payment-gateway") | {verb, user: .user.username, allowed: .annotations["authorization.k8s.io/decision"], reason: .annotations["authorization.k8s.io/reason"]}'
```
`scripts/tail-audit-log.sh` is just the last of these, pre-filtered
and formatted as one line per event - reach for the raw commands
above if you want to show more detail on screen, or if you're
debugging why the filtered script isn't printing anything.

## Falco (optional, advanced - only if you specifically want it)

Falco just consumes the same audit stream the section above reads
directly, so it's not adding new detection capability for this
demo - only a nicer UI/alerting layer. Consider it optional. If you
still want it:

1. **Switch the kind config to webhook mode** instead of file mode
   (Falco's k8saudit plugin listens over HTTP as a webhook
   receiver, not by reading the file). Replace the
   `audit-log-path` args in `00-cluster/kind-config.yaml` with:
   ```yaml
   audit-policy-file: /etc/kubernetes/audit-policy.yaml
   audit-webhook-config-file: /etc/kubernetes/audit-webhook.yaml
   ```
   and add a second `extraMounts`/`extraVolumes` entry mounting a
   local `audit-webhook.yaml` (a kubeconfig-format file) to
   `/etc/kubernetes/audit-webhook.yaml`, containing:
   ```yaml
   apiVersion: v1
   kind: Config
   clusters:
     - name: falco
       cluster:
         server: http://<k8saudit-webhook-clusterIP>:9765/k8s-audit
   contexts:
     - name: falco
       context: {cluster: falco, user: ""}
   current-context: falco
   ```
   The ClusterIP isn't known until after Falco is installed
   (chicken-and-egg on a single-cluster setup) - easiest fix is to
   install Falco first with a placeholder, grab the real ClusterIP
   with `kubectl get svc -n falco k8saudit-webhook`, update the
   webhook config file, then `kind delete cluster` and recreate
   with the correct IP baked in. Budget real setup time for this.

2. **Install Falco via Helm**, configured for the k8saudit plugin
   (no kernel driver needed - webhook mode, not syscalls):
   ```bash
   helm repo add falcosecurity https://falcosecurity.github.io/charts
   helm repo update
   ```
   with a values file along these lines:
   ```yaml
   driver:
     enabled: false
   controller:
     kind: deployment
     deployment:
       replicas: 1
   falcoctl:
     artifact:
       install:
         enabled: true
       follow:
         enabled: true
     config:
       artifact:
         install:
           refs: [k8saudit-rules:latest, k8saudit:latest, json:latest]
         follow:
           refs: [k8saudit-rules:latest]
   services:
     - name: k8saudit-webhook
       type: ClusterIP
       ports:
         - port: 9765
           protocol: TCP
   falco:
     rules_files:
       - /etc/falco/k8s_audit_rules.yaml
       - /etc/falco/rules.d
     plugins:
       - name: k8saudit
         library_path: libk8saudit.so
         open_params: "http://:9765/k8s-audit"
       - name: json
         library_path: libjson.so
     load_plugins: [k8saudit, json]
   ```
   ```bash
   helm install falco falcosecurity/falco -n falco --create-namespace -f values-k8saudit.yaml
   ```
   The demo's own custom rule isn't shipped as a file anymore (the
   repo uses the audit-log approach above instead) - if you want a
   Falco rule specifically for this attack, write one along these
   lines and mount it the same way, via a ConfigMap and the chart's
   `customRules` values key (check `helm show values
   falcosecurity/falco` for the exact current key name, since this
   chart evolves):
   ```yaml
   - rule: Agent Identity Attempted Unauthorized Deployment Write
     desc: >
       Detects the k8s-mcp-server agent ServiceAccount attempting
       to update/patch any Deployment other than checkout-service.
     condition: >
       ka and ka.target.resource = "deployments" and
       (ka.verb in (update, patch)) and
       ka.user.name = "system:serviceaccount:agent-system:k8s-mcp-server" and
       ka.target.name != "checkout-service"
     output: >
       Agent identity attempted unauthorized Deployment write
       (user=%ka.user.name verb=%ka.verb name=%ka.target.name
       allowed=%ka.auth.allowed reason=%ka.auth.reason)
     priority: CRITICAL
     source: k8s_audit
   ```

3. **Verify**: `kubectl logs -n falco -l app.kubernetes.io/name=falco -f`
   should show `Loaded event sources: k8s_audit` on startup, then
   your custom rule firing when the agent's denied write happens.

This is genuinely fiddly and the values-file keys above can drift
between chart versions - treat it as a stretch goal, test it fully
at least once well before the event, and fall back to
`scripts/tail-audit-log.sh` (Path A above) if it's not behaving
cleanly close to showtime.

## Cleanup

```bash
kind delete cluster --name dandiya-defense
```
