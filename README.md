# How to setup the ArgoCD based KKP installation

## Need of GitOps solution
Kubermatic Kubernetes Platform is very versatile solution to create and manage Kuberntes clusters (user-clusters) across plethora of Cloud providers and on-prem virtualizaton platforms. But this flexibility also means that there are good amount of moving parts. Kubermatic Kubernetes Platform (KKP) provides various tools to manage user-clusters across various regions and cloud.

This is why if we utilize a GitOps solution to manage KKP and it's upgrades, KKP administrator would have better peace of mind. While KKP installation does not come ready with a GitOps solution, we have provided a unofficial component for ArgoCD based KKP management.

This page outlines how to install ArgoCD and team provided Apps to manage KKP seeds and their upgrades.

## Preparation

In order to setup and manage KKP using a GitOps solution, one must first know some basics about KKP. Following links could be useful to get that knowledge, if you are new to KKP

**FIXME** - remove version specific link parts

1. [KKP main documentation home](https://docs.kubermatic.com/kubermatic/v2.25/) For general overview. This documentation is quite vast and I would suggest you glance through this but focus on specific links below.
1. [KKP Architecture, terminology and planning](https://docs.kubermatic.com/kubermatic/v2.25/architecture/)
1. [Hardware requirements, firewall requirements](https://docs.kubermatic.com/kubermatic/v2.25/architecture/requirements/cluster-requirements/) and [supported cloud providers](https://docs.kubermatic.com/kubermatic/v2.25/architecture/supported-providers/) and [DNS requirements](https://docs.kubermatic.com/kubermatic/v2.25/installation/install-kkp-ce/#update-dns--tls)

We will install KKP along the way so, we do not need a running KKP installation. But if you already have KKP installation running, you can still make use of this guide to onboard your existing KKP installation to ArgoCD. This might involve in directory re-organization though.

## Introduction
For the demonstration, 
1. we will use 2 kubernetes clusters in AWS (created using Kubeone but they could be any Kubernetes clusters as long as they have a network path to reach each other)
1. install KKP master on one cluster (c1) and also use this cluster as seed (master-seed combo cluster)
1. Make 2nd cluster (c2) as dedicated seed

### ArgoCD Apps
We will install ArgoCD on both the clusters and we will following components on both clusters via ArgoCD. In non-GitOps scenario, some  of these components are managed via kubermatic-installer and rest are left to managed by KKP administrator in master/seed clusters.

1. Core KKP components
    1. DEX (in master)
    1. ngix-ingress-controller
    1. certManager
1. Backup components
    1. Velero
1. Seed monitoring tools
    1. Prometheus
    1. AlertManager
    1. Grafana
    1. KubeStateMetrics
    1. NodeExporter
    1. BlackboxExporter
    1. Identity aware proxy (IAP) for seed monitoring  components
1. Logging components
    1. Promtail
    1. Loki
1. S3 like object storage - minio
1. User-cluster mla components
    1. Minio and Minio Lifecycle Mananger
    1. Grafana
    1. Consul
    1. Cortex
    1. LokiDistributed
    1. AlertmanagerProxy
    1. iap for user-mla
    1. secrets - grafana and minio secrets
1. Seed Settings - Kubermatic configuration, Seed objects, preset objects and such misc objects needed for Seed configuration
1. Seed Extras - This is a generic ArgoCD app to deploy arbitrary resources not covered by above things and as per needs of KKP Admin.

### ADD HERE
> * Directory Structure
> * How to customize ArgoCD templates based on directory structure differences?
> * How to configure ArgoCD Apps - what each app provides for?

## Installation

### Setup two Kubernetes Clusters
This step install two Kubernetes clusters using Kubeone in AWS. You can skip this step, if you already have access to two kubernetes clusters.

FIXME: Where is the source-code for this? 
TODO: k8s-adventure code uses single VM control-plane. Add warning that this is not production ready.

Use kubeone to create 2 clusters in DEV env - master-seed combo and regular seed. Steps below are generic to any kubeone installation. We install basic VMs using terraform and then use kubeone to bootstrap the control plane and worker node machines.

```shell
# directory structure
.
├── dev-master
│   ├── kubeone.yaml
│   ├── main.tf
│   ├── output.tf
│   ├── terraform.tfvars
│   ├── variables.tf
│   ├── versions.tf
├── dev-seed
│   ├── kubeone.yaml
│   ├── main.tf
│   ├── output.tf
│   ├── terraform.tfvars
│   ├── variables.tf
│   ├── versions.tf
└── kubeone

# Kubeone needs ssh-keys to communicate with machines.
# make sure to use ssh-keys which do not need any passphrase 

# Setup CP machines and other infra
export AWS_PROFILE=<your AWS profile>
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

This same folder structure can be further expanded to add kubeone installations for additional environments like staging and prod.

### Installation of KKP with Argo Installation Steps

For ease of installation, I have prepared a `Makefile` to just make commands easier to read. Internally, it just depends on helm, kubectl and kubermatic-installer binaries.

#### Installation of KKP Master-seed combo
1. Install ArgoCD and all the ArgoCD Apps
    ```shell
    cd temp-argocd-testing
    make deploy-argo-dev-master deploy-argo-apps-dev-master
    FIXME: move the argocd-app to be pulled from a repo? Right now referred from local in make target
    ```
1. Tag the git with right label
    TODO: Talk about what is right label
    ```shell
    make push-git-tag-dev
    ```
1. ArgoCD syncs nginx ingress and cert-manager automatically
1. Manually update the DNS records so that ArgoCD is accessible. TODO: elaborate DNS naming structure
    ```shell
    # Apply DNS record manually in AWS Route53
    # vj1.lab.kubermatic.io and *.vj1.lab.kubermatic.io
    # now you can access ArgoCD at https://argocd.vj1.lab.kubermatic.io
    ```
1. Install KKP EE without helm-charts. If we want to finish the demo with separate seed, we will need Enterprise Edition KKP. You can run the demo with master-seed combo, you can use community edition of KKP.
    ```shell
    make install-kkp-dev
    ```
1. Apply ClusterIssuer. Note: During the demo, we are using staging letsencrypt certificate provider. In real world, you should use production lets-encrypt certificate issuer. Just need to change the url in below. TODO: Can we not roll this out via ArgoCD as well?
    ```shell
    kubectl apply -f dev/clusterIssuer.yaml
    ```
1. Add seed for self (need manual update of kubeconfig in seed.yaml)
    ```shell
    make create-long-lived-master-seed-kubeconfig
    # above target creates a file seed-ready-kube-config
    base64 -w0 ./seed-ready-kube-config
    # Manually update the output of above commend in the seed-kubeconfig-secret-self.yaml
    kubectl apply -f dev/vj1-master/seed-kubeconfig-secret-self.yaml
    ```
1. Sync all apps in ArgoCD by accessing ArgoCD UI and syncing apps manually
1. Seed DNS record AFTER seed has been added (needed for usercluster creation) manual
    ```shell
    # Apply DNS record manually in AWS Route53
    # *.self.seed.vj1.lab.kubermatic.io
    ```
1. Now we can create user-clusters on this master-seed cluster

#### Installation of dedicated KKP seed
> Note: You can follow these steps only if you have a KKP EE license with you. With KKP CE licence, you can only work with one seed (which is master-seed combo above)

We follow simlar procedure as master-seed combo but with slightly different commands.

1. Install ArgoCD and all the ArgoCD Apps
    ```shell
    make deploy-argo-dev-seed deploy-argo-apps-dev-seed
    ```
1. Apply ClusterIssuer. Note: During the demo, we are using staging letsencrypt certificate provider. In real world, you should use production lets-encrypt certificate issuer. Just need to change the url in below. TODO: Can we not roll this out via ArgoCD as well?
    ```shell
    kubectl apply -f dev/clusterIssuer.yaml
    ```
1. Add Seed nginx-ingress DNS record
    ```shell
    # Apply DNS record manually in AWS Route53
    # india.vj1.lab.kubermatic.io and *.india.vj1.lab.kubermatic.io
    # now you can access ArgoCD at https://argocd.india.vj1.lab.kubermatic.io
    ```
1. Prepare kubeconfig of cluster-admin privileges so that it can be added as secret and then this cluster can be added as Seed in master cluster configuration
    ```shell
    make create-long-lived-seed-kubeconfig

    # NOTE: export master kubeconfig for below operation
    kubectl apply -f dev/vj1-master/seed-kubeconfig-secret-india.yaml
    ```
1. Sync all apps in ArgoCD by accessing ArgoCD UI and syncing apps manually
1. Add Seed nodeport proxy DNS record
```shell
# Apply DNS record manually in AWS Route53
# *.india.seed.vj1.lab.kubermatic.io
```
1. Now we can create user-clusters on this dedicated seed cluster as well.

----

## Verification that this entire setup works
1. Clusters creation on both the seeds (**Note:** If your VPC does not have a NAT Gateway, then worker nodes must have public IP)
1. Access All Monitoring, Logging, Alerting links - available in left nav on any project within KKP.
1. Check minio and velero setup
1. Check User-mla grafana and see you can access user-cluster metrics and logs. You must remember to enable user-cluster monitoring and logging during creation of user-cluster.
1. KKP upgrade scenario
    1. Change the KKP version in Makefile
    1. Rollout KKP installer target again
    1. Create new git tag and push this new tag
    1. rollout argo-apps again and sync all apps on both seeds.


## Further improvements which still to be done
1. Use Secrets folder (e.g. with git-crypt)
1. Sync Presets
1. Thanos Application
1. Can we look at moving Argo App templates to ApplicationSet / App of Apps?
1. Optional External-DNS app so that DNS entries can be done separately.
1. Can we run make targets via Github actions?
