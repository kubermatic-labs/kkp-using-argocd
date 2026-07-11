#! /bin/bash
#
# Foreground port-forward from the WSL host to a user cluster's apiserver
# (or any other Service in its cluster-<name> namespace). Bound to 0.0.0.0 so
# it's reachable from Windows too (same mechanism as the KKP dashboard/ingress
# -- see kind-install/run-local-kind.sh). Run this in its own terminal and
# Ctrl+C it when you're done; nothing is left running in the background and
# it isn't tied to cluster creation/deletion at all.
#
# Usage: ./kind-install/port-forward-usercluster.sh <cluster-name> [local-port] [service] [service-port]
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [local-port] [service] [service-port]}"
LOCAL_PORT="${2:-30118}"
SERVICE="${3:-apiserver-external}"
SERVICE_PORT="${4:-443}"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kkp-local}"
export KUBECONFIG="./kind-install/${KIND_CLUSTER_NAME}-kubeconfig"

echo "Forwarding 0.0.0.0:${LOCAL_PORT} -> svc/${SERVICE}:${SERVICE_PORT} in namespace cluster-${CLUSTER_NAME}."
echo "Reachable from WSL and Windows at that port for as long as this is running. Ctrl+C to stop."
exec kubectl port-forward -n "cluster-${CLUSTER_NAME}" "svc/${SERVICE}" --address 0.0.0.0 "${LOCAL_PORT}:${SERVICE_PORT}"
