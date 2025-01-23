#! /bin/bash

set -euo pipefail

# INPUTS:
# 1. git repository where customization are present
# 2. git tag name which we want to apply (or may be just release name and we build the tag name)
# 3. additional seed clusters should be created or not

# TODO: Accept the versions as Args or via a config file
# To upgrade KKP, update the version of kkp here.
#KKP_VERSION=v2.25.11
KKP_VERSION=v2.26.2
K1_VERSION=1.8.3
ARGO_VERSION=5.36.10
ENV=dev
MASTER=dev-master
# SEED=false # - don't create extra seed. Any other value - name of the seed
SEED=dev-seed
CLUSTER_PREFIX=argodemo

INSTALL_DIR=./binaries/kubermatic/releases/${KKP_VERSION}
KUBEONE_INSTALL_DIR=./binaries/kubeone/releases/${K1_VERSION}
MASTER_KUBECONFIG=./kubeone-install/${MASTER}/${CLUSTER_PREFIX}-${MASTER}-kubeconfig
SEED_KUBECONFIG=./kubeone-install/${SEED}/${CLUSTER_PREFIX}-${SEED}-kubeconfig

# LOGIC
# validate that we have kubeone, kubectl, helm, git, sed, chainsaw binaries available
# TODO: validate availability of ssh-agent?
validatePreReq() {
  echo validate Prerequisites.
  if [[ -n "${AWS_ACCESS_KEY_ID-}" && -n "${AWS_SECRET_ACCESS_KEY-}" ]]; then
    echo AWS credentials found! Proceeding.
  elif [[ -n "${AWS_PROFILE-}" ]]; then
    echo AWS profile variable found! Proceeding.
  else
    echo No AWS credentials configured. You must export either combination of AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY OR AWS_PROFILE env variable. Exiting the script.
    exit 1
  fi

  if ! [ -x "$(command -v git)" ]; then
    echo 'Error: git is not installed.' >&2
    exit 1
  fi

  if ! [ -x ${KUBEONE_INSTALL_DIR}/kubeone ]; then
    echo 'Error: kubeone is not installed.' >&2
    exit 1
  fi

  if ! [ -x "$(command -v helm)" ]; then
    echo 'Error: helm is not installed.' >&2
    exit 1
  fi

  if ! [ -x "$(command -v sed)" ]; then
    echo 'Error: sed is not installed.' >&2
    exit 1
  fi

  if ! [ -x "$(command -v chainsaw)" ]; then
    echo 'Error: chainsaw testing tool is not installed.' >&2
    exit 1
  fi
}

# Based on flag - create kubeone clusters (you should be able to skip it otherwise)
# TODO: Check flag about whether to create seed clusters or not
# fix directory naming?
createSeedClusters(){ 
  echo creating Seed Clusters
  cd kubeone-install/${MASTER} && terraform init && terraform apply -auto-approve &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml --auto-approve
  if [ $? -ne 0 ]; then
    echo terraform install failed.
    exit 2
  fi
  cd ../..

  if [[ ${SEED} != false ]]; then
    cd kubeone-install/${SEED} && terraform init && terraform apply -auto-approve &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml --auto-approve
    if [ $? -ne 0 ]; then
      echo terraform install failed.
      exit 3
    fi
    cd ../..
  fi
}

# Validate kubeone clusters - apiserver availability, smoke test
# TODO: do via chainsaw as well as check apiserver availability
validateSeedClusters(){
  echo validateSeedClusters: Not implemented.
}
# deploy argo and kkp argo apps
deployArgoApps() {
  echo Deploying ArgoCD and KKP ArgoCD Apps.
  # TODO: variable for the ingress hostname
	helm repo add dharapvj https://dharapvj.github.io/helm-charts/
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update dharapvj
  helm repo update argo
  # master seed
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install argocd --version ${ARGO_VERSION} --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set "server.ingress.hosts[0]=argocd.${CLUSTER_PREFIX}.lab.kubermatic.io" --set "server.ingress.tls[0].hosts[0]=argocd.${CLUSTER_PREFIX}.lab.kubermatic.io"
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./${ENV}/demo-master/argoapps-values.yaml dharapvj/argocd-apps

  if [[ ${SEED} != false ]]; then
    KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install argocd --version ${ARGO_VERSION} --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set "server.ingress.hosts[0]=argocd.india.${CLUSTER_PREFIX}.lab.kubermatic.io" --set "server.ingress.tls[0].hosts[0]=argocd.india.${CLUSTER_PREFIX}.lab.kubermatic.io"
    KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./${ENV}/india-seed/argoapps-values.yaml dharapvj/argocd-apps
  fi
}
# download kkp release and run kkp installer
installKKP(){
  echo installing KKP on master seed.
  if [ ! -d "${INSTALL_DIR}" ]; then
    echo "$INSTALL_DIR does not exist. Downloading KKP release"
    BIN_ARCH=linux-amd64
    mkdir -p ${INSTALL_DIR}/
    wget https://github.com/kubermatic/kubermatic/releases/download/${KKP_VERSION}/kubermatic-ee-${KKP_VERSION}-${BIN_ARCH}.tar.gz -O- | tar -xz --directory ${INSTALL_DIR}/
  fi

	KUBECONFIG=${MASTER_KUBECONFIG} ${INSTALL_DIR}/kubermatic-installer deploy \
	  --charts-directory ${INSTALL_DIR}/charts --config ./${ENV}/demo-master/k8cConfig.yaml --helm-values ./${ENV}/demo-master/values.yaml \
	  --skip-charts='cert-manager,nginx-ingress-controller,dex'
}
# generate kubeconfig secret and make a git commit programatically and push tag
generateNPushSeedKubeConfig() {
  echo generating and pushing latest Seed Kubeconfig secrets.
	local kubeconfig_b64=$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/${MASTER}/${CLUSTER_PREFIX}-${MASTER}-kubeconfig | base64 -w0)
  # echo $kubeconfig_b64
	sed -i "/kubeconfig: /s/: .*/: `echo $kubeconfig_b64`/" ${ENV}/demo-master/seed-kubeconfig-secret-self.yaml
  # reset
  kubeconfig_b64=""
  if [[ ${SEED} != false ]]; then
    kubeconfig_b64=$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/${SEED}/${CLUSTER_PREFIX}-${SEED}-kubeconfig | base64 -w0)
    sed -i "/kubeconfig: /s/: .*/: `echo $kubeconfig_b64`/" ${ENV}/demo-master/seed-kubeconfig-secret-india.yaml
  fi
  # automated git commit and push tag
  git add ${ENV}/demo-master/seed-kubeconfig-secret-india.yaml ${ENV}/demo-master/seed-kubeconfig-secret-self.yaml
  git commit -m "Adding latest seed kubeconfigs so that Seed resources will reconcile correctly" || echo "ignore commit failure, proceed"
  git push origin main
  git tag -f ${ENV}-kkp-${KKP_VERSION}
	git push origin -f ${ENV}-kkp-${KKP_VERSION}
}
# TODO: validate installation? Create user clusters, access MLA links etc.
# more the merrier
validateDemoInstallation() {
  echo Validating the Demo Installation.
  echo sleeping for many minutes while restarting some services to get cert-manager based certs clearly created.
  # sleep for completion of installation of all services!
  sleep 4m

  # hack: need to work the DNS issues so that certs get created properly
  KUBECONFIG=$PWD/kubeone-install/${MASTER}/argodemo-${MASTER}-kubeconfig kubectl rollout restart deploy -n kube-system coredns
  sleep 1m
  KUBECONFIG=$PWD/kubeone-install/${MASTER}/argodemo-${MASTER}-kubeconfig kubectl rollout restart ds -n kube-system node-local-dns
  sleep 8m
  KUBECONFIG=$PWD/kubeone-install/${MASTER}/argodemo-${MASTER}-kubeconfig kubectl rollout restart deploy -n cert-manager cert-manager
  sleep 6m
  KUBECONFIG=$PWD/kubeone-install/${MASTER}/argodemo-${MASTER}-kubeconfig chainsaw test tests/e2e/master-seed

  if [[ ${SEED} != false ]]; then
    echo now running e2e tests for seed
    echo sleeping for many minutes while restarting some services to get cert-manager based certs clearly created.
    # hack: need to work the DNS issues so that certs get created properly
    KUBECONFIG=$PWD/kubeone-install/${SEED}/argodemo-${SEED}-kubeconfig kubectl rollout restart deploy -n kube-system coredns
    sleep 1m
    KUBECONFIG=$PWD/kubeone-install/${SEED}/argodemo-${SEED}-kubeconfig kubectl rollout restart ds -n kube-system node-local-dns
    sleep 8m
    KUBECONFIG=$PWD/kubeone-install/${SEED}/argodemo-${SEED}-kubeconfig kubectl rollout restart deploy -n cert-manager cert-manager
    sleep 6m
    KUBECONFIG=$PWD/kubeone-install/${SEED}/argodemo-${SEED}-kubeconfig chainsaw test tests/e2e/seed-india
  fi
}

# post validation, cleanup
cleanup() {
  echo cleanup all the cluster resources.
  # first destroy master so that kubermatic-operator is gone otherwise it tries to recreate seed node-port-proxy LB
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller || true
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller || true
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy || true
	cd kubeone-install/${MASTER} && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml --auto-approve
	terraform init && terraform destroy -auto-approve
  cd ../..

  if [[ ${SEED} != false ]]; then
    # now destroy seed
    KUBECONFIG=${SEED_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller || true
    KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller || true
    KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy || true
    cd kubeone-install/${SEED} && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml --auto-approve
    terraform init && terraform destroy -auto-approve
  fi
}

date
validatePreReq
createSeedClusters
validateSeedClusters
deployArgoApps
installKKP
generateNPushSeedKubeConfig
validateDemoInstallation
# cleanup
date
