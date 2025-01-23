terraform {
  backend "s3" {
    # bucket = "kubermatic-e2e-test-tf"
    bucket = "cluster-backup-e2e"
    key    = "kkp-argocd-test/tfstate/dev-seed"
    region = "eu-north-1"
  }
}