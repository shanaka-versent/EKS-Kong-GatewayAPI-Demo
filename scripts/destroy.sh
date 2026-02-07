#!/bin/bash
# EKS Kong Gateway POC - Automated Stack Teardown
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# This script ensures clean teardown of the entire stack without manual intervention.
# It handles the correct destruction order to prevent orphaned resources (NLBs, ENIs)
# that block subnet and VPC deletion.
#
# PROBLEM THIS SOLVES:
# ====================
# Kubernetes services of type LoadBalancer (e.g., created by Istio Gateway or
# misconfigured Kong) create NLBs outside of Terraform. These NLBs attach ENIs
# to VPC subnets. When terraform destroy tries to delete subnets, it fails because
# the ENIs still exist.
#
# DESTRUCTION ORDER:
# ==================
# 1. Delete ArgoCD applications (cascade deletes all K8s resources)
# 2. Wait for all LoadBalancer services to be fully removed
# 3. Clean up any orphaned NLBs/ENIs in the VPC (safety net)
# 4. Run terraform destroy (handles CloudFront, NLB, EKS, VPC)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log "Running pre-flight checks..."

    for cmd in kubectl aws terraform jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd is required but not installed."
            exit 1
        fi
    done

    if ! kubectl cluster-info &>/dev/null; then
        warn "Cannot connect to Kubernetes cluster. Skipping K8s cleanup steps."
        return 1
    fi

    log "Pre-flight checks passed."
    return 0
}

# ---------------------------------------------------------------------------
# Step 1: Delete ArgoCD applications (cascade delete via finalizers)
# ---------------------------------------------------------------------------
delete_argocd_apps() {
    log "Step 1: Deleting ArgoCD applications..."

    # Delete root app — ArgoCD finalizers will cascade delete all child apps and K8s resources
    if kubectl get app kong-gateway-root -n argocd &>/dev/null; then
        kubectl delete app kong-gateway-root -n argocd --timeout=300s 2>/dev/null || true
        log "Waiting for ArgoCD cascade deletion to complete..."
        kubectl wait --for=delete app/kong-gateway-root -n argocd --timeout=300s 2>/dev/null || true
    else
        log "ArgoCD root app not found, checking for individual apps..."
    fi

    # Safety net: delete any remaining ArgoCD apps
    local remaining_apps
    remaining_apps=$(kubectl get app -n argocd -o name 2>/dev/null || true)
    if [[ -n "$remaining_apps" ]]; then
        warn "Found remaining ArgoCD apps, deleting individually..."
        echo "$remaining_apps" | while read -r app; do
            kubectl delete "$app" -n argocd --timeout=120s 2>/dev/null || true
        done
    fi

    log "ArgoCD applications deleted."
}

# ---------------------------------------------------------------------------
# Step 2: Delete any remaining LoadBalancer services
# ---------------------------------------------------------------------------
delete_loadbalancer_services() {
    log "Step 2: Checking for remaining LoadBalancer services..."

    local lb_services
    lb_services=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' || true)

    if [[ -n "$lb_services" ]]; then
        warn "Found LoadBalancer services that could create orphaned NLBs:"
        echo "$lb_services" | while read -r svc; do
            echo "  - $svc"
        done

        echo "$lb_services" | while read -r svc; do
            local ns="${svc%%/*}"
            local name="${svc##*/}"
            log "Deleting LoadBalancer service: $ns/$name"
            kubectl delete svc "$name" -n "$ns" --timeout=120s 2>/dev/null || true
        done

        log "Waiting 60s for NLBs to deprovision..."
        sleep 60
    else
        log "No LoadBalancer services found."
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Clean up remaining K8s resources
# ---------------------------------------------------------------------------
cleanup_k8s_resources() {
    log "Step 3: Cleaning up remaining K8s resources..."

    # Delete Kong secrets
    for secret in kong-gateway-tls konnect-client-tls konnect-cluster-cert; do
        kubectl delete secret "$secret" -n kong 2>/dev/null || true
    done

    # Delete TargetGroupBinding if it exists (Terraform will also try, but belt-and-suspenders)
    kubectl delete targetgroupbinding --all -n kong 2>/dev/null || true

    # Delete namespaces created by apps (ArgoCD finalizers should handle this, but safety net)
    for ns in api tenant-app1 tenant-app2 gateway-health; do
        if kubectl get ns "$ns" &>/dev/null; then
            kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
        fi
    done

    log "K8s resource cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 4: Clean up orphaned AWS NLBs in the VPC (safety net)
# ---------------------------------------------------------------------------
cleanup_orphaned_nlbs() {
    log "Step 4: Checking for orphaned NLBs in VPC..."

    # Get VPC ID from Terraform state
    local vpc_id
    vpc_id=$(cd "$TERRAFORM_DIR" && terraform output -raw vpc_id 2>/dev/null || true)

    if [[ -z "$vpc_id" ]]; then
        warn "Could not determine VPC ID from Terraform state. Skipping orphaned NLB cleanup."
        return
    fi

    # Find NLBs in this VPC that are NOT managed by Terraform
    local terraform_nlb_arn
    terraform_nlb_arn=$(cd "$TERRAFORM_DIR" && terraform output -raw nlb_dns_name 2>/dev/null || echo "NONE")

    local nlbs
    nlbs=$(aws elbv2 describe-load-balancers --query \
        "LoadBalancers[?VpcId=='${vpc_id}' && Type=='network'].{ARN:LoadBalancerArn,Name:LoadBalancerName,DNS:DNSName}" \
        --output json 2>/dev/null || echo "[]")

    local orphaned_count
    orphaned_count=$(echo "$nlbs" | jq '[.[] | select(.DNS != "'"$terraform_nlb_arn"'")] | length')

    if [[ "$orphaned_count" -gt 0 ]]; then
        warn "Found $orphaned_count NLB(s) in VPC $vpc_id not managed by Terraform:"
        echo "$nlbs" | jq -r '.[] | select(.DNS != "'"$terraform_nlb_arn"'") | "  - \(.Name) (\(.ARN))"'

        echo ""
        read -rp "Delete these orphaned NLBs? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$nlbs" | jq -r '.[] | select(.DNS != "'"$terraform_nlb_arn"'") | .ARN' | while read -r arn; do
                log "Deleting orphaned NLB: $arn"
                aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
            done
            log "Waiting 60s for NLB ENIs to be released..."
            sleep 60
        else
            warn "Skipping orphaned NLB deletion. terraform destroy may fail on subnet deletion."
        fi
    else
        log "No orphaned NLBs found."
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Terraform destroy
# ---------------------------------------------------------------------------
terraform_destroy() {
    log "Step 5: Running terraform destroy..."

    cd "$TERRAFORM_DIR"

    # Verify Terraform is initialized
    if [[ ! -d ".terraform" ]]; then
        log "Initializing Terraform..."
        terraform init
    fi

    terraform destroy -auto-approve

    log "Terraform destroy complete."
}

# ---------------------------------------------------------------------------
# Step 6: Clean up local artifacts
# ---------------------------------------------------------------------------
cleanup_local() {
    log "Step 6: Cleaning up local artifacts..."

    # Clean up generated certificates
    if [[ -d "${REPO_DIR}/certs" ]]; then
        rm -rf "${REPO_DIR}/certs"
        log "Removed certs/ directory."
    fi

    log "Local cleanup complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=========================================="
    echo "  EKS Kong Gateway POC - Stack Teardown"
    echo "=========================================="
    echo ""

    local k8s_available=true
    preflight_checks || k8s_available=false

    if [[ "$k8s_available" == true ]]; then
        delete_argocd_apps
        delete_loadbalancer_services
        cleanup_k8s_resources
        cleanup_orphaned_nlbs
    else
        warn "Skipping K8s cleanup (cluster unreachable). Running terraform destroy directly."
    fi

    terraform_destroy
    cleanup_local

    echo ""
    log "Stack teardown complete."
    echo ""
}

main "$@"
