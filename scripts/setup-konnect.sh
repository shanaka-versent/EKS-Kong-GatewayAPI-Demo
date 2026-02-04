#!/bin/bash
# Setup Kong Konnect Integration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# This script helps configure Kong Gateway to connect to Kong Konnect.
#
# Prerequisites:
# 1. Log in to Kong Konnect: https://cloud.konghq.com
# 2. Create/select a Control Plane
# 3. Go to Data Plane Nodes → New Data Plane Node
# 4. Download the certificates (tls.crt, tls.key, ca.crt)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${1:-$SCRIPT_DIR/../certs/konnect}"

echo "=== Kong Konnect Integration Setup ==="
echo ""
echo "This script will create Kubernetes secrets for Kong Konnect connection."
echo ""

# Check if certificates exist
if [[ ! -f "${CERTS_DIR}/tls.crt" ]] || [[ ! -f "${CERTS_DIR}/tls.key" ]] || [[ ! -f "${CERTS_DIR}/ca.crt" ]]; then
    echo "ERROR: Certificate files not found in ${CERTS_DIR}"
    echo ""
    echo "Please download certificates from Kong Konnect:"
    echo "1. Log in to https://cloud.konghq.com"
    echo "2. Go to Gateway Manager → Your Control Plane"
    echo "3. Click 'Data Plane Nodes' → 'New Data Plane Node'"
    echo "4. Download and save certificates to: ${CERTS_DIR}/"
    echo "   - tls.crt"
    echo "   - tls.key"
    echo "   - ca.crt"
    echo ""
    exit 1
fi

echo "Found certificates in: ${CERTS_DIR}"
echo ""

# Create kong namespace if not exists
echo "Creating kong namespace..."
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -

# Create TLS secret for Konnect connection
echo "Creating konnect-client-tls secret..."
kubectl create secret tls konnect-client-tls -n kong \
    --cert="${CERTS_DIR}/tls.crt" \
    --key="${CERTS_DIR}/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create cluster certificate secret
echo "Creating konnect-cluster-cert secret..."
kubectl create secret generic konnect-cluster-cert -n kong \
    --from-file=ca.crt="${CERTS_DIR}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Secrets Created Successfully ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Update k8s/kong/konnect-values.yaml with your Control Plane endpoints:"
echo "   - cluster_control_plane: <your-cp>.us.cp0.konghq.com:443"
echo "   - cluster_server_name: <your-cp>.us.cp0.konghq.com"
echo "   - cluster_telemetry_endpoint: <your-cp>.us.tp0.konghq.com:443"
echo "   - cluster_telemetry_server_name: <your-cp>.us.tp0.konghq.com"
echo ""
echo "2. Deploy Kong Gateway using ArgoCD:"
echo "   kubectl apply -f argocd/apps/root-app.yaml"
echo ""
echo "3. Verify Konnect connection in the dashboard:"
echo "   https://cloud.konghq.com → Gateway Manager → Your Control Plane"
echo ""
