cluster_name = "argodemo-dev-master"

vpc_id = "vpc-0f923a77c89ca2d15" # vpc - kkp-argocd-e2e-test-vpc
subnets_cidr = 27
cluster_autoscaler_max_replicas    = "10"
cluster_autoscaler_min_replicas    = "1"
control_plane_vm_count             = "1"
initial_machinedeployment_replicas = "1" # temp reduction to 1 from 2
os                                 = "ubuntu"
ssh_public_key_file                = "~/.ssh/id_rsa.pub"
worker_type                        = "t3a.large"  # so that we get 8GB RAM
control_plane_type                 = "t3a.medium"  # so that we get 8GB RAM
