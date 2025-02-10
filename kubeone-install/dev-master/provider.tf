terraform {
  backend "s3" {
    bucket = "kubermatic-e2e-test-tf"
    region = "eu-central-1"
    # bucket = "cluster-backup-e2e"
    # region = "eu-west-1"
    key    = "kkp-argocd-test/tfstate/dev-master"
  }
}