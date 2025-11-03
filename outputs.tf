# outputs.tf - Output information for CKA/CKAD Kubernetes Infrastructure

locals {
  key_pair_name = var.create_key_pair ? aws_key_pair.k8s_key_pair[0].key_name : var.existing_key_name
}

# VPC and Network Information
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.k8s_vpc.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.k8s_vpc.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.k8s_public_subnet[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.k8s_igw.id
}

# Security Group Information
output "control_plane_security_group_id" {
  description = "Security group ID for control plane node"
  value       = aws_security_group.k8s_control_plane_sg.id
}

output "worker_nodes_security_group_id" {
  description = "Security group ID for worker nodes"
  value       = aws_security_group.k8s_worker_sg.id
}

# Key Pair Information
output "key_pair_name" {
  description = "Name of the EC2 key pair used"
  value       = local.key_pair_name
}

# Control Plane Node Information
output "control_plane_instance_id" {
  description = "Instance ID of the control plane node"
  value       = aws_instance.k8s_control_plane.id
}

output "control_plane_public_ip" {
  description = "Public IP address of the control plane node"
  value       = aws_instance.k8s_control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP address of the control plane node"
  value       = aws_instance.k8s_control_plane.private_ip
}

output "control_plane_public_dns" {
  description = "Public DNS name of the control plane node"
  value       = aws_instance.k8s_control_plane.public_dns
}

# Worker Nodes Information
output "worker_node_instance_ids" {
  description = "Instance IDs of the worker nodes"
  value       = aws_instance.k8s_worker_nodes[*].id
}

output "worker_node_public_ips" {
  description = "Public IP addresses of the worker nodes"
  value       = aws_instance.k8s_worker_nodes[*].public_ip
}

output "worker_node_private_ips" {
  description = "Private IP addresses of the worker nodes"
  value       = aws_instance.k8s_worker_nodes[*].private_ip
}

output "worker_node_public_dns" {
  description = "Public DNS names of the worker nodes"
  value       = aws_instance.k8s_worker_nodes[*].public_dns
}

# SSH Connection Commands
output "ssh_command_control_plane" {
  description = "SSH command to connect to the control plane node"
  value       = "ssh -i ~/.ssh/${local.key_pair_name}.pem ec2-user@${aws_instance.k8s_control_plane.public_ip}"
}

output "ssh_commands_worker_nodes" {
  description = "SSH commands to connect to worker nodes"
  value = [
    for i, instance in aws_instance.k8s_worker_nodes :
    "ssh -i ~/.ssh/${local.key_pair_name}.pem ec2-user@${instance.public_ip}"
  ]
}

# Kubernetes Configuration Information
output "kubernetes_api_server_url" {
  description = "Kubernetes API server URL"
  value       = "https://${aws_instance.k8s_control_plane.public_ip}:6443"
}

output "cluster_name" {
  description = "Name of the Kubernetes cluster"
  value       = "${var.project_name}-cluster"
}

output "pod_network_cidr" {
  description = "CIDR block for pod network"
  value       = var.pod_cidr
}

output "service_network_cidr" {
  description = "CIDR block for service network"
  value       = var.service_cidr
}

# Setup Instructions
output "setup_instructions" {
  description = "Step-by-step setup instructions"
  value = <<-EOT
    # Kubernetes CKA/CKAD Practice Environment Setup Instructions

    ## 1. Connect to Control Plane Node
    ${join("\n    ", [
      "ssh -i ~/.ssh/${local.key_pair_name}.pem ec2-user@${aws_instance.k8s_control_plane.public_ip}"
    ])}

    ## 2. Initialize Kubernetes Cluster on Control Plane
    Execute your control plane setup script on the control plane node.

    ## 3. Connect to Worker Nodes
    ${join("\n    ", flatten([
      for i, instance in aws_instance.k8s_worker_nodes : [
        "# Worker Node ${i + 1}:",
        "ssh -i ~/.ssh/${local.key_pair_name}.pem ec2-user@${instance.public_ip}"
      ]
    ]))}

    ## 4. Join Worker Nodes to Cluster
    Execute your worker node setup script on each worker node.

    ## 5. Verify Cluster Status
    kubectl get nodes
    kubectl get pods --all-namespaces

    ## 6. Access Cluster Externally (if needed)
    kubectl config set-cluster ${var.project_name}-cluster --server=https://${aws_instance.k8s_control_plane.public_ip}:6443

    ## Cluster Information
    - Control Plane: ${aws_instance.k8s_control_plane.public_ip}
    - Worker Nodes: ${join(", ", aws_instance.k8s_worker_nodes[*].public_ip)}
    - VPC CIDR: ${var.vpc_cidr}
    - Pod Network: ${var.pod_cidr}
    - Service Network: ${var.service_cidr}
  EOT
}

# Cost Estimation
output "estimated_monthly_cost" {
  description = "Estimated monthly cost in USD (approximate)"
  value = {
    control_plane_instance = "~$25-35/month (t3.medium)"
    worker_nodes          = "~$15-20/month per node (t3.small)"
    total_instances       = "~${25 + (var.worker_node_count * 15)}-${35 + (var.worker_node_count * 20)}/month"
    ebs_storage          = "~${(var.control_plane_volume_size + (var.worker_node_count * var.worker_node_volume_size)) * 0.08}/month"
    data_transfer        = "~$5-15/month (depends on usage)"
    note                 = "Costs may vary based on region, usage patterns, and AWS pricing changes"
  }
}

# Resource Summary
output "resource_summary" {
  description = "Summary of created resources"
  value = {
    vpc                    = 1
    subnets               = length(var.public_subnet_cidrs)
    internet_gateway      = 1
    route_tables          = 1
    security_groups       = 2
    ec2_instances         = 1 + var.worker_node_count
    ebs_volumes          = 1 + var.worker_node_count
    key_pairs            = var.create_key_pair ? 1 : 0
    iam_roles            = 1
    iam_instance_profiles = 1
  }
}

# Cluster Join Information (for manual setup)
output "cluster_join_command_template" {
  description = "Template for kubeadm join command (to be populated after cluster init)"
  value       = "kubeadm join ${aws_instance.k8s_control_plane.private_ip}:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
}

# Network Configuration for Scripts
output "network_configuration" {
  description = "Network configuration for setup scripts"
  value = {
    vpc_cidr           = var.vpc_cidr
    pod_cidr          = var.pod_cidr
    service_cidr      = var.service_cidr
    control_plane_ip  = aws_instance.k8s_control_plane.private_ip
    worker_node_ips   = aws_instance.k8s_worker_nodes[*].private_ip
    dns_domain        = "cluster.local"
  }
}

# Security Information
output "security_configuration" {
  description = "Security configuration details"
  value = {
    control_plane_sg_id = aws_security_group.k8s_control_plane_sg.id
    worker_node_sg_id   = aws_security_group.k8s_worker_sg.id
    allowed_ssh_cidrs   = var.allowed_ssh_cidrs
    encryption_enabled  = true
    key_pair_name      = local.key_pair_name
  }
}

# Validation Checks
output "validation_checks" {
  description = "Commands to validate the infrastructure"
  value = <<-EOT
    # Infrastructure Validation Commands

    ## 1. Verify EC2 Instances
    aws ec2 describe-instances --region ${var.aws_region} --filters "Name=tag:Project,Values=${var.project_name}"

    ## 2. Check Security Groups
    aws ec2 describe-security-groups --region ${var.aws_region} --group-ids ${aws_security_group.k8s_control_plane_sg.id} ${aws_security_group.k8s_worker_sg.id}

    ## 3. Verify Network Connectivity
    # Test SSH connectivity to all nodes
    # Test port 6443 connectivity to control plane
    # Test inter-node communication

    ## 4. Validate DNS Resolution
    nslookup ${aws_instance.k8s_control_plane.public_dns}
    ${join("\n    ", [for instance in aws_instance.k8s_worker_nodes : "nslookup ${instance.public_dns}"])}

    ## 5. Check Instance Health
    aws ec2 describe-instance-status --region ${var.aws_region} --instance-ids ${aws_instance.k8s_control_plane.id} ${join(" ", aws_instance.k8s_worker_nodes[*].id)}
  EOT
}

# Cleanup Instructions
output "cleanup_instructions" {
  description = "Instructions to clean up resources"
  value = <<-EOT
    # Cleanup Instructions

    ## 1. Terraform Destroy
    terraform destroy -auto-approve

    ## 2. Manual Cleanup (if needed)
    # Check for any remaining EBS snapshots
    aws ec2 describe-snapshots --region ${var.aws_region} --owner-ids self --filters "Name=tag:Project,Values=${var.project_name}"

    # Check for any remaining security groups
    aws ec2 describe-security-groups --region ${var.aws_region} --filters "Name=tag:Project,Values=${var.project_name}"

    # Verify VPC deletion
    aws ec2 describe-vpcs --region ${var.aws_region} --filters "Name=tag:Project,Values=${var.project_name}"
    # Check AWS billing dashboard to confirm no ongoing charges
  EOT
}