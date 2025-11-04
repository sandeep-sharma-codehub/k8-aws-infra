# Kubernetes Cluster Deployment Guide

## Quick Start

### 1. Deploy Infrastructure with Terraform

```bash
# Configure your variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

### 2. Deploy Kubernetes Cluster

```bash
# Simple one-command deployment
./deploy-cluster.sh
```

That's it! The script will:
- Verify prerequisites and Terraform outputs
- Copy setup scripts to control plane and workers
- Execute setup scripts with sudo permissions
- Retrieve kubeadm join command automatically
- Join all worker nodes to the cluster
- Verify cluster health
- Display cluster status and next steps

---

## Advanced Usage

### Custom SSH Key Location

```bash
SSH_KEY_PATH=~/.ssh/my-custom-key.pem ./deploy-cluster.sh
```

### Parallel Worker Deployment (Faster)

```bash
SETUP_WORKERS_PARALLEL=true ./deploy-cluster.sh
```

### Skip Waiting for Nodes to be Ready

```bash
WAIT_FOR_READY=false ./deploy-cluster.sh
```

### Custom SSH User

```bash
SSH_USER=ubuntu ./deploy-cluster.sh
```

### Combine Multiple Options

```bash
SSH_KEY_PATH=~/.ssh/my-key.pem \
SETUP_WORKERS_PARALLEL=true \
./deploy-cluster.sh
```

---

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_KEY_PATH` | Auto-detect | Path to SSH private key |
| `TERRAFORM_DIR` | `.` (current) | Terraform project directory |
| `SETUP_WORKERS_PARALLEL` | `false` | Deploy workers in parallel |
| `WAIT_FOR_READY` | `true` | Wait for nodes to be Ready |
| `MAX_RETRY_ATTEMPTS` | `3` | SSH connection retry attempts |
| `CONNECTION_TIMEOUT` | `10` | SSH connection timeout (seconds) |
| `SSH_USER` | `ec2-user` | SSH user for EC2 instances |

---

## What the Script Does

### Phase 1: Pre-flight Checks
- Verifies Terraform state exists
- Checks required commands (terraform, ssh, scp, jq)
- Validates setup scripts exist
- Retrieves Terraform outputs (IPs, SSH key name)
- Auto-detects SSH key location
- Tests SSH connectivity to all nodes

### Phase 2: Control Plane Deployment
- Copies `setup-control-plane-al2023.sh` to control plane
- Executes setup script with sudo
- Installs and configures:
  - containerd runtime
  - Kubernetes components (kubelet, kubeadm, kubectl)
  - Calico CNI
  - Metrics Server
  - EBS CSI Driver
  - StorageClasses
  - Sample storage resources
- Retrieves kubeadm join command

### Phase 3: Worker Nodes Deployment
- For each worker node:
  - Copies `setup-worker-al2023.sh`
  - Executes setup script with join command
  - Installs containerd and Kubernetes
  - Joins node to cluster
- Can run sequentially (default) or in parallel
- Continues with warnings if a worker fails

### Phase 4: Verification
- Waits for all nodes to become Ready (optional)
- Displays cluster status (`kubectl get nodes`)
- Shows system pods status
- Displays StorageClasses
- Shows sample storage resources

---

## Expected Output

```
==============================================================================
Kubernetes Cluster Deployment Automation
==============================================================================

[2025-11-04 10:15:23] Starting deployment at Mon Nov  4 10:15:23 PST 2025
[2025-11-04 10:15:23] Deployment log: deployment-20251104-101523.log

================================================================================
[Phase 1] Pre-flight Checks
================================================================================
✓ Terraform directory found
✓ Terraform state found
✓ Required commands available
✓ Control plane setup script found
✓ Worker setup script found
✓ Control plane IP: 54.123.45.67
✓ Worker nodes found: 2
  Worker 1: 54.123.45.68
  Worker 2: 54.123.45.69
✓ SSH key found: ~/.ssh/k8s-cluster.pem
✓ Control plane SSH connection verified
✓ Worker 1 SSH connection verified
✓ Worker 2 SSH connection verified

================================================================================
[Phase 2] Control Plane Deployment (54.123.45.67)
================================================================================
[2025-11-04 10:16:01] Copying control plane setup script...
✓ File copied successfully
[2025-11-04 10:16:02] Executing control plane setup script...

[Control Plane] [2025-11-04 10:16:05] Starting Kubernetes Control Plane setup...
[Control Plane] [2025-11-04 10:16:45] System preparation completed
[Control Plane] [2025-11-04 10:17:30] Hostname set to: k8s-control-plane
[Control Plane] [2025-11-04 10:20:15] containerd installed
[Control Plane] [2025-11-04 10:23:40] Kubernetes components installed
[Control Plane] [2025-11-04 10:25:20] Cluster initialized successfully
[Control Plane] [2025-11-04 10:27:00] Calico CNI installed
[Control Plane] [2025-11-04 10:27:45] Metrics Server installed
[Control Plane] [2025-11-04 10:28:30] AWS EBS CSI Driver installed
[Control Plane] [2025-11-04 10:28:45] StorageClasses created
[Control Plane] [2025-11-04 10:29:10] Sample storage resources created
[Control Plane] [2025-11-04 10:29:30] Setup completed successfully!

✓ Control plane setup completed successfully
✓ Join command retrieved successfully

================================================================================
[Phase 3] Worker Nodes Deployment
================================================================================
[2025-11-04 10:30:00] Deploying workers sequentially...
[2025-11-04 10:30:01] Deploying worker-1 (54.123.45.68)...
✓ File copied successfully
[2025-11-04 10:30:15] Executing worker-1 setup script...

[Worker-1] [2025-11-04 10:30:20] Starting Kubernetes Worker Node setup...
[Worker-1] [2025-11-04 10:35:40] Worker node joined successfully
✓ Worker-1 setup completed successfully

[2025-11-04 10:36:00] Deploying worker-2 (54.123.45.69)...
✓ File copied successfully
[2025-11-04 10:36:15] Executing worker-2 setup script...

[Worker-2] [2025-11-04 10:36:20] Starting Kubernetes Worker Node setup...
[Worker-2] [2025-11-04 10:41:35] Worker node joined successfully
✓ Worker-2 setup completed successfully

✓ All workers deployed successfully

================================================================================
[Phase 4] Cluster Verification
================================================================================
✓ All nodes are Ready

[Cluster] NAME                STATUS   ROLE           AGE   VERSION
[Cluster] k8s-control-plane   Ready    control-plane  15m   v1.30.0
[Cluster] k8s-worker-1        Ready    <none>         5m    v1.30.0
[Cluster] k8s-worker-2        Ready    <none>         5m    v1.30.0

==============================================================================
Deployment Summary
==============================================================================

✓ Deployment completed successfully! 🎉

Cluster Information:
  Control Plane: 54.123.45.67
  Worker Nodes: 2
  Total Duration: 26m 15s

Next Steps:
  1. SSH to control plane:
     ssh -i ~/.ssh/k8s-cluster.pem ec2-user@54.123.45.67

  2. View cluster status:
     kubectl get nodes
     kubectl get pods --all-namespaces

  3. Explore storage examples:
     kubectl get all -n storage-examples
     kubectl get pvc -n storage-examples

  4. View storage classes:
     kubectl get storageclass

Deployment log saved to: deployment-20251104-101523.log

==============================================================================
Deployment Complete
==============================================================================
```

---

## Troubleshooting

### SSH Connection Failures

If SSH connections fail:

```bash
# Verify SSH key permissions
chmod 400 ~/.ssh/k8s-cluster.pem

# Test SSH manually
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Check security group allows SSH from your IP
# AWS Console → EC2 → Security Groups
```

### Control Plane Setup Fails

Check the deployment log for detailed error messages:

```bash
cat deployment-<timestamp>.log
```

Common issues:
- Insufficient instance resources (use t3.medium minimum)
- Network connectivity issues
- Package repository issues

### Worker Join Failures

If workers fail to join:

```bash
# SSH to control plane and generate new join command
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>
sudo kubeadm token create --print-join-command

# Manually run worker setup on failed worker
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<worker-ip>
sudo /tmp/setup-worker-al2023.sh "kubeadm join ..."
```

### Deployment Log

All output is saved to `deployment-<timestamp>.log` for troubleshooting:

```bash
# View the log
cat deployment-*.log

# Search for errors
grep ERROR deployment-*.log

# View control plane output only
grep "Control Plane" deployment-*.log
```

---

## Manual Deployment (Alternative)

If you prefer manual control, you can deploy step by step:

### 1. Deploy Control Plane

```bash
# Copy script
scp -i ~/.ssh/k8s-cluster.pem setup-control-plane-al2023.sh ec2-user@<CP-IP>:/tmp/

# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<CP-IP>

# Run setup
sudo /tmp/setup-control-plane-al2023.sh

# Get join command
cat /tmp/kubeadm-join-command.sh
```

### 2. Deploy Workers

```bash
# For each worker, copy script
scp -i ~/.ssh/k8s-cluster.pem setup-worker-al2023.sh ec2-user@<WORKER-IP>:/tmp/

# SSH to worker
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<WORKER-IP>

# Run setup with join command
sudo /tmp/setup-worker-al2023.sh "kubeadm join <CP-IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

---

## Cleanup

To destroy the cluster:

```bash
terraform destroy
```

This will remove all AWS resources including:
- EC2 instances
- EBS volumes
- Security groups
- VPC and networking components

---

## Cost Management

The deployment script creates resources that incur AWS costs:

**Approximate Monthly Cost (default configuration):**
- Control plane (t3.medium): ~$30/month
- 2 workers (t3.small): ~$30/month
- EBS storage (70GB): ~$5.60/month
- Data transfer: ~$5-10/month
- **Total: ~$70-75/month**

**To minimize costs:**
1. Stop instances when not in use (loses ephemeral data)
2. Destroy cluster with `terraform destroy` when done
3. Use smaller instance types for practice
4. Enable auto-shutdown (see terraform.tfvars options)

---

## CKA Exam Practice

Once deployed, you have a fully functional Kubernetes cluster for CKA practice:

- ✅ Multi-node cluster (1 control plane + 2 workers)
- ✅ Networking with Calico CNI
- ✅ Storage with EBS CSI Driver
- ✅ Multiple StorageClasses
- ✅ Sample resources in multiple namespaces
- ✅ RBAC examples
- ✅ NetworkPolicy examples
- ✅ Metrics Server for resource monitoring

Practice topics:
- Cluster administration
- Workload scheduling
- Storage management
- Networking and services
- Security and RBAC
- Troubleshooting
- Cluster maintenance and upgrades

---

## Support

For issues or questions:
1. Check deployment log: `deployment-*.log`
2. Review Terraform outputs: `terraform output`
3. Verify AWS resources in AWS Console
4. Check script logs on instances: `/var/log/cloud-init-output.log`
