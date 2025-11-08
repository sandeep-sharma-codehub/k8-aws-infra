# Kubernetes CKA/CKAD Practice Environment on AWS

Self-managed Kubernetes cluster infrastructure on AWS using Terraform, designed for kubernetes learning and Practicing.

Prerequisite: Create a pem key and place it in ~/.ssh location  k8-cluster.pem

## Features

✅ **Production-like Setup**: Multi-node cluster with kubeadm (not EKS)
✅ **Automated Deployment**: One-command cluster deployment
✅ **Full Storage Support**: AWS EBS CSI Driver with multiple StorageClasses
✅ **Networking**: Calico CNI with NetworkPolicy support
✅ **Monitoring**: Metrics Server pre-installed
✅ **Exam-Ready**: Sample resources, RBAC, and real-world configurations
✅ **Cost-Optimized**: ~$70-75/month for complete practice environment

## Quick Start

### 1. Deploy Infrastructure

```bash
# Clone repository
cd k8-aws-infra

# Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-west-2"

# Configure Terraform variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# Deploy AWS infrastructure
terraform init
terraform plan
terraform apply
```

### 2. Deploy Kubernetes Cluster

```bash
# Automated deployment (recommended)
./deploy-cluster.sh
```

**That's it!** Your Kubernetes cluster will be fully configured and ready in ~25-30 minutes.

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for detailed instructions and advanced options.

## What Gets Deployed

### Infrastructure (Terraform)
- **VPC**: Custom VPC with public subnets across multiple AZs
- **EC2 Instances**:
  - 1x Control Plane (t3.medium)
  - 2x Worker Nodes (t3.small, configurable)
- **Security Groups**: Properly configured for Kubernetes communication
- **IAM Roles**: EBS CSI Driver permissions
- **EBS Volumes**: Encrypted gp3 volumes for all nodes

### Kubernetes Components (Automated Setup)
- **Container Runtime**: containerd v1.7.13
- **Kubernetes**: v1.30.0 (configurable)
- **CNI Plugin**: Calico v3.27.0
- **Storage**: AWS EBS CSI Driver v1.28
- **Monitoring**: Metrics Server
- **Sample Resources**: Namespaces, PVCs, Deployments, StatefulSets

### StorageClasses Created
- `ebs-gp3` (default): General Purpose SSD, 3000 IOPS
- `ebs-gp2`: Legacy general purpose SSD
- `ebs-io2`: High-performance provisioned IOPS
- `ebs-sc1`: Cold HDD for throughput-optimized workloads

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         AWS VPC                             │
│  ┌─────────────────────┐  ┌──────────────────────────────┐  │
│  │  Public Subnet 1    │  │     Public Subnet 2          │  │
│  │                     │  │                              │  │
│  │  ┌──────────────┐   │  │  ┌──────────┐  ┌──────────┐  │  │
│  │  │ Control      │   │  │  │ Worker-1 │  │ Worker-2 │  │  │
│  │  │ Plane        │───┼──┼──│          │  │          │  │  │
│  │  │ t3.medium    │   │  │  │t3.medium │  │t3.medium │  │  │
│  │  │              │   │  │  │          │  │          │  │  │
│  │  └──────────────┘   │  │  └──────────┘  └──────────┘  │  │
│  │                     │  │                              │  │
│  │  • API Server       │  │  • kubelet                   │  │
│  │  • etcd             │  │  • Container Runtime         │  │
│  │  • Controller Mgr   │  │  • Calico Node               │  │
│  │  • Scheduler        │  │  • EBS CSI Node Plugin       │  │
│  │  • Calico           │  │                              │  │
│  │  • EBS CSI Driver   │  │                              │  │
│  └─────────────────────┘  └──────────────────────────────┘  │
│                                                             │
│  Security Groups | IAM Roles | Internet Gateway             │
└─────────────────────────────────────────────────────────────┘
                          │
                    [Internet]
                          │
                   [Your Laptop]
```

## Project Structure

```
k8-aws-infra/
├── main.tf                          # Terraform infrastructure
├── variables.tf                     # Configuration variables (30+)
├── outputs.tf                       # Terraform outputs
├── terraform.tfvars.example         # Example configuration
├── setup-control-plane-al2023.sh    # Control plane setup script
├── setup-worker-al2023.sh           # Worker node setup script
├── deploy-cluster.sh                # Automated deployment orchestration
├── DEPLOYMENT_GUIDE.md              # Detailed deployment instructions
└── README.md                        # This file
```

## Prerequisites

- **Terraform**: v1.0 or higher
- **AWS Account**: With appropriate permissions
- **SSH**: For connecting to instances
- **jq**: For parsing JSON (Terraform outputs)
- **Local Machine**: Linux or macOS (Windows WSL supported)

## Configuration Options

Customize your cluster via `terraform.tfvars`:

```hcl
# Instance types
control_plane_instance_type = "t3.medium"   # or t3.large for better performance
worker_node_instance_type   = "t3.medium"   # or t3.medium
worker_node_count          = 2              # 1-10 workers

# Storage
control_plane_volume_size = 30              # GB
worker_node_volume_size   = 20              # GB

# Networking
vpc_cidr           = "10.0.0.0/16"
pod_cidr           = "192.168.0.0/16"
service_cidr       = "10.96.0.0/12"

# Kubernetes version
kubernetes_version = "1.30.0"

# Features
enable_metrics_server        = true
enable_network_policies      = true
create_sample_namespaces     = true
```

See `terraform.tfvars.example` for all options.

## Cost Estimate

**Default Configuration (1 control plane + 2 workers):**

| Component | Monthly Cost |
|-----------|--------------|
| t3.medium (control plane) | ~$30 |
| 2x t3.small (workers) | ~$30 |
| EBS storage (70GB) | ~$5.60 |
| Data transfer | ~$5-10 |
| **Total** | **~$70-75** |

**Minimal Configuration (~$22/month):**
- 1x t3.small control plane
- 1x t3.micro worker
- Reduced storage

**Always run `terraform destroy` when not using the cluster to avoid unnecessary charges.**


### Sample Resources Included

**Namespaces**: frontend, backend, monitoring, testing, production, storage-examples

**Storage Examples**:
- PersistentVolumeClaims with different StorageClasses
- Pod with volume mounts
- Deployment with persistent storage
- StatefulSet with volumeClaimTemplates
- ConfigMaps and Secrets examples

**RBAC Examples**:
- ServiceAccounts
- Roles and RoleBindings
- ClusterRoles and ClusterRoleBindings

**Network Policies**:
- Default deny-all policy in production namespace
- Pod-to-pod communication rules

## Usage

### Accessing the Cluster

```bash
# SSH to control plane
ssh -i ~/.ssh/k8-cluster.pem ec2-user@<control-plane-ip>

# From control plane, use kubectl
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get storageclass
```

### Common Commands

```bash
# View cluster info
kubectl cluster-info

# View nodes with details
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Explore storage examples
kubectl get all -n storage-examples
kubectl get pvc -n storage-examples

# Test storage provisioning
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF

# View created volume
kubectl get pvc test-pvc
kubectl get pv

# Use metrics
kubectl top nodes
kubectl top pods -A
```

### Advanced Deployment Options

```bash
# Deploy with custom SSH key
SSH_KEY_PATH=~/.ssh/my-key.pem ./deploy-cluster.sh

# Deploy workers in parallel (faster)
SETUP_WORKERS_PARALLEL=true ./deploy-cluster.sh

# Skip waiting for nodes to be Ready
WAIT_FOR_READY=false ./deploy-cluster.sh
```

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for more options.

## Verification

After deployment, verify everything works:

```bash
# All nodes should be Ready
kubectl get nodes

# All system pods should be Running
kubectl get pods -n kube-system

# StorageClasses should exist
kubectl get storageclass

# EBS CSI Driver should be running
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n kube-system -l app=ebs-csi-node

# Sample resources should exist
kubectl get all -n storage-examples
```

## Troubleshooting

### SSH Issues
```bash
# Fix key permissions
chmod 400 ~/.ssh/k8-cluster.pem

# Test SSH manually
ssh -i ~/.ssh/k8-cluster.pem ec2-user@<ip>
```

### Deployment Failures
```bash
# Check deployment log
cat deployment-*.log

# View Terraform outputs
terraform output

# Manually run setup scripts
ssh -i ~/.ssh/k8-cluster.pem ec2-user@<control-plane-ip>
sudo /tmp/setup-control-plane-al2023.sh
```

### Node Not Ready
```bash
# Check node status
kubectl describe node <node-name>

# Check kubelet logs
sudo journalctl -u kubelet -f

# Check containerd
sudo systemctl status containerd
```

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for detailed troubleshooting.

## Cluster Maintenance

### Upgrading Kubernetes Version

1. Update `kubernetes_version` in `terraform.tfvars`
2. Run `terraform apply` (updates variables only)
3. Follow kubeadm upgrade procedures on control plane
4. Upgrade worker nodes

### Adding Worker Nodes

1. Update `worker_node_count` in `terraform.tfvars`
2. Run `terraform apply`
3. Run `deploy-cluster.sh` (will only deploy new workers)

### Removing the Cluster

```bash
terraform destroy
```

This removes all AWS resources and stops billing.

## Security Considerations

**For Practice Environment:**
- SSH is open to 0.0.0.0/0 by default (configure `allowed_ssh_cidrs` to restrict)
- No pod security policies enforced by default
- Firewall disabled for simplicity

**For Production Use:**
- Restrict SSH to known IPs
- Enable pod security standards
- Implement proper RBAC
- Enable audit logging
- Set up monitoring and alerting
- Use private subnets for worker nodes
- Enable encryption at rest for etcd

## Cleanup

```bash
# Destroy all infrastructure
terraform destroy

# Remove deployment logs
rm deployment-*.log

# Remove SSH key (if you want)
rm ~/.ssh/k8-cluster.pem
```

## Documentation

- **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)**: Detailed deployment instructions
- **[terraform.tfvars.example](terraform.tfvars.example)**: Configuration examples
- **Inline Comments**: All Terraform and scripts are well-commented

## Support & Contributions

This is a practice environment for learning kubernetes and CKA/CKAD preparation. For issues:
1. Check deployment logs
2. Review Terraform outputs
3. Verify AWS resources in console
4. Check instance logs: `/var/log/cloud-init-output.log`

## License

This project is intended for educational purposes for Kubernetes certification preparation.

## Acknowledgments

Built for hands-on Kubernetes learning and CKA/CKAD exam preparation.

---

**Happy Learning! 🚀**

For detailed deployment instructions, see [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)
