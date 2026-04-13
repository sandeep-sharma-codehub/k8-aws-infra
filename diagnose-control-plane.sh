#!/bin/bash

# diagnose-control-plane.sh
# Comprehensive diagnostic script for Kubernetes control plane nodes
# Usage: ./diagnose-control-plane.sh <control-plane-ip>

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTROL_PLANE_IP="${1:-}"
KEY_PATH="${2:-$HOME/.ssh/k8-cluster.pem}"

if [ -z "$CONTROL_PLANE_IP" ]; then
    echo -e "${RED}Error: Control plane IP address required${NC}"
    echo "Usage: $0 <control-plane-ip> [key-path]"
    echo "Example: $0 44.204.107.188"
    exit 1
fi

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${RED}Error: SSH key not found at $KEY_PATH${NC}"
    exit 1
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KUBERNETES CONTROL PLANE DIAGNOSTICS                ║${NC}"
echo -e "${BLUE}║   Target: $CONTROL_PLANE_IP$(printf '%*s' $((42 - ${#CONTROL_PLANE_IP})) '')║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Section 1: System Resources
echo -e "${YELLOW}═══ 1. SYSTEM RESOURCES ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
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
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Containerd Status:"
sudo systemctl status containerd --no-pager | head -10
echo ""

echo "Containerd Version:"
containerd --version 2>/dev/null || echo "containerd command not found"
echo ""
ENDSSH

# Section 3: Kubelet Service
echo -e "${YELLOW}═══ 3. KUBELET SERVICE ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Kubelet Service Status:"
sudo systemctl status kubelet --no-pager | head -15
echo ""

echo "Recent Kubelet Logs (errors/warnings):"
sudo journalctl -u kubelet -n 50 --no-pager | grep -E "error|failed|warning|crash" | tail -20 || echo "No errors found in recent logs"
echo ""
ENDSSH

# Section 4: Control Plane Containers
echo -e "${YELLOW}═══ 4. CONTROL PLANE CONTAINERS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "All Control Plane Containers:"
sudo crictl ps | head -1
sudo crictl ps | grep -E "kube-apiserver|kube-controller|kube-scheduler|etcd" || echo "⚠️  No control plane containers running!"
echo ""

echo "Control Plane Pods:"
sudo crictl pods | head -1
sudo crictl pods | grep -E "kube-system" || echo "⚠️  No kube-system pods found"
echo ""
ENDSSH

# Section 5: API Server Status
echo -e "${YELLOW}═══ 5. API SERVER STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if sudo crictl ps | grep -q "kube-apiserver"; then
    echo "✓ API Server is RUNNING"
    API_CONTAINER=$(sudo crictl ps | grep kube-apiserver | awk '{print $1}')
    echo "Container ID: $API_CONTAINER"
    echo ""

    echo "API Server Logs (last 40 lines):"
    sudo crictl logs --tail=40 $API_CONTAINER 2>/dev/null || echo "Could not retrieve logs"
else
    echo "✗ API Server is NOT RUNNING"
    echo ""

    echo "Checking for stopped API server containers:"
    sudo crictl ps -a | grep kube-apiserver | head -3 || echo "No API server containers found"
    echo ""

    echo "Attempting to get logs from last container:"
    STOPPED_API=$(sudo crictl ps -a | grep kube-apiserver | head -1 | awk '{print $1}')
    if [ ! -z "$STOPPED_API" ]; then
        sudo crictl logs --tail=50 $STOPPED_API 2>/dev/null || echo "Could not retrieve logs"
    fi
fi
echo ""
ENDSSH

# Section 6: etcd Status
echo -e "${YELLOW}═══ 6. ETCD STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if sudo crictl ps | grep -q "etcd"; then
    echo "✓ etcd is RUNNING"
    ETCD_CONTAINER=$(sudo crictl ps | grep etcd | awk '{print $1}')
    echo "Container ID: $ETCD_CONTAINER"
    echo ""

    echo "etcd Logs (last 30 lines):"
    sudo crictl logs --tail=30 $ETCD_CONTAINER 2>/dev/null || echo "Could not retrieve logs"
else
    echo "✗ etcd is NOT RUNNING"
    echo ""

    echo "Checking for stopped etcd containers:"
    sudo crictl ps -a | grep etcd | head -3 || echo "No etcd containers found"
fi
echo ""
ENDSSH

# Section 7: Controller Manager
echo -e "${YELLOW}═══ 7. CONTROLLER MANAGER STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if sudo crictl ps | grep -q "kube-controller-manager"; then
    echo "✓ Controller Manager is RUNNING"
    CONTROLLER_CONTAINER=$(sudo crictl ps | grep kube-controller-manager | awk '{print $1}')
    echo "Container ID: $CONTROLLER_CONTAINER"
    echo ""

    echo "Controller Manager Logs (last 20 lines, errors only):"
    sudo crictl logs --tail=50 $CONTROLLER_CONTAINER 2>/dev/null | grep -i "error\|failed" | tail -20 || echo "No errors found"
else
    echo "✗ Controller Manager is NOT RUNNING"
fi
echo ""
ENDSSH

# Section 8: Scheduler
echo -e "${YELLOW}═══ 8. SCHEDULER STATUS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if sudo crictl ps | grep -q "kube-scheduler"; then
    echo "✓ Scheduler is RUNNING"
    SCHEDULER_CONTAINER=$(sudo crictl ps | grep kube-scheduler | awk '{print $1}')
    echo "Container ID: $SCHEDULER_CONTAINER"
    echo ""

    echo "Scheduler Logs (last 20 lines, errors only):"
    sudo crictl logs --tail=50 $SCHEDULER_CONTAINER 2>/dev/null | grep -i "error\|failed" | tail -20 || echo "No errors found"
else
    echo "✗ Scheduler is NOT RUNNING"
fi
echo ""
ENDSSH

# Section 9: Static Pod Manifests
echo -e "${YELLOW}═══ 9. STATIC POD MANIFESTS ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Manifests Directory:"
ls -lah /etc/kubernetes/manifests/ 2>/dev/null || echo "⚠️  Manifests directory not found"
echo ""

echo "Checking Critical Manifests:"
for manifest in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    if [ -f "/etc/kubernetes/manifests/$manifest" ]; then
        echo "  ✓ $manifest exists"
    else
        echo "  ✗ $manifest MISSING"
    fi
done
echo ""
ENDSSH

# Section 10: Network & Connectivity
echo -e "${YELLOW}═══ 10. NETWORK & CONNECTIVITY ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Network Interfaces:"
ip -br addr | grep -v "lo"
echo ""

echo "Listening Ports (Kubernetes):"
sudo netstat -tlnp 2>/dev/null | grep -E "6443|2379|2380|10250|10251|10252" || echo "No Kubernetes ports found listening"
echo ""

echo "Firewall Status:"
sudo iptables -L -n | head -10
echo ""
ENDSSH

# Section 11: Kubernetes Cluster Info
echo -e "${YELLOW}═══ 11. KUBERNETES CLUSTER INFO ===${NC}"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if [ -f /etc/kubernetes/admin.conf ]; then
    echo "Cluster Info:"
    sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf cluster-info 2>/dev/null || echo "⚠️  Cannot connect to API server"
    echo ""

    echo "Node Status:"
    sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes 2>/dev/null || echo "⚠️  Cannot retrieve node status"
    echo ""

    echo "Control Plane Pods:"
    sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system 2>/dev/null || echo "⚠️  Cannot retrieve pod status"
else
    echo "⚠️  /etc/kubernetes/admin.conf not found"
fi
echo ""
ENDSSH

# Summary
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   DIAGNOSIS COMPLETE                                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Common Remediation Steps:${NC}"
echo -e "  ${YELLOW}1.${NC} Restart kubelet:         ssh -i $KEY_PATH ec2-user@$CONTROL_PLANE_IP 'sudo systemctl restart kubelet'"
echo -e "  ${YELLOW}2.${NC} Restart containerd:      ssh -i $KEY_PATH ec2-user@$CONTROL_PLANE_IP 'sudo systemctl restart containerd'"
echo -e "  ${YELLOW}3.${NC} Check disk space:        If disk full, clean up logs or upgrade instance"
echo -e "  ${YELLOW}4.${NC} Check memory:            If OOM, upgrade to larger instance (t3.large recommended)"
echo -e "  ${YELLOW}5.${NC} Reset cluster:           ssh -i $KEY_PATH ec2-user@$CONTROL_PLANE_IP 'sudo kubeadm reset -f'"
echo ""
