#! /bin/bash
#
# Quickest possible KKP bring-up on a local kind cluster: master == seed,
# no AWS/kubeone/Vault. DNS and certs are solved by using a nip.io wildcard
# domain (resolves to whatever IP is embedded in it, no dnsmasq needed) and
# a cert-manager selfSigned ClusterIssuer (no ACME needed). dex, cert-manager
# and nginx-ingress-controller are ArgoCD-managed and waited on (see
# installArgoCD/installKkpArgoApps/waitForArgoApps below) since the installer
# itself needs them up; everything else KKP can offer -- monitoring, logging,
# backup, storage, IAP, user-cluster MLA, even the test project/cluster itself
# (seedExtras) -- is also ArgoCD-managed (dev/local-kind/argoapps-values.yaml)
# but syncs async in the background, same as ci.sh's deployArgoApps() cruises
# straight into installKKP without waiting on any of it.
#
# Steps: 1) kind cluster (with local pull-through registry mirrors)
#        2) ArgoCD + kkp-argo-apps (full app set, see argoapps-values.yaml)
#        3) wait for dex/cert-manager/nginx-ingress-controller only
#        4) kubermatic-installer deploy (remaining charts, --skip-charts for
#           the three above)
#        5) apply seed kubeconfig secret directly (no git push for this part)
#        6) apply Seed CR pointing at that secret
#        7) create the CA-trust secret IAP's oauth2-proxy needs to call out to
#           dex's self-signed HTTPS endpoint (best-effort, doesn't block on it)
set -euo pipefail

echodate() {
  echo "[$(date +"%m-%d %T")] $*"
}

cd "$(dirname "$0")/.."

KKP_VERSION=v2.29.7
LOCAL_ENV_DIR=./dev/local-kind

# Using the WSL VM's own IP instead of 127.0.0.1: on this machine, Windows ->
# WSL2 localhost-forwarding doesn't work (likely blocked by managed-network
# security software), but Windows can reach the WSL VM's IP directly. nip.io
# resolves whatever IP is embedded in the hostname, so this just works from
# both WSL and Windows without any /etc/hosts or dnsmasq config. Re-run this
# script whenever the WSL IP changes (e.g. after a reboot).
WSL_IP="$(hostname -I | awk '{print $1}')"
KKP_DOMAIN="kkp.${WSL_IP}.nip.io"

# ArgoCD's Application `targetRevision` for the values-overlay repo (this
# repo itself -- see dev/local-kind/argoapps-values.yaml's repoURL) resolves
# to a git *tag* named "{environment}-kkp-{kkpVersion}" (kkp-argo-apps
# chart's git-tag-version helper), not a branch -- the branch below only
# exists for human review of what's being pushed. Using "local-kind" as the
# environment (instead of "dev") keeps this tag from colliding with the real
# demo-master/india-seed environment's own "dev-kkp-v2.29.7" tag that ci.sh
# already force-pushes.
GITOPS_BRANCH="local-kind-gitops"
GITOPS_TAG="local-kind-kkp-${KKP_VERSION}"

# Renders dev/local-kind/values.yaml (the nginx/dex/cert-manager Helm values)
# into local-kind/self/values.yaml and pushes it to GITOPS_BRANCH/GITOPS_TAG,
# so the ArgoCD Applications created by installKkpArgoApps() can fetch it.
# Must run as the invoking (non-root) user -- root has no access to the
# user's SSH agent/git credentials -- and therefore must run *before* the
# sudo re-exec below. Uses a disposable git worktree so the user's actual
# checked-out branch and its uncommitted changes are never touched.
pushGitopsValuesRef() {
  echodate "Publishing ArgoCD values overlay to branch '${GITOPS_BRANCH}' (tag '${GITOPS_TAG}')."

  git fetch origin main >/dev/null
  git fetch origin "${GITOPS_BRANCH}" >/dev/null 2>&1 || true

  local base_ref="origin/main"
  if git show-ref --verify --quiet "refs/remotes/origin/${GITOPS_BRANCH}"; then
    base_ref="origin/${GITOPS_BRANCH}"
  fi

  # Clean up any worktree left behind by a crashed previous run before
  # adding a new one -- `git worktree add` refuses a branch that's still
  # checked out elsewhere.
  git worktree prune

  local wt_parent wt_dir
  wt_parent="$(mktemp -d)"
  wt_dir="${wt_parent}/worktree"
  trap 'rm -rf "$wt_parent"; git worktree prune' RETURN

  git worktree add --detach "$wt_dir" "$base_ref" >/dev/null

  mkdir -p "${wt_dir}/local-kind/self/clusters"
  cat >"${wt_dir}/local-kind/values.yaml" <<'EOF'
# Env-specific overlay for the "local-kind" ArgoCD environment. Intentionally
# empty -- this environment has a single seed ("self", master==seed) and all
# actual values live in local-kind/self/values.yaml. Kept as a file (rather
# than omitted) because the kkp-argo-apps chart's valueFiles list references
# it unconditionally.
EOF
  sed "s/__KKP_DOMAIN__/${KKP_DOMAIN}/g" "${LOCAL_ENV_DIR}/values.yaml" >"${wt_dir}/local-kind/self/values.yaml"
  sed "s/__KKP_DOMAIN__/${KKP_DOMAIN}/g" "${LOCAL_ENV_DIR}/values-usermla.yaml" >"${wt_dir}/local-kind/self/values-usermla.yaml"

  # Raw manifests applied as-is by the seedExtras ArgoCD Application (project +
  # bringyourown test cluster) -- no __KKP_DOMAIN__ templating needed in these.
  cp "${LOCAL_ENV_DIR}/self/clusters/"*.yaml "${wt_dir}/local-kind/self/clusters/"

  (
    cd "$wt_dir"
    git checkout -B "$GITOPS_BRANCH"
    git add local-kind/values.yaml local-kind/self/values.yaml local-kind/self/values-usermla.yaml local-kind/self/clusters
    if ! git diff --cached --quiet; then
      git commit -m "Render local-kind ArgoCD values overlay (domain ${KKP_DOMAIN})"
    else
      echodate "No changes to the gitops values overlay."
    fi
    git push origin "HEAD:refs/heads/${GITOPS_BRANCH}"
    git tag -f "$GITOPS_TAG"
    git push -f origin "refs/tags/${GITOPS_TAG}"
  )
}

# Rootful podman is required so nested containers (cilium-agent inside a user
# cluster's worker) get the host's real initial user namespace -- rootless
# podman remaps root to a subuid range, which the kernel never treats as
# CAP_SYS_ADMIN-capable for cgroup-attach eBPF program loads (cilium's
# CGroupSock probe), no matter what container flags are passed. Re-exec as
# root if not already; -E preserves KIND_CLUSTER_NAME etc. if set by caller.
if [ "$(id -u)" -ne 0 ]; then
  pushGitopsValuesRef
  echo "Re-executing as root (rootful podman needed, see kind-install/HANDOFF.md)."
  exec sudo -E "$0" "$@"
fi

# kind supports podman as an alternative container runtime for its "nodes".
export KIND_EXPERIMENTAL_PROVIDER=podman

INSTALL_DIR=./binaries/kubermatic/releases/${KKP_VERSION}
INSTALLER=${INSTALL_DIR}/kubermatic-installer

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kkp-local}"
LOCAL_KUBECONFIG="./kind-install/${KIND_CLUSTER_NAME}-kubeconfig"
RENDERED_ENV_DIR="$(mktemp -d)"

# Set to "false" to keep an already-existing kind cluster instead of
# deleting/recreating it every run -- e.g. when a previous run got past
# cluster creation but failed/timed out later on, and you just want to
# continue against the same cluster. Everything after createKindCluster is
# already idempotent (helm upgrade --install, kubectl apply), so re-running
# against the same cluster is safe either way.
RECREATE_CLUSTER="${RECREATE_CLUSTER:-true}"

ARGO_VERSION=9.3.0
ARGO_APPS_VERSION=2.29

# Host-side directory backing ArgoCD repo-server's git clone cache (mounted
# into the kind node via cluster-nodeport.yaml's extraMounts, then into the
# repo-server pod itself via installArgoCD()'s repoServer.existingVolumes.tmp
# override). Survives `kind delete cluster` -- same "don't recreate this
# every run" idea as the registry mirrors in registry-mirror.sh, just for
# git clones of the (large) kkpRepoURL repo instead of container images.
# Owned by uid 999 because that's the non-root user the argo-cd images run
# as (repoServer.containerSecurityContext.runAsNonRoot).
ARGOCD_REPO_CACHE_HOST_DIR="/var/lib/local-kind-argocd-repo-cache"
ARGOCD_REPO_CACHE_NODE_PATH="/mnt/argocd-repo-cache"

# shellcheck source=./registry-mirror.sh
source ./kind-install/registry-mirror.sh

renderEnvFiles() {
  echodate "Using domain ${KKP_DOMAIN} (WSL IP ${WSL_IP})."
  sed "s/__KKP_DOMAIN__/${KKP_DOMAIN}/g" "${LOCAL_ENV_DIR}/k8cConfig.yaml" >"${RENDERED_ENV_DIR}/k8cConfig.yaml"
  sed "s/__KKP_DOMAIN__/${KKP_DOMAIN}/g" "${LOCAL_ENV_DIR}/values.yaml" >"${RENDERED_ENV_DIR}/values.yaml"
}

retry() {
  local tries=$1
  shift
  local i=0
  until "$@"; do
    i=$((i + 1))
    if [ $i -ge "$tries" ]; then
      echodate "Command failed after $tries attempts: $*"
      return 1
    fi
    echodate "Attempt $i/$tries failed, retrying in 5s: $*"
    sleep 5
  done
}

validatePreReq() {
  echodate "Validating prerequisites."
  for bin in kind kubectl helm jq podman; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echodate "Error: '$bin' is not installed/on PATH."
      exit 1
    fi
  done
  if [ ! -x "$INSTALLER" ]; then
    echodate "Error: $INSTALLER not found. Check KKP_VERSION / binaries/ download."
    exit 1
  fi
}

ensureArgoRepoCacheDir() {
  mkdir -p "$ARGOCD_REPO_CACHE_HOST_DIR"
  chown -R 999:999 "$ARGOCD_REPO_CACHE_HOST_DIR"
}

createKindCluster() {
  if [ "$RECREATE_CLUSTER" = "false" ] && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    echodate "Reusing existing kind cluster '${KIND_CLUSTER_NAME}' (RECREATE_CLUSTER=false)."
    kind get kubeconfig --name "$KIND_CLUSTER_NAME" >"$LOCAL_KUBECONFIG"
  else
    echodate "(Re)creating kind cluster '${KIND_CLUSTER_NAME}'."
    kind delete cluster --name "$KIND_CLUSTER_NAME" || true
    kind create cluster --name "$KIND_CLUSTER_NAME" \
      --config ./kind-install/cluster-nodeport.yaml \
      --kubeconfig "$LOCAL_KUBECONFIG"
  fi
  connectRegistryMirrorsToKindNetwork
}

installArgoCD() {
  echodate "Installing ArgoCD (server ingress: argocd.${KKP_DOMAIN})."
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd --version "${ARGO_VERSION}" --namespace argocd --create-namespace \
    argo/argo-cd -f values-argocd.yaml \
    --set "server.ingress.hostname=argocd.${KKP_DOMAIN}" \
    --set 'server.ingress.annotations.cert-manager\.io/cluster-issuer=selfsigned-issuer' \
    --set "repoServer.existingVolumes.tmp.hostPath.path=${ARGOCD_REPO_CACHE_NODE_PATH}" \
    --set repoServer.existingVolumes.tmp.hostPath.type=DirectoryOrCreate
}

installKkpArgoApps() {
  echodate "Installing ArgoCD Applications for dex/nginx-ingress-controller/cert-manager (kkp-argo-apps)."
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  helm repo add dharapvj https://dharapvj.github.io/helm-charts/ >/dev/null 2>&1 || true
  helm repo update dharapvj >/dev/null
  helm upgrade --install kkp-argo-apps --version "${ARGO_APPS_VERSION}.*" \
    --set kkpVersion="${KKP_VERSION}" \
    -f "${LOCAL_ENV_DIR}/argoapps-values.yaml" \
    dharapvj/argocd-apps
}

waitForArgoApps() {
  # Give ArgoCD generous time here: on a freshly-installed ArgoCD, the
  # repo-server/application-controller are themselves cold-starting, the
  # first sync has to git-clone the (public) kubermatic/kubermatic repo, and
  # image pulls for dex/cert-manager/nginx-ingress-controller are competing
  # with everything else installKKP is about to pull too -- 2 minutes proved
  # too short in practice, hence the 8m budget and explicit per-app wait
  # (rather than a blind retry against a Service that may not exist yet).
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  local app
  for app in dex nginx-ingress-controller cert-manager; do
    echodate "Waiting for ArgoCD Application '${app}' to become Healthy (up to 8m)."
    if ! kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
        "application.argoproj.io/${app}" -n argocd --timeout=8m; then
      echodate "Application '${app}' did not reach Healthy in time. Current state:"
      kubectl get "application.argoproj.io/${app}" -n argocd -o wide || true
      kubectl describe "application.argoproj.io/${app}" -n argocd || true
      return 1
    fi
  done
}

installKKP() {
  echodate "Installing KKP onto kind (dex/cert-manager/nginx-ingress-controller are ArgoCD-managed, see above)."
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  "$INSTALLER" deploy kubermatic-master \
    --charts-directory "${INSTALL_DIR}/charts" \
    --config "${RENDERED_ENV_DIR}/k8cConfig.yaml" \
    --helm-values "${RENDERED_ENV_DIR}/values.yaml" \
    --storageclass copy-default \
    --disable-telemetry \
    --skip-charts='cert-manager,nginx-ingress-controller,dex'
}

patchCoreDNSForLocalDomain() {
  # KKP_DOMAIN resolves (via nip.io) to the WSL IP everywhere -- including
  # inside pods, where that IP is NOT the pod itself, but it's also not
  # routable back into the cluster from outside. Anything running in-cluster
  # that calls out to its own public URL (e.g. kubermatic-api hitting the dex
  # OIDC issuer) needs to resolve to the ingress Service instead. Rewrite the
  # name in-cluster to the ingress Service's FQDN, so DNS resolves to the real
  # ClusterIP. The Service's own ports were set to 8080/8443 (see
  # dev/local-kind/values.yaml) to match, so the URL's port still lands
  # correctly.
  echodate "Patching CoreDNS so ${KKP_DOMAIN} resolves in-cluster to the ingress Service."
  export KUBECONFIG="$LOCAL_KUBECONFIG"

  # nginx-ingress-controller is now installed asynchronously by ArgoCD
  # (installKkpArgoApps) rather than synchronously as part of installKKP, so
  # its Service may not exist yet by the time this runs. waitForArgoApps
  # already waited up to 8m for the Application to report Healthy, but that
  # can be a false-positive on a cold ArgoCD (repo-server still git-cloning
  # kkpRepoURL for the very first sync of the run) -- give this the same
  # order-of-magnitude budget rather than the 2min it had before, so a slow
  # first sync doesn't abort the whole script (set -e) before
  # applySelfSignedIssuer ever runs, which is what left dex/argocd/kubermatic
  # certs permanently stuck without a ClusterIssuer.
  echodate "Waiting for the nginx-ingress-controller Service to exist."
  retry 90 kubectl get svc nginx-ingress-controller -n nginx-ingress-controller

  local corefile
  corefile="$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')"
  if ! grep -q "rewrite name ${KKP_DOMAIN}" <<<"$corefile"; then
    corefile="$(sed "s#\\(\\s*\\)kubernetes cluster\\.local#\\1rewrite name ${KKP_DOMAIN} nginx-ingress-controller.nginx-ingress-controller.svc.cluster.local\\n\\1kubernetes cluster.local#" <<<"$corefile")"
  fi

  kubectl create configmap coredns -n kube-system \
    --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deploy/coredns -n kube-system
  kubectl rollout status deploy/coredns -n kube-system --timeout=60s
}

applySelfSignedIssuer() {
  echodate "Applying selfsigned ClusterIssuer (retrying until cert-manager webhook is ready)."
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  # Higher retry budget than before: cert-manager is now installed
  # asynchronously by ArgoCD (installKkpArgoApps) rather than synchronously
  # as part of installKKP, so it takes longer to become ready.
  retry 30 kubectl apply -f "${LOCAL_ENV_DIR}/selfsigned-issuer.yaml"
}

generateAndApplySeedKubeconfig() {
  echodate "Generating seed kubeconfig (master == seed) and applying it as a Secret directly."
  export KUBECONFIG="$LOCAL_KUBECONFIG"

  local seed_kubeconfig
  seed_kubeconfig="$(mktemp)"
  cp "$LOCAL_KUBECONFIG" "$seed_kubeconfig"

  # Swaps client-cert auth for a cluster-admin ServiceAccount token. Must run
  # while the kubeconfig's server field still points at the host-reachable
  # 127.0.0.1:<port> address (i.e. before the sed below).
  "$INSTALLER" convert-kubeconfig "$seed_kubeconfig" -i

  # kind's server address (127.0.0.1:<port>) is only reachable from the host,
  # not from pods inside the cluster. Point it at the in-cluster API service
  # instead -- same cert, so the existing CA data still validates.
  sed -i 's/127\.0\.0\.1.*/kubernetes.default.svc.cluster.local./' "$seed_kubeconfig"

  kubectl create secret generic kind-local-seed-kubeconfig \
    --namespace kubermatic \
    --from-file=kubeconfig="$seed_kubeconfig" \
    --dry-run=client -o yaml | kubectl apply -f -

  rm -f "$seed_kubeconfig"
}

applySeed() {
  echodate "Applying Seed CR."
  export KUBECONFIG="$LOCAL_KUBECONFIG"
  retry 6 kubectl apply -f "${LOCAL_ENV_DIR}/seed.yaml"
}

createIapTrustedCaSecret() {
  # dex's TLS cert (Ingress secret "dex-tls", issued by the selfsigned-issuer
  # ClusterIssuer) is self-signed -- issuer == subject -- so the leaf cert
  # itself IS the CA needed to validate it. IAP's oauth2-proxy containers
  # (seed-mla-iap in namespace "iap", user-mla-iap in namespace "mla") each
  # need that cert available as a Secret (customProviderCA in
  # dev/local-kind/values.yaml / values-usermla.yaml) to trust dex's HTTPS
  # endpoint when validating the OIDC issuer. Best-effort: the iap/mla
  # namespaces and the dex-tls secret all come from independently-syncing
  # ArgoCD Applications, so this may need a few tries the first run through;
  # doesn't fail the whole script if it's still not ready (oauth2-proxy pods
  # will just crash-loop until re-run, same as any other async app that
  # hasn't synced yet).
  echodate "Creating CA-trust secret for IAP's oauth2-proxy (from dex's self-signed cert)."
  export KUBECONFIG="$LOCAL_KUBECONFIG"

  # Not using retry() here: its own progress messages go to stdout via
  # echodate, which would corrupt a captured `$(...)` value.
  local dex_cert="" i=0
  until [ -n "$dex_cert" ]; do
    dex_cert="$(kubectl get secret dex-tls -n dex -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
    [ -n "$dex_cert" ] && break
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      echodate "WARNING: dex-tls secret not found/empty after retries -- skipping IAP CA secret. Re-run this function manually once dex's cert is issued."
      return 0
    fi
    sleep 5
  done

  local ns
  for ns in iap mla; do
    if ! retry 20 kubectl get namespace "$ns" >/dev/null 2>&1; then
      echodate "WARNING: namespace '${ns}' not found after retries -- skipping IAP CA secret there. Re-run once its ArgoCD Application has created the namespace."
      continue
    fi
    echo "$dex_cert" | base64 -d | kubectl create secret generic selfsigned-ca-cert \
      --namespace "$ns" \
      --from-file=ca.crt=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -
  done
}

handBackKubeconfigOwnership() {
  # Everything above ran as root (see the re-exec at the top). Hand the
  # kubeconfig back to the invoking user so later plain `kubectl`/scripts
  # (join-usercluster-node.sh, port-forward-usercluster.sh, ad-hoc checks)
  # don't need sudo just to read it.
  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$LOCAL_KUBECONFIG"
  fi
}

echodate "Starting local KKP kind bring-up."
validatePreReq
renderEnvFiles
ensureRegistryMirrors
ensureArgoRepoCacheDir
createKindCluster
handBackKubeconfigOwnership
installArgoCD
installKkpArgoApps
waitForArgoApps
installKKP
patchCoreDNSForLocalDomain
applySelfSignedIssuer
generateAndApplySeedKubeconfig
applySeed
createIapTrustedCaSecret
rm -rf "$RENDERED_ENV_DIR"

echodate "Done. KUBECONFIG=${LOCAL_KUBECONFIG}"
echodate "Dashboard: https://${KKP_DOMAIN}:8443 (self-signed cert -- accept the browser warning)"
echodate "Login: vijay@kubermatic.com / vj"
echodate "Check seed status with: KUBECONFIG=${LOCAL_KUBECONFIG} kubectl get seed -n kubermatic kubermatic -o yaml"
