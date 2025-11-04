# Troubleshooting Guide

## Issue: API Server Failed to Become Ready After 600 Seconds

### Root Cause Analysis

Based on deployment log `deployment-20251104-165832.log`:

**Primary Issue:**
The `cp -i` command was prompting for confirmation when copying kubeconfig files:
```
cp: overwrite '/root/.kube/config'?
cp: overwrite '/home/ec2-user/.kube/config'?
```

When running non-interactively through SSH, these prompts either:
1. Fail silently without copying the file
2. Hang waiting for input that never comes
3. Use stdin from the script, causing unexpected behavior

Without a valid kubeconfig at `/root/.kube/config`, the `kubectl` commands in the Calico installation phase timed out after 10 minutes.

**Secondary Issue:**
The `KUBECONFIG` environment variable was not exported for the root user during script execution, even if the config file was copied successfully.

### Fix Applied

✅ **Changed interactive copy to forced copy:**
```bash
# Before (BROKEN):
cp -i /etc/kubernetes/admin.conf /root/.kube/config

# After (FIXED):
cp -f /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config
```

### Additional Issue: No Worker Nodes

The deployment log shows:
```
WARNING: No worker nodes found in Terraform output
```

**Likely Causes:**
1. Terraform apply didn't create worker nodes
2. `worker_node_count` variable is set to 0
3. Worker resources failed to create

**To Fix:**
```bash
# Check Terraform state
terraform state list | grep worker

# Check worker_node_count
terraform output -json | jq '.worker_node_count'

# If needed, update terraform.tfvars
worker_node_count = 2

# Re-apply
terraform apply
```

### Additional Issue: Service Account Not Found Error

**Symptoms:**
```
Error from server (Forbidden): error when creating "STDIN": pods "sample-pod-with-volume" is forbidden:
error looking up service account storage-examples/default: serviceaccount "default" not found
```

**Root Cause:**
When a namespace is created, Kubernetes asynchronously creates the default service account. If pods are created too quickly after namespace creation, they fail because the service account doesn't exist yet.

**Fix Applied:**
✅ **Added wait logic for default service accounts:**
```bash
# After creating namespace
kubectl create namespace storage-examples

# Wait for default service account (now in script)
while ! kubectl get serviceaccount default -n storage-examples &>/dev/null; do
    sleep 1
done
```

The script now waits up to 30 seconds for the default service account to be created in each namespace before proceeding with resource creation.

---

## Common Issues and Solutions

### 1. API Server Not Responding / Connection Refused

**Symptoms:**
```
E1104 12:50:58 memcache.go:265] couldn't get current server API group list:
Get "https://10.0.1.83:6443/api?timeout=32s": net/http: TLS handshake timeout
The connection to the server 10.0.1.83:6443 was refused - did you specify the right host or port?
```

**Root Causes:**

**a) Insufficient Memory (Most Common):**
```bash
# Check memory on control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>
free -h

# If available memory < 500MB, this is the issue
```

**Solution:**
```bash
# Option 1: Upgrade instance type (recommended)
# Edit terraform.tfvars:
control_plane_instance_type = "t3.large"  # Instead of t3.medium

terraform apply
./deploy-cluster.sh

# Option 2: Reduce worker load temporarily
worker_node_count = 1
terraform apply
```

**Why:** t3.medium (4GB RAM) is minimum for control plane, but under load (EBS CSI driver, Calico, metrics server, sample resources), it can run out of memory causing API server to crash.

**b) API Server Pod Crashed:**
```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Check if API server is running
sudo crictl ps | grep apiserver
# If nothing, it crashed

# Check kubelet logs for why
sudo journalctl -u kubelet -n 100 | grep apiserver

# Restart kubelet to recreate pod
sudo systemctl restart kubelet

# Wait 30 seconds
sleep 30

# Check again
kubectl get nodes
```

**c) etcd Issues:**
```bash
# Check if etcd is running
sudo crictl ps | grep etcd

# Check etcd logs
ETCD_ID=$(sudo crictl ps | grep etcd | awk '{print $1}')
sudo crictl logs --tail=100 $ETCD_ID

# Common etcd issues:
# - Disk full (check: df -h)
# - Corrupted data (requires reset)
# - Out of memory
```

**d) Static Pod Manifest Corruption:**
```bash
# Check if manifest exists
ls -la /etc/kubernetes/manifests/kube-apiserver.yaml

# Validate YAML syntax
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -A 5 -B 5 error

# If corrupt, reset cluster
sudo kubeadm reset -f
sudo /tmp/setup-control-plane-al2023.sh
```

**Quick Diagnosis Script:**
```bash
# Run the diagnostic script
./diagnose-api-server.sh <control-plane-ip>
```

This will check:
- API server container status
- System resources (memory, disk)
- Kubelet status and logs
- etcd status and logs
- API server logs
- Static pod manifests
- Containerd status

**Complete Reset (Last Resort):**
```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Full reset
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo systemctl restart containerd
sudo systemctl restart kubelet
sleep 10

# Re-run setup
sudo /tmp/setup-control-plane-al2023.sh
```

---

### 2. SSH Connection Failures

**Symptoms:**
```
ERROR: Cannot establish SSH connection to control plane
```

**Causes & Solutions:**

**a) Security Group Not Allowing SSH:**
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids <sg-id>

# Update terraform.tfvars to allow your IP
allowed_ssh_cidrs = ["YOUR_IP/32"]
terraform apply
```

**b) Wrong SSH Key:**
```bash
# Verify key exists
ls -la ~/.ssh/k8s-cluster.pem

# Check permissions
chmod 400 ~/.ssh/k8s-cluster.pem

# Specify key explicitly
SSH_KEY_PATH=~/.ssh/your-key.pem ./deploy-cluster.sh
```

**c) Instance Not Ready:**
```bash
# Wait a few minutes after terraform apply
# Check instance status in AWS Console

# Test SSH manually
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<ip> -v
```

### 2. Control Plane Setup Fails During kubeadm init

**Symptoms:**
```
ERROR: Cluster initialization failed after 3 attempts
```

**Diagnostic Steps:**

```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Check system resources
free -h
df -h
top

# Check if kubelet is running
sudo systemctl status kubelet

# Check kubelet logs
sudo journalctl -u kubelet -n 100

# Check containerd
sudo systemctl status containerd
sudo journalctl -u containerd -n 50

# Check if port 6443 is in use
sudo netstat -tlnp | grep 6443

# Check if previous cluster exists
ls -la /etc/kubernetes/manifests/
ls -la /var/lib/etcd/
```

**Solutions:**

**Insufficient Memory:**
```bash
# Control plane needs at least 2GB RAM (t3.medium recommended)
# Check current instance type
terraform output control_plane_instance_type

# Update if needed
control_plane_instance_type = "t3.medium"
terraform apply
```

**Previous Failed Installation:**
```bash
# Clean up and retry
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet
sudo systemctl restart kubelet

# Re-run setup
sudo /tmp/setup-control-plane-al2023.sh
```

### 3. Calico CNI Installation Hangs or Fails

**Symptoms:**
```
INFO: Waiting for API server... (120/120)
ERROR: API server failed to become ready
```

**Diagnostic Steps:**

```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Check if API server is actually running
sudo crictl ps | grep apiserver
sudo kubectl get nodes

# If kubectl fails, check kubeconfig
ls -la /root/.kube/config
sudo cat /root/.kube/config

# Check API server logs
sudo crictl logs <apiserver-container-id>

# Check API server pod
sudo kubectl get pods -n kube-system | grep apiserver
sudo kubectl describe pod -n kube-system <apiserver-pod>
```

**Solutions:**

**Kubeconfig Not Properly Copied:**
```bash
# This is now fixed in the script, but to manually fix:
sudo mkdir -p /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config
kubectl get nodes
```

**API Server Not Healthy:**
```bash
# Check API server static pod manifest
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml

# Check etcd health
sudo crictl ps | grep etcd
sudo ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  endpoint health
```

### 4. Worker Node Join Failures

**Symptoms:**
```
ERROR: Worker-1 setup failed
```

**Diagnostic Steps:**

```bash
# SSH to worker node
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<worker-ip>

# Check kubelet status
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50

# Check containerd
sudo systemctl status containerd

# Check connectivity to control plane
telnet <control-plane-private-ip> 6443
curl -k https://<control-plane-private-ip>:6443
```

**Solutions:**

**Token Expired:**
```bash
# On control plane, generate new join command
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>
sudo kubeadm token create --print-join-command

# Copy the output and use it on worker
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<worker-ip>
sudo /tmp/setup-worker-al2023.sh "kubeadm join ..."
```

**Network Connectivity:**
```bash
# Check security groups allow communication
# Control plane SG should allow port 6443 from worker nodes
# Worker SG should allow port 10250 from control plane

# Verify in terraform.tfvars
terraform apply
```

### 5. EBS CSI Driver Not Working

**Symptoms:**
```
PVC stuck in Pending state
Events show: waiting for a volume to be created
```

**Diagnostic Steps:**

```bash
# Check EBS CSI Driver pods
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n kube-system -l app=ebs-csi-node

# Check logs
kubectl logs -n kube-system -l app=ebs-csi-controller -c ebs-plugin

# Check IAM permissions
aws sts get-caller-identity
```

**Solutions:**

**IAM Role Not Attached:**
```bash
# Verify instance has IAM role
aws ec2 describe-instances --instance-ids <instance-id> | jq '.Reservations[].Instances[].IamInstanceProfile'

# The IAM policy should have been created by Terraform
# Check if policy exists
aws iam list-policies | grep ebs-csi-driver

# If missing, re-apply Terraform
terraform apply
```

**CSI Driver Not Installed:**
```bash
# Check if CSI driver is installed
kubectl get csidrivers

# Reinstall if needed
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.28"
```

### 6. Nodes Stuck in NotReady State

**Symptoms:**
```
NAME                STATUS     ROLE
k8s-control-plane   NotReady   control-plane
```

**Diagnostic Steps:**

```bash
# Check node status details
kubectl describe node k8s-control-plane

# Check CNI installation
kubectl get pods -n calico-system
kubectl get pods -n tigera-operator

# Check kubelet
sudo systemctl status kubelet
sudo journalctl -u kubelet | tail -50
```

**Solutions:**

**CNI Not Installed:**
```bash
# Verify Calico is running
kubectl get pods -n calico-system
kubectl get installation -o yaml

# Reinstall Calico if needed
kubectl delete installation default
# Re-run setup script's Calico section
```

**Kubelet Not Running:**
```bash
sudo systemctl restart kubelet
sudo systemctl status kubelet
```

---

## Manual Recovery Procedures

### Complete Cluster Reset and Redeploy

```bash
# 1. Destroy infrastructure
terraform destroy -auto-approve

# 2. Clean up local files
rm deployment-*.log
rm /tmp/kubeadm-join-command-*.sh

# 3. Re-deploy infrastructure
terraform apply -auto-approve

# 4. Wait 2-3 minutes for instances to initialize

# 5. Deploy cluster
./deploy-cluster.sh
```

### Reset Control Plane Without Destroying Infrastructure

```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# Reset Kubernetes
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d

# Clean up iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Restart services
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Re-run setup
sudo /tmp/setup-control-plane-al2023.sh
```

### Reset Worker Node

```bash
# SSH to worker
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<worker-ip>

# Reset Kubernetes
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni/net.d

# Clean up iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Restart services
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Get new join command from control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>
sudo kubeadm token create --print-join-command

# Re-join (back on worker)
sudo /tmp/setup-worker-al2023.sh "kubeadm join ..."
```

---

## Verification Commands

### After Successful Deployment

```bash
# SSH to control plane
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@<control-plane-ip>

# All checks should pass:

# 1. Nodes are Ready
kubectl get nodes
# Expected: All nodes show STATUS = Ready

# 2. System pods are Running
kubectl get pods -n kube-system
# Expected: All pods show STATUS = Running

# 3. Calico is healthy
kubectl get pods -n calico-system
kubectl get pods -n tigera-operator
# Expected: All pods show STATUS = Running

# 4. EBS CSI Driver is running
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n kube-system -l app=ebs-csi-node
# Expected: Controller and node pods Running

# 5. StorageClasses exist
kubectl get storageclass
# Expected: ebs-gp3 (default), ebs-gp2, ebs-io2, ebs-sc1

# 6. Sample resources created
kubectl get all -n storage-examples
# Expected: Pods, deployments, statefulsets, services

# 7. Test storage provisioning
kubectl get pvc -n storage-examples
kubectl get pv
# Expected: PVCs show STATUS = Bound

# 8. Metrics Server working
kubectl top nodes
kubectl top pods -A
# Expected: Resource usage shown
```

---

## Logs and Debugging

### Important Log Locations

**On Control Plane / Worker Nodes:**
```bash
# Kubelet logs
sudo journalctl -u kubelet -f

# Containerd logs
sudo journalctl -u containerd -f

# System logs
sudo tail -f /var/log/messages

# Cloud-init logs (first boot)
sudo cat /var/log/cloud-init-output.log
```

**On Local Machine:**
```bash
# Deployment logs
cat deployment-*.log

# Terraform state
terraform show

# Terraform outputs
terraform output
```

### Useful Debugging Commands

```bash
# Container runtime
sudo crictl ps           # List running containers
sudo crictl pods         # List pods
sudo crictl logs <id>    # View container logs
sudo crictl inspect <id> # Inspect container

# Kubernetes
kubectl get events --all-namespaces --sort-by='.lastTimestamp'
kubectl describe node <node-name>
kubectl describe pod -n kube-system <pod-name>
kubectl logs -n kube-system <pod-name>

# Network
sudo iptables -L -n -v
sudo ip route show
sudo ip addr show

# Calico
kubectl get ippools
kubectl get felixconfiguration
calicoctl node status  # If calicoctl installed
```

---

## Getting Help

If issues persist:

1. **Collect Information:**
   ```bash
   # Save deployment log
   cat deployment-*.log > issue.log

   # Get cluster state (if accessible)
   kubectl get nodes -o yaml > nodes.yaml
   kubectl get pods -A -o yaml > pods.yaml
   kubectl get events -A > events.log

   # Get system logs from control plane
   sudo journalctl -u kubelet --no-pager > kubelet.log
   sudo journalctl -u containerd --no-pager > containerd.log
   ```

2. **Check AWS Resources:**
   - Verify instances are running
   - Check security groups
   - Verify IAM roles attached
   - Check VPC and subnet configuration

3. **Review Configuration:**
   - Check `terraform.tfvars` settings
   - Verify region and availability zones
   - Check instance types and sizes

4. **Common Resolution:**
   - Most issues are resolved by `terraform destroy` followed by `terraform apply` and `./deploy-cluster.sh`
