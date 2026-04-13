# main.tf - Core Terraform Infrastructure for CKA/CKAD Kubernetes Practice Environment

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Purpose     = "CKA-CKAD-Practice"
      ManagedBy   = "Terraform"
    }
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Locals for computed values
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "CKA-CKAD-Practice"
  }

  control_plane_name = "${var.project_name}-control-plane"
  worker_node_prefix = "${var.project_name}-worker"
}

# VPC Configuration
resource "aws_vpc" "k8s_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "k8s_igw" {
  vpc_id = aws_vpc.k8s_vpc.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

# Public Subnets
resource "aws_subnet" "k8s_public_subnet" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.k8s_vpc.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
    Type = "Public"
  })
}

# Route Table for Public Subnets
resource "aws_route_table" "k8s_public_rt" {
  vpc_id = aws_vpc.k8s_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k8s_igw.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

# Route Table Association
resource "aws_route_table_association" "k8s_public_rta" {
  count          = length(aws_subnet.k8s_public_subnet)
  subnet_id      = aws_subnet.k8s_public_subnet[count.index].id
  route_table_id = aws_route_table.k8s_public_rt.id
}

# Security Group for Control Plane
resource "aws_security_group" "k8s_control_plane_sg" {
  name_prefix = "${var.project_name}-control-plane-"
  vpc_id      = aws_vpc.k8s_vpc.id
  description = "Security group for Kubernetes control plane node"

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Kubernetes API server
  ingress {
    description = "Kubernetes API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = concat([var.vpc_cidr], var.allowed_ssh_cidrs)
  }

  # etcd server client API
  ingress {
    description = "etcd server client API"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Kubelet API
  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # kube-controller-manager
  ingress {
    description = "kube-controller-manager"
    from_port   = 10257
    to_port     = 10257
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # kube-scheduler
  ingress {
    description = "kube-scheduler"
    from_port   = 10259
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Calico BGP
  ingress {
    description = "Calico BGP"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Pod-to-pod communication
  ingress {
    description = "Pod-to-pod communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.pod_cidr]
  }

  # All outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-control-plane-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for Worker Nodes
resource "aws_security_group" "k8s_worker_sg" {
  name_prefix = "${var.project_name}-worker-"
  vpc_id      = aws_vpc.k8s_vpc.id
  description = "Security group for Kubernetes worker nodes"

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Kubelet API
  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NodePort Services
  ingress {
    description = "NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Calico BGP
  ingress {
    description = "Calico BGP"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Pod-to-pod communication
  ingress {
    description = "Pod-to-pod communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.pod_cidr]
  }

  # All outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-worker-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Key Pair for SSH access
resource "aws_key_pair" "k8s_key_pair" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "${var.project_name}-keypair"
  public_key = var.public_key

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-keypair"
  })
}

# Control Plane Instance
resource "aws_instance" "k8s_control_plane" {
  ami           = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux.id
  instance_type = var.control_plane_instance_type
  key_name      = var.create_key_pair ? aws_key_pair.k8s_key_pair[0].key_name : var.existing_key_name

  subnet_id                   = aws_subnet.k8s_public_subnet[0].id
  vpc_security_group_ids      = [aws_security_group.k8s_control_plane_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.control_plane_volume_size
    encrypted   = true
    iops        = 3000
    throughput  = 125

    tags = merge(local.common_tags, {
      Name = "${local.control_plane_name}-root-volume"
    })
  }

  tags = merge(local.common_tags, {
    Name = local.control_plane_name
    Role = "control-plane"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# Worker Node Instances
resource "aws_instance" "k8s_worker_nodes" {
  count         = var.worker_node_count
  ami           = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux.id
  instance_type = var.worker_node_instance_type
  key_name      = var.create_key_pair ? aws_key_pair.k8s_key_pair[0].key_name : var.existing_key_name

  subnet_id                   = aws_subnet.k8s_public_subnet[count.index % length(aws_subnet.k8s_public_subnet)].id
  vpc_security_group_ids      = [aws_security_group.k8s_worker_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.worker_node_volume_size
    encrypted   = true
    iops        = 3000
    throughput  = 125

    tags = merge(local.common_tags, {
      Name = "${local.worker_node_prefix}-${count.index + 1}-root-volume"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.worker_node_prefix}-${count.index + 1}"
    Role = "worker"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# IAM Role for EC2 instances (for future use with AWS integrations)
resource "aws_iam_role" "k8s_instance_role" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_instance_profile" "k8s_instance_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.k8s_instance_role.name

  tags = local.common_tags
}

# IAM Policy for EBS CSI Driver
resource "aws_iam_policy" "ebs_csi_driver_policy" {
  name        = "${var.project_name}-ebs-csi-driver-policy"
  description = "Policy for EBS CSI Driver to manage EBS volumes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "CreateVolume",
              "CreateSnapshot"
            ]
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteTags"
        ]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/kubernetes.io/created-for/pvc/name" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeSnapshotName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# Attach EBS CSI Driver Policy to Instance Role
resource "aws_iam_role_policy_attachment" "ebs_csi_driver_attach" {
  role       = aws_iam_role.k8s_instance_role.name
  policy_arn = aws_iam_policy.ebs_csi_driver_policy.arn
}