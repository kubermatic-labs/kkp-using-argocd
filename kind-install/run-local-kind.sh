#! /bin/bash
#
# Quickest possible KKP bring-up on a local kind cluster: master == seed,
# no AWS/kubeone/Vault. DNS and certs are solved by using a nip.io wildcard
# domain (resolves to whatever IP is embedded in it, no dnsmasq needed) and
# a cert-manager selfSigned ClusterIssuer (no ACME needed). dex,
# cert-manager and nginx-ingress-controller are ArgoCD-managed (see
# installArgoCD/installKkpArgoApps below); everything else is still deployed
# directly by kubermatic-installer.
#
# Steps: 1) kind cluster (with local pull-through registry mirrors)
#        2) ArgoCD + kkp-argo-apps (dex/cert-manager/nginx-ingress-controller)
#        3) kubermatic-installer deploy (remaining charts, --skip-charts for
#           the three above)
#        4) apply seed kubeconfig secret directly (no git push for this part)
#        5) apply Seed CR pointing at that secret
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

  mkdir -p "${wt_dir}/local-kind/self"
  cat >"${wt_dir}/local-kind/values.yaml" <<'EOF'
# Env-specific overlay for the "local-kind" ArgoCD environment. Intentionally
# empty -- this environment has a single seed ("self", master==seed) and all
# actual values live in local-kind/self/values.yaml. Kept as a file (rather
# than omitted) because the kkp-argo-apps chart's valueFiles list references
# it unconditionally.
EOF
  sed "s/__KKP_DOMAIN__/${KKP_DOMAIN}/g" "${LOCAL_ENV_DIR}/values.yaml" >"${wt_dir}/local-kind/self/values.yaml"

  (
    cd "$wt_dir"
    git checkout -B "$GITOPS_BRANCH"
    git add local-kind/values.yaml local-kind/self/values.yaml
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

ARGO_VERSION=9.3.0
ARGO_APPS_VERSION=2.29

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

createKindCluster() {
  echodate "(Re)creating kind cluster '${KIND_CLUSTER_NAME}'."
  kind delete cluster --name "$KIND_CLUSTER_NAME" || true
  kind create cluster --name "$KIND_CLUSTER_NAME" \
    --config ./kind-install/cluster-nodeport.yaml \
    --kubeconfig "$LOCAL_KUBECONFIG"
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
    --set 'server.ingress.annotations.cert-manager\.io/cluster-issuer=selfsigned-issuer'
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
  # its Service may not exist yet by the time this runs.
  echodate "Waiting for the nginx-ingress-controller Service to exist."
  retry 24 kubectl get svc nginx-ingress-controller -n nginx-ingress-controller

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
createKindCluster
installArgoCD
installKkpArgoApps
installKKP
patchCoreDNSForLocalDomain
applySelfSignedIssuer
generateAndApplySeedKubeconfig
applySeed
handBackKubeconfigOwnership
rm -rf "$RENDERED_ENV_DIR"

echodate "Done. KUBECONFIG=${LOCAL_KUBECONFIG}"
echodate "Dashboard: https://${KKP_DOMAIN}:8443 (self-signed cert -- accept the browser warning)"
echodate "Login: vijay@kubermatic.com / vj"
echodate "Check seed status with: KUBECONFIG=${LOCAL_KUBECONFIG} kubectl get seed -n kubermatic kubermatic -o yaml"
