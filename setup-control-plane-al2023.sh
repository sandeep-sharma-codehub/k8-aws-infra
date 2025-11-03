#!/bin/bash

# setup-control-plane-al2023.sh
# Kubernetes Control Plane Setup Script - Amazon Linux 2023 Optimized
# Version: 1.1
# Fixed for Amazon Linux 2023 package management

set -euo pipefail
trap 'error "Script failed at line $LINENO"' ERR

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

K8S_VERSION="1.30.0"
K8S_VERSION_SHORT="1.30"
CONTAINERD_VERSION="1.7.13"
RUNC_VERSION="1.1.12"
CNI_VERSION="1.4.0"
CALICO_VERSION="v3.27.0"
POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_NAME="k8s-cka-ckad-cluster"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"; exit 1; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system"
    fi
    
    . /etc/os-release
    if [[ "$ID" != "amzn" ]]; then
        error "This script is specifically for Amazon Linux 2023. Detected: $ID"
    fi
    
    log "Confirmed Amazon Linux 2023: $PRETTY_NAME"
}

# =============================================================================
# SYSTEM PREPARATION
# =============================================================================

prepare_system() {
    log "Preparing system for Kubernetes..."
    
    # Update system
    dnf update -y --allowerasing
    
    # Install basic tools
    dnf install -y wget curl tar gzip --allowerasing
    
    # Disable swap
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    # Load kernel modules
    cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
    
    # Configure sysctl
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system
    
    # Disable firewall for simplicity
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    
    log "System preparation completed"
}

# =============================================================================
# CONTAINERD INSTALLATION
# =============================================================================

install_containerd() {
    log "Installing containerd from binary..."

    cd /tmp

    # Download and install containerd
    wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    tar Cxzvf /usr/local containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz

    # Download and install runc
    wget https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
    install -m 755 runc.amd64 /usr/local/sbin/runc

    # Download and install CNI plugins
    mkdir -p /opt/cni/bin
    wget https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
    tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${CNI_VERSION}.tgz

    # Clean up temporary files
    rm -f /tmp/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    rm -f /tmp/runc.amd64
    rm -f /tmp/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
    log "Cleaned up temporary installation files"
    
    # Create containerd service
    cat <<EOF > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    
    # Start containerd
    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd
    
    if ! systemctl is-active --quiet containerd; then
        error "Failed to start containerd"
    fi
    
    log "Containerd installed and started successfully"
}

# =============================================================================
# KUBERNETES INSTALLATION
# =============================================================================

install_kubernetes() {
    log "Installing Kubernetes components..."
    
    # Add Kubernetes repository
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    
    # Install Kubernetes components
    dnf install -y kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION} --disableexcludes=kubernetes --allowerasing
    
    # Configure kubelet
    cat <<EOF > /etc/default/kubelet
KUBELET_EXTRA_ARGS=--cloud-provider=external
EOF
    
    systemctl enable kubelet
    
    log "Kubernetes components installed"
}

# =============================================================================
# CLUSTER INITIALIZATION
# =============================================================================

initialize_cluster() {
    log "Initializing Kubernetes cluster..."
    
    # Get instance IPs using IMDSv2
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
    PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)
    PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)
    
    # Validate IPs
    if [[ -z "$PRIVATE_IP" ]]; then
        error "Failed to get private IP address"
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        warn "Failed to get public IP address, using private IP only"
        PUBLIC_IP="$PRIVATE_IP"
    fi
    
    log "Private IP: $PRIVATE_IP, Public IP: $PUBLIC_IP"
    
    # Create kubernetes directory
    mkdir -p /etc/kubernetes
    
    # Create kubeadm config
cat <<EOF > /etc/kubernetes/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${PRIVATE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    cloud-provider: external
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
clusterName: ${CLUSTER_NAME}
controlPlaneEndpoint: ${PRIVATE_IP}:6443
networking:
  serviceSubnet: ${SERVICE_CIDR}
  podSubnet: ${POD_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
  - ${PRIVATE_IP}
  - ${PUBLIC_IP}
  - localhost
  - 127.0.0.1
controllerManager:
  extraArgs:
    cloud-provider: external
scheduler: {}
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
cgroupDriver: systemd
EOF
    
    # Initialize cluster
    kubeadm init --config=/etc/kubernetes/kubeadm-config.yaml
    
    # Configure kubectl for root
    mkdir -p /root/.kube
    cp -i /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    
    # Configure kubectl for ec2-user
    if id "ec2-user" &>/dev/null; then
        mkdir -p /home/ec2-user/.kube
        cp -i /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
        chown ec2-user:ec2-user /home/ec2-user/.kube/config
        
        # Add aliases and KUBECONFIG export
        cat <<EOF >> /home/ec2-user/.bashrc
export KUBECONFIG=/home/ec2-user/.kube/config
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgn='kubectl get nodes'
EOF
    fi
    
    log "Cluster initialized successfully"
}

# =============================================================================
# CNI INSTALLATION
# =============================================================================

install_calico() {
    log "Installing Calico CNI..."
    
    # Wait for API server to be fully ready
    local max_attempts=60
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if timeout 10 kubectl get nodes &>/dev/null && timeout 10 kubectl get pods -n kube-system &>/dev/null; then
            log "API server is ready"
            break
        fi
        info "Waiting for API server... ($attempt/$max_attempts)"
        sleep 5
        ((attempt++))
        if [[ $attempt -gt $max_attempts ]]; then
            error "API server failed to become ready"
        fi
    done
    
    # Install Calico operator with validation disabled initially
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml --validate=false
    
    # Wait for Calico CRDs to be ready
    info "Waiting for Calico CRDs to be installed..."
    local crd_attempts=30
    local crd_attempt=1
    
    while [[ $crd_attempt -le $crd_attempts ]]; do
        if kubectl get crd installations.operator.tigera.io &>/dev/null; then
            log "Calico CRDs are ready"
            break
        fi
        info "Waiting for CRDs... ($crd_attempt/$crd_attempts)"
        sleep 10
        ((crd_attempt++))
        if [[ $crd_attempt -gt $crd_attempts ]]; then
            error "Calico CRDs failed to install"
        fi
    done
    
    # Create Calico configuration
    cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    
    log "Calico CNI installed"
}

# =============================================================================
# ADDITIONAL COMPONENTS
# =============================================================================

install_metrics_server() {
    log "Installing Metrics Server..."
    
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Patch for lab environment
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
        {
            "op": "add",
            "path": "/spec/template/spec/containers/0/args/-",
            "value": "--kubelet-insecure-tls"
        }
    ]'
    
    log "Metrics Server installed"
}

create_sample_resources() {
    log "Creating sample resources..."
    
    # Create namespaces
    for ns in frontend backend monitoring testing production; do
        kubectl create namespace "$ns" || true
    done
    
    # Create sample network policy
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
    
    # Create sample RBAC
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: frontend
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: frontend
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: frontend
subjects:
- kind: ServiceAccount
  name: frontend-sa
  namespace: frontend
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
    
    log "Sample resources created"
}

# =============================================================================
# VERIFICATION AND OUTPUT
# =============================================================================

verify_installation() {
    log "Verifying installation..."
    
    echo ""
    info "Checking nodes..."
    kubectl get nodes -o wide
    
    echo ""
    info "Checking system pods..."
    kubectl get pods --all-namespaces
    
    echo ""
    info "Cluster information:"
    kubectl cluster-info
    
    log "Verification completed"
}

generate_join_command() {
    log "Generating join command..."
    
    kubeadm token create --print-join-command > /tmp/kubeadm-join-command.sh
    chmod +x /tmp/kubeadm-join-command.sh
    
    echo ""
    echo "=============================================================================="
    echo "WORKER NODE JOIN COMMAND"
    echo "=============================================================================="
    cat /tmp/kubeadm-join-command.sh
    echo "=============================================================================="
    
    log "Join command saved to /tmp/kubeadm-join-command.sh"
}

print_completion() {
    echo ""
    echo "=============================================================================="
    echo "CONTROL PLANE SETUP COMPLETED SUCCESSFULLY!"
    echo "=============================================================================="
    echo ""
    echo "Cluster Information:"
    echo "  Cluster Name: ${CLUSTER_NAME}"
    echo "  Kubernetes Version: v${K8S_VERSION}"
    echo "  Pod CIDR: ${POD_CIDR}"
    echo "  Service CIDR: ${SERVICE_CIDR}"
    echo ""
    echo "Next Steps:"
    echo "  1. Use the join command above to add worker nodes"
    echo "  2. Verify cluster: kubectl get nodes"
    echo "  3. Check pods: kubectl get pods --all-namespaces"
    echo ""
    echo "Happy Learning! 🚀"
    echo "=============================================================================="
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log "Starting Kubernetes Control Plane setup for Amazon Linux 2023..."
    
    check_root
    check_os
    
    prepare_system
    install_containerd
    install_kubernetes
    initialize_cluster
    install_calico
    install_metrics_server
    create_sample_resources
    
    verify_installation
    generate_join_command
    print_completion
    
    log "Setup completed successfully!"
}

main "$@"