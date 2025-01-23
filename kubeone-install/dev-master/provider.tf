terraform {
  backend "s3" {
    bucket = "kubermatic-e2e-test-tf"
    key    = "tfstate/dev-master"
    region = "eu-north-1"
  }
}