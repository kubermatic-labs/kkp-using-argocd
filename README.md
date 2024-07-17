# How to setup the ArgoCD based KKP installation

## Preparation

1. use kubeone to create 2 clusters in DEV env - master-seed combo and regular seed
```shell
# make sure to use ssh-keys used do not need any passphrase 
# Setup CP machines and other infra
export AWS_PROFILE=vj-playground
cd dev-master
terraform plan && terraform init
terraform apply -auto-approve
terraform output -json > tf.json
cd ../dev-seed
terraform plan && terraform init
terraform apply -auto-approve
terraform output -json > tf.json

# Apply kubeone and download kubeconfigs
cd ../dev-master
../kubeone apply -t . -m ./kubeone.yaml --verbose
export KUBECONFIG=$PWD/vj-dev-master-kubeconfig # adjust as per cluster name

# in another shell
cd ../dev-seed
../kubeone apply -t . -m ./kubeone.yaml --verbose
export KUBECONFIG=$PWD/vj-dev-seed-kubeconfig  # adjust as per cluster name
```

2. In future - we can create similar 2 clusters for staging env

## KKP with Argo Installation Steps

in each master-seed combo, I need to install in following order
1. ArgoCD ✔
1. Tag the git with right label ✔
1. everything via ArgoCD - at least nginx ingress and cert-manager ✔
1. DNS record ✔ manual
1. KKP EE without helm-charts ✔
1. Apply ClusterIssuer ✔
1. Add seed for self (need manual update of kubeconfig in seed.yaml)
1. Sync all apps in ArgoCD 
1. Seed DNS record AFTER seed has been added (needed for usercluster creation) ✔ manual
```shell
# master-seed combo setup
cd temp-argocd-testing
make deploy-argo-dev-master deploy-argo-apps-dev-master
FIXME: move the argocd-app to be pulled from a repo? Right now referred from local in make target
make push-git-tag-dev

# Apply DNS record manually in AWS Route53
# vj1.lab.kubermatic.io and *.vj1.lab.kubermatic.io
# now you can access ArgoCD at https://argocd.vj1.lab.kubermatic.io

make install-kkp-dev
kubectl apply -f dev/clusterIssuer.yaml
make create-long-lived-master-seed-kubeconfig
base64 -w0 ./seed-ready-kube-config

# Manually update the kubeconfig in the seed-kubeconfig-secret-self.yaml

kubectl apply -f dev/vj1-master/seed-kubeconfig-secret-self.yaml

# Sync apps via ArogCD

# Apply DNS record manually in AWS Route53
# *.self.seed.vj1.lab.kubermatic.io
# now we can create user-clusters on this master-seed cluster

# FIXME: grafana app sync issues. Remove KPS artifacts from common folder

```

In each non-master seed - 
I need to install 
1. ArgoCD and apps ✔
1. Apply ClusterIssuer
1. Seed nginx-ingress DNS record ✔ manual
1. kubeconfig of cluster-admin privs to be created so that it can be added as secret and then this seed be added into master cluster ✔
1. everything via ArgoCD. ✔


```shell
# normal seed setup
make deploy-argo-dev-seed deploy-argo-apps-dev-seed
k apply -f dev/clusterIssuer.yaml

# Apply DNS record manually in AWS Route53
# vj1.lab.kubermatic.io and *.india.vj1.lab.kubermatic.io
# now you can access ArgoCD at https://argocd.vj1.lab.kubermatic.io

make create-long-lived-seed-kubeconfig

# NOTE: export master kubeconfig for below operation
kubectl apply -f dev/vj1-master/seed-kubeconfig-secret-india.yaml

# Sync apps via ArogCD

# Apply DNS record manually in AWS Route53
# *.india.seed.vj1.lab.kubermatic.io
# now we can create user-clusters on this regular seed cluster

```

----

Verification that all works
1. Clusters creation ✔ (only works with public EC2 right now due to lack of NAT gateway. Also not working with india seed)
1. MLA access ✔ india seed - certificate issue
1. minio and velero setup  ✔
1. User-mla install and access?
1. KKP upgrade scenario
    1. Change the KKP version in Makefile ✔
    1. Rollout KKP installer target again ✔
    1. Create new git tag and push this new tag ✔
    1. rollout argo-apps again ✔
1. FIXMEs


TODO:
Presets sync?
Secrets encryption?