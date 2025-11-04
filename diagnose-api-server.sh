#!/bin/bash

# diagnose-api-server.sh
# Quick diagnostic script for API server issues

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTROL_PLANE_IP="${1:-}"

if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "Usage: $0 <control-plane-ip>"
    exit 1
fi

echo -e "${BLUE}Diagnosing API server on $CONTROL_PLANE_IP${NC}"
echo ""

echo -e "${YELLOW}=== 1. Checking API Server Pod Status ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "API Server container status:"
sudo crictl ps | grep apiserver || echo "API server container not running!"
echo ""

echo "All control plane containers:"
sudo crictl ps | grep -E "kube-apiserver|kube-controller|kube-scheduler|etcd" || true
echo ""
ENDSSH

echo -e "${YELLOW}=== 2. Checking System Resources ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Memory usage:"
free -h
echo ""

echo "Disk usage:"
df -h
echo ""

echo "Load average:"
uptime
echo ""
ENDSSH

echo -e "${YELLOW}=== 3. Checking Kubelet Status ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Kubelet service status:"
sudo systemctl status kubelet --no-pager | head -20
echo ""

echo "Recent kubelet logs:"
sudo journalctl -u kubelet -n 30 --no-pager
echo ""
ENDSSH

echo -e "${YELLOW}=== 4. Checking etcd Status ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "etcd container status:"
sudo crictl ps | grep etcd || echo "etcd container not running!"
echo ""

if sudo crictl ps | grep -q etcd; then
    ETCD_CONTAINER=$(sudo crictl ps | grep etcd | awk '{print $1}')
    echo "etcd logs (last 20 lines):"
    sudo crictl logs --tail=20 $ETCD_CONTAINER 2>/dev/null || echo "Could not get etcd logs"
fi
echo ""
ENDSSH

echo -e "${YELLOW}=== 5. Checking API Server Logs ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
if sudo crictl ps | grep -q apiserver; then
    API_CONTAINER=$(sudo crictl ps | grep apiserver | awk '{print $1}')
    echo "API server logs (last 50 lines):"
    sudo crictl logs --tail=50 $API_CONTAINER 2>/dev/null || echo "Could not get API server logs"
else
    echo "API server container not running. Checking pod logs:"
    sudo crictl pods | grep apiserver || echo "No API server pod found"
fi
echo ""
ENDSSH

echo -e "${YELLOW}=== 6. Checking Static Pod Manifests ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Static pod manifests:"
ls -la /etc/kubernetes/manifests/ || echo "Manifests directory not found!"
echo ""

if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
    echo "API server manifest exists"
else
    echo "WARNING: API server manifest missing!"
fi
echo ""
ENDSSH

echo -e "${YELLOW}=== 7. Checking Containerd Status ===${NC}"
ssh -i ~/.ssh/k8s-cluster.pem ec2-user@$CONTROL_PLANE_IP << 'ENDSSH'
echo "Containerd service status:"
sudo systemctl status containerd --no-pager | head -10
echo ""
ENDSSH

echo ""
echo -e "${GREEN}=== Diagnosis Complete ===${NC}"
echo ""
echo -e "${BLUE}Common Fixes:${NC}"
echo "1. Restart kubelet: ssh ... 'sudo systemctl restart kubelet'"
echo "2. Restart containerd: ssh ... 'sudo systemctl restart containerd'"
echo "3. Check logs above for specific errors"
echo "4. If resources low, upgrade to t3.large"
echo "5. Reset cluster: ssh ... 'sudo kubeadm reset -f && sudo /tmp/setup-control-plane-al2023.sh'"
