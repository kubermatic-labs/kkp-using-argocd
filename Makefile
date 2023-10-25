KKP_VERSION=v2.23.2
INSTALL_DIR=/opt/kubermatic/wacker-git/sandbox-setup/kubermatic/mgmt.sandbox.manufacturing.wacker.corp/releases/${KKP_VERSION}


install-kkp-dev:
	${INSTALL_DIR}/kubermatic-installer deploy \
	  --charts-directory ${INSTALL_DIR}/charts --config ./dev/vj1-master/k8cConfig.yaml --helm-values ./dev/vj1-master/values.yaml --storageclass aws \
	  --skip-charts='cert-manager,nginx-ingress-controller,dex'

deploy-argo-dev-master:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'hosts[0]=argocd.vj1.lab.kubermatic.io'

deploy-argo-dev-seed:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml --set 'hosts[0]=argocd.india.vj1.lab.kubermatic.io'

deploy-argo-apps-dev-master:
	helm template argo-apps --set kkpVersion=${KKP_VERSION} -f ./dev/vj1-master/argoapps-values.yaml /opt/kubermatic/community-components/ArgoCD-managed-seed | kubectl apply -f -