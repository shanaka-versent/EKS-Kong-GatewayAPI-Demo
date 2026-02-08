#!/bin/bash
# Setup Kong Konnect Integration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Generates a self-signed mTLS certificate, registers it with Konnect via API,
# and creates the K8s secret used by both the data plane and KIC controller.
#
# This script replaces any manual Konnect UI certificate download workflow.
# All interaction with Konnect is via API — no UI steps required beyond
# creating the Control Plane and generating a Personal Access Token.
#
# Prerequisites:
#   1. A Konnect Control Plane (KIC type) — note the Control Plane ID
#   2. A Konnect Personal Access Token (kpat_xxx)
#   3. kubectl configured and pointing to your EKS cluster
#
# Usage:
#   export KONNECT_REGION="au"           # us, eu, au, me, in, sg
#   export KONNECT_TOKEN="kpat_xxx..."
#   export CONTROL_PLANE_ID="your-cp-id-here"
#   ./scripts/setup-konnect.sh
#
# What it does:
#   1. Generates a self-signed mTLS certificate (tls.crt + tls.key)
#   2. Registers the certificate with Konnect via API
#   3. Creates the kong-cluster-cert K8s TLS secret in the kong namespace
#   4. Prints the endpoints to configure in ArgoCD apps

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Validate environment variables
# ---------------------------------------------------------------------------
validate_env() {
    local missing=false

    if [[ -z "${KONNECT_REGION:-}" ]]; then
        error "KONNECT_REGION not set (e.g., us, eu, au, me, in, sg)"
        missing=true
    fi
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        error "KONNECT_TOKEN not set (Personal Access Token from Konnect)"
        missing=true
    fi
    if [[ -z "${CONTROL_PLANE_ID:-}" ]]; then
        error "CONTROL_PLANE_ID not set (Control Plane UUID from Konnect)"
        missing=true
    fi

    if [[ "$missing" == true ]]; then
        echo ""
        echo "Usage:"
        echo "  export KONNECT_REGION=\"au\""
        echo "  export KONNECT_TOKEN=\"kpat_xxx...\""
        echo "  export CONTROL_PLANE_ID=\"your-cp-id-here\""
        echo "  ./scripts/setup-konnect.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Generate self-signed mTLS certificate
# ---------------------------------------------------------------------------
generate_cert() {
    log "Generating self-signed mTLS certificate..."

    openssl req -new -x509 -nodes -newkey rsa:2048 \
        -subj "/CN=kongdp/C=US" \
        -keyout ./tls.key -out ./tls.crt -days 365 2>/dev/null

    log "  Certificate: ./tls.crt"
    log "  Private key: ./tls.key"
}

# ---------------------------------------------------------------------------
# Register certificate with Konnect via API
# ---------------------------------------------------------------------------
register_cert() {
    log "Registering certificate with Konnect (${KONNECT_REGION} region)..."

    CERT=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' tls.crt)

    HTTP_CODE=$(curl -s -o /tmp/konnect-response.json -w "%{http_code}" \
        -X POST "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/dp-client-certificates" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"cert\": \"$CERT\"}")

    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        log "  Certificate registered successfully (HTTP $HTTP_CODE)"
    else
        error "  Failed to register certificate (HTTP $HTTP_CODE)"
        error "  Response: $(cat /tmp/konnect-response.json)"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Create K8s secret
# ---------------------------------------------------------------------------
create_secret() {
    log "Creating kong namespace and kong-cluster-cert secret..."

    kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret tls kong-cluster-cert -n kong \
        --cert=./tls.crt --key=./tls.key \
        --dry-run=client -o yaml | kubectl apply -f -

    log "  Secret kong-cluster-cert created in kong namespace"
}

# ---------------------------------------------------------------------------
# Print next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Konnect Integration Setup Complete"
    echo "=========================================="
    echo ""
    echo "Control Plane ID: ${CONTROL_PLANE_ID}"
    echo "Region:           ${KONNECT_REGION}"
    echo ""
    echo "Update the KIC controller ArgoCD app with your endpoints:"
    echo ""
    echo "  File: argocd/apps/02b-kong-controller.yaml"
    echo "  konnect:"
    echo "    runtimeGroupID: \"${CONTROL_PLANE_ID}\""
    echo "    apiHostname: \"${KONNECT_REGION}.kic.api.konghq.com\""
    echo "    tlsClientCertSecretName: \"kong-cluster-cert\""
    echo ""
    echo "  Note: Only the KIC controller connects to Konnect."
    echo "  The data plane (02-kong-gateway.yaml) does NOT need any Konnect config."
    echo "  KIC handles all config sync, node registration, and telemetry."
    echo ""
    echo "Deploy via ArgoCD:"
    echo "   kubectl apply -f argocd/apps/root-app.yaml"
    echo ""
    echo "4. Verify in Konnect dashboard:"
    echo "   https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    echo ""
    echo "Cleanup: rm -f ./tls.crt ./tls.key"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=========================================="
    echo "  Kong Konnect Integration Setup"
    echo "=========================================="
    echo ""

    validate_env
    generate_cert
    register_cert
    create_secret
    show_next_steps
}

main "$@"
