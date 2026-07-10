#! /bin/bash
#
# Joins a fresh worker node container to a `bringyourown` KKP user cluster.
#
# Host prerequisites (one-time, see kind-install/HANDOFF.md for how these
# were discovered -- all are needed because the worker "node" is itself a
# nested container under rootless podman on WSL2, which is a much more
# constrained environment than a real VM/bare-metal kubeadm node):
#  - bpffs mounted at /sys/fs/bpf on the WSL host (`sudo mount -t bpf bpf
#    /sys/fs/bpf`, persisted via /etc/fstab). Cilium's mount-bpf-fs init
#    container can't create this mount itself from inside a nested rootless
#    container (permission denied), but CAN use one already mounted on the
#    host if it's bind-mounted in.
#  - memlock ulimit raised system-wide (cilium's eBPF maps need to lock more
#    memory than the WSL default 64MB hard limit allows, and a container can
#    never exceed its parent's hard limit no matter what --ulimit says at
#    `podman run` time). Requires a fresh login session to take effect after
#    changing /etc/security/limits.d and /etc/systemd/system.conf.
#
# The user cluster's apiserver-external Service gets a random NodePort
# (componentsOverride.apiserver.nodePortRange does NOT control this -- that
# field configures the in-cluster kube-apiserver's own --service-node-port-
# range flag, a completely different thing, confirmed by testing). Rather
# than fight that, this script starts its own `kubectl port-forward` (against
# the always-reachable seed apiserver) on the WSL host, bound to the exact
# same port number the cluster's admin-kubeconfig already expects -- so the
# kubeconfig and the printed join command both work completely unmodified,
# fully TLS-verified (the apiserver's cert covers the WSL host's own IP,
# which is exactly what gets connected to).
#
# The worker node is a standalone podman container (kindest/base: systemd +
# containerd, same nested-container plumbing kind's own nodes use, but
# without kind's ~1-2GB of pre-pulled control-plane images). kubeadm/kubelet/
# kubectl are copied directly from the already-working seed node
# (kkp-local-control-plane) rather than apt-installed -- no external network
# dependency, faster, and version skew within the same minor is a complete
# non-issue for kubeadm join.
#
# Usage: ./kind-install/join-usercluster-node.sh <cluster-name> [worker-name]
set -euo pipefail

# Rootful podman required -- see the matching re-exec block and comment in
# run-local-kind.sh, and kind-install/HANDOFF.md failure-history item 11.
if [ "$(id -u)" -ne 0 ]; then
  echo "Re-executing as root (rootful podman needed, see kind-install/HANDOFF.md)."
  exec sudo -E "$0" "$@"
fi

cd "$(dirname "$0")/.."

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [worker-name]}"
WORKER_NAME="${2:-kkp-worker-${CLUSTER_NAME}}"
BASE_IMAGE="docker.io/kindest/base:v20260601-995e8fa5"
SEED_NODE="kkp-local-control-plane"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kkp-local}"
export KUBECONFIG="./kind-install/${KIND_CLUSTER_NAME}-kubeconfig"
NAMESPACE="cluster-${CLUSTER_NAME}"
SCRATCH="$(mktemp -d)"
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echodate() {
  echo "[$(date +"%m-%d %T")] $*"
}

echodate "Checking host prerequisites."
if ! mount | grep -q "/sys/fs/bpf type bpf"; then
  echodate "ERROR: bpffs is not mounted at /sys/fs/bpf on the host."
  echodate "  Run: sudo mount -t bpf bpf /sys/fs/bpf"
  echodate "  And persist it: echo 'bpffs /sys/fs/bpf bpf rw,relatime 0 0' | sudo tee -a /etc/fstab"
  exit 1
fi
MEMLOCK_LIMIT="$(ulimit -Hl)"
if [ "$MEMLOCK_LIMIT" != "unlimited" ]; then
  echodate "WARNING: memlock hard ulimit is '${MEMLOCK_LIMIT}' (not unlimited)."
  echodate "  Cilium's eBPF maps may fail with 'failed to set memlock rlimit: operation not permitted'."
  echodate "  See kind-install/HANDOFF.md for how to raise it (needs a fresh login session)."
fi

K8S_VERSION="$(kubectl get cluster "${CLUSTER_NAME}" -o jsonpath='{.spec.version}')"
APISERVER_PORT="$(kubectl get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.address.port}')"
echodate "Cluster ${CLUSTER_NAME} is Kubernetes ${K8S_VERSION}, apiserver port ${APISERVER_PORT}."

echodate "Starting a temporary port-forward on 0.0.0.0:${APISERVER_PORT} (killed on exit)."
kubectl port-forward -n "$NAMESPACE" svc/apiserver-external --address 0.0.0.0 "${APISERVER_PORT}:443" >"${SCRATCH}/port-forward.log" 2>&1 &
PF_PID=$!
for i in $(seq 1 15); do
  curl -sk -o /dev/null "https://127.0.0.1:${APISERVER_PORT}/healthz" && break
  sleep 1
done

echodate "Fetching admin kubeconfig and kubeadm/kubelet/kubectl binaries + kubelet systemd units from ${SEED_NODE}."
kubectl get secret admin-kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.kubeconfig}' | base64 -d >"${SCRATCH}/admin-kubeconfig.yaml"
mkdir -p "${SCRATCH}/k8s-bin"
for f in kubeadm kubelet kubectl; do
  podman cp "${SEED_NODE}:/usr/bin/$f" "${SCRATCH}/k8s-bin/$f"
  chmod +x "${SCRATCH}/k8s-bin/$f"
done
podman cp "${SEED_NODE}:/etc/systemd/system/kubelet.service" "${SCRATCH}/k8s-bin/kubelet.service"
podman cp "${SEED_NODE}:/etc/systemd/system/kubelet.service.d" "${SCRATCH}/k8s-bin/kubelet.service.d"
# podman cp preserves the source's ownership; kubelet.service.d comes out
# owned by the container's root UID (mapped to a subuid the host user
# doesn't own), which blocks the EXIT trap's `rm -rf "$SCRATCH"` later.
chmod -R u+rwX "${SCRATCH}/k8s-bin/kubelet.service.d"

echodate "Generating a fresh join command against the live cluster."
JOIN_CMD="$("${SCRATCH}/k8s-bin/kubeadm" token create --kubeconfig="${SCRATCH}/admin-kubeconfig.yaml" --print-join-command --ttl=1h)"
echodate "${JOIN_CMD}"

echodate "Launching worker node container '${WORKER_NAME}' (${BASE_IMAGE})."
podman rm -f "$WORKER_NAME" >/dev/null 2>&1 || true
podman volume rm "${WORKER_NAME}-var" >/dev/null 2>&1 || true
podman run -d --name "$WORKER_NAME" --hostname "$WORKER_NAME" \
  --privileged --tmpfs /tmp --tmpfs /run \
  --volume "${WORKER_NAME}-var":/var:suid,exec,dev \
  --volume /lib/modules:/lib/modules:ro \
  --volume /sys/fs/bpf:/sys/fs/bpf \
  --net kind \
  --cgroupns=private --device /dev/fuse \
  --ulimit memlock=-1:-1 \
  --tty \
  -e container=podman \
  "$BASE_IMAGE" >/dev/null

echodate "Waiting for containerd to be ready inside the worker."
for i in $(seq 1 15); do
  podman exec "$WORKER_NAME" systemctl is-active containerd >/dev/null 2>&1 && break
  sleep 2
done

# Preflight requirement; not namespaced the way you might expect, so it has
# to be set inside this specific container even though the flag is global.
podman exec "$WORKER_NAME" sysctl -w net.ipv4.ip_forward=1 >/dev/null

echodate "Installing kubeadm/kubelet/kubectl (copied from ${SEED_NODE}, no network dependency)."
for f in kubeadm kubelet kubectl; do
  podman cp "${SCRATCH}/k8s-bin/$f" "${WORKER_NAME}:/usr/bin/$f"
  podman exec "$WORKER_NAME" chmod +x "/usr/bin/$f"
done
podman cp "${SCRATCH}/k8s-bin/kubelet.service" "${WORKER_NAME}:/etc/systemd/system/kubelet.service"
podman cp "${SCRATCH}/k8s-bin/kubelet.service.d" "${WORKER_NAME}:/etc/systemd/system/kubelet.service.d"
podman exec "$WORKER_NAME" systemctl daemon-reload
podman exec "$WORKER_NAME" systemctl enable kubelet >/dev/null 2>&1 || true

# --fail-swap-on=false: swap is host-wide (not namespaced away), so kubelet
#   would otherwise refuse to start on this machine.
# --feature-gates=KubeletInUserNamespace=true: several kernel-flag writes
#   (vm/overcommit_memory, kernel/panic) are denied in a nested rootless
#   container; this tells kubelet to tolerate that instead of failing.
podman exec "$WORKER_NAME" sh -c 'echo "KUBELET_EXTRA_ARGS=--fail-swap-on=false --feature-gates=KubeletInUserNamespace=true" > /etc/default/kubelet'

echodate "Joining (keeps the port-forward alive throughout since kubeadm needs it for the CSR/bootstrap phase too, not just discovery)."
podman exec "$WORKER_NAME" bash -c "$JOIN_CMD"

echodate "Done. Start the persistent tunnels (apiserver + konnectivity, both backgrounded, no extra terminals needed):"
echodate "  ./kind-install/manage-usercluster-tunnels.sh ${CLUSTER_NAME} start"
echodate "Then check node status with:"
echodate "  kubectl --kubeconfig=/tmp/${CLUSTER_NAME}-admin.yaml get nodes"
