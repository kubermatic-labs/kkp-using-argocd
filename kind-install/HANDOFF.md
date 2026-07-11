# Handoff: local KKP-on-kind, bringyourown worker node join

Context for a fresh chat session. Point a new Claude Code session at this
file to resume.

## Goal

Lightest-possible KKP install on a local kind cluster (podman on WSL2,
**rootful** — see "Decisions & fixes" below) — no AWS/kubeone/Vault. Base
master+seed bring-up works, full ArgoCD app stack (monitoring/logging/
backup/storage/IAP/userMLA) works, and a `bringyourown` worker node can join
a user cluster end to end (node `Ready`, cilium/coredns/konnectivity/
metrics-server all `Running`).

## What's done and working

- `run-local-kind.sh`: idempotent bring-up. Deletes/recreates the kind
  cluster (podman provider), installs ArgoCD, installs the KKP app stack
  through ArgoCD (dex/nginx/cert-manager/monitoring/logging/velero/minio/
  IAP/userMLA/metrics-server/seedSettings), then runs the KKP installer for
  what ArgoCD doesn't own, patches CoreDNS, applies the CA issuer, applies
  the Seed CR. Domain is `kkp.<WSL-IP>.nip.io` (auto-detected each run —
  see "Open items" for why this isn't static yet).
- `dev/local-kind/`: KubermaticConfiguration, Helm values, CA issuer, Seed
  manifest, KubermaticSettings, all templated with `__KKP_DOMAIN__`.
- `join-usercluster-node.sh <cluster-name> [worker-name]`: scripted
  bringyourown worker join, every fix below baked in. Confirmed working
  end-to-end.
- `manage-usercluster-tunnels.sh <cluster-name> {start|stop|status}`:
  backgrounded, PID-tracked `kubectl port-forward` tunnels (apiserver +
  konnectivity) so a joined cluster is usable without leaving foreground
  terminals open.
- `port-forward-usercluster.sh <cluster> [port] [service] [service-port]`:
  general-purpose foreground port-forward, for reaching any Service
  ad hoc — not tied to cluster lifecycle, not superseded by the tunnel
  manager above (which only covers the two fixed services a join needs).
- `registry-mirror.sh`: 4 persistent `registry:2` pull-through caches
  (docker/quay/registry.k8s.io/ghcr) so repeat `kind delete/create` cycles
  don't re-pull images. Survive `cleanup.sh`.
- `cleanup.sh`: tears down worker containers, tunnels, and the kind
  cluster. Leaves registry mirrors alone on purpose.

## Host-level prerequisites (one-time, stable across WSL restarts)

1. **bpffs mounted at `/sys/fs/bpf`** (needed because nested rootless
   mounts of bpffs are blocked — see rootful note below for why this
   matters less now, but the mount itself is still required):
   ```
   sudo mount -t bpf bpf /sys/fs/bpf
   echo "bpffs /sys/fs/bpf bpf rw,relatime 0 0" | sudo tee -a /etc/fstab
   ```
2. **memlock ulimit**: cilium's eBPF maps need to lock more memory than the
   default 64MB hard ulimit allows.
   ```
   echo '* soft memlock unlimited
   * hard memlock unlimited' | sudo tee /etc/security/limits.d/99-memlock.conf
   sudo sed -i 's/#DefaultLimitMEMLOCK=8M/DefaultLimitMEMLOCK=infinity/' /etc/systemd/system.conf
   sudo systemctl daemon-reexec
   ```
   In practice this config is unreliable to inherit (systemd-logind computes
   its own `RLIMIT_MEMLOCK` default of `RAM/8` for the login session,
   overriding it). Both `run-local-kind.sh` and `join-usercluster-node.sh`
   self-heal around this by calling `ulimit -H -l unlimited` directly once
   already running as root (root holds `CAP_SYS_RESOURCE`, so it can always
   raise its own hard limit regardless of what it inherited).
3. **pids_limit raised** — podman's per-container default (2048) isn't
   enough headroom for a single kind node standing in for kubelet +
   containerd + ~40 pods' worth of processes/threads at once (hit when the
   full ArgoCD app stack starts up together — surfaced as `kube-proxy`
   itself, and everything else, crash-looping with `fork/exec ...: resource
   temporarily unavailable`).
   ```
   # /etc/containers/containers.conf
   [containers]
   pids_limit = 16384
   ```
4. **Run from a real terminal, not VSCode/Claude-Code-spawned** — required
   only because `sudo`'s password prompt needs a real TTY (not for the
   ulimit anymore, per point 2).

**Verify rootful podman works before running the pipeline** (storage/config
may not be initialized if this host only ever ran rootless podman before):
`sudo podman info` and `sudo podman run --rm hello-world`.

## Decisions & fixes

**Rootful podman, not rootless.** Rootless podman hit a hard, structural
wall: cilium in `ebpf` proxy mode (kube-proxy replacement) needs to load
`cgroup`-attach eBPF program types, which requires `CAP_SYS_ADMIN` as
evaluated against the **host's initial user namespace** — a rootless
container is always in a non-initial user namespace, so this can never
pass, no matter what capabilities the container is granted. (Rootless also
separately can't bind ports <1024 or mount bpffs itself — both worked
around at the time, but moot now.) This is a testing-only setup, so the
tradeoff of a real root podman daemon was accepted over routing around each
symptom individually (e.g. `canal` CNI instead of cilium). `run-local-kind.sh`
and `join-usercluster-node.sh` both self-re-exec via `sudo -E` if not
already root — just run them normally, no need to prefix with `sudo`.
`run-local-kind.sh` chows the generated kubeconfig back to the invoking
user at the end so plain `kubectl` calls afterward don't need root. A
rootful kind/podman instance is entirely separate storage from a rootless
one — if switching a host over, delete the old rootless cluster first to
free its host port bindings.

**Domain and cert handling.** `*.127.0.0.1.nip.io` resolves to `127.0.0.1`
even inside pods (breaks kubermatic-api's self-call to its own dex issuer),
and Windows can't reach the WSL host via `127.0.0.1` at all on this machine
(managed-network security software likely blocks WSL2 localhost-forwarding)
— but Windows **can** reach the WSL VM's own IP directly. So the domain
embeds the WSL host's real IP (`kkp.<WSL-IP>.nip.io`) instead of
`127.0.0.1`, with a CoreDNS `rewrite` rule so in-cluster callers resolve it
to the ingress Service rather than looping back to themselves. Certs: a
root `ca-issuer` (real `CA:TRUE` Certificate, `dev/local-kind/ca-issuer.yaml`)
rather than a plain `selfSigned` leaf — a self-signed *leaf* cert
(`CA:FALSE`) can never pass as its own trust anchor under standard TLS
verification, which is what IAP's oauth2-proxy needs when validating dex's
OIDC discovery endpoint. Every ingress sharing the OIDC-issuer hostname
(`dex` and `kubermatic`, same host/different paths) must use the same
issuer — nginx serves exactly one cert per hostname regardless of path, so
if only one of two ingresses on a shared host is repointed, the wrong cert
gets served and verification still fails.

**Cilium `proxyMode: ebpf` + `nodePortRange`.** Final working config is
`proxyMode: ebpf` (the CRD default) with **no** `componentsOverride.
apiserver.nodePortRange` set. That field doesn't do what it sounds like —
it configures the in-cluster kube-apiserver's `--service-node-port-range`
flag, not the apiserver-external Service's actual NodePort (which is
random and should be read back with `kubectl get cluster <name> -o
jsonpath='{.status.address.port}'`, then reached via `kubectl
port-forward` to that exact port — `kubeadm join`'s discovery step
enforces hostname/SAN TLS matching even with
`--discovery-token-unsafe-skip-ca-verification`, so it must hit the real
address the cert covers, not a raw container IP). Worse, a single-port
pseudo-range (`min == max`) makes cilium itself fatal with "NodePort range
min port must be smaller than max port" — and the field is immutable once
a cluster exists, so it must be right (i.e. absent) before creation, not
patched after.

**Worker node kubelet config** (`/etc/default/kubelet` on the joining
worker): `--fail-swap-on=false` (swap is host-wide, can't be disabled per
container) and `--feature-gates=KubeletInUserNamespace=true` (several
kernel-flag writes kubelet wants need real `CAP_SYS_ADMIN`, which a nested
container doesn't have — same feature gate kind sets for its own nodes).
bpffs is bind-mounted into the worker (`--volume /sys/fs/bpf:/sys/fs/bpf`)
rather than letting cilium's init container try to mount it itself, for
the same nested-namespace reason.

**Package installs skip apt.** `pkgs.k8s.io` hit persistent 403s from
CloudFront (likely rate-limiting). `join-usercluster-node.sh` instead
copies kubeadm/kubelet/kubectl binaries + kubelet systemd units directly
from the already-working seed node (`kkp-local-control-plane`) — no
external dependency, and version skew within the same minor is a non-issue
for kubeadm join.

**ArgoCD gitops overlay via a dedicated branch/tag, not a real push.**
This repo's own git remote is `kubermatic-labs/kkp-using-argocd`, the exact
`repoURL` the `kkp-argo-apps` chart points at. To avoid pushing this
working tree's in-progress state to `main` on every local run,
`pushGitopsValuesRef()` renders the `__KKP_DOMAIN__` templates and pushes
them (via a disposable `git worktree`, never touching the invoking user's
actual checkout) to a `local-kind-gitops` branch, tagged
`local-kind-kkp-v2.29.7` (force-pushed each run) — `environment: local-kind`
keeps this from colliding with the real `dev-kkp-v2.29.7` tag `ci.sh` uses.
Runs pre-`sudo`-re-exec since root has no access to the invoking user's git
credentials.

**Project + test cluster are ArgoCD-managed too**, via `seedExtras`
(`dev/local-kind/self/clusters/project.yaml` + `cluster.yaml`), same
mechanism `ci.sh` uses for `dev/demo-master/clusters/`. Fixed IDs (not
freshly generated) so they're reproducible across every kind-cluster
recreate.

**Diagnosing worker-node crash-loops before a CNI is up**: `kubectl logs`
doesn't work (konnectivity has no working agent until a CNI exists —
chicken-and-egg), and `.lastState.terminated.message` is truncated at 4096
bytes by Kubernetes itself. Get the full error via `podman exec <worker>
crictl logs <container-id>` on the worker directly. A crash-looping
install also triggers Helm's `atomic` auto-uninstall, which can wedge a
namespace in `Terminating` forever if cluster-wide API discovery is
simultaneously broken (e.g. a stale `metrics.k8s.io` APIService because
metrics-server itself is `Pending` for the same root cause) — deleting the
broken APIService often doesn't stick before it's recreated. What works:
force-clear the namespace's finalizers directly (`GET` the namespace JSON,
zero out `spec.finalizers`, `PUT` to `/api/v1/namespaces/<ns>/finalize`).

**Resource sizing**: nginx/dex trimmed to `replicaCount: 1` (chart defaults
3/2) with reduced `requests` (cpu 10-20m), matching the same
"demo-only" convention already used for the real kubeone-based envs in
`dev/values.yaml`. Confirmed via the installer binary's own symbol table
that `kubermatic-installer deploy kubermatic-master` only ever touches
kubermatic-operator/cert-manager/dex/envoy-gateway-controller/nginx/
storage-class/telemetry — monitoring/logging/MLA/velero/minio belong to
separate stacks this script never calls directly (they're all
ArgoCD-managed here instead).

**Gaps found comparing against `dev/demo-master` (which has all of this
working), now fixed**:
- No metrics-server — kubeone's default addon set installs it for free on
  the real kubeone-based envs; this script has no kubeone in its loop at
  all. Fixed by adding a `metricsServer` Application to the shared
  `kkp-argocd-apps` chart (first Application in that chart sourcing a real
  upstream Helm repo rather than the kubermatic/kubermatic git repo),
  gated `enable: false` by default, on for local-kind only, with
  `--kubelet-insecure-tls` (kind's kubelet serving certs aren't valid for
  TLS verification).

## Known non-blocking oddities

- kubeadm preflight warnings about swap and missing `hugetlb` cgroup are
  expected and harmless (swap becomes fatal only without
  `--fail-swap-on=false`, already handled; the working seed node lacks
  `hugetlb` too).

## Open items

1. **WSL IP isn't static** — see the domain/cert note above for why the
   domain embeds it. Investigated options for making it fixed so
   `values.yaml`/`k8cConfig.yaml` etc. could be static, committed files
   instead of re-rendered every run:
   - `.wslconfig` already has `networkingMode=mirrored` present but
     **commented out**. Mirrored mode would make WSL present the Windows
     host's own network adapter IP(s) directly instead of a NAT address on
     an internal vswitch that WSL recreates (and can renumber) on restart
     — plausibly far more stable, and might also fix the underlying
     Windows-can't-reach-127.0.0.1 issue this setup currently routes around
     with nip.io. **Not yet tried** — requires `wsl --shutdown` +
     Windows-side testing to confirm it actually holds a stable IP on this
     host and doesn't reintroduce the localhost-forwarding block for a
     different reason. Worth trying next.
   - No supported way to statically pin the NAT vswitch's own subnet/IP
     short of a fragile Windows-boot-time `netsh` script fighting Hyper-V's
     own IPAM — not recommended.
   - Fallback if mirrored mode doesn't pan out: cache the last-detected IP
     and only re-render/re-push the gitops overlay when it actually
     changes, rather than unconditionally every run. Reduces churn without
     needing a host networking change, but doesn't make the files
     statically editable the way a truly fixed IP would.
2. Confirm a full cold `run-local-kind.sh` run (not a live hand-patch)
   exercises the CA-issuer fix correctly from a clean cluster.
3. Confirm, on a fresh run, that `kubectl top nodes` works, the usercluster
   MLA toggle takes effect on a real test cluster, and the dashboard's left
   nav shows the new links.
