#!/bin/bash

# diagnose-worker.sh
# Comprehensive diagnostic script for Kubernetes worker nodes
# Usage: ./diagnose-worker.sh <worker-ip>

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKER_IP="${1:-}"
KEY_PATH="${2:-$HOME/.ssh/k8s-cluster.pem}"

if [ -z "$WORKER_IP" ]; then
    echo -e "${RED}Error: Worker node IP address required${NC}"
    echo "Usage: $0 <worker-ip> [key-path]"
    echo "Example: $0 44.195.85.200"
    exit 1
fi

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${RED}Error: SSH key not found at $KEY_PATH${NC}"
    exit 1
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KUBERNETES WORKER NODE DIAGNOSTICS                  ║${NC}"
echo -e "${BLUE}║   Target: $WORKER_IP$(printf '%*s' $((42 - ${#WORKER_IP})) '')║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Section 1: System Resources
echo -e "${YELLOW}═══ 1. SYSTEM RESOURCES ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Memory Usage:"
free -h
echo ""

echo "Disk Usage:"
df -h | head -6
echo ""

echo "CPU Load & Uptime:"
uptime
echo ""

echo "Top Memory Consumers:"
ps aux --sort=-%mem | head -6
echo ""
ENDSSH

# Section 2: Container Runtime
echo -e "${YELLOW}═══ 2. CONTAINER RUNTIME (containerd) ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Containerd Status:"
sudo systemctl status containerd --no-pager | head -10
echo ""

echo "Containerd Version:"
containerd --version 2>/dev/null || echo "containerd command not found"
echo ""

echo "Running Containers:"
sudo crictl ps | head -10
echo ""

echo "Container Count:"
RUNNING=$(sudo crictl ps -q 2>/dev/null | wc -l)
TOTAL=$(sudo crictl ps -a -q 2>/dev/null | wc -l)
echo "Running: $RUNNING / Total: $TOTAL"
echo ""
ENDSSH

# Section 3: Kubelet Service
echo -e "${YELLOW}═══ 3. KUBELET SERVICE ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Kubelet Service Status:"
sudo systemctl status kubelet --no-pager | head -15
echo ""

echo "Kubelet Version:"
kubelet --version 2>/dev/null || echo "kubelet command not found"
echo ""

echo "Recent Kubelet Logs (errors/warnings):"
sudo journalctl -u kubelet -n 50 --no-pager | grep -E "error|failed|warning|crash" | tail -20 || echo "No errors found in recent logs"
echo ""

echo "Kubelet Certificate Status:"
sudo journalctl -u kubelet -n 100 --no-pager | grep -i "certificate" | tail -10 || echo "No certificate issues found"
echo ""
ENDSSH

# Section 4: Node Registration & Cluster Connectivity
echo -e "${YELLOW}═══ 4. NODE REGISTRATION & CONNECTIVITY ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Node Registration Status:"
if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "✓ kubelet.conf exists (node configured)"

    # Try to extract control plane endpoint
    CONTROL_PLANE=$(grep "server:" /etc/kubernetes/kubelet.conf | awk '{print $2}')
    echo "Control Plane: $CONTROL_PLANE"
    echo ""

    # Test connectivity to control plane
    if [ ! -z "$CONTROL_PLANE" ]; then
        CP_HOST=$(echo $CONTROL_PLANE | sed 's|https://||' | cut -d':' -f1)
        CP_PORT=$(echo $CONTROL_PLANE | sed 's|https://||' | cut -d':' -f2)

        echo "Testing connectivity to control plane ($CP_HOST:$CP_PORT):"
        if timeout 5 bash -c ">/dev/tcp/$CP_HOST/$CP_PORT" 2>/dev/null; then
            echo "✓ Can reach control plane"
        else
            echo "✗ Cannot reach control plane"
        fi
    fi
else
    echo "✗ kubelet.conf NOT found (node not joined to cluster)"
fi
echo ""

echo "Kubeadm Join Status:"
if [ -f /etc/kubernetes/bootstrap-kubelet.conf ] || [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "✓ Node has been joined to cluster"
else
    echo "⚠️  Node may not have joined the cluster yet"
fi
echo ""
ENDSSH

# Section 5: CNI Plugin Status
echo -e "${YELLOW}═══ 5. CNI PLUGIN STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "CNI Configuration:"
if [ -d /etc/cni/net.d ]; then
    echo "✓ CNI directory exists"
    ls -lah /etc/cni/net.d/ 2>/dev/null || echo "Cannot list CNI configs"
else
    echo "⚠️  CNI directory not found"
fi
echo ""

echo "CNI Binaries:"
if [ -d /opt/cni/bin ]; then
    echo "✓ CNI binaries directory exists"
    ls /opt/cni/bin/ 2>/dev/null | head -10 || echo "Cannot list CNI binaries"
else
    echo "⚠️  CNI binaries directory not found"
fi
echo ""

echo "CNI Pods (should be running):"
sudo crictl pods | grep -E "calico|flannel|weave|cilium" || echo "No CNI pods found (may be managed by DaemonSet)"
echo ""
ENDSSH

# Section 6: Pod Status
echo -e "${YELLOW}═══ 6. POD STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Running Pods:"
sudo crictl pods | head -10
echo ""

echo "Pod Count by State:"
READY=$(sudo crictl pods 2>/dev/null | grep -c "Ready" || echo "0")
NOT_READY=$(sudo crictl pods 2>/dev/null | grep -c "NotReady" || echo "0")
echo "Ready: $READY"
echo "NotReady: $NOT_READY"
echo ""

echo "Failed/CrashLooping Pods:"
sudo crictl ps -a | grep -E "Error|CrashLoop|Back-off" || echo "No failed pods"
echo ""
ENDSSH

# Section 7: Network Configuration
echo -e "${YELLOW}═══ 7. NETWORK CONFIGURATION ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Network Interfaces:"
ip -br addr | grep -v "lo"
echo ""

echo "Default Route:"
ip route | grep default
echo ""

echo "Listening Ports (Kubernetes):"
sudo netstat -tlnp 2>/dev/null | grep -E "10250|10256|30000" || echo "No Kubernetes ports found listening"
echo ""

echo "Bridge Interfaces (CNI):"
ip -br link | grep -E "cni|flannel|calico|veth" || echo "No CNI bridges found"
echo ""

echo "IP Forwarding (should be 1):"
cat /proc/sys/net/ipv4/ip_forward
echo ""
ENDSSH

# Section 8: Storage & Volumes
echo -e "${YELLOW}═══ 8. STORAGE & VOLUMES ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Mounted Volumes:"
df -h | grep "/var/lib/kubelet" || echo "No kubelet volumes mounted"
echo ""

echo "Volume Plugin Directory:"
ls -lah /var/lib/kubelet/plugins/ 2>/dev/null || echo "No volume plugins directory"
echo ""
ENDSSH

# Section 9: System Logs
echo -e "${YELLOW}═══ 9. SYSTEM LOGS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
echo "Recent System Errors:"
sudo journalctl -p err -n 20 --no-pager | tail -20 || echo "No recent errors"
echo ""

echo "OOM Events:"
sudo journalctl -n 1000 --no-pager | grep -i "out of memory" | tail -10 || echo "No OOM events"
echo ""
ENDSSH

# Section 10: Kubernetes Client Check
echo -e "${YELLOW}═══ 10. KUBERNETES CLIENT CHECK ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$WORKER_IP << 'ENDSSH'
if command -v kubectl &> /dev/null; then
    echo "kubectl version:"
    kubectl version --client --short 2>/dev/null || echo "kubectl available but cannot get version"
else
    echo "⚠️  kubectl not installed (optional for worker nodes)"
fi
echo ""
ENDSSH

# Summary
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   DIAGNOSIS COMPLETE                                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Common Remediation Steps:${NC}"
echo -e "  ${YELLOW}1.${NC} Restart kubelet:         ssh -i $KEY_PATH ec2-user@$WORKER_IP 'sudo systemctl restart kubelet'"
echo -e "  ${YELLOW}2.${NC} Restart containerd:      ssh -i $KEY_PATH ec2-user@$WORKER_IP 'sudo systemctl restart containerd'"
echo -e "  ${YELLOW}3.${NC} Check connectivity:      Ensure worker can reach control plane on port 6443"
echo -e "  ${YELLOW}4.${NC} Check CNI:               Verify CNI plugin is installed and configured"
echo -e "  ${YELLOW}5.${NC} Re-join cluster:         If node not registered, run kubeadm join again"
echo -e "  ${YELLOW}6.${NC} Check resources:         Monitor CPU/memory usage, upgrade if needed"
echo ""
