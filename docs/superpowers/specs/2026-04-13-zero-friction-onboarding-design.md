# Zero-Friction Onboarding Design

**Date:** 2026-04-13  
**Goal:** Any intermediate learner can `git clone` this repo and have a working Kubernetes cluster with local `kubectl` access in one command.  
**Target audience:** Intermediate learners preparing for CKA/CKAD  
**kubectl access:** Both local machine and control plane node

---

## Problem Statement

The current repo requires several manual steps before deployment works:
- No `terraform.tfvars.example` file (README references it but it doesn't exist)
- `terraform.tfvars` is committed with real values despite being in `.gitignore`
- SSH keypair must exist at a specific path before running anything
- Kubernetes versions and CIDRs are hardcoded in setup scripts, disconnected from Terraform variables
- No local kubeconfig download after deploy — learner must SSH to use kubectl
- `cleanup-workers.sh` is untracked; `diagnose-control-plane.sh` has uncommitted changes

---

## Design

### 1. New Files

#### `bootstrap.sh`
Single entry point for new learners. Runs end-to-end and handles all setup.

**Flow:**

```
1. PREFLIGHT
   - Check required tools: terraform, aws, jq, ssh-keygen
   - Verify AWS credentials: aws sts get-caller-identity

2. SSH KEY
   - If ~/.ssh/k8-cluster.pem exists → use it
   - If not → generate new RSA keypair, save to ~/.ssh/k8-cluster.pem + ~/.ssh/k8-cluster.pub

3. CONFIGURE terraform.tfvars
   - If terraform.tfvars already exists → skip (safe to re-run)
   - Copy terraform.tfvars.example → terraform.tfvars
   - Auto-detect current public IP → set allowed_ssh_cidrs = ["<detected-ip>/32"]
   - Set existing_key_name = "k8-cluster"

4. TERRAFORM
   - terraform init
   - terraform plan (displays what will be created + cost estimate)
   - Prompt: "This will create AWS resources. Continue? [y/N]"
   - terraform apply -auto-approve on confirmation

5. KUBERNETES CLUSTER
   - Call ./deploy-cluster.sh

6. LOCAL KUBECTL
   - Download kubeconfig from control plane
   - Patch server URL: private IP → public IP
   - Save to ~/.kube/k8s-practice-config (does not overwrite ~/.kube/config)
   - Print export KUBECONFIG instruction + SSH command
   - Run kubectl get nodes to confirm success
```

**Behaviour:**
- Never overwrites existing `terraform.tfvars`
- Never overwrites existing `~/.kube/config` — saves to named file
- Aborts with a clear message on any failure
- Safe to re-run: each step checks state before acting
- `bootstrap.sh` is a wrapper — it calls `deploy-cluster.sh` internally. `deploy-cluster.sh` continues to work standalone for users who have already run Terraform manually.

#### `terraform.tfvars.example`
Clean example file with no real values, safe to commit. Replaces the current committed `terraform.tfvars`.

Contains all variables with sensible defaults and inline comments explaining each.  
`bootstrap.sh` references this file as its template.

---

### 2. Modified Files

#### `deploy-cluster.sh` — Phase 6 added
New phase appended after existing Phase 5 (kubectl on workers). Phases 1–5 are untouched.

**Phase 6: Local kubectl Setup**
```
- On control plane: copy /etc/kubernetes/admin.conf → /tmp/kubeconfig-export.yaml
- SCP to local /tmp/k8s-practice-kubeconfig.yaml
- Patch: replace control plane private IP with public IP in server URL
- Save to ~/.kube/k8s-practice-config
- Print connection instructions to screen
```

#### `README.md` — Quick Start simplified
```markdown
## Quick Start

1. Clone the repo
2. Run ./bootstrap.sh
3. Run kubectl get nodes
```
The rest of the README (architecture, cost table, configuration reference, troubleshooting) is unchanged.

---

### 3. Git Hygiene Fixes

| Action | File |
|--------|------|
| `git rm --cached` | `terraform.tfvars` (tracked despite being in .gitignore) |
| Verify not tracked | `k8-cluster.pem` |
| `git add` + commit | `cleanup-workers.sh` (currently `??` untracked) |
| `git add` + commit | `diagnose-control-plane.sh` (currently `M` modified) |

---

### 4. What Is Out of Scope

- Parameterizing Kubernetes version / CIDRs from Terraform into setup scripts (versions work fine for CKA/CKAD practice)
- Practice exercises / labs folder
- Multi-cloud or non-AWS support
- Windows support beyond WSL (current README already notes WSL is supported)

---

## Success Criteria

1. A learner with AWS credentials can run `./bootstrap.sh` and reach `kubectl get nodes` showing all nodes Ready without reading any documentation first
2. No secrets or real credentials exist in the committed codebase
3. `deploy-cluster.sh` can be run standalone (without bootstrap) and still works as before
4. Local kubectl works: `export KUBECONFIG=~/.kube/k8s-practice-config && kubectl get nodes`
5. SSH kubectl works: `ssh -i ~/.ssh/k8-cluster.pem ec2-user@<ip>` then `kubectl get nodes`
