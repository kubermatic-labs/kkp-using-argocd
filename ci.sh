#! /bin/bash

set -euo pipefail

# TODO: Accept the versions as Args or via a config file
KKP_VERSION=v2.25.11
K1_VERSION=1.8.3
# To upgrade KKP, update the version of kkp here.
#KKP_VERSION=v2.25.6
INSTALL_DIR=./binaries/kubermatic/releases/${KKP_VERSION}
KUBEONE_INSTALL_DIR=./binaries/kubeone/releases/${K1_VERSION}
# TODO = variablize env value `dev` as well as other values like argodemo, master and seed
MASTER_KUBECONFIG=./kubeone-install/dev-master/argodemo-dev-master-kubeconfig
SEED_KUBECONFIG=./kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig

# INPUTS:
# 1. git repository where customization are present
# 2. git tag name which we want to apply (or may be just release name and we build the tag name)
# 3. seed clusters should be created or not

# LOGIC
# validate that we have make, kubeone, kubectl, helm, git, sed binaries available
validatePreReq() {
  echo validatePreReq: Not implemented.
  # validate that either AWS_PROFILE or AWS_ACCESS_KEY and AWS_SECRET_KEY env variables are available
}

# Based on flag - create kubeone clusters (you should be able to skip it otherwise)
createSeedClusters(){ 
  echo creating Seed Clusters
  # TODO: Check flag about whether to create or not. Also flag should dictate whether extra seed is needed or not.
  # `dev` should be from ENV var
  cd kubeone-install/dev-master && terraform init && terraform apply -auto-approve &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml --auto-approve
  cd ../..
  # TODO: preferablly, in another shell - create seed cluster
  cd kubeone-install/dev-seed && terraform init && terraform apply -auto-approve &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml --auto-approve
  cd ../..
}
# Validate kubeone clusters - apiserver availability, smoke test
validateSeedClusters(){
  echo validateSeedClusters: Not implemented.
}
# deploy argo and kkp argo apps
deployArgoApps() {
  echo Deploying ArgoCD and KKP ArgoCD Apps.
  # master seed
  # TODO: variable for the ingress hostname
  # variable for argocd chart version
	helm repo add dharapvj https://dharapvj.github.io/helm-charts/
	helm repo update dharapvj
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.argodemo.lab.kubermatic.io'
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/demo-master/argoapps-values.yaml dharapvj/argocd-apps

  # TODO: preferably in separate shell
	KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.india.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.india.argodemo.lab.kubermatic.io'
	KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/india-seed/argoapps-values.yaml dharapvj/argocd-apps
}
# download kkp release and run kkp installer
installKKP(){
  echo installing KKP on master seed.
  # TODO: download only if it release folder does not exist?
  BIN_ARCH=linux-amd64
	mkdir -p ${INSTALL_DIR}/
	wget https://github.com/kubermatic/kubermatic/releases/download/${KKP_VERSION}/kubermatic-ee-${KKP_VERSION}-${BIN_ARCH}.tar.gz -O- | tar -xz --directory ${INSTALL_DIR}/
	KUBECONFIG=${MASTER_KUBECONFIG} ${INSTALL_DIR}/kubermatic-installer deploy \
	  --charts-directory ${INSTALL_DIR}/charts --config ./dev/demo-master/k8cConfig.yaml --helm-values ./dev/demo-master/values.yaml \
	  --skip-charts='cert-manager,nginx-ingress-controller,dex'
}
# generate kubeconfig secret and make a git commit programatically and push tag
generateNPushSeedKubeConfig() {
  echo generating and pushing latest Seed Kubeconfig secrets.
	local kubeconfig_b64=$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-master/argodemo-dev-master-kubeconfig | base64 -w0)
  # echo $kubeconfig_b64
	sed -i "/kubeconfig: /s/: .*/: `echo $kubeconfig_b64`/" dev/demo-master/seed-kubeconfig-secret-self.yaml
  # reset
  kubeconfig_b64=""
	kubeconfig_b64=$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig | base64 -w0)
	sed -i "/kubeconfig: /s/: .*/: `echo $kubeconfig_b64`/" dev/demo-master/seed-kubeconfig-secret-india.yaml

  # automated git commit and push tag
  # TODO: variables for the files? also env `dev`
  git add dev/demo-master/seed-kubeconfig-secret-india.yaml dev/demo-master/seed-kubeconfig-secret-self.yaml
  git commit -m "Adding latest seed kubeconfigs so that Seed resources will reconcile correctly"
  git push origin main
  git tag -f dev-kkp-${KKP_VERSION}
	git push origin -f dev-kkp-${KKP_VERSION}
}
# validate installation? Create user clusters, access MLA links etc.
# more the merrier
validateDemoInstallation() {
  echo validate the Demo Installation - master seed as well as india seed.
  # sleep for completion of installation of all services!
  sleep 10m
  KUBECONFIG=$PWD/kubeone-install/dev-master/argodemo-dev-master-kubeconfig kubectl kuttl test --config ./tests/e2e/kuttl-test-master-seed.yaml
  KUBECONFIG=$PWD/kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig kubectl kuttl test --config ./tests/e2e/kuttl-test-seed-india.yaml 
}

# post validation, cleanup
cleanup() {
  echo cleanup all the cluster resources.
  # first destroy master so that kubermatic-operator is gone otherwise it tries to recreate seed node-port-proxy LB
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy
	cd kubeone-install/dev-master && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml --auto-approve
	terraform init && terraform destroy -auto-approve
  cd ../..

  # now destroy seed
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy
	cd kubeone-install/dev-seed && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml --auto-approve
	terraform init && terraform destroy -auto-approve

}

validatePreReq
createSeedClusters
validateSeedClusters
deployArgoApps
installKKP
generateNPushSeedKubeConfig
validateDemoInstallation
cleanup