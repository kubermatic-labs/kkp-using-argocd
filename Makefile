K1_VERSION=1.8.3
# To upgrade KKP, update the version of kkp here.
#KKP_VERSION=v2.25.11
KKP_VERSION=v2.26.2
INSTALL_DIR=./binaries/kubermatic/releases/${KKP_VERSION}
KUBEONE_INSTALL_DIR=./binaries/kubeone/releases/${K1_VERSION}
MASTER_KUBECONFIG=./kubeone-install/dev-master/argodemo-dev-master-kubeconfig
SEED_KUBECONFIG=./kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig

#use e.g. for MAC OS: BIN_ARCH=darwin-amd64 make download-kkp-release
BIN_ARCH ?= linux-amd64
download-kkp-release:
	mkdir -p ${INSTALL_DIR}/
	wget https://github.com/kubermatic/kubermatic/releases/download/${KKP_VERSION}/kubermatic-ee-${KKP_VERSION}-${BIN_ARCH}.tar.gz -O- | tar -xz --directory ${INSTALL_DIR}/

download-kubeone-release:
	mkdir -p ${KUBEONE_INSTALL_DIR}
	curl -LO "https://github.com/kubermatic/kubeone/releases/download/v${K1_VERSION}/kubeone_${K1_VERSION}_linux_amd64.zip" && \
    unzip kubeone_${K1_VERSION}_linux_amd64.zip -d kubeone_${K1_VERSION}_linux_amd64 && \
    mv kubeone_${K1_VERSION}_linux_amd64/kubeone ${KUBEONE_INSTALL_DIR} && rm -rf kubeone_${K1_VERSION}_linux_amd64 kubeone_${K1_VERSION}_linux_amd64.zip

k1-apply-master:
	cd kubeone-install/dev-master && terraform init && terraform apply &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml

k1-detroy-master:
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller
	KUBECONFIG=${MASTER_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy
	cd kubeone-install/dev-master && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml
	cd kubeone-install/dev-master && terraform init && terraform destroy

k1-apply-seed:
	cd kubeone-install/dev-seed && terraform init && terraform apply &&../../${KUBEONE_INSTALL_DIR}/kubeone apply -t . -m kubeone.yaml

k1-detroy-seed:
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete app -n argocd nginx-ingress-controller
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n nginx-ingress-controller nginx-ingress-controller
	KUBECONFIG=${SEED_KUBECONFIG} kubectl delete svc -n kubermatic nodeport-proxy
	cd kubeone-install/dev-seed && ../../${KUBEONE_INSTALL_DIR}/kubeone reset -t . -m kubeone.yaml
	cd kubeone-install/dev-seed && terraform init && terraform destroy

install-kkp-dev:
	KUBECONFIG=${MASTER_KUBECONFIG} ${INSTALL_DIR}/kubermatic-installer deploy \
	  --charts-directory ${INSTALL_DIR}/charts --config ./dev/demo-master/k8cConfig.yaml --helm-values ./dev/demo-master/values.yaml \
	  --skip-charts='cert-manager,nginx-ingress-controller,dex'

# install-kkp-dev-user-mla:
# 	${INSTALL_DIR}/kubermatic-installer deploy usercluster-mla \
# 	  --charts-directory ${INSTALL_DIR}/charts --config ./dev/demo-master/k8cConfig.yaml --helm-values ./dev/demo-master/values-usermla.yaml

create-long-lived-master-seed-kubeconfig:
	@kubeconfig=$$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-master/argodemo-dev-master-kubeconfig | base64 -w0) && \
	sed -i "/kubeconfig: /s/: .*/: `echo $$kubeconfig`/" dev/demo-master/seed-kubeconfig-secret-self.yaml

# DEV Master
deploy-argo-dev-master:
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.argodemo.lab.kubermatic.io'

deploy-argo-apps-dev-master:
	helm repo add dharapvj https://dharapvj.github.io/helm-charts/
	helm repo update dharapvj
	KUBECONFIG=${MASTER_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/demo-master/argoapps-values.yaml dharapvj/argocd-apps

push-git-tag-dev:
	git tag -f dev-kkp-${KKP_VERSION}
	git push origin -f dev-kkp-${KKP_VERSION}

# DEV India Seed
deploy-argo-dev-seed:
	KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.india.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.india.argodemo.lab.kubermatic.io'

deploy-argo-apps-dev-seed:
	helm repo add dharapvj https://dharapvj.github.io/helm-charts/
	helm repo update dharapvj
	KUBECONFIG=${SEED_KUBECONFIG} helm upgrade --install kkp-argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/india-seed/argoapps-values.yaml dharapvj/argocd-apps

create-long-lived-seed-kubeconfig:
	@kubeconfig=$$(${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig | base64 -w0) && \
	sed -i "/kubeconfig: /s/: .*/: `echo $$kubeconfig`/" dev/demo-master/seed-kubeconfig-secret-india.yaml

# deploy-kube-prometheus-stack:
# 	helm upgrade --install -n monitoring1 --create-namespace kube-prometheus-stack prometheus-community/kube-prometheus-stack -f values-kube-prometheus-stack.yaml -f values-kube-prometheus-stack-slack-config.yaml

# ### Local testing
# create-kind-cluster:
# 	kind create cluster --config=./kind-install/cluster-nodeport.yaml --image kindest/node:v1.27.3

# deploy-argo-kind-cluster:
# 	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.dreamit.local' --set 'server.ingress.tls[0].hosts[0]=argocd.dreamit.local'
# deploy-argo-apps-kind-cluster:
# 	helm template argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/kind/argoapps-values.yaml /opt/kubermatic/community-components/ArgoCD-managed-seed | kubectl apply -f -

# TEMP
deploy-external-dns:
	helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
	helm repo update external-dns
	helm upgrade --install external-dns external-dns/external-dns -f ./values-external-dns.yaml
