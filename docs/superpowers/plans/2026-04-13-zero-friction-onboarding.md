# Zero-Friction Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Any learner can `git clone` the repo and run `./bootstrap.sh` to get a working Kubernetes cluster with both local and SSH kubectl access — no manual steps required.

**Architecture:** A new `bootstrap.sh` orchestrates the full setup (SSH key generation, terraform.tfvars creation, Terraform apply, cluster deploy, local kubeconfig). A new Phase 6 in `deploy-cluster.sh` downloads and patches the kubeconfig for local use. A clean `terraform.tfvars.example` replaces the currently committed `terraform.tfvars`.

**Tech Stack:** Bash, Terraform (AWS provider ~5.0), kubeadm, kubectl, AWS CLI, jq

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `bootstrap.sh` | **Create** | End-to-end setup orchestrator for new learners |
| `terraform.tfvars.example` | **Create** | Clean documented config template (no real values) |
| `main.tf` | **Modify** | Allow port 6443 from `allowed_ssh_cidrs` (required for local kubectl) |
| `deploy-cluster.sh` | **Modify** | Add Phase 6: download + patch kubeconfig for local use |
| `README.md` | **Modify** | Simplify Quick Start to 3 lines |
| `terraform.tfvars` | **Untrack** | Remove from git (already in .gitignore) |
| `cleanup-workers.sh` | **Commit** | Currently untracked |
| `diagnose-control-plane.sh` | **Commit** | Currently has uncommitted changes |

---

## Task 1: Git Hygiene

**Files:**
- Untrack: `terraform.tfvars`
- Verify untracked: `k8-cluster.pem`
- Commit: `cleanup-workers.sh`
- Commit: `diagnose-control-plane.sh`

- [ ] **Step 1: Check what is currently tracked**

```bash
git status
git ls-files terraform.tfvars k8-cluster.pem
```

Expected output: both files listed by `git ls-files` if they are tracked.

- [ ] **Step 2: Untrack terraform.tfvars without deleting it**

```bash
git rm --cached terraform.tfvars
```

Expected: `rm 'terraform.tfvars'`

- [ ] **Step 3: Untrack k8-cluster.pem if it is tracked**

Only run this if `git ls-files k8-cluster.pem` returned output in Step 1:

```bash
git rm --cached k8-cluster.pem
```

Skip if it was already untracked.

- [ ] **Step 4: Stage and commit the pending files**

```bash
git add cleanup-workers.sh diagnose-control-plane.sh
git commit -m "chore: commit cleanup-workers and diagnose-control-plane scripts"
```

- [ ] **Step 5: Commit the untracking of sensitive files**

```bash
git commit -m "chore: untrack terraform.tfvars and pem key from git history"
```

- [ ] **Step 6: Verify clean state**

```bash
git status
git ls-files terraform.tfvars k8-cluster.pem
```

Expected: `git ls-files` returns nothing. `git status` shows terraform.tfvars and k8-cluster.pem only if they physically exist (as untracked, ignored files).

---

## Task 2: Create terraform.tfvars.example

**Files:**
- Create: `terraform.tfvars.example`

- [ ] **Step 1: Create the file**

Create `terraform.tfvars.example` with the following content:

```hcl
# terraform.tfvars.example
# Copy to terraform.tfvars and customize, OR just run ./bootstrap.sh (fills values automatically)

# =============================================================================
# GENERAL CONFIGURATION
# =============================================================================

aws_region   = "us-east-1"   # Change to your preferred region
project_name = "k8s-practice"
environment  = "practice"

# =============================================================================
# NETWORK CONFIGURATION
# =============================================================================

vpc_cidr            = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
pod_cidr            = "192.168.0.0/16"
service_cidr        = "10.96.0.0/12"

# =============================================================================
# SECURITY CONFIGURATION
# =============================================================================

# SECURITY: Replace 0.0.0.0/0 with your IP for better security: ["YOUR_IP/32"]
# bootstrap.sh sets this to your detected public IP automatically.
allowed_ssh_cidrs = ["0.0.0.0/0"]

# =============================================================================
# INSTANCE CONFIGURATION
# =============================================================================

ami_id = ""  # Leave empty to use latest Amazon Linux 2023

control_plane_instance_type = "t3.medium"   # Minimum recommended
worker_node_instance_type   = "t3.small"
worker_node_count           = 2             # 1-10 workers

# =============================================================================
# STORAGE CONFIGURATION
# =============================================================================

control_plane_volume_size = 30   # GB
worker_node_volume_size   = 20   # GB

# =============================================================================
# SSH KEY CONFIGURATION
# =============================================================================

# bootstrap.sh sets create_key_pair=true and fills public_key automatically.
# For manual setup: set create_key_pair=true and paste your public key below,
# OR set create_key_pair=false and provide an existing AWS key pair name.
create_key_pair   = true
public_key        = ""   # Paste output of: cat ~/.ssh/your-key.pub
existing_key_name = ""   # Only needed if create_key_pair = false

# =============================================================================
# KUBERNETES CONFIGURATION
# =============================================================================

kubernetes_version = "1.30.0"
container_runtime  = "containerd"
cni_plugin         = "calico"

# =============================================================================
# FEATURE FLAGS
# =============================================================================

enable_audit_logging      = true
enable_network_policies   = true
enable_ingress_controller = true
enable_metrics_server     = true

install_additional_tools = true
create_sample_namespaces = true
sample_namespaces = ["frontend", "backend", "monitoring", "testing", "production"]

# =============================================================================
# COST OPTIMIZATION
# =============================================================================

enable_spot_instances               = false
spot_instance_interruption_behavior = "terminate"
auto_shutdown_enabled               = false
auto_shutdown_time                  = "18:00"

# =============================================================================
# MONITORING AND LOGGING (disabled by default to reduce cost)
# =============================================================================

enable_cloudwatch_logs = false
log_retention_days     = 7

# =============================================================================
# BACKUP (disabled by default)
# =============================================================================

enable_ebs_snapshots    = false
snapshot_retention_days = 7
```

- [ ] **Step 2: Verify the file covers all variables in variables.tf**

```bash
grep '^variable ' variables.tf | sed 's/variable "\(.*\)" {/\1/' | sort > /tmp/vars.txt
grep -E '^[a-z_]+ ' terraform.tfvars.example | sed 's/ =.*//' | sort > /tmp/example.txt
diff /tmp/vars.txt /tmp/example.txt
```

Expected: no output (all variables present). If there are variables in `/tmp/vars.txt` missing from `/tmp/example.txt`, add them to `terraform.tfvars.example`.

- [ ] **Step 3: Commit**

```bash
git add terraform.tfvars.example
git commit -m "feat: add terraform.tfvars.example with documented defaults"
```

---

## Task 3: Open API Server Port for Local kubectl

**Files:**
- Modify: `main.tf` lines 129-136 (Kubernetes API server ingress rule)

The current rule only allows port 6443 from the VPC CIDR. Local `kubectl` connects from outside the VPC, so this port must also accept traffic from `allowed_ssh_cidrs`.

- [ ] **Step 1: Read the current ingress rule**

In `main.tf`, find the block around line 129:

```hcl
# Kubernetes API server
ingress {
    description = "Kubernetes API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
}
```

- [ ] **Step 2: Update the rule to also allow from allowed_ssh_cidrs**

Replace the `cidr_blocks` line in that block:

```hcl
# Kubernetes API server
ingress {
    description = "Kubernetes API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = concat([var.vpc_cidr], var.allowed_ssh_cidrs)
}
```

- [ ] **Step 3: Verify the change is syntactically valid**

```bash
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add main.tf
git commit -m "fix: allow kubectl API access from allowed_ssh_cidrs for local use"
```

---

## Task 4: Add Phase 6 to deploy-cluster.sh

**Files:**
- Modify: `deploy-cluster.sh`

Phase 6 downloads the kubeconfig from the control plane, patches the server address from private to public IP, and saves it to `~/.kube/k8s-practice-config`.

- [ ] **Step 1: Add the setup_local_kubectl function**

In `deploy-cluster.sh`, add this function after the `configure_kubectl_on_workers` function (around line 582), before the `print_summary` function:

```bash
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
```

- [ ] **Step 2: Call setup_local_kubectl from main()**

In the `main()` function, add the call after `configure_kubectl_on_workers`. Find this block (around line 680):

```bash
    # Phase 5: Configure kubectl on workers
    if [ ${#WORKER_IPS[@]} -gt 0 ]; then
        configure_kubectl_on_workers
    fi

    # Print summary
    print_summary
```

Replace with:

```bash
    # Phase 5: Configure kubectl on workers
    if [ ${#WORKER_IPS[@]} -gt 0 ]; then
        configure_kubectl_on_workers
    fi

    # Phase 6: Set up local kubectl access
    setup_local_kubectl

    # Print summary
    print_summary
```

- [ ] **Step 3: Verify the script is syntactically valid**

```bash
bash -n deploy-cluster.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add deploy-cluster.sh
git commit -m "feat: add Phase 6 to deploy-cluster.sh for local kubeconfig setup"
```

---

## Task 5: Create bootstrap.sh

**Files:**
- Create: `bootstrap.sh`

- [ ] **Step 1: Create the file**

Create `bootstrap.sh` with the following content:

```bash
#!/bin/bash

# bootstrap.sh - Zero-friction setup for Kubernetes CKA/CKAD practice environment
# Usage: ./bootstrap.sh
# Re-run safe: each step skips if already done

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

KEY_NAME="k8-cluster"
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"
PUB_KEY_PATH="$HOME/.ssh/${KEY_NAME}.pub"
KUBECONFIG_DEST="$HOME/.kube/k8s-practice-config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# UTILITIES
# =============================================================================

log()     { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${BLUE}→ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "${RED}✗ ERROR: $1${NC}"; exit 1; }

section() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# STEP 1: PREFLIGHT CHECKS
# =============================================================================

preflight_checks() {
    section "Step 1/6: Preflight Checks"

    local missing=()
    for cmd in terraform aws jq ssh-keygen curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}\n\nInstall them and re-run bootstrap.sh\n  macOS: brew install terraform awscli jq curl\n  Linux: see docs for your distro"
    fi
    log "Required tools available: terraform, aws, jq, ssh-keygen, curl"

    if ! aws sts get-caller-identity &>/dev/null; then
        error "AWS credentials not configured.\n\nRun:  aws configure\nOr set environment variables:\n  export AWS_ACCESS_KEY_ID=...\n  export AWS_SECRET_ACCESS_KEY=...\n  export AWS_REGION=..."
    fi
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text)
    log "AWS credentials valid (Account: $account_id)"

    if [ ! -f "terraform.tfvars.example" ]; then
        error "Run bootstrap.sh from the repo root directory (terraform.tfvars.example not found)"
    fi
    log "Running from repo root directory"
}

# =============================================================================
# STEP 2: SSH KEY SETUP
# =============================================================================

setup_ssh_key() {
    section "Step 2/6: SSH Key Setup"

    if [ -f "$KEY_PATH" ]; then
        log "SSH key already exists at $KEY_PATH"
        chmod 400 "$KEY_PATH"
        # Regenerate public key if missing
        if [ ! -f "$PUB_KEY_PATH" ]; then
            ssh-keygen -y -f "$KEY_PATH" > "$PUB_KEY_PATH"
            log "Public key regenerated at $PUB_KEY_PATH"
        fi
        return 0
    fi

    info "Generating new 4096-bit RSA keypair..."
    mkdir -p "$HOME/.ssh"
    # ssh-keygen -f path creates path (private) and path.pub (public)
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -C "k8s-practice-cluster" 2>/dev/null
    # ssh-keygen appends .pub to the -f path; rename to clean name
    if [ -f "${KEY_PATH}.pub" ]; then
        mv "${KEY_PATH}.pub" "$PUB_KEY_PATH"
    fi
    chmod 400 "$KEY_PATH"

    log "SSH private key: $KEY_PATH"
    log "SSH public key:  $PUB_KEY_PATH"
}

# =============================================================================
# STEP 3: CONFIGURE terraform.tfvars
# =============================================================================

configure_tfvars() {
    section "Step 3/6: Configure terraform.tfvars"

    if [ -f "terraform.tfvars" ]; then
        log "terraform.tfvars already exists — skipping (delete it to reconfigure)"
        return 0
    fi

    info "Detecting your public IP address..."
    local my_ip=""
    my_ip=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
            curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            echo "")

    local ssh_cidrs
    if [ -n "$my_ip" ]; then
        ssh_cidrs="[\"${my_ip}/32\"]"
        log "SSH access will be restricted to your IP: ${my_ip}/32"
    else
        ssh_cidrs="[\"0.0.0.0/0\"]"
        warn "Could not detect public IP — SSH open to 0.0.0.0/0. Update allowed_ssh_cidrs in terraform.tfvars to restrict access."
    fi

    local public_key_content
    public_key_content=$(cat "$PUB_KEY_PATH")

    # Write terraform.tfvars directly (avoids fragile sed substitutions on multiline values)
    cat > terraform.tfvars << TFVARS
# Generated by bootstrap.sh on $(date)
# Edit this file to customize your cluster. Re-run bootstrap.sh after changes.

aws_region   = "us-east-1"
project_name = "k8s-practice"
environment  = "practice"

vpc_cidr            = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
pod_cidr            = "192.168.0.0/16"
service_cidr        = "10.96.0.0/12"

allowed_ssh_cidrs = ${ssh_cidrs}

ami_id                      = ""
control_plane_instance_type = "t3.medium"
worker_node_instance_type   = "t3.small"
worker_node_count           = 2

control_plane_volume_size = 30
worker_node_volume_size   = 20

create_key_pair   = true
public_key        = "${public_key_content}"
existing_key_name = ""

kubernetes_version = "1.30.0"
container_runtime  = "containerd"
cni_plugin         = "calico"

enable_audit_logging      = true
enable_network_policies   = true
enable_ingress_controller = true
enable_metrics_server     = true

install_additional_tools = true
create_sample_namespaces = true
sample_namespaces = ["frontend", "backend", "monitoring", "testing", "production"]

enable_spot_instances               = false
spot_instance_interruption_behavior = "terminate"
auto_shutdown_enabled               = false
auto_shutdown_time                  = "18:00"

enable_cloudwatch_logs = false
log_retention_days     = 7

enable_ebs_snapshots    = false
snapshot_retention_days = 7
TFVARS

    log "terraform.tfvars created"
    info "Review terraform.tfvars to change region, instance types, or worker count before continuing."
    echo ""
    echo -e "${YELLOW}Press ENTER to continue with the default settings, or Ctrl+C to edit terraform.tfvars first.${NC}"
    read -r
}

# =============================================================================
# STEP 4: TERRAFORM
# =============================================================================

run_terraform() {
    section "Step 4/6: Deploy AWS Infrastructure"

    info "Initializing Terraform..."
    terraform init -upgrade

    echo ""
    info "Planning infrastructure..."
    terraform plan -out=tfplan

    echo ""
    echo -e "${YELLOW}The plan above will create AWS resources that cost approximately \$70-75/month.${NC}"
    echo -e "${YELLOW}Run 'terraform destroy' when you are done to stop all charges.${NC}"
    echo ""
    read -p "Continue with deployment? [y/N] " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Deployment cancelled. Edit terraform.tfvars if needed, then re-run ./bootstrap.sh"
        rm -f tfplan
        exit 0
    fi

    terraform apply tfplan
    rm -f tfplan
    log "AWS infrastructure deployed"
}

# =============================================================================
# STEP 5: DEPLOY KUBERNETES CLUSTER
# =============================================================================

deploy_cluster() {
    section "Step 5/6: Deploy Kubernetes Cluster"

    chmod +x deploy-cluster.sh

    # Pass SSH key path explicitly so deploy-cluster.sh uses the key we generated
    export SSH_KEY_PATH="$KEY_PATH"
    ./deploy-cluster.sh
}

# =============================================================================
# STEP 6: FINAL INSTRUCTIONS
# =============================================================================

print_final_instructions() {
    section "Step 6/6: Done!"

    local cp_ip=""
    cp_ip=$(terraform output -raw control_plane_public_ip 2>/dev/null || echo "<control-plane-ip>")

    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║   Your Kubernetes practice cluster is ready! 🎉     ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [ -f "$KUBECONFIG_DEST" ]; then
        echo -e "${BOLD}Use kubectl from your local machine:${NC}"
        echo -e "  ${CYAN}export KUBECONFIG=$KUBECONFIG_DEST${NC}"
        echo -e "  ${CYAN}kubectl get nodes${NC}"
        echo ""
    fi

    echo -e "${BOLD}SSH to the control plane:${NC}"
    echo -e "  ${CYAN}ssh -i $KEY_PATH ec2-user@${cp_ip}${NC}"
    echo ""

    echo -e "${BOLD}SSH to the control plane and use kubectl there:${NC}"
    echo -e "  ${CYAN}ssh -i $KEY_PATH ec2-user@${cp_ip}${NC}"
    echo -e "  ${CYAN}kubectl get nodes${NC}"
    echo ""

    echo -e "${YELLOW}IMPORTANT: Run 'terraform destroy' when done practicing to stop AWS charges.${NC}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   Kubernetes Practice Environment Bootstrap          ║${NC}"
    echo -e "${BOLD}${BLUE}║   CKA/CKAD Practice on AWS                          ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    preflight_checks
    setup_ssh_key
    configure_tfvars
    run_terraform
    deploy_cluster
    print_final_instructions
}

main "$@"
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x bootstrap.sh
```

- [ ] **Step 3: Verify the script has no syntax errors**

```bash
bash -n bootstrap.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 4: Run a dry-run preflight check (no AWS resources created)**

Temporarily comment out `setup_ssh_key`, `configure_tfvars`, `run_terraform`, `deploy_cluster` calls in `main()`, then run:

```bash
./bootstrap.sh
```

Expected output includes:
```
✓ Required tools available: terraform, aws, jq, ssh-keygen, curl
✓ AWS credentials valid (Account: ...)
✓ Running from repo root directory
```

Restore the `main()` function after verification.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: add bootstrap.sh for zero-friction cluster setup"
```

---

## Task 6: Update README.md Quick Start

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Quick Start section**

In `README.md`, find the current Quick Start section:

```markdown
## Quick Start

### 1. Deploy Infrastructure

```bash
# Clone repository
cd k8-aws-infra

# Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-access-key"
...
```

### 2. Deploy Kubernetes Cluster

```bash
# Automated deployment (recommended)
./deploy-cluster.sh
```

**That's it!** Your Kubernetes cluster will be fully configured and ready in ~25-30 minutes.

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for detailed instructions and advanced options.
```

Replace it with:

```markdown
## Quick Start

```bash
# 1. Clone the repo
git clone <repo-url> && cd k8-aws-infra

# 2. Configure AWS credentials (if not already set)
aws configure

# 3. Run bootstrap — handles everything automatically
./bootstrap.sh
```

Your cluster will be ready in ~25-30 minutes. The script will:
- Generate an SSH keypair if you don't have one
- Create `terraform.tfvars` with your IP and public key pre-filled
- Deploy AWS infrastructure with Terraform
- Bootstrap the Kubernetes cluster
- Download `kubectl` config to `~/.kube/k8s-practice-config`

```bash
# After bootstrap completes:
export KUBECONFIG=~/.kube/k8s-practice-config
kubectl get nodes
```

**Prerequisites:** `terraform`, `aws` CLI, `jq`, `curl` — see [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for install instructions.

**Advanced / manual deployment:** See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md).

**When done practicing:**
```bash
terraform destroy
```
```

- [ ] **Step 2: Verify the rest of README.md is unchanged**

```bash
git diff README.md
```

Confirm only the Quick Start section changed.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: simplify README Quick Start to bootstrap.sh workflow"
```

---

## Verification Checklist

After all tasks are complete, verify the success criteria from the spec:

- [ ] **SC1: No docs needed** — Someone unfamiliar with the repo can read the new Quick Start and run `./bootstrap.sh` without any other context
- [ ] **SC2: No secrets committed** — `git ls-files | xargs grep -l "AAAA\|BEGIN RSA\|aws_secret"` returns nothing
- [ ] **SC3: deploy-cluster.sh standalone** — `bash -n deploy-cluster.sh` passes; the script still works with `SSH_KEY_PATH` env var set
- [ ] **SC4: Local kubectl** — After deploy: `export KUBECONFIG=~/.kube/k8s-practice-config && kubectl get nodes` shows nodes Ready
- [ ] **SC5: SSH kubectl** — `ssh -i ~/.ssh/k8-cluster.pem ec2-user@<cp-ip>` then `kubectl get nodes` shows nodes Ready
