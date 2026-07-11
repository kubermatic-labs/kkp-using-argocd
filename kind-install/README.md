# Local kind KKP bring-up

Everything is one script. Run it from a **real WSL terminal** (not
VSCode/Claude-Code-spawned — `sudo` needs a TTY).

## 1. Run it

```
./kind-install/run-local-kind.sh
```

Does everything, in order: pushes the ArgoCD values overlay (git, as your
user) → re-execs as root → starts/reuses the 4 registry-mirror containers →
(re)creates the kind cluster → installs ArgoCD → installs the
dex/cert-manager/nginx-ingress-controller ArgoCD Apps → installs the rest of
KKP → patches CoreDNS → applies the selfsigned issuer → applies the seed
kubeconfig + Seed CR → hands the kubeconfig back to your user.

Takes a few minutes. Watch the `[MM-DD HH:MM:SS]` log lines for progress.

## 2. Check it worked

```
export KUBECONFIG=./kind-install/kkp-local-kubeconfig

kubectl get application -n argocd            # dex/nginx-ingress-controller/cert-manager -> Synced, Healthy
kubectl get seed -n kubermatic kubermatic -o yaml   # look for phase: Healthy
kubectl get pods -A                           # nothing stuck Pending/CrashLoop
podman ps --filter name=kind-registry         # 4 mirrors running
```

Dashboard: printed at the end of the script (`https://kkp.<wsl-ip>.nip.io:8443`,
accept the self-signed cert warning). Login: `vijay@kubermatic.com` / `vj`.

## 3. Re-run / iterate

Just run `./kind-install/run-local-kind.sh` again — it deletes and recreates
the kind cluster every time, but the registry mirrors and their image cache
persist (not torn down), so repeat runs are faster.

If a run got past cluster creation but failed/timed out later (e.g. ArgoCD
was still cold-starting when a wait timed out), you don't have to lose the
cluster to retry — everything after cluster creation is idempotent:

```
RECREATE_CLUSTER=false ./kind-install/run-local-kind.sh
```

This reuses the existing kind cluster and just re-runs (and re-waits on)
every step against it.

## 4. (Optional) join a worker node to a user cluster

Create a `bringyourown` cluster (dashboard, or `kubectl apply -f
kind-install/test-cluster.yaml`), then:

```
./kind-install/join-usercluster-node.sh <cluster-name>
./kind-install/manage-usercluster-tunnels.sh <cluster-name> start
```

## 5. Clean up

```
./kind-install/cleanup.sh
```

No arguments — nukes everything: all joined worker node containers + their
volumes, all background tunnels, and the kind cluster itself. Registry
mirrors are deliberately left alone (they're the permanent cache) — the
script prints how to remove those too if you really want to.

## Troubleshooting

- `sudo: a terminal is required` → you're in a non-interactive shell; open a
  real terminal.
- ArgoCD Apps stuck `Progressing`/`Unknown` → `waitForArgoApps` already waits
  up to 8m per app (dex/nginx-ingress-controller/cert-manager) and prints
  `kubectl describe application ...` on timeout; read that output first. If
  it times out, re-run with `RECREATE_CLUSTER=false` (see above) instead of
  starting over.
- Full context / failure history: `kind-install/HANDOFF.md`.
