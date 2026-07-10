#! /bin/bash
#
# Local pull-through-cache registries so run-local-kind.sh's delete/recreate-
# every-run cycle doesn't re-pull the same images from the internet each
# time. Each entry below is a plain `registry:2` container running in
# pull-through mode (REGISTRY_PROXY_REMOTEURL) against one upstream, backed
# by a named podman volume that survives `kind delete cluster` -- these
# mirror containers are never torn down by run-local-kind.sh, only the kind
# cluster itself is. Meant to be sourced, not executed directly.

# name -> upstream registry URL. Matches kind-install/cluster-nodeport.yaml's
# containerdConfigPatches -- add an entry here and there together.
declare -A REGISTRY_MIRRORS=(
  [docker]="https://registry-1.docker.io"
  [quay]="https://quay.io"
  [registryk8s]="https://registry.k8s.io"
  [ghcr]="https://ghcr.io"
)

ensureRegistryMirror() {
  local name="$1" upstream="$2" container="kind-registry-${1}"
  if podman container inspect "$container" >/dev/null 2>&1; then
    if [ "$(podman inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
      echodate "Starting existing (stopped) registry mirror '${container}'."
      podman start "$container" >/dev/null
    fi
    return
  fi
  echodate "Creating registry mirror '${container}' (upstream: ${upstream})."
  podman run -d --restart=always --name "$container" \
    -v "${container}-data:/var/lib/registry" \
    -e REGISTRY_PROXY_REMOTEURL="$upstream" \
    registry:2 >/dev/null
}

ensureRegistryMirrors() {
  local name
  for name in "${!REGISTRY_MIRRORS[@]}"; do
    ensureRegistryMirror "$name" "${REGISTRY_MIRRORS[$name]}"
  done
}

# Run after `kind create cluster` -- the "kind" podman network only exists
# once a cluster has been created at least once, and this is idempotent so
# it's safe to call on every run regardless of whether kind reused or
# recreated the network.
connectRegistryMirrorsToKindNetwork() {
  local name
  for name in "${!REGISTRY_MIRRORS[@]}"; do
    podman network connect kind "kind-registry-${name}" 2>/dev/null || true
  done
}
