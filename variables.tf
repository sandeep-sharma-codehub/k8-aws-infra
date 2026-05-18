# variables.tf - Configuration variables for CKA/CKAD Kubernetes Infrastructure

# =============================================================================
# GENERAL CONFIGURATION
# =============================================================================

variable "aws_region" {
  description = "AWS region for infrastructure deployment"
  type        = string
  default     = "us-west-2"

  validation {
    condition = can(regex("^[a-z]+-[a-z]+-[0-9]$", var.aws_region))
    error_message = "AWS region must be a valid region format (e.g., us-west-2)."
  }
}

variable "project_name" {
  description = "Name of the project, used for resource naming and tagging"
  type        = string
  default     = "k8s-cka-ckad"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.project_name))
    error_message = "Project name can only contain alphanumeric characters and hyphens."
  }
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "practice"

  validation {
    condition     = contains(["dev", "staging", "prod", "practice", "lab"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, practice, lab."
  }
}

# =============================================================================
# NETWORK CONFIGURATION
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least 2 public subnets are required for high availability."
  }
}

variable "pod_cidr" {
  description = "CIDR block for Kubernetes pods (used by CNI)"
  type        = string
  default     = "192.168.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "Pod CIDR must be a valid IPv4 CIDR block."
  }
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.96.0.0/12"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "Service CIDR must be a valid IPv4 CIDR block."
  }
}

# =============================================================================
# SECURITY CONFIGURATION
# =============================================================================

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to instances"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = alltrue([
      for cidr in var.allowed_ssh_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All SSH CIDR blocks must be valid IPv4 CIDR blocks."
  }
}

# =============================================================================
# INSTANCE CONFIGURATION
# =============================================================================

variable "ami_id" {
  description = "AMI ID for EC2 instances (leave empty to use latest Amazon Linux 2023)"
  type        = string
  default     = ""
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane node"
  type        = string
  default     = "t3.medium"

  validation {
    condition = contains([
      "t3.small", "t3.medium", "t3.large", "t3.xlarge",
      "m5.large", "m5.xlarge", "m5.2xlarge",
      "c5.large", "c5.xlarge", "c5.2xlarge"
    ], var.control_plane_instance_type)
    error_message = "Control plane instance type must be suitable for Kubernetes control plane (minimum t3.medium recommended)."
  }
}

variable "worker_node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"

  validation {
    condition = contains([
      "t3.micro", "t3.small", "t3.medium", "t3.large",
      "m5.large", "m5.xlarge", "c5.large", "c5.xlarge"
    ], var.worker_node_instance_type)
    error_message = "Worker node instance type must be suitable for Kubernetes workloads."
  }
}

variable "worker_node_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_node_count >= 1 && var.worker_node_count <= 10
    error_message = "Worker node count must be between 1 and 10."
  }
}

# =============================================================================
# STORAGE CONFIGURATION
# =============================================================================

variable "control_plane_volume_size" {
  description = "Root volume size in GB for control plane node"
  type        = number
  default     = 30

  validation {
    condition     = var.control_plane_volume_size >= 20 && var.control_plane_volume_size <= 500
    error_message = "Control plane volume size must be between 20GB and 500GB."
  }
}

variable "worker_node_volume_size" {
  description = "Root volume size in GB for worker nodes"
  type        = number
  default     = 20

  validation {
    condition     = var.worker_node_volume_size >= 15 && var.worker_node_volume_size <= 500
    error_message = "Worker node volume size must be between 15GB and 500GB."
  }
}

# =============================================================================
# SSH KEY CONFIGURATION
# =============================================================================

variable "create_key_pair" {
  description = "Whether to create a new EC2 key pair"
  type        = bool
  default     = true
}

variable "public_key" {
  description = "Public key content for EC2 key pair (required if create_key_pair is true)"
  type        = string
  default     = ""
  sensitive   = false
}

variable "existing_key_name" {
  description = "Name of existing EC2 key pair (required if create_key_pair is false)"
  type        = string
  default     = ""
}

# =============================================================================
# KUBERNETES CONFIGURATION
# =============================================================================

variable "kubernetes_version" {
  description = "Kubernetes version to install"
  type        = string
  default     = "1.30.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "Kubernetes version must be in semantic version format (e.g., 1.30.0)."
  }
}

variable "container_runtime" {
  description = "Container runtime to use (containerd or cri-o)"
  type        = string
  default     = "containerd"

  validation {
    condition     = contains(["containerd", "cri-o"], var.container_runtime)
    error_message = "Container runtime must be either 'containerd' or 'cri-o'."
  }
}

variable "cni_plugin" {
  description = "CNI plugin to install (calico, flannel, weave)"
  type        = string
  default     = "calico"

  validation {
    condition     = contains(["calico", "flannel", "weave"], var.cni_plugin)
    error_message = "CNI plugin must be one of: calico, flannel, weave."
  }
}

# =============================================================================
# FEATURE FLAGS
# =============================================================================

variable "enable_audit_logging" {
  description = "Enable Kubernetes audit logging"
  type        = bool
  default     = true
}

variable "enable_network_policies" {
  description = "Enable NetworkPolicy support (requires compatible CNI)"
  type        = bool
  default     = true
}

variable "enable_ingress_controller" {
  description = "Install NGINX Ingress Controller"
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Install Kubernetes Metrics Server"
  type        = bool
  default     = true
}

# =============================================================================
# COST OPTIMIZATION
# =============================================================================

variable "enable_spot_instances" {
  description = "Use spot instances for worker nodes (cost optimization, ~60-70% cheaper)"
  type        = bool
  default     = false
}

variable "enable_spot_control_plane" {
  description = "Use spot instance for control plane (saves cost but risks cluster downtime on interruption)"
  type        = bool
  default     = false
}

variable "spot_instance_interruption_behavior" {
  description = "Behavior when a spot instance is interrupted (stop, terminate)"
  type        = string
  default     = "terminate"

  validation {
    condition     = contains(["stop", "terminate"], var.spot_instance_interruption_behavior)
    error_message = "Spot instance interruption behavior must be either 'stop' or 'terminate'."
  }
}

variable "auto_shutdown_enabled" {
  description = "Enable automatic shutdown of instances during off-hours"
  type        = bool
  default     = false
}

variable "auto_shutdown_time" {
  description = "Time to automatically shutdown instances (24-hour format, e.g., '18:00')"
  type        = string
  default     = "18:00"

  validation {
    condition     = can(regex("^([0-1][0-9]|2[0-3]):[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "Auto shutdown time must be in HH:MM format (24-hour)."
  }
}

# =============================================================================
# MONITORING AND LOGGING
# =============================================================================

variable "enable_cloudwatch_logs" {
  description = "Enable CloudWatch logging for instances"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 7

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653
    ], var.log_retention_days)
    error_message = "Log retention days must be a valid CloudWatch retention period."
  }
}

# =============================================================================
# ADDITIONAL CONFIGURATION
# =============================================================================

variable "install_additional_tools" {
  description = "Install additional tools for CKA/CKAD practice (helm, istio, etc.)"
  type        = bool
  default     = true
}

variable "create_sample_namespaces" {
  description = "Create sample namespaces for practice"
  type        = bool
  default     = true
}

variable "sample_namespaces" {
  description = "List of sample namespaces to create"
  type        = list(string)
  default     = ["frontend", "backend", "monitoring", "testing", "production"]

  validation {
    condition = alltrue([
      for ns in var.sample_namespaces : can(regex("^[a-z0-9-]+$", ns))
    ])
    error_message = "Namespace names must contain only lowercase letters, numbers, and hyphens."
  }
}

# =============================================================================
# BACKUP AND DISASTER RECOVERY
# =============================================================================

variable "enable_ebs_snapshots" {
  description = "Enable automatic EBS snapshots"
  type        = bool
  default     = false
}

variable "snapshot_retention_days" {
  description = "Number of days to retain EBS snapshots"
  type        = number
  default     = 7

  validation {
    condition     = var.snapshot_retention_days >= 1 && var.snapshot_retention_days <= 365
    error_message = "Snapshot retention days must be between 1 and 365."
  }
}