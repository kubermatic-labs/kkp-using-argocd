deploy-argo:
	helm upgrade --install argocd --version 5.36.10 --namespace argocd --create-namespace argo/argo-cd -f values-argocd.yaml
