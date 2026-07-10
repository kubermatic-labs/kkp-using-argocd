#! /bin/bash
#
# Manages the persistent background tunnels a bringyourown user cluster
# needs for day-to-day use after `join-usercluster-node.sh` has joined a
# worker:
#   - apiserver-external: so `kubectl`/the admin-kubeconfig can reach the
#     cluster's apiserver at all from WSL/Windows.
#   - konnectivity-server: so `kubectl logs`/`exec` into pods on the worker
#     work. The konnectivity-agent running on the worker dials out to this
#     Service's NodePort via the same WSL-host-IP nip.io address the
#     apiserver uses; nothing external is listening on that port unless
#     this tunnel is running (see kind-install/HANDOFF.md).
#
# Runs both as background (`setsid`-detached) processes tracked by PID
# files, instead of needing two more foreground terminals left open. Also
# refreshes the admin-kubeconfig at /tmp/<cluster>-admin.yaml on `start`.
#
# Usage: ./kind-install/manage-usercluster-tunnels.sh <cluster-name> {start|stop|status}
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> {start|stop|status}}"
ACTION="${2:?Usage: $0 <cluster-name> {start|stop|status}}"
NAMESPACE="cluster-${CLUSTER_NAME}"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kkp-local}"
export KUBECONFIG="./kind-install/${KIND_CLUSTER_NAME}-kubeconfig"

STATE_DIR="/tmp/kkp-tunnels/${CLUSTER_NAME}"
ADMIN_KUBECONFIG="/tmp/${CLUSTER_NAME}-admin.yaml"
mkdir -p "$STATE_DIR"

echodate() {
  echo "[$(date +"%m-%d %T")] $*"
}

isRunning() {
  local pidfile="$1"
  [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

startTunnel() {
  local name="$1" service="$2" local_port="$3" service_port="$4"
  local pidfile="${STATE_DIR}/${name}.pid"
  local logfile="${STATE_DIR}/${name}.log"

  if isRunning "$pidfile"; then
    echodate "${name}: already running (pid $(cat "$pidfile")), skipping."
    return
  fi

  echodate "${name}: starting tunnel 0.0.0.0:${local_port} -> svc/${service}:${service_port}."
  setsid kubectl port-forward -n "$NAMESPACE" "svc/${service}" --address 0.0.0.0 \
    "${local_port}:${service_port}" >"$logfile" 2>&1 </dev/null &
  disown
  echo $! >"$pidfile"
  sleep 1
  if ! isRunning "$pidfile"; then
    echodate "${name}: failed to start, check ${logfile}:"
    tail -n 20 "$logfile" || true
    return 1
  fi
}

stopTunnel() {
  local name="$1"
  local pidfile="${STATE_DIR}/${name}.pid"
  if isRunning "$pidfile"; then
    echodate "${name}: stopping (pid $(cat "$pidfile"))."
    kill "$(cat "$pidfile")" 2>/dev/null || true
  else
    echodate "${name}: not running."
  fi
  rm -f "$pidfile"
}

statusTunnel() {
  local name="$1" local_port="$2"
  local pidfile="${STATE_DIR}/${name}.pid"
  if isRunning "$pidfile"; then
    echodate "${name}: RUNNING (pid $(cat "$pidfile"), port ${local_port}) -- log: ${STATE_DIR}/${name}.log"
  else
    echodate "${name}: STOPPED"
  fi
}

case "$ACTION" in
start)
  APISERVER_PORT="$(kubectl get cluster "$CLUSTER_NAME" -o jsonpath='{.status.address.port}')"
  KONNECTIVITY_NODEPORT="$(kubectl get svc konnectivity-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')"

  startTunnel apiserver apiserver-external "$APISERVER_PORT" 443
  startTunnel konnectivity konnectivity-server "$KONNECTIVITY_NODEPORT" 443

  echodate "Refreshing admin-kubeconfig at ${ADMIN_KUBECONFIG}."
  for i in $(seq 1 15); do
    curl -sk -o /dev/null "https://127.0.0.1:${APISERVER_PORT}/healthz" && break
    sleep 1
  done
  kubectl get secret admin-kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.kubeconfig}' | base64 -d >"$ADMIN_KUBECONFIG"

  echodate "Done. Try: kubectl --kubeconfig=${ADMIN_KUBECONFIG} get nodes"
  echodate "         kubectl --kubeconfig=${ADMIN_KUBECONFIG} logs -n kube-system <pod> (works once konnectivity-agent's keepalive picks up the tunnel, ~1min)"
  ;;
stop)
  stopTunnel apiserver
  stopTunnel konnectivity
  ;;
status)
  APISERVER_PORT="$(kubectl get cluster "$CLUSTER_NAME" -o jsonpath='{.status.address.port}' 2>/dev/null || echo '?')"
  KONNECTIVITY_NODEPORT="$(kubectl get svc konnectivity-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '?')"
  statusTunnel apiserver "$APISERVER_PORT"
  statusTunnel konnectivity "$KONNECTIVITY_NODEPORT"
  ;;
*)
  echo "Usage: $0 <cluster-name> {start|stop|status}"
  exit 1
  ;;
esac
