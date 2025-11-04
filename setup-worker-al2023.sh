#!/bin/bash

# setup-worker-al2023.sh
# Kubernetes Worker Node Setup Script - Amazon Linux 2023 Optimized
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

get_join_command() {
    if [[ $# -gt 0 ]]; then
        JOIN_COMMAND="$*"
    elif [[ -f "/tmp/kubeadm-join-command.sh" ]]; then
        JOIN_COMMAND=$(cat /tmp/kubeadm-join-command.sh)
    else
        echo ""
        echo "=============================================================================="
        echo "WORKER NODE JOIN COMMAND REQUIRED"
        echo "=============================================================================="
        echo ""
        echo "Please provide the kubeadm join command from the control plane."
        echo "You can get this by running: kubeadm token create --print-join-command"
        echo ""
        read -p "Enter the join command: " JOIN_COMMAND
    fi
    
    if [[ ! "$JOIN_COMMAND" =~ ^kubeadm\ join ]]; then
        error "Invalid join command format. Must start with 'kubeadm join'"
    fi
    
    log "Join command validated successfully"
}

# =============================================================================
# SYSTEM PREPARATION
# =============================================================================

prepare_system() {
    log "Preparing system for Kubernetes..."
    
    dnf update -y --allowerasing
    dnf install -y wget curl tar gzip --allowerasing
    
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
    
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system
    
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    
    log "System preparation completed"
}

set_hostname() {
    log "Setting hostname for worker node..."

    # Try to get worker number from AWS instance name tag or use last octet of IP
    # Use ip command as fallback since hostname -I may not work reliably on AL2023
    PRIVATE_IP=$(ip addr show | grep -E "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d'/' -f1 | head -1)

    if [ -z "$PRIVATE_IP" ]; then
        warn "Could not determine private IP, using fallback"
        PRIVATE_IP="127.0.0.1"
    fi

    LAST_OCTET=$(echo $PRIVATE_IP | cut -d'.' -f4)

    # Try to get instance name from AWS metadata
    INSTANCE_NAME=""
    if command -v curl &> /dev/null; then
        INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
        if [ ! -z "$INSTANCE_ID" ] && command -v aws &> /dev/null; then
            INSTANCE_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
        fi
    fi

    # If we got a name tag with "worker" in it, use that; otherwise use IP-based naming
    if [[ "$INSTANCE_NAME" =~ worker-([0-9]+) ]]; then
        WORKER_NUM="${BASH_REMATCH[1]}"
        HOSTNAME="k8s-worker-${WORKER_NUM}"
    else
        # Use last octet of IP as worker identifier
        HOSTNAME="k8s-worker-${LAST_OCTET}"
    fi

    # Set the hostname
    hostnamectl set-hostname "$HOSTNAME"

    # Update /etc/hosts with new hostname
    # Remove old entries for this IP (escape dots for sed)
    PRIVATE_IP_ESCAPED=$(echo "$PRIVATE_IP" | sed 's/\./\\./g')
    sed -i "/$PRIVATE_IP_ESCAPED/d" /etc/hosts

    # Add new entry
    echo "$PRIVATE_IP $HOSTNAME" >> /etc/hosts

    # Also add localhost entries if not present
    if ! grep -q "127.0.0.1.*localhost" /etc/hosts; then
        sed -i '1i127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4' /etc/hosts
    fi
    if ! grep -q "::1.*localhost" /etc/hosts; then
        sed -i '2i::1         localhost localhost.localdomain localhost6 localhost6.localdomain6' /etc/hosts
    fi

    # Update cloud-init to preserve hostname across reboots
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi

    # Verify hostname
    CURRENT_HOSTNAME=$(hostname)
    log "Hostname set to: $CURRENT_HOSTNAME"
    info "Private IP: $PRIVATE_IP"
}

# =============================================================================
# CONTAINERD INSTALLATION
# =============================================================================

install_containerd() {
    log "Installing containerd from binary..."

    cd /tmp

    wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    tar Cxzvf /usr/local containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz

    wget https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
    install -m 755 runc.amd64 /usr/local/sbin/runc

    mkdir -p /opt/cni/bin
    wget https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
    tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${CNI_VERSION}.tgz

    # Clean up temporary files
    rm -f /tmp/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    rm -f /tmp/runc.amd64
    rm -f /tmp/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
    log "Cleaned up temporary installation files"
    
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
    
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    
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
    
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    
    dnf install -y kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION} --disableexcludes=kubernetes --allowerasing
    
    cat <<EOF > /etc/default/kubelet
KUBELET_EXTRA_ARGS=--cloud-provider=external
EOF
    
    systemctl enable kubelet
    
    log "Kubernetes components installed"
}

# =============================================================================
# CLUSTER JOIN
# =============================================================================

join_cluster() {
    log "Joining worker node to Kubernetes cluster..."

    # Pre-join diagnostics
    log "Running pre-join diagnostics..."

    # Extract API server address from join command
    API_SERVER=$(echo "$JOIN_COMMAND" | grep -oP 'https://\K[^/]+' | head -1)
    if [ -z "$API_SERVER" ]; then
        warn "Could not extract API server from join command"
    else
        info "API Server: $API_SERVER"

        # Test DNS resolution
        info "Testing DNS resolution for API server..."
        API_HOST="${API_SERVER%:*}"
        if nslookup "$API_HOST" &>/dev/null; then
            info "DNS resolution successful for $API_HOST"
        else
            warn "DNS resolution failed for $API_HOST - ensure /etc/resolv.conf is configured"
        fi

        # Test TCP connectivity to API server
        info "Testing TCP connectivity to API server..."
        API_PORT=${API_SERVER##*:}
        if [ "$API_PORT" == "$API_SERVER" ]; then
            API_PORT=6443
        fi

        if timeout 5 bash -c "echo >/dev/tcp/$API_HOST/$API_PORT" 2>/dev/null; then
            info "Successfully connected to API server on $API_SERVER"
        else
            warn "Could not connect to API server on $API_SERVER:$API_PORT"
            warn "Verify: 1) Security groups allow port $API_PORT from worker to control plane"
            warn "        2) Control plane is running and accessible"
            warn "        3) Network connectivity between worker and control plane"
        fi
    fi

    # Wait for containerd to be fully ready
    log "Waiting for containerd to be ready..."
    for i in {1..30}; do
        if systemctl is-active --quiet containerd; then
            info "containerd is running"
            break
        fi
        if [ $i -eq 30 ]; then
            error "containerd failed to start after 30 seconds"
        fi
        sleep 1
    done

    # Ensure kubelet is configured before starting
    log "Configuring kubelet..."
    cat <<EOF > /etc/default/kubelet
KUBELET_EXTRA_ARGS=--cloud-provider=external
EOF

    # Wait for kubelet to be ready
    log "Starting and waiting for kubelet to be ready..."
    systemctl enable kubelet
    systemctl start kubelet

    for i in {1..30}; do
        if systemctl is-active --quiet kubelet; then
            info "kubelet is running"
            break
        fi
        if [ $i -eq 30 ]; then
            error "kubelet failed to start after 30 seconds"
        fi
        sleep 1
    done

    # Give services time to stabilize
    log "Allowing services to stabilize (10 seconds)..."
    sleep 10

    # Execute the join command with retry logic
    MAX_RETRIES=3
    RETRY_COUNT=0
    JOIN_SUCCESS=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Executing kubeadm join (attempt $RETRY_COUNT/$MAX_RETRIES)..."

        if eval "$JOIN_COMMAND"; then
            info "kubeadm join command executed successfully"
            JOIN_SUCCESS=true
            break
        else
            EXIT_CODE=$?
            warn "kubeadm join failed with exit code $EXIT_CODE"

            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                warn "Retrying in 15 seconds (attempt $RETRY_COUNT/$MAX_RETRIES)..."
                sleep 15
            fi
        fi
    done

    if [ "$JOIN_SUCCESS" = false ]; then
        error "Failed to join cluster after $MAX_RETRIES attempts. Run with --v=5 for detailed logs: kubeadm join ... --v=5"
    fi

    # Restart kubelet after successful join
    log "Restarting kubelet after successful join..."
    systemctl restart kubelet

    # Wait for kubelet to stabilize after restart
    log "Waiting for kubelet to stabilize..."
    sleep 5

    log "Worker node successfully joined the cluster"
}

# =============================================================================
# POST-JOIN CONFIGURATION
# =============================================================================

configure_user() {
    log "Configuring kubectl for ec2-user..."
    
    if id "ec2-user" &>/dev/null; then
        mkdir -p /home/ec2-user/.kube
        chown ec2-user:ec2-user /home/ec2-user/.kube
        
        cat <<EOF >> /home/ec2-user/.bashrc
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgn='kubectl get nodes'
EOF
        
        chown ec2-user:ec2-user /home/ec2-user/.bashrc
    fi
    
    log "User configuration completed"
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_installation() {
    log "Verifying installation..."
    
    echo ""
    info "Checking services..."
    systemctl status containerd --no-pager -l
    systemctl status kubelet --no-pager -l
    
    echo ""
    info "Recent kubelet logs:"
    journalctl -u kubelet --no-pager --lines=10
    
    log "Verification completed"
}

print_completion() {
    echo ""
    echo "=============================================================================="
    echo "WORKER NODE SETUP COMPLETED SUCCESSFULLY!"
    echo "=============================================================================="
    echo ""
    echo "Next Steps:"
    echo "  1. Verify node appears in cluster: kubectl get nodes (from control plane)"
    echo "  2. Wait for node to be Ready status"
    echo "  3. Check that system pods are scheduled on this node"
    echo ""
    echo "Happy Learning! 🚀"
    echo "=============================================================================="
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log "Starting Kubernetes Worker Node setup for Amazon Linux 2023..."

    check_root
    check_os
    get_join_command "$@"

    prepare_system
    set_hostname
    install_containerd
    install_kubernetes
    join_cluster
    configure_user
    
    verify_installation
    print_completion
    
    log "Setup completed successfully!"
}

main "$@"