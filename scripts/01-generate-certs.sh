#!/bin/bash
# EKS Kong Gateway POC - Generate TLS Certificates for End-to-End TLS
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# ⚠️  DEPRECATED: This script is no longer needed for proxy TLS.
#     cert-manager now automatically obtains and renews Let's Encrypt
#     certificates via DNS-01 challenge on Route53.
#     The kong-gateway-tls secret is managed by cert-manager (see
#     argocd/apps/00b-cert-manager.yaml and k8s/cert-manager/).
#
#     For Konnect mTLS authentication, use scripts/setup-konnect.sh instead.
#
# This script generates self-signed TLS certificates for the Kong Gateway backend.
#
# END-TO-END TLS ARCHITECTURE:
# ============================
# 1. Client → CloudFront: TLS terminated using ACM certificate (managed by AWS)
# 2. CloudFront → VPC Origin → NLB → Kong Gateway: TLS using Let's Encrypt cert (cert-manager)
# 3. Kong Gateway → Backend Pods: Plain HTTP (cluster-internal)
#
# The certificates generated here are for the BACKEND connection
# (CloudFront → Kong Gateway via NLB).
# For the FRONTEND (client-facing), use AWS ACM certificates.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../certs"
DOMAIN="${1:-kong-gateway.local}"

echo "=== Generating TLS Certificates for Kong Gateway Backend ==="
echo ""
echo "End-to-End TLS Flow:"
echo "  Client --[TLS/ACM]--> CloudFront --[TLS/Self-signed]--> NLB --> Kong Gateway --[HTTP]--> Pods"
echo ""
echo "Domain: ${DOMAIN}"
echo "Output directory: ${CERTS_DIR}"

mkdir -p "${CERTS_DIR}"

# Generate CA private key
echo "Generating CA private key..."
openssl genrsa -out "${CERTS_DIR}/ca.key" 4096

# Generate CA certificate
echo "Generating CA certificate..."
openssl req -new -x509 -days 365 -key "${CERTS_DIR}/ca.key" \
  -out "${CERTS_DIR}/ca.crt" \
  -subj "/C=AU/ST=NSW/L=Sydney/O=Kong Gateway POC/CN=Kong Gateway POC CA"

# Generate server private key
echo "Generating server private key..."
openssl genrsa -out "${CERTS_DIR}/server.key" 2048

# Create OpenSSL config for SAN
cat > "${CERTS_DIR}/server.cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = AU
ST = NSW
L = Sydney
O = Kong Gateway POC
CN = ${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
DNS.4 = kong-gateway-kong-proxy.kong.svc.cluster.local
DNS.5 = *.kong.svc.cluster.local
IP.1 = 127.0.0.1
EOF

# Generate server CSR
echo "Generating server CSR..."
openssl req -new -key "${CERTS_DIR}/server.key" \
  -out "${CERTS_DIR}/server.csr" \
  -config "${CERTS_DIR}/server.cnf"

# Sign server certificate with CA
echo "Signing server certificate..."
openssl x509 -req -days 365 \
  -in "${CERTS_DIR}/server.csr" \
  -CA "${CERTS_DIR}/ca.crt" \
  -CAkey "${CERTS_DIR}/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/server.crt" \
  -extensions req_ext \
  -extfile "${CERTS_DIR}/server.cnf"

# Cleanup
rm -f "${CERTS_DIR}/server.csr" "${CERTS_DIR}/server.cnf" "${CERTS_DIR}/ca.srl"

echo ""
echo "=== Certificates Generated Successfully ==="
echo ""
echo "Files created:"
echo "  CA Certificate:     ${CERTS_DIR}/ca.crt"
echo "  Server Certificate: ${CERTS_DIR}/server.crt"
echo "  Server Key:         ${CERTS_DIR}/server.key"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Create the Kubernetes TLS secret for Kong Gateway:"
echo ""
echo "   kubectl create namespace kong"
echo "   kubectl create secret tls kong-gateway-tls \\"
echo "     --cert=${CERTS_DIR}/server.crt \\"
echo "     --key=${CERTS_DIR}/server.key \\"
echo "     -n kong"
echo ""
echo "2. Deploy via ArgoCD (the Gateway resource references this secret):"
echo ""
echo "   kubectl apply -f argocd/root-app.yaml"
echo ""
