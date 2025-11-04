# Kubernetes Security Group Audit Report

## Configuration Summary

**VPC CIDR:** `10.0.0.0/16`
**Pod CIDR:** `192.168.0.0/16`
**Service CIDR:** `10.96.0.0/12`
**SSH Access:** `0.0.0.0/0` (⚠️ Wide open - consider restricting)

---

## Control Plane Security Group

### Currently Configured Ports

| Port(s) | Protocol | Source | Purpose | Status |
|---------|----------|--------|---------|--------|
| 22 | TCP | 0.0.0.0/0 | SSH Access | ✅ Configured |
| 6443 | TCP | 10.0.0.0/16 (VPC) | Kubernetes API Server | ✅ Configured |
| 2379-2380 | TCP | 10.0.0.0/16 (VPC) | etcd Server Client API | ✅ Configured |
| 10250 | TCP | 10.0.0.0/16 (VPC) | Kubelet API | ✅ Configured |
| 10257 | TCP | 10.0.0.0/16 (VPC) | kube-controller-manager | ✅ Configured |
| 10259 | TCP | 10.0.0.0/16 (VPC) | kube-scheduler | ✅ Configured |
| 179 | TCP | 10.0.0.0/16 (VPC) | Calico BGP | ✅ Configured |
| 0-65535 | TCP | 192.168.0.0/16 (Pod CIDR) | Pod-to-pod communication | ✅ Configured |
| 0-65535 | ALL | 0.0.0.0/0 | All outbound traffic | ✅ Configured |

### ⚠️ Missing Ports (May be needed)

| Port(s) | Protocol | Source | Purpose | Required? |
|---------|----------|--------|---------|-----------|
| 6443 | TCP | 0.0.0.0/0 or Your IP | External kubectl access | Optional - if you want to access from outside VPC |
| 4789 | UDP | 10.0.0.0/16 | Calico VXLAN (if using VXLAN mode) | ⚠️ **CRITICAL** - Your setup uses VXLAN |
| 4789 | UDP | 192.168.0.0/16 | Calico VXLAN from pods | ⚠️ **CRITICAL** - Your setup uses VXLAN |
| 5473 | TCP | 10.0.0.0/16 | Calico Typha (if using Typha) | Optional |
| 9099 | TCP | 10.0.0.0/16 | Calico Felix metrics | Optional |

### 🔴 Critical Issue Found

**Calico VXLAN Port (4789/UDP) is MISSING!**

Your setup script configures Calico with `VXLANCrossSubnet` encapsulation mode (setup-control-plane-al2023.sh:447), but the security group does NOT allow UDP port 4789.

**Impact:** Pod networking across nodes will fail without this port!

---

## Worker Node Security Group

### Currently Configured Ports

| Port(s) | Protocol | Source | Purpose | Status |
|---------|----------|--------|---------|--------|
| 22 | TCP | 0.0.0.0/0 | SSH Access | ✅ Configured |
| 10250 | TCP | 10.0.0.0/16 (VPC) | Kubelet API | ✅ Configured |
| 30000-32767 | TCP | 0.0.0.0/0 | NodePort Services | ✅ Configured |
| 179 | TCP | 10.0.0.0/16 (VPC) | Calico BGP | ✅ Configured |
| 0-65535 | TCP | 192.168.0.0/16 (Pod CIDR) | Pod-to-pod communication | ✅ Configured |
| 0-65535 | ALL | 0.0.0.0/0 | All outbound traffic | ✅ Configured |

### ⚠️ Missing Ports (May be needed)

| Port(s) | Protocol | Source | Purpose | Required? |
|---------|----------|--------|---------|-----------|
| 4789 | UDP | 10.0.0.0/16 | Calico VXLAN | ⚠️ **CRITICAL** - Required for VXLAN mode |
| 4789 | UDP | 192.168.0.0/16 | Calico VXLAN from pods | ⚠️ **CRITICAL** - Required for VXLAN mode |
| 10256 | TCP | 10.0.0.0/16 | kube-proxy health check | Optional |
| 9099 | TCP | 10.0.0.0/16 | Calico Felix metrics | Optional |
| 30000-32767 | UDP | 0.0.0.0/0 | NodePort Services (UDP) | Optional - if you need UDP services |

### 🔴 Critical Issue Found

**Calico VXLAN Port (4789/UDP) is MISSING!**

Workers cannot communicate with pods on other nodes without this port.

---

## Kubernetes Port Requirements Reference

### Control Plane Node

#### Required Ports (MUST be open)

| Port | Protocol | Direction | Source/Destination | Component |
|------|----------|-----------|-------------------|-----------|
| 6443 | TCP | Inbound | Worker nodes, kubectl clients | kube-apiserver |
| 2379-2380 | TCP | Inbound | kube-apiserver, etcd clients | etcd |
| 10250 | TCP | Inbound | Control plane, worker nodes | kubelet |
| 10257 | TCP | Inbound | Self | kube-controller-manager |
| 10259 | TCP | Inbound | Self | kube-scheduler |

#### CNI-Specific Ports (Calico with VXLAN)

| Port | Protocol | Direction | Source/Destination | Component |
|------|----------|-----------|-------------------|-----------|
| 179 | TCP | Inbound/Outbound | All nodes | Calico BGP |
| **4789** | **UDP** | **Inbound/Outbound** | **All nodes** | **Calico VXLAN** |
| 5473 | TCP | Inbound/Outbound | Typha agents | Calico Typha (optional) |
| 9099 | TCP | Inbound | Monitoring | Calico Felix metrics |

### Worker Node

#### Required Ports (MUST be open)

| Port | Protocol | Direction | Source/Destination | Component |
|------|----------|-----------|-------------------|-----------|
| 10250 | TCP | Inbound | Control plane | kubelet |
| 30000-32767 | TCP | Inbound | External clients | NodePort Services |

#### CNI-Specific Ports (Calico with VXLAN)

| Port | Protocol | Direction | Source/Destination | Component |
|------|----------|-----------|-------------------|-----------|
| 179 | TCP | Inbound/Outbound | All nodes | Calico BGP |
| **4789** | **UDP** | **Inbound/Outbound** | **All nodes** | **Calico VXLAN** |
| 5473 | TCP | Inbound/Outbound | Typha agents | Calico Typha (optional) |
| 9099 | TCP | Inbound | Monitoring | Calico Felix metrics |

---

## Security Recommendations

### 🔴 Critical (Fix Immediately)

1. **Add VXLAN port 4789/UDP to both security groups**
   - Source: VPC CIDR (10.0.0.0/16)
   - Source: Pod CIDR (192.168.0.0/16)
   - Required for Calico networking with VXLANCrossSubnet mode

### 🟡 High Priority (Security Improvements)

2. **Restrict SSH access (port 22)**
   - Current: `0.0.0.0/0` (entire internet)
   - Recommended: Your specific IP or corporate network CIDR
   - Example: `203.0.113.0/24` (replace with your IP)

3. **Restrict API server access (port 6443)**
   - Current: Only from VPC (good for internal)
   - Consider: Add ingress rule from your IP for external kubectl access
   - Alternative: Use bastion host or VPN

4. **Restrict NodePort access (30000-32767)**
   - Current: `0.0.0.0/0` (entire internet)
   - Recommended: Specific CIDR blocks that need service access
   - Or use LoadBalancer/Ingress instead of NodePort

### 🟢 Optional Improvements

5. **Add ICMP for troubleshooting**
   - Type: ICMP Echo Request/Reply
   - Source: VPC CIDR
   - Useful for network debugging

6. **Add metrics ports (if using monitoring)**
   - Port 9099/TCP (Calico metrics)
   - Port 10256/TCP (kube-proxy health)
   - Port 9153/TCP (CoreDNS metrics)
   - Source: VPC CIDR or monitoring systems

7. **Enable VPC Flow Logs**
   - Monitor network traffic patterns
   - Detect anomalies
   - Aid in troubleshooting

---

## How to Fix Critical VXLAN Issue

### Option 1: Update Terraform (Recommended)

Add to `main.tf` in control plane security group (after line 190):

```hcl
# Calico VXLAN
ingress {
  description = "Calico VXLAN"
  from_port   = 4789
  to_port     = 4789
  protocol    = "udp"
  cidr_blocks = [var.vpc_cidr]
}

ingress {
  description = "Calico VXLAN from pods"
  from_port   = 4789
  to_port     = 4789
  protocol    = "udp"
  cidr_blocks = [var.pod_cidr]
}
```

Add to `main.tf` in worker security group (after line 259):

```hcl
# Calico VXLAN
ingress {
  description = "Calico VXLAN"
  from_port   = 4789
  to_port     = 4789
  protocol    = "udp"
  cidr_blocks = [var.vpc_cidr]
}

ingress {
  description = "Calico VXLAN from pods"
  from_port   = 4789
  to_port     = 4789
  protocol    = "udp"
  cidr_blocks = [var.pod_cidr]
}
```

Then apply:

```bash
terraform apply
```

### Option 2: Manual AWS Console

1. Go to EC2 Console → Security Groups
2. Find `k8s-cka-ckad-control-plane-*` security group
3. Edit inbound rules → Add rule:
   - Type: Custom UDP
   - Port: 4789
   - Source: 10.0.0.0/16
4. Add another rule:
   - Type: Custom UDP
   - Port: 4789
   - Source: 192.168.0.0/16
5. Repeat for `k8s-cka-ckad-worker-*` security group

### Option 3: AWS CLI

```bash
# Get security group IDs
CONTROL_PLANE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=k8s-cka-ckad-control-plane-*" \
  --query 'SecurityGroups[0].GroupId' --output text)

WORKER_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=k8s-cka-ckad-worker-*" \
  --query 'SecurityGroups[0].GroupId' --output text)

# Add VXLAN rules to control plane
aws ec2 authorize-security-group-ingress \
  --group-id $CONTROL_PLANE_SG \
  --ip-permissions \
    IpProtocol=udp,FromPort=4789,ToPort=4789,IpRanges='[{CidrIp=10.0.0.0/16,Description="Calico VXLAN"}]'

aws ec2 authorize-security-group-ingress \
  --group-id $CONTROL_PLANE_SG \
  --ip-permissions \
    IpProtocol=udp,FromPort=4789,ToPort=4789,IpRanges='[{CidrIp=192.168.0.0/16,Description="Calico VXLAN from pods"}]'

# Add VXLAN rules to workers
aws ec2 authorize-security-group-ingress \
  --group-id $WORKER_SG \
  --ip-permissions \
    IpProtocol=udp,FromPort=4789,ToPort=4789,IpRanges='[{CidrIp=10.0.0.0/16,Description="Calico VXLAN"}]'

aws ec2 authorize-security-group-ingress \
  --group-id $WORKER_SG \
  --ip-permissions \
    IpProtocol=udp,FromPort=4789,ToPort=4789,IpRanges='[{CidrIp=192.168.0.0/16,Description="Calico VXLAN from pods"}]'
```

---

## Testing Network Connectivity

After fixing the security groups, verify connectivity:

### From Control Plane:

```bash
# Test VXLAN port to worker
nc -uvz <worker-private-ip> 4789

# Check Calico status
sudo calicoctl node status

# Check pod connectivity
kubectl get pods -A -o wide
kubectl exec -it <pod-name> -- ping <other-pod-ip>
```

### From Worker:

```bash
# Test VXLAN port to control plane
nc -uvz <control-plane-private-ip> 4789

# Check network interfaces
ip link show | grep vxlan
```

---

## Summary

**Status:** ❌ **CRITICAL ISSUE FOUND**

Your security groups are **missing UDP port 4789** which is required for Calico VXLAN networking. This will cause:
- Pods on different nodes cannot communicate
- Services may not work correctly
- Network policies will fail

**Action Required:**
1. Add UDP port 4789 to both security groups immediately
2. Consider restricting SSH and NodePort access for better security
3. Test pod-to-pod connectivity after changes

**Good News:**
- All TCP ports are correctly configured
- Egress rules are properly open
- Pod CIDR rules are in place
