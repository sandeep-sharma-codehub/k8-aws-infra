#!/bin/bash

# deploy-cluster.sh - Automated Kubernetes Cluster Deployment
# Version: 1.0
# Description: Orchestrates the deployment of a complete Kubernetes cluster
#              by copying and executing setup scripts on AWS EC2 instances

set -euo pipefail

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

# User-configurable via environment variables
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
TERRAFORM_DIR="${TERRAFORM_DIR:-.}"
SETUP_WORKERS_PARALLEL="${SETUP_WORKERS_PARALLEL:-false}"
WAIT_FOR_READY="${WAIT_FOR_READY:-true}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY_ATTEMPTS:-3}"
CONNECTION_TIMEOUT="${CONNECTION_TIMEOUT:-10}"
SSH_USER="${SSH_USER:-ec2-user}"

# Script paths
CONTROL_PLANE_SCRIPT="setup-control-plane-al2023.sh"
WORKER_SCRIPT="setup-worker-al2023.sh"

# Temporary files
JOIN_COMMAND_FILE="/tmp/kubeadm-join-command-$(date +%s).sh"
DEPLOYMENT_LOG="deployment-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Global variables
CONTROL_PLANE_IP=""
WORKER_IPS=()
SSH_KEY=""
FAILED_WORKERS=()

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}${msg}${NC}" | tee -a "$DEPLOYMENT_LOG"
}

info() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}${msg}${NC}" | tee -a "$DEPLOYMENT_LOG"
}

warn() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}${msg}${NC}" | tee -a "$DEPLOYMENT_LOG"
}

error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}${msg}${NC}" | tee -a "$DEPLOYMENT_LOG"
    exit 1
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$DEPLOYMENT_LOG"
}

phase() {
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${CYAN}${BOLD}[Phase $1] $2${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}" | tee -a "$DEPLOYMENT_LOG"
}

section() {
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${BOLD}==============================================================================${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${BOLD}$1${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${BOLD}==============================================================================${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"
}

# =============================================================================
# SSH HELPER FUNCTIONS
# =============================================================================

test_ssh_connection() {
    local host=$1
    local max_attempts=${2:-$MAX_RETRY_ATTEMPTS}
    local attempt=1

    info "Testing SSH connection to $host..."

    while [ $attempt -le $max_attempts ]; do
        if ssh -i "$SSH_KEY" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=$CONNECTION_TIMEOUT \
               -o BatchMode=yes \
               "$SSH_USER@$host" "echo 'SSH OK'" &>/dev/null; then
            return 0
        fi

        warn "SSH connection attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done

    return 1
}

ssh_exec() {
    local host=$1
    local command=$2
    local log_prefix=${3:-"SSH"}

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=$CONNECTION_TIMEOUT \
        "$SSH_USER@$host" "$command" 2>&1 | \
        while IFS= read -r line; do
            echo -e "${BLUE}[$log_prefix]${NC} $line" | tee -a "$DEPLOYMENT_LOG"
        done

    return ${PIPESTATUS[0]}
}

scp_file() {
    local source=$1
    local host=$2
    local destination=$3

    info "Copying $source to $host:$destination..."

    if scp -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=$CONNECTION_TIMEOUT \
           "$source" "$SSH_USER@$host:$destination" >> "$DEPLOYMENT_LOG" 2>&1; then
        success "File copied successfully"
        return 0
    else
        error "Failed to copy file to $host"
        return 1
    fi
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_prerequisites() {
    phase "1" "Pre-flight Checks"

    # Check if running from correct directory
    if [ ! -f "$TERRAFORM_DIR/main.tf" ]; then
        error "main.tf not found in $TERRAFORM_DIR. Are you in the correct directory?"
    fi
    success "Terraform directory found"

    # Check if Terraform state exists
    if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ] && [ ! -f "$TERRAFORM_DIR/.terraform/terraform.tfstate" ]; then
        error "Terraform state not found. Please run 'terraform apply' first."
    fi
    success "Terraform state found"

    # Check required commands
    for cmd in terraform ssh scp jq; do
        if ! command -v $cmd &> /dev/null; then
            error "Required command not found: $cmd"
        fi
    done
    success "Required commands available"

    # Check if setup scripts exist
    if [ ! -f "$CONTROL_PLANE_SCRIPT" ]; then
        error "Control plane setup script not found: $CONTROL_PLANE_SCRIPT"
    fi
    success "Control plane setup script found"

    if [ ! -f "$WORKER_SCRIPT" ]; then
        error "Worker setup script not found: $WORKER_SCRIPT"
    fi
    success "Worker setup script found"
}

get_terraform_outputs() {
    info "Retrieving Terraform outputs..."

    # Get control plane IP
    CONTROL_PLANE_IP=$(cd "$TERRAFORM_DIR" && terraform output -raw control_plane_public_ip 2>/dev/null)
    if [ -z "$CONTROL_PLANE_IP" ]; then
        error "Could not retrieve control plane IP from Terraform output"
    fi
    success "Control plane IP: $CONTROL_PLANE_IP"

    # Get worker IPs (JSON array)
    local worker_ips_json=$(cd "$TERRAFORM_DIR" && terraform output -json worker_node_public_ips 2>/dev/null)
    if [ -z "$worker_ips_json" ] || [ "$worker_ips_json" == "null" ]; then
        warn "No worker nodes found in Terraform output"
    else
        # Parse JSON array into bash array
        local ips_output=$(echo "$worker_ips_json" | jq -r '.[]')
        while IFS= read -r ip; do
            [ -n "$ip" ] && WORKER_IPS+=("$ip")
        done <<EOF
$ips_output
EOF
        success "Worker nodes found: ${#WORKER_IPS[@]}"
        for i in "${!WORKER_IPS[@]}"; do
            info "  Worker $((i+1)): ${WORKER_IPS[$i]}"
        done
    fi

    # Get SSH key name and try to locate it
    local key_name=$(cd "$TERRAFORM_DIR" && terraform output -raw key_pair_name 2>/dev/null)
    if [ -z "$key_name" ]; then
        warn "Could not retrieve key pair name from Terraform output"
        key_name="k8-cluster"
    fi

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
        error "SSH key not found. Please set SSH_KEY_PATH environment variable or place key at ~/.ssh/${key_name}.pem"
    fi

    success "SSH key found: $SSH_KEY"

    # Verify key permissions
    local key_perms=$(stat -f "%OLp" "$SSH_KEY" 2>/dev/null || stat -c "%a" "$SSH_KEY" 2>/dev/null)
    if [ "$key_perms" != "400" ] && [ "$key_perms" != "600" ]; then
        warn "SSH key permissions are $key_perms, should be 400 or 600"
        info "Fixing permissions: chmod 400 $SSH_KEY"
        chmod 400 "$SSH_KEY"
    fi
}

verify_ssh_connectivity() {
    info "Verifying SSH connectivity to all nodes..."

    # Test control plane
    if ! test_ssh_connection "$CONTROL_PLANE_IP"; then
        error "Cannot establish SSH connection to control plane: $CONTROL_PLANE_IP"
    fi
    success "Control plane SSH connection verified"

    # Test workers
    for i in "${!WORKER_IPS[@]}"; do
        if ! test_ssh_connection "${WORKER_IPS[$i]}"; then
            error "Cannot establish SSH connection to worker $((i+1)): ${WORKER_IPS[$i]}"
        fi
        success "Worker $((i+1)) SSH connection verified"
    done
}

# =============================================================================
# CONTROL PLANE DEPLOYMENT
# =============================================================================

deploy_control_plane() {
    phase "2" "Control Plane Deployment ($CONTROL_PLANE_IP)"

    # Copy setup script
    info "Copying control plane setup script..."
    scp_file "$CONTROL_PLANE_SCRIPT" "$CONTROL_PLANE_IP" "/tmp/$CONTROL_PLANE_SCRIPT"

    # Set executable permissions
    info "Setting executable permissions..."
    ssh_exec "$CONTROL_PLANE_IP" "chmod +x /tmp/$CONTROL_PLANE_SCRIPT" "Control Plane" || \
        error "Failed to set executable permissions"

    # Execute setup script
    info "Executing control plane setup script (this may take 10-15 minutes)..."
    echo "" | tee -a "$DEPLOYMENT_LOG"

    if ssh_exec "$CONTROL_PLANE_IP" "sudo /tmp/$CONTROL_PLANE_SCRIPT" "Control Plane"; then
        success "Control plane setup completed successfully"
    else
        error "Control plane setup failed. Check logs above for details."
    fi

    # Retrieve join command
    info "Retrieving kubeadm join command..."
    if scp -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           "$SSH_USER@$CONTROL_PLANE_IP:/tmp/kubeadm-join-command.sh" \
           "$JOIN_COMMAND_FILE" >> "$DEPLOYMENT_LOG" 2>&1; then
        success "Join command retrieved successfully"
    else
        error "Failed to retrieve join command from control plane"
    fi

    # Validate join command
    if [ ! -f "$JOIN_COMMAND_FILE" ] || [ ! -s "$JOIN_COMMAND_FILE" ]; then
        error "Join command file is empty or missing"
    fi

    local join_cmd=$(cat "$JOIN_COMMAND_FILE")
    if [[ ! "$join_cmd" =~ ^kubeadm\ join ]]; then
        error "Invalid join command format: $join_cmd"
    fi

    info "Join command: $(echo $join_cmd | cut -c1-50)..."

    # Verify control plane health
    info "Verifying control plane health..."
    sleep 10  # Give control plane a moment to settle

    if ssh_exec "$CONTROL_PLANE_IP" "kubectl get nodes 2>/dev/null | grep control-plane" "Control Plane" &>/dev/null; then
        success "Control plane is responding to kubectl commands"
    else
        warn "Control plane may not be fully ready yet, continuing anyway..."
    fi
}

# =============================================================================
# WORKER NODES DEPLOYMENT
# =============================================================================

deploy_worker() {
    local worker_ip=$1
    local worker_num=$2
    local join_command=$(cat "$JOIN_COMMAND_FILE")

    info "Deploying worker-$worker_num ($worker_ip)..."

    # Copy setup script
    if ! scp_file "$WORKER_SCRIPT" "$worker_ip" "/tmp/$WORKER_SCRIPT"; then
        warn "Failed to copy script to worker-$worker_num"
        FAILED_WORKERS+=("worker-$worker_num")
        return 1
    fi

    # Set executable permissions
    if ! ssh_exec "$worker_ip" "chmod +x /tmp/$WORKER_SCRIPT" "Worker-$worker_num" &>/dev/null; then
        warn "Failed to set executable permissions on worker-$worker_num"
        FAILED_WORKERS+=("worker-$worker_num")
        return 1
    fi

    # Execute setup script with join command
    info "Executing worker-$worker_num setup script (this may take 5-10 minutes)..."
    echo "" | tee -a "$DEPLOYMENT_LOG"

    if ssh_exec "$worker_ip" "sudo /tmp/$WORKER_SCRIPT '$join_command'" "Worker-$worker_num"; then
        success "Worker-$worker_num setup completed successfully"
        return 0
    else
        warn "Worker-$worker_num setup failed"
        FAILED_WORKERS+=("worker-$worker_num")
        return 1
    fi
}

deploy_workers() {
    phase "3" "Worker Nodes Deployment"

    if [ ${#WORKER_IPS[@]} -eq 0 ]; then
        warn "No worker nodes to deploy"
        return
    fi

    if [ "$SETUP_WORKERS_PARALLEL" = "true" ]; then
        info "Deploying workers in parallel mode..."

        # Deploy workers in parallel
        local pids=()
        for i in "${!WORKER_IPS[@]}"; do
            deploy_worker "${WORKER_IPS[$i]}" "$((i+1))" &
            pids+=($!)
        done

        # Wait for all workers
        info "Waiting for all workers to complete..."
        for pid in "${pids[@]}"; do
            wait $pid || warn "A worker deployment failed"
        done
    else
        info "Deploying workers sequentially..."

        # Deploy workers sequentially
        for i in "${!WORKER_IPS[@]}"; do
            deploy_worker "${WORKER_IPS[$i]}" "$((i+1))"
            echo "" | tee -a "$DEPLOYMENT_LOG"
        done
    fi

    # Report on failed workers
    if [ ${#FAILED_WORKERS[@]} -gt 0 ]; then
        warn "Some workers failed to deploy: ${FAILED_WORKERS[*]}"
        warn "You may need to manually fix these workers"
    else
        success "All workers deployed successfully"
    fi
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_cluster() {
    phase "4" "Cluster Verification"

    if [ "$WAIT_FOR_READY" = "true" ]; then
        info "Waiting for all nodes to become Ready (max 5 minutes)..."

        local max_wait=300  # 5 minutes
        local elapsed=0

        while [ $elapsed -lt $max_wait ]; do
            # Count total nodes and Ready nodes to determine if all are ready
            local total_nodes=$(ssh -i "$SSH_KEY" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=$CONNECTION_TIMEOUT \
                "$SSH_USER@$CONTROL_PLANE_IP" \
                "kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")

            local ready_nodes=$(ssh -i "$SSH_KEY" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=$CONNECTION_TIMEOUT \
                "$SSH_USER@$CONTROL_PLANE_IP" \
                "kubectl get nodes --no-headers 2>/dev/null | grep -w Ready | wc -l | tr -d ' '" 2>/dev/null || echo "0")

            if [ "$total_nodes" -gt "0" ] && [ "$total_nodes" = "$ready_nodes" ]; then
                success "All nodes are Ready"
                break
            fi

            info "Waiting for nodes to be Ready... ($elapsed seconds elapsed)"
            sleep 10
            elapsed=$((elapsed + 10))
        done

        if [ $elapsed -ge $max_wait ]; then
            warn "Timeout waiting for all nodes to be Ready"
        fi
    fi

    # Display cluster status
    echo "" | tee -a "$DEPLOYMENT_LOG"
    info "Cluster Status:"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    # Check if API server is responding
    if ! ssh_exec "$CONTROL_PLANE_IP" "kubectl get nodes -o wide 2>&1" "Cluster"; then
        error "API server is not responding. Please run: ./diagnose-api-server.sh $CONTROL_PLANE_IP"
    fi

    echo "" | tee -a "$DEPLOYMENT_LOG"
    info "System Pods Status:"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    ssh_exec "$CONTROL_PLANE_IP" "kubectl get pods -n kube-system" "Cluster"

    echo "" | tee -a "$DEPLOYMENT_LOG"
    info "Storage Configuration:"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    ssh_exec "$CONTROL_PLANE_IP" "kubectl get storageclass" "Cluster"

    echo "" | tee -a "$DEPLOYMENT_LOG"
    info "Sample Storage Resources:"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    ssh_exec "$CONTROL_PLANE_IP" "kubectl get all -n storage-examples" "Cluster"
}

# =============================================================================
# KUBECTL CONFIGURATION FOR WORKERS
# =============================================================================

configure_kubectl_on_workers() {
    phase "5" "Configure kubectl Access on Worker Nodes"

    if [ ${#WORKER_IPS[@]} -eq 0 ]; then
        warn "No worker nodes to configure"
        return
    fi

    info "Setting up kubectl access on worker nodes..."

    # Prepare admin.conf on control plane
    info "Preparing kubeconfig on control plane..."
    if ! ssh_exec "$CONTROL_PLANE_IP" \
        "sudo cp /etc/kubernetes/admin.conf /tmp/admin.conf && sudo chown $SSH_USER:$SSH_USER /tmp/admin.conf" \
        "Control Plane" &>/dev/null; then
        warn "Failed to prepare kubeconfig on control plane"
        return 1
    fi

    # Download kubeconfig locally
    local temp_kubeconfig="/tmp/kubeadm-admin-$(date +%s).conf"
    info "Downloading kubeconfig..."
    if ! scp -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=$CONNECTION_TIMEOUT \
           "$SSH_USER@$CONTROL_PLANE_IP:/tmp/admin.conf" \
           "$temp_kubeconfig" >> "$DEPLOYMENT_LOG" 2>&1; then
        warn "Failed to download kubeconfig from control plane"
        return 1
    fi
    success "Kubeconfig downloaded"

    # Configure each worker
    for i in "${!WORKER_IPS[@]}"; do
        local worker_ip="${WORKER_IPS[$i]}"
        local worker_num=$((i+1))

        info "Configuring kubectl on worker-$worker_num ($worker_ip)..."

        # Create .kube directory
        if ! ssh -i "$SSH_KEY" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=$CONNECTION_TIMEOUT \
               "$SSH_USER@$worker_ip" \
               "mkdir -p \$HOME/.kube" >> "$DEPLOYMENT_LOG" 2>&1; then
            warn "Failed to create .kube directory on worker-$worker_num"
            continue
        fi

        # Copy kubeconfig to worker
        if ! scp -i "$SSH_KEY" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=$CONNECTION_TIMEOUT \
               "$temp_kubeconfig" \
               "$SSH_USER@$worker_ip:~/.kube/config" >> "$DEPLOYMENT_LOG" 2>&1; then
            warn "Failed to copy kubeconfig to worker-$worker_num"
            continue
        fi

        # Set proper ownership
        if ! ssh -i "$SSH_KEY" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=$CONNECTION_TIMEOUT \
               "$SSH_USER@$worker_ip" \
               "sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config" >> "$DEPLOYMENT_LOG" 2>&1; then
            warn "Failed to set ownership on worker-$worker_num"
            continue
        fi

        # Verify kubectl access
        if ssh -i "$SSH_KEY" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=$CONNECTION_TIMEOUT \
               "$SSH_USER@$worker_ip" \
               "kubectl get nodes &>/dev/null" 2>&1; then
            success "Worker-$worker_num kubectl configured successfully"
        else
            warn "Worker-$worker_num kubectl configuration may not be working"
        fi
    done

    # Cleanup
    rm -f "$temp_kubeconfig"
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$CONTROL_PLANE_IP" \
        "rm -f /tmp/admin.conf" >> "$DEPLOYMENT_LOG" 2>&1

    success "kubectl configuration completed for all workers"
}

# =============================================================================
# LOCAL KUBECTL SETUP
# =============================================================================

setup_local_kubectl() {
    phase "6" "Local kubectl Setup"

    local kubeconfig_dest="$HOME/.kube/k8s-practice-config"
    local tmp_kubeconfig="/tmp/k8s-practice-kubeconfig-$(date +%s).yaml"

    # Copy kubeconfig on control plane to a readable location
    info "Exporting kubeconfig from control plane..."
    if ! ssh -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout="$CONNECTION_TIMEOUT" \
           "$SSH_USER@$CONTROL_PLANE_IP" \
           "sudo cp /etc/kubernetes/admin.conf /tmp/kubeconfig-export.yaml && sudo chown \$(id -u):\$(id -g) /tmp/kubeconfig-export.yaml" >> "$DEPLOYMENT_LOG" 2>&1; then
        warn "Failed to export kubeconfig on control plane — skipping local kubectl setup"
        return 0
    fi

    # Download to local temp file
    if ! scp -i "$SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout="$CONNECTION_TIMEOUT" \
           "$SSH_USER@$CONTROL_PLANE_IP:/tmp/kubeconfig-export.yaml" \
           "$tmp_kubeconfig" >> "$DEPLOYMENT_LOG" 2>&1; then
        warn "Failed to download kubeconfig — skipping local kubectl setup"
        return 0
    fi

    # Patch server URL: replace private IP with public IP
    local private_ip
    private_ip=$(grep "server:" "$tmp_kubeconfig" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [ -n "$private_ip" ]; then
        sed -i.bak "s|https://${private_ip}:6443|https://${CONTROL_PLANE_IP}:6443|g" "$tmp_kubeconfig"
        rm -f "${tmp_kubeconfig}.bak"
        success "Server URL patched: $private_ip → $CONTROL_PLANE_IP"
    else
        warn "Could not detect private IP in kubeconfig — local kubectl may not connect"
    fi

    # Save to named file (never overwrites ~/.kube/config)
    mkdir -p "$HOME/.kube"
    cp "$tmp_kubeconfig" "$kubeconfig_dest"
    chmod 600 "$kubeconfig_dest"
    rm -f "$tmp_kubeconfig"

    # Clean up temp file on control plane
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$CONTROL_PLANE_IP" \
        "rm -f /tmp/kubeconfig-export.yaml" >> "$DEPLOYMENT_LOG" 2>&1 || true

    success "Kubeconfig saved to $kubeconfig_dest"
    info "To use kubectl locally:"
    echo -e "  ${CYAN}export KUBECONFIG=$kubeconfig_dest${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  ${CYAN}kubectl get nodes${NC}" | tee -a "$DEPLOYMENT_LOG"
}

# =============================================================================
# SUMMARY AND CLEANUP
# =============================================================================

print_summary() {
    section "Deployment Summary"

    local end_time=$(date +%s)
    local start_time=$(stat -f %m "$DEPLOYMENT_LOG" 2>/dev/null || stat -c %Y "$DEPLOYMENT_LOG" 2>/dev/null)
    local duration=$((end_time - start_time))
    local duration_min=$((duration / 60))
    local duration_sec=$((duration % 60))

    if [ ${#FAILED_WORKERS[@]} -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ Deployment completed successfully! 🎉${NC}" | tee -a "$DEPLOYMENT_LOG"
    else
        echo -e "${YELLOW}${BOLD}⚠ Deployment completed with warnings${NC}" | tee -a "$DEPLOYMENT_LOG"
        echo -e "${YELLOW}Failed workers: ${FAILED_WORKERS[*]}${NC}" | tee -a "$DEPLOYMENT_LOG"
    fi

    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "${BOLD}Cluster Information:${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  Control Plane: ${CONTROL_PLANE_IP}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  Worker Nodes: ${#WORKER_IPS[@]}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  Total Duration: ${duration_min}m ${duration_sec}s" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    echo -e "${BOLD}kubectl Access:${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  ✓ kubectl configured on control plane and all worker nodes" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  ✓ You can run kubectl commands from any node in the cluster" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    echo -e "${BOLD}Next Steps:${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  1. SSH to control plane:" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}ssh -i $SSH_KEY $SSH_USER@$CONTROL_PLANE_IP${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  2. SSH to worker nodes (kubectl is available on all workers):" | tee -a "$DEPLOYMENT_LOG"
    for i in "${!WORKER_IPS[@]}"; do
        echo -e "     ${CYAN}ssh -i $SSH_KEY $SSH_USER@${WORKER_IPS[$i]}${NC}" | tee -a "$DEPLOYMENT_LOG"
    done
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  3. View cluster status (from any node):" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}kubectl get nodes${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}kubectl get pods --all-namespaces${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  4. Explore storage examples:" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}kubectl get all -n storage-examples${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}kubectl get pvc -n storage-examples${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"
    echo -e "  5. View storage classes:" | tee -a "$DEPLOYMENT_LOG"
    echo -e "     ${CYAN}kubectl get storageclass${NC}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    echo -e "${BOLD}Deployment log saved to:${NC} ${DEPLOYMENT_LOG}" | tee -a "$DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    section "Deployment Complete"
}

cleanup() {
    # Clean up temporary files
    if [ -f "$JOIN_COMMAND_FILE" ]; then
        rm -f "$JOIN_COMMAND_FILE"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Trap cleanup on exit
    trap cleanup EXIT

    section "Kubernetes Cluster Deployment Automation"

    info "Starting deployment at $(date)"
    info "Deployment log: $DEPLOYMENT_LOG"
    echo "" | tee -a "$DEPLOYMENT_LOG"

    # Phase 1: Pre-flight checks
    check_prerequisites
    get_terraform_outputs
    verify_ssh_connectivity

    # Phase 2: Deploy control plane
    deploy_control_plane

    # Phase 3: Deploy workers
    if [ ${#WORKER_IPS[@]} -gt 0 ]; then
        deploy_workers
    fi

    # Phase 4: Verify cluster
    verify_cluster

    # Phase 5: Configure kubectl on workers
    if [ ${#WORKER_IPS[@]} -gt 0 ]; then
        configure_kubectl_on_workers
    fi

    # Phase 6: Set up local kubectl access
    setup_local_kubectl

    # Print summary
    print_summary
}

# Run main function
main "$@"
