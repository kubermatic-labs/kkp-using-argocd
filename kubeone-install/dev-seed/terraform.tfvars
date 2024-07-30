cluster_name = "argodemo-dev-seed"

cluster_autoscaler_max_replicas    = "10"
cluster_autoscaler_min_replicas    = "2"
control_plane_vm_count             = "1"
initial_machinedeployment_replicas = "2"
os                                 = "ubuntu"
ssh_public_key_file                = "~/.ssh/id_rsa.pub"
worker_type                        = "t3a.large"  # so that we get 8GB RAM
control_plane_type                 = "t3a.large"  # so that we get 8GB RAM