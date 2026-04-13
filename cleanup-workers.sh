#!/bin/bash

# cleanup-workers.sh
# Automated cleanup script for Kubernetes worker nodes
# Usage: ./cleanup-workers.sh [terraform-dir]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
TERRAFORM_DIR="${1:-.}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_USER="${SSH_USER:-ec2-user}"
CONNECTION_TIMEOUT="${CONNECTION_TIMEOUT:-10}"

# Global variables
WORKER_IPS=()
SSH_KEY=""
CLEANUP_LOG="worker-cleanup-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}${msg}${NC}" | tee -a "$CLEANUP_LOG"
}

info() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}${msg}${NC}" | tee -a "$CLEANUP_LOG"
}

warn() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}${msg}${NC}" | tee -a "$CLEANUP_LOG"
}

error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}${msg}${NC}" | tee -a "$CLEANUP_LOG"
    exit 1
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$CLEANUP_LOG"
}

section() {
    echo "" | tee -a "$CLEANUP_LOG"
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════╗${NC}" | tee -a "$CLEANUP_LOG"
    echo -e "${CYAN}${BOLD}║   $1$(printf '%*s' $((52 - ${#1})) '')║${NC}" | tee -a "$CLEANUP_LOG"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════╝${NC}" | tee -a "$CLEANUP_LOG"
    echo "" | tee -a "$CLEANUP_LOG"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_prerequisites() {
    info "Checking prerequisites..."

    # Check Terraform directory
    if [ ! -f "$TERRAFORM_DIR/main.tf" ]; then
        error "main.tf not found in $TERRAFORM_DIR"
    fi
    success "Terraform directory found"

    # Check Terraform state
    if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ] && [ ! -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]; then
        error "Terraform state not found. Please run 'terraform apply' first"
    fi
    success "Terraform state found"

    # Check required commands
    for cmd in terraform ssh jq; do
        if ! command -v $cmd &> /dev/null; then
            error "Required command not found: $cmd"
        fi
    done
    success "Required commands available"
}

get_worker_ips() {
    info "Retrieving worker node IPs from Terraform..."

    # Get worker IPs
    local worker_ips_json=$(cd "$TERRAFORM_DIR" && terraform output -json worker_node_public_ips 2>/dev/null)
    if [ -z "$worker_ips_json" ] || [ "$worker_ips_json" == "null" ]; then
        error "No worker nodes found in Terraform output"
    fi

    # Parse JSON array
    local ips_output=$(echo "$worker_ips_json" | jq -r '.[]')
    while IFS= read -r ip; do
        [ -n "$ip" ] && WORKER_IPS+=("$ip")
    done <<EOF
$ips_output
EOF

    if [ ${#WORKER_IPS[@]} -eq 0 ]; then
        error "No worker IPs found"
    fi

    success "Found ${#WORKER_IPS[@]} worker nodes"
    for i in "${!WORKER_IPS[@]}"; do
        info "  Worker $((i+1)): ${WORKER_IPS[$i]}"
    done
}

get_ssh_key() {
    info "Locating SSH key..."

    # Get key name from Terraform
    local key_name=$(cd "$TERRAFORM_DIR" && terraform output -raw key_pair_name 2>/dev/null || echo "k8-cluster")

    # Auto-detect SSH key location
    if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
        SSH_KEY="$SSH_KEY_PATH"
    elif [ -f "$HOME/.ssh/${key_name}.pem" ]; then
        SSH_KEY="$HOME/.ssh/${key_name}.pem"
    elif [ -f "$HOME/.ssh/${key_name}" ]; then
        SSH_KEY="$HOME/.ssh/${key_name}"
    elif [ -f "./${key_name}.pem" ]; then
        SSH_KEY="./${key_name}.pem"
    else
        error "SSH key not found. Set SSH_KEY_PATH or place key at ~/.ssh/${key_name}.pem"
    fi

    success "SSH key found: $SSH_KEY"

    # Fix permissions if needed
    local key_perms=$(stat -f "%OLp" "$SSH_KEY" 2>/dev/null || stat -c "%a" "$SSH_KEY" 2>/dev/null)
    if [ "$key_perms" != "400" ] && [ "$key_perms" != "600" ]; then
        chmod 400 "$SSH_KEY"
        info "Fixed SSH key permissions"
    fi
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

test_ssh_connection() {
    local host=$1
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=$CONNECTION_TIMEOUT \
        -o BatchMode=yes \
        "$SSH_USER@$host" "echo 'SSH OK'" &>/dev/null
}

cleanup_single_worker() {
    local worker_ip=$1
    local worker_num=$2

    info "Cleaning up Worker $worker_num ($worker_ip)..."

    if ! test_ssh_connection "$worker_ip"; then
        warn "Cannot connect to Worker $worker_num - skipping"
        return 1
    fi

    # Execute cleanup commands
    local cleanup_script='
echo "Stopping kubelet service..."
sudo systemctl stop kubelet 2>/dev/null || true
sleep 2

echo "Killing any remaining kubelet processes..."
sudo pkill -9 -f kubelet 2>/dev/null || true
sleep 1

echo "Resetting Kubernetes configuration..."
sudo kubeadm reset -f 2>/dev/null || true

echo "Force removing Kubernetes files..."
sudo rm -f /etc/kubernetes/kubelet.conf
sudo rm -f /etc/kubernetes/pki/ca.crt
sudo rm -f /etc/kubernetes/bootstrap-kubelet.conf

echo "Removing Kubernetes directories..."
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /opt/cni/bin/

echo "Cleaning up container runtime..."
sudo systemctl restart containerd
sleep 2

echo "Restarting kubelet..."
sudo systemctl restart kubelet
sudo systemctl enable kubelet

echo "Verifying cleanup..."
if [ ! -f /etc/kubernetes/kubelet.conf ]; then
    echo "✓ kubelet.conf removed"
else
    echo "⚠ kubelet.conf still exists - force removing"
    sudo rm -f /etc/kubernetes/kubelet.conf
fi

if [ ! -f /etc/kubernetes/pki/ca.crt ]; then
    echo "✓ ca.crt removed"
else
    echo "⚠ ca.crt still exists - force removing"
    sudo rm -f /etc/kubernetes/pki/ca.crt
fi

if ! sudo netstat -tlnp 2>/dev/null | grep -q ":10250.*kubelet"; then
    echo "✓ Port 10250 is free"
else
    echo "⚠ Port 10250 still in use - killing process"
    sudo fuser -k 10250/tcp 2>/dev/null || true
fi

echo "✓ Worker cleanup complete"
'

    if ssh -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=$CONNECTION_TIMEOUT \
           "$SSH_USER@$worker_ip" "$cleanup_script" 2>&1 | \
           while IFS= read -r line; do
               echo -e "${BLUE}[Worker-$worker_num]${NC} $line" | tee -a "$CLEANUP_LOG"
           done; then
        success "Worker $worker_num cleanup completed"
        return 0
    else
        warn "Worker $worker_num cleanup failed"
        return 1
    fi
}

cleanup_all_workers() {
    section "CLEANING UP ALL WORKER NODES"

    local failed_workers=()
    local success_count=0

    for i in "${!WORKER_IPS[@]}"; do
        local worker_num=$((i+1))
        local worker_ip="${WORKER_IPS[$i]}"

        if cleanup_single_worker "$worker_ip" "$worker_num"; then
            success_count=$((success_count + 1))
        else
            failed_workers+=("$worker_num")
        fi
        echo ""
    done

    # Summary
    section "CLEANUP SUMMARY"
    log "Total workers: ${#WORKER_IPS[@]}"
    log "Successfully cleaned: $success_count"
    log "Failed: ${#failed_workers[@]}"

    if [ ${#failed_workers[@]} -gt 0 ]; then
        warn "Failed workers: ${failed_workers[*]}"
        echo ""
        echo -e "${YELLOW}Manual cleanup may be required for failed workers.${NC}"
        echo -e "${YELLOW}You can retry with: ./cleanup-workers.sh${NC}"
    else
        echo ""
        echo -e "${GREEN}All workers cleaned successfully!${NC}"
        echo -e "${GREEN}Workers are now ready for 'kubeadm join' commands.${NC}"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    section "KUBERNETES WORKER CLEANUP"

    echo -e "${YELLOW}This script will reset ALL worker nodes in your cluster.${NC}"
    echo -e "${YELLOW}This will remove all Kubernetes configuration and stop all pods.${NC}"
    echo ""
    echo -e "${RED}Are you sure you want to continue? (y/N):${NC}"
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi

    check_prerequisites
    get_worker_ips
    get_ssh_key
    cleanup_all_workers

    echo ""
    echo -e "${CYAN}Cleanup log saved to: $CLEANUP_LOG${NC}"
}

# Run main function
main "$@"