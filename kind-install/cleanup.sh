#! /bin/bash
#
# Nukes all local KKP test infra in one shot: every joined worker node
# container + its volume (auto-discovered by the kkp-worker-* naming
# convention join-usercluster-node.sh uses), every background tunnel
# (manage-usercluster-tunnels.sh), and the kind cluster itself. No cluster
# name needed -- this is throwaway test infra, so "clean slate" just means
# everything.
#
# Deliberately does NOT touch the registry mirrors (kind-registry-*) -- those
# are meant to persist as a permanent local cache across cleanups. Remove
# them yourself (see the printed hint at the end) if you really want to.
#
# Usage: ./kind-install/cleanup.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-executing as root (rootful podman needed, see kind-install/HANDOFF.md)."
  exec sudo -E "$0" "$@"
fi

cd "$(dirname "$0")/.."

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kkp-local}"

echodate() {
  echo "[$(date +"%m-%d %T")] $*"
}

echodate "Stopping all background tunnels."
for pidfile in /tmp/kkp-tunnels/*/*.pid; do
  [ -f "$pidfile" ] || continue
  kill "$(cat "$pidfile")" 2>/dev/null || true
done
rm -rf /tmp/kkp-tunnels
rm -f /tmp/*-admin.yaml

echodate "Removing all worker node containers and their volumes."
podman ps -a --filter name=kkp-worker- --format '{{.Names}}' | while read -r container; do
  echodate "  ${container}"
  podman rm -f "$container" >/dev/null 2>&1 || true
  podman volume rm -f "${container}-var" >/dev/null 2>&1 || true
done

echodate "Deleting kind cluster '${KIND_CLUSTER_NAME}'."
kind delete cluster --name "$KIND_CLUSTER_NAME" || true
rm -f "./kind-install/${KIND_CLUSTER_NAME}-kubeconfig"

echodate "Done."
echodate "Registry mirrors (kind-registry-*) were left running/cached on purpose -- to remove those too:"
echodate "  podman rm -f kind-registry-{docker,quay,registryk8s,ghcr}"
echodate "  podman volume rm kind-registry-{docker,quay,registryk8s,ghcr}-data"
