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

# name -> the registry hostname images actually reference (what containerd's
# registry.mirrors key must match). Kept separate from REGISTRY_MIRRORS above
# since e.g. docker.io images are actually served from registry-1.docker.io.
declare -A REGISTRY_MIRROR_HOSTS=(
  [docker]="docker.io"
  [quay]="quay.io"
  [registryk8s]="registry.k8s.io"
  [ghcr]="ghcr.io"
)

# Prints the containerd config.toml mirror stanzas for all REGISTRY_MIRRORS
# entries -- the same content baked statically into cluster-nodeport.yaml's
# containerdConfigPatches for kind-created nodes. Used to apply the identical
# config to worker containers that don't go through `kind create cluster`
# (e.g. join-usercluster-node.sh's bringyourown worker, which bypasses KKP's
# machine-controller/cloud-init node provisioning entirely, so there's no
# Datacenter/Seed-level node-settings hook for this -- the worker's
# containerd has to be configured directly).
registryMirrorContainerdConfig() {
  local name
  for name in "${!REGISTRY_MIRRORS[@]}"; do
    cat <<EOF
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY_MIRROR_HOSTS[$name]}"]
  endpoint = ["http://kind-registry-${name}:5000"]
EOF
  done
}

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
  # REGISTRY_PROXY_TTL=0s: registry:2 defaults proxy.ttl to 168h (7 days),
  # after which cached blobs are evicted and re-fetched from upstream on
  # next use. This is meant to be a permanent local dev cache, not a
  # time-limited one -- 0s disables TTL-based eviction entirely. Content
  # only goes away if you delete the "${container}-data" volume yourself.
  podman run -d --restart=always --name "$container" \
    -v "${container}-data:/var/lib/registry" \
    -e REGISTRY_PROXY_REMOTEURL="$upstream" \
    -e REGISTRY_PROXY_TTL=0s \
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
