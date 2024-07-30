KKP_VERSION=v2.25.5
# TODO: To test KKP upgrade scenario
#KKP_VERSION=v2.25.6
INSTALL_DIR=../kubermatic/releases/${KKP_VERSION}


install-kkp-dev:
	${INSTALL_DIR}/kubermatic-installer deploy \
	  --charts-directory ${INSTALL_DIR}/charts --config ./dev/demo-master/k8cConfig.yaml --helm-values ./dev/demo-master/values.yaml --storageclass aws \
	  --skip-charts='cert-manager,nginx-ingress-controller,dex'

create-long-lived-master-seed-kubeconfig:
	${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-master/argodemo-dev-master-kubeconfig | base64 -w0 > ./seed-ready-kube-config

# DEV Master
deploy-argo-dev-master:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.argodemo.lab.kubermatic.io'

deploy-argo-apps-dev-master:
	helm template argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/demo-master/argoapps-values.yaml /opt/kubermatic/community-components/ArgoCD-managed-seed | kubectl apply -f -

push-git-tag-dev:
	git tag -f dev-kkp-${KKP_VERSION}
	git push origin -f dev-kkp-${KKP_VERSION}

# DEV India Seed
deploy-argo-dev-seed:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.india.argodemo.lab.kubermatic.io' --set 'server.ingress.tls[0].hosts[0]=argocd.india.argodemo.lab.kubermatic.io'

deploy-argo-apps-dev-seed:
	helm template argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/india-seed/argoapps-values.yaml /opt/kubermatic/community-components/ArgoCD-managed-seed | kubectl apply -f -

create-long-lived-seed-kubeconfig:
	${INSTALL_DIR}/kubermatic-installer convert-kubeconfig ./kubeone-install/dev-seed/argodemo-dev-seed-kubeconfig > ./seed-ready-kube-config

deploy-kube-prometheus-stack:
	helm upgrade --install -n monitoring1 --create-namespace kube-prometheus-stack prometheus-community/kube-prometheus-stack -f values-kube-prometheus-stack.yaml -f values-kube-prometheus-stack-slack-config.yaml

### Local testing
create-kind-cluster:
	kind create cluster --config=./kind-install/cluster-nodeport.yaml --image kindest/node:v1.27.3

deploy-argo-kind-cluster:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'server.ingress.hosts[0]=argocd.dreamit.local' --set 'server.ingress.tls[0].hosts[0]=argocd.dreamit.local'
deploy-argo-apps-kind-cluster:
	helm template argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/kind/argoapps-values.yaml /opt/kubermatic/community-components/ArgoCD-managed-seed | kubectl apply -f -
