# POC - AWS EKS with Kubernetes Gateway API & Kong Gateway

**Author:** Shanaka Jayasundera - shanakaj@gmail.com

This POC demonstrates how to implement Kubernetes Gateway API on AWS EKS with **Kong Gateway Enterprise**, integrated with **Kong Konnect** for centralized API management, analytics, and developer portal.

While my previous posts used Istio as the Gateway API implementation, Kong Gateway offers a different approach—focusing on API gateway capabilities at the edge without the service mesh complexity.

> **Licensing:** This project uses **Kong Gateway Enterprise** (`kong/kong-gateway` image) with licensing automatically managed by Kong Konnect. A [free trial](https://konghq.com/products/kong-konnect/register) gives you 30 days of full Enterprise functionality. An [OSS alternative](#alternative-kong-gateway-oss-without-konnect) is available if you don't have a Konnect subscription.

This is particularly relevant for teams who:
- Need API management features (rate limiting, authentication, developer portal) without a full service mesh
- Want a simpler operational model (no sidecars)
- Are already using or evaluating Kong for API management
- Need to expose both APIs and web applications through the same gateway

---

## Reference Architecture (Common Pattern)

All implementations in this series follow a common reference architecture. The pattern is **cloud-agnostic** and applies to both AWS (CloudFront) and Azure (Front Door).

```mermaid
flowchart TB
    Client["Client"]

    subgraph Edge["Edge / CDN Layer"]
        CDN["CDN + WAF"]
    end

    subgraph Private["Private Connectivity"]
        PL["Private Link / VPC Origin"]
    end

    subgraph Cloud["Cloud VPC / VNet — Private Subnets"]
        ILB["Internal Load Balancer (L4)"]

        subgraph K8s["Kubernetes Cluster"]
            APIGW["API Gateway Capability"]
            GW["K8s Gateway API"]
            SVC["Backend Services"]
        end
    end

    Client --> CDN
    CDN --> PL
    PL --> ILB
    ILB --> APIGW
    APIGW --> GW
    GW --> SVC
```

| Layer | Responsibility | Cloud Agnostic |
|-------|---------------|----------------|
| **CDN + WAF** | DDoS protection, geo-blocking, TLS termination, WAF rules (SQLi, XSS, rate limiting) | AWS CloudFront / Azure Front Door |
| **Private Connectivity** | End-to-end private path from edge to VPC — no public endpoints | AWS VPC Origin / Azure Private Link |
| **Internal Load Balancer** | L4 load balancing in private subnets, health checks | AWS NLB / Azure Internal LB |
| **API Gateway Capability** | Auth, rate limiting, request transforms, API key management | Kong, AWS API GW, or built into K8s GW |
| **K8s Gateway API** | Path-based routing via HTTPRoute CRDs, namespace isolation | Kong GatewayClass, Istio GatewayClass |
| **Backend Services** | Application workloads (APIs, web apps, microservices) | K8s Deployments + Services |

> **Key Security Property:** The Internal Load Balancer has NO public endpoint. Private connectivity from the CDN uses AWS-managed ENIs (VPC Origin) or Azure Private Endpoints. **It is impossible to bypass the CDN/WAF layer.**

### Where Does the API Gateway Capability Sit?

The key architectural decision across implementations is **where the API Gateway capability lives**:

```mermaid
flowchart LR
    subgraph Impl1["Implementation 1: Kong Gateway"]
        direction TB
        A1["CDN + WAF"]
        B1["Internal LB"]
        C1["Kong Gateway\n(API GW + K8s GW API)"]
        D1["Backend Services"]
        A1 --> B1 --> C1 --> D1
    end

    subgraph Impl2["Implementation 2: AWS API Gateway"]
        direction TB
        A2["CDN + WAF"]
        B2["AWS API Gateway\n(API GW capability)"]
        C2["Internal LB"]
        D2["K8s Gateway API\n(Istio/Kong)"]
        E2["Backend Services"]
        A2 --> B2 --> C2 --> D2 --> E2
    end
```

| | Implementation 1: Kong | Implementation 2: AWS API GW |
|---|---|---|
| **API Gateway** | Kong Gateway (inside K8s) | AWS API Gateway (outside K8s) |
| **K8s Routing** | Kong IS the Gateway API impl | Istio or Kong (routing only) |
| **Traffic Split** | Single path for all traffic | Separate paths for Web vs API |
| **API Management** | Kong Plugins (200+) | API GW features + Lambda Authorizer |
| **Private Connectivity** | VPC Origin to NLB | VPC Link to NLB |

---

## Implementation 1: Kong Gateway (This Repo)

Kong Gateway serves as BOTH the API Gateway and the Kubernetes Gateway API implementation. All traffic (web + API) flows through a single path.

```mermaid
flowchart TB
    Client["Client"]

    subgraph Edge["CloudFront Edge"]
        CF["CloudFront"]
        WAF["AWS WAF\n(CommonRuleSet, SQLi,\nKnownBadInputs, Rate Limit)"]
    end

    subgraph VPC["AWS VPC — Private Subnets Only"]
        VPCOrigin["VPC Origin\n(AWS Backbone)"]
        NLB["Internal NLB\n(Terraform-managed)"]

        subgraph EKS["EKS Cluster"]
            TGB["TargetGroupBinding"]

            subgraph KongNS["Kong Gateway"]
                Kong["Kong Pods\n(ClusterIP)"]
                Plugins["Plugins:\nRate Limit | JWT Auth\nCORS | Transforms"]
            end

            subgraph Routes["HTTPRoutes"]
                R1["/app1"]
                R2["/app2"]
                R3["/api/*"]
                R4["/healthz"]
            end

            subgraph Apps["Backend Services"]
                App1["sample-app-1"]
                App2["sample-app-2"]
                API["users-api"]
                Health["health-responder"]
            end
        end
    end

    subgraph Konnect["Kong Konnect (SaaS)"]
        Analytics["Analytics"]
        Portal["Dev Portal"]
    end

    Client --> CF
    CF --> WAF
    WAF --> VPCOrigin
    VPCOrigin --> NLB
    NLB --> TGB
    TGB --> Kong
    Kong --> Plugins
    Plugins --> Routes
    R1 --> App1
    R2 --> App2
    R3 --> API
    R4 --> Health
    Kong -..-> Konnect
```

**Traffic Flow:**
```
Client --> CloudFront + WAF --> VPC Origin --> Internal NLB --> Kong Gateway --> HTTPRoutes --> Backend Services
```

**Why this pattern:**
- Kong Gateway handles API management (auth, rate limiting, transforms) AND K8s routing in a single component
- No need for a separate AWS API Gateway service — Kong replaces it
- Single traffic path for both web content and APIs
- Kong Konnect provides analytics, developer portal, and centralized management as SaaS

---

## How Kong Implements the Kubernetes Gateway API

Kong Gateway implements the Kubernetes Gateway API **exactly like Istio does**. The architecture is directly comparable:

| Component | Istio | Kong |
|-----------|-------|------|
| **Controller** (watches Gateway API resources) | Istiod | Kong Ingress Controller (KIC) |
| **Data Plane** (processes traffic) | Envoy Proxy | Kong Gateway |
| **GatewayClass controllerName** | `gateway.istio.io/gateway-controller` | `konghq.com/kic-gateway-controller` |

```mermaid
flowchart LR
    subgraph "Kong Gateway API Implementation"
        KIC["Kong Ingress Controller\n(watches Gateway API CRDs)"]
        KG["Kong Gateway Pods\n(data plane - processes traffic)"]
    end
    
    GC["GatewayClass\n(kong)"]
    GW["Gateway\n(kong-gateway)"]
    HR["HTTPRoute\n(/app1, /app2, /api/*)"]
    SVC["Backend Services"]
    
    GC --> KIC
    GW --> KIC
    HR --> KIC
    KIC -->|"configures"| KG
    KG -->|"routes to"| SVC
```

**Key resources in this project:**
- **GatewayClass** (`k8s/kong/gateway-class.yaml`): Registers Kong as the Gateway API implementation
- **Gateway** (`k8s/kong/gateway.yaml`): Creates the Kong Gateway instance listening on ports 80/443
- **HTTPRoute** resources (`k8s/apps/*/httproute.yaml`): Define path-based routing rules

> **Note:** This is the same Gateway API standard. If you've used Istio's Gateway API implementation, switching to Kong only requires changing the `gatewayClassName` — the HTTPRoute resources remain identical.

---

## Implementation 2: Istio + AWS API Gateway

AWS API Gateway handles API management as a managed service. Traffic is split — API requests go through API Gateway, web requests go directly to an ALB. Istio provides the K8s Gateway API implementation and service mesh (mTLS).

```mermaid
flowchart TB
    Client["Client"]

    subgraph Edge["CloudFront Edge"]
        CF["CloudFront"]
        WAF["AWS WAF"]
    end

    subgraph AWS["AWS Cloud"]
        subgraph APIPath["API Traffic Path (/api/*)"]
            APIGW["AWS API Gateway\n(HTTP API v2)"]
            Lambda["Lambda Authorizer\n(header validation)"]
            VPCLink["VPC Link\n(Private)"]
        end

        subgraph WebPath["Web Traffic Path (/*default)"]
            ALB["ALB\n(Public Subnets)"]
        end

        subgraph VPC["VPC — Private Subnets"]
            NLB2["Internal NLB"]

            subgraph EKS2["EKS Cluster"]
                IstioGW["Istio Gateway\n(K8s Gateway API)"]
                HR2["HTTPRoutes"]
                Apps2["Backend Services"]
            end
        end

        subgraph S3Path["Static Assets (/static/*)"]
            S3["S3 Bucket + OAC"]
        end
    end

    Client --> CF
    CF --> WAF

    WAF --> APIGW
    APIGW --> Lambda
    APIGW --> VPCLink
    VPCLink --> NLB2

    WAF --> ALB
    ALB --> NLB2

    WAF --> S3

    NLB2 --> IstioGW
    IstioGW --> HR2
    HR2 --> Apps2
```

**Traffic Flows:**
```
API:    Client --> CloudFront + WAF --> AWS API Gateway --> VPC Link --> Internal NLB --> Istio Gateway --> Backend
Web:    Client --> CloudFront + WAF --> ALB --> Internal NLB --> Istio Gateway --> Backend
Static: Client --> CloudFront + WAF --> S3 (OAC)
```

**Why this pattern:**
- AWS API Gateway provides managed API features (throttling, API keys, usage plans, Lambda authorizers)
- Istio adds service mesh capabilities (mTLS, internal traffic policies, observability)
- Separate paths allow different caching and security policies per traffic type
- Best for teams already invested in AWS managed services

---

## Comparison: Implementation Trade-offs

| Aspect | Kong Gateway (Impl 1) | AWS API GW + Istio (Impl 2) |
|--------|----------------------|------------------------------|
| **API Gateway** | Kong (in-cluster) | AWS API Gateway (managed) |
| **K8s Gateway API** | Kong GatewayClass | Istio GatewayClass |
| **Service Mesh** | None (add Kong Mesh if needed) | Istio Ambient (mTLS, ztunnel) |
| **Traffic Paths** | Single (all through Kong) | Split (API vs Web vs Static) |
| **Private Connectivity** | VPC Origin (fully private) | VPC Link + ALB (ALB is public) |
| **Bypass Protection** | Impossible (no public LB) | Header validation (Lambda) |
| **Plugin Ecosystem** | 200+ Kong plugins | AWS-managed features |
| **Developer Portal** | Kong Konnect (SaaS) | Not built-in |
| **Operational Overhead** | Lower (single gateway) | Higher (API GW + ALB + Istio) |
| **Cost Model** | Kong license + compute | AWS API GW per-request pricing |
| **East-West Security** | None by default | Istio mTLS (built-in) |

---

## Kong Gateway vs Istio: When to Use Which?

| Aspect | Kong Gateway | Istio |
|--------|--------------|-------|
| **Primary Focus** | API Gateway (North-South) | Service Mesh (East-West + North-South) |
| **Architecture** | Edge proxy only | Sidecar or Ambient mesh |
| **API Management** | Built-in (auth, rate limiting, portal) | Limited |
| **Service-to-Service mTLS** | Requires Kong Mesh | Built-in |
| **Operational Complexity** | Lower | Higher |
| **Resource Overhead** | Lower (edge only) | Higher (sidecars/ztunnel) |
| **Best For** | API-first, external consumers | Microservices security, observability |

**Choose Kong Gateway when:** You need strong API management at the edge, have external API consumers, want simpler operations, or don't need service mesh features.

**Choose Istio when:** You need service-to-service mTLS, internal traffic policies, or full mesh observability.

**You can use both together:** Kong at the edge for API management, Istio Ambient internally for service mesh.

---

## Architecture Layers

```mermaid
flowchart TB
    subgraph L1["Layer 1: Cloud Foundation"]
        direction LR
        VPC["VPC"]
        Subnets["Subnets"]
        NAT["NAT / IGW"]
    end

    subgraph L2["Layer 2: Platform + Edge"]
        direction LR
        EKS["EKS Cluster"]
        IAM["IAM (IRSA)"]
        NLB["Internal NLB"]
        CF["CloudFront + WAF"]
        ArgoCD["ArgoCD"]
    end

    subgraph L3["Layer 3: Gateway"]
        direction LR
        CRDs["Gateway API CRDs"]
        KongGW["Kong Gateway"]
        GW["Gateway Resource"]
        KPlugins["Kong Plugins"]
    end

    subgraph L4["Layer 4: Applications"]
        direction LR
        App1["App 1"]
        App2["App 2"]
        UsersAPI["Users API"]
        HealthResp["Health Responder"]
    end

    L1 -->|"Terraform"| L2
    L2 -->|"Terraform + ArgoCD"| L3
    L3 -->|"ArgoCD"| L4
```

| Layer | Tool | What It Creates |
|-------|------|-----------------|
| **Layer 1** | Terraform | VPC, Subnets (Public/Private), NAT/IGW, Route Tables |
| **Layer 2** | Terraform | EKS, Node Groups, IAM (IRSA), LB Controller, Internal NLB, CloudFront + WAF + VPC Origin, ArgoCD |
| **Layer 3** | ArgoCD | Gateway API CRDs, Kong Gateway (ClusterIP), Gateway, HTTPRoutes, Kong Plugins |
| **Layer 4** | ArgoCD | Applications (app1, app2, users-api, health-responder) |

---

## EKS Cluster Architecture

```mermaid
flowchart TB
    subgraph Edge["CloudFront Edge"]
        CF["CloudFront + WAF"]
    end

    subgraph VPC["AWS VPC"]
        subgraph PubSub["Public Subnets"]
            NAT["NAT Gateway"]
        end

        subgraph PrivSub["Private Subnets"]
            VPCOrigin["VPC Origin ENIs"]
            NLB["Internal NLB"]

            subgraph EKS["EKS Cluster"]
                subgraph SysNodes["System Node Pool"]
                    ArgoCD["ArgoCD"]
                    Kong["Kong Gateway"]
                    LBC["LB Controller"]
                end

                subgraph UserNodes["User Node Pool"]
                    App1["App 1"]
                    App2["App 2"]
                    API["Users API"]
                end
            end
        end
    end

    CF --> VPCOrigin
    VPCOrigin --> NLB
    NLB --> Kong
    Kong --> App1
    Kong --> App2
    Kong --> API
    UserNodes --> NAT
```

| Node Pool | Taint | Workloads |
|-----------|-------|-----------|
| System Nodes | CriticalAddonsOnly | ArgoCD, Kong components, AWS LB Controller |
| User Nodes | None | Application workloads (app1, app2, users-api) |

---

## Defense in Depth

Security is applied at every layer. WAF handles infrastructure threats at the edge, Kong plugins handle application/API concerns inside the cluster.

```mermaid
flowchart LR
    subgraph L1["Layer 1: Edge"]
        WAF["WAF\nDDoS, SQLi, XSS\nRate Limit, Geo-block"]
    end

    subgraph L2["Layer 2: Network"]
        NLB["Internal NLB\nNo public IP\nSG: CloudFront only"]
    end

    subgraph L3["Layer 3: Application"]
        Kong["Kong Plugins\nJWT Auth, Rate Limit\nCORS, Transforms"]
    end

    subgraph L4["Layer 4: Workload"]
        Pod["Pod Security\nResource Limits\nNamespace Isolation"]
    end

    L1 --> L2 --> L3 --> L4
```

| Layer | What | Example Threats Blocked |
|-------|------|------------------------|
| **Edge (WAF)** | AWS Managed Rules | SQL injection, XSS, known bad inputs, bot floods |
| **Network (NLB)** | Security Groups | Direct access bypass, unauthorized CIDR ranges |
| **Application (Kong)** | Plugins | Unauthenticated API calls, excessive per-consumer requests |
| **Workload (K8s)** | Pod Security | Container escape, privilege escalation, resource abuse |

---

## Kong Plugin Chain

```mermaid
flowchart LR
    Req["Request"]

    subgraph Kong["Kong Gateway"]
        Route["Route\nMatching"]
        Auth["JWT Auth"]
        Rate["Rate\nLimit"]
        Transform["Request\nTransform"]
        Proxy["Proxy"]
    end

    Backend["Backend\nService"]

    Req --> Route --> Auth --> Rate --> Transform --> Proxy --> Backend
```

### Rate Limiting
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: rate-limiting
config:
  minute: 100
  policy: local
  limit_by: ip
plugin: rate-limiting
```

### JWT Authentication
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: jwt-auth
config:
  claims_to_verify:
  - exp
plugin: jwt
```

### CORS
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: cors
config:
  origins: ["*"]
  methods: [GET, POST, PUT, DELETE]
plugin: cors
```

---

## Health Check Flow

NLB health probes target Kong's status endpoint directly. Application health checks route through Kong to the health-responder service:

```mermaid
flowchart LR
    NLB["Internal NLB"]
    Kong["Kong Gateway"]
    HR["HTTPRoute\n/healthz/*"]
    Health["health-responder"]

    NLB -->|"TCP :8100\n/healthz/ready"| Kong
    Kong --> HR --> Health
    Health -->|"200 OK"| NLB
```

---

## Kong Gateway Editions & Licensing

Kong Gateway comes in two editions. This project defaults to Enterprise via Konnect:

| | Kong Gateway Enterprise (Default) | Kong Gateway OSS (Alternative) |
|---|---|---|
| **Docker Image** | `kong/kong-gateway` | `kong/kong` |
| **License** | Automatically managed by Konnect | No license needed |
| **Enterprise Plugins** | OpenID Connect, OAuth2 Introspection, mTLS, Vault, OPA, etc. | Not available |
| **Analytics** | Konnect Observability (real-time dashboards) | Self-managed (Prometheus/Grafana) |
| **Developer Portal** | Built-in via Konnect | Not available |
| **Admin UI** | Kong Manager + Konnect Dashboard | Kong Manager (limited) |
| **Gateway API Support** | Full (GatewayClass, Gateway, HTTPRoute) | Full (GatewayClass, Gateway, HTTPRoute) |
| **Cost** | Free trial (30 days) → Plus or Enterprise tier | Free forever |

> **Recommendation:** Start with the [Konnect free trial](https://konghq.com/products/kong-konnect/register) to get Enterprise features with zero license management. See the [OSS alternative](#alternative-kong-gateway-oss-without-konnect) section if you prefer to run without Konnect.

---

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5
- kubectl
- Helm 3.x
- Kong Konnect account ([free trial](https://konghq.com/products/kong-konnect/register) or paid subscription)

## Deployment Steps

### Step 1: Clone Repository

```bash
git clone https://github.com/shanaka-versent/EKS-Kong-GatewayAPI-Demo.git
cd EKS-Kong-GatewayAPI-Demo
```

### Step 2: Deploy Infrastructure (Layers 1 & 2)

```bash
cd terraform
terraform init

# Deploy without CloudFront (basic setup)
terraform apply

# OR deploy with CloudFront + WAF + VPC Origin (production-ready)
terraform apply -var="enable_cloudfront=true"
```

> **Note:** When `enable_cloudfront=true`, Terraform creates the Internal NLB, CloudFront VPC Origin, and WAF. The VPC Origin can take 15+ minutes to deploy.

### Step 3: Configure kubectl

```bash
$(terraform output -raw eks_get_credentials_command)
```

### Step 4: Configure Kong Konnect Integration

This step connects your Kong Gateway Enterprise data plane to Konnect. Konnect automatically provisions the Enterprise license — no license file management required.

> **Don't have a Konnect account?** See the [OSS alternative](#alternative-kong-gateway-oss-without-konnect) to deploy without Konnect.

1. **Create a Control Plane in Konnect**
   - Sign in to [cloud.konghq.com](https://cloud.konghq.com)
   - In the left sidebar, click **API Gateway**
   - Click **+ New Control Plane** → choose **Kong Ingress Controller**
   - Name it (e.g., `eks-demo`) and save
   - Note the **Control Plane ID** from the overview page

2. **Generate mTLS Certificates**
   ```bash
   openssl req -new -x509 -nodes -newkey rsa:2048 \
     -subj "/CN=kongdp/C=US" \
     -keyout ./tls.key -out ./tls.crt -days 365
   ```

3. **Create TLS Secret in Kubernetes**
   ```bash
   kubectl create namespace kong
   kubectl create secret tls konnect-client-tls -n kong \
     --cert=./tls.crt \
     --key=./tls.key
   ```

4. **Register Certificate with Konnect**
   ```bash
   # Set your Konnect variables
   export KONNECT_REGION="us"          # us, eu, au, me, in, sg
   export KONNECT_TOKEN="kpat_xxx..."  # Personal access token from Konnect
   export CONTROL_PLANE_ID="your-cp-id-here"

   # Format certificate for API (remove newlines)
   CERT=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' tls.crt)

   # Register the certificate with Konnect
   curl -X POST "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/dp-client-certificates" \
     -H "Authorization: Bearer $KONNECT_TOKEN" \
     --json "{\"cert\": \"$CERT\"}"
   ```

5. **Update Helm Values**

   Update `k8s/kong/konnect-values.yaml` with your Konnect endpoints:
   ```yaml
   image:
     repository: kong/kong-gateway   # Enterprise image (license via Konnect)
     tag: "3.9"

   ingressController:
     enabled: true
     konnect:
       enabled: true
       controlPlaneId: "<your-control-plane-id>"
       tlsClientCertSecretName: konnect-client-tls

   gateway:
     env:
       role: data_plane
       database: "off"
       konnect_mode: "on"
       vitals: "off"
       cluster_mtls: pki
       cluster_control_plane: "<your-cp>.us.cp0.konghq.com:443"
       cluster_server_name: "<your-cp>.us.cp0.konghq.com"
       cluster_telemetry_endpoint: "<your-tp>.us.tp0.konghq.com:443"
       cluster_telemetry_server_name: "<your-tp>.us.tp0.konghq.com"
       cluster_cert: /etc/secrets/konnect-client-tls/tls.crt
       cluster_cert_key: /etc/secrets/konnect-client-tls/tls.key
       lua_ssl_trusted_certificate: system

     secretVolumes:
       - konnect-client-tls
   ```

#### Konnect Configuration Parameters Reference

| Parameter | Description | Example |
|-----------|-------------|---------|
| `cluster_control_plane` | Control plane endpoint (host:port) | `example.us.cp0.konghq.com:443` |
| `cluster_server_name` | SNI for TLS connection to control plane | `example.us.cp0.konghq.com` |
| `cluster_telemetry_endpoint` | Telemetry endpoint for analytics | `example.us.tp0.konghq.com:443` |
| `cluster_telemetry_server_name` | SNI for telemetry TLS connection | `example.us.tp0.konghq.com` |
| `cluster_mtls` | mTLS mode (`pki` for Konnect) | `pki` |
| `cluster_cert` | Path to client certificate | `/etc/secrets/konnect-client-tls/tls.crt` |
| `cluster_cert_key` | Path to client private key | `/etc/secrets/konnect-client-tls/tls.key` |

### Step 5: Deploy ArgoCD Root App (Layers 3 & 4)

```bash
# Get ArgoCD admin password
terraform output -raw argocd_admin_password

# Apply root application
kubectl apply -f argocd/apps/root-app.yaml

# Wait for all apps to sync
kubectl get applications -n argocd -w
```

### Step 6: Verify Deployment

#### Verify Gateway API Resources

```bash
# Verify Kong Gateway pods are running
kubectl get pods -n kong

# Check GatewayClass status
kubectl get gatewayclass kong -o yaml

# Check Gateway status
kubectl get gateway kong-gateway -n kong -o yaml

# Verify HTTPRoutes are working
kubectl get httproutes -A
```

#### Verify Konnect Connection

1. **Check Data Plane Status in Konnect UI**
   - Go to Kong Konnect dashboard at [cloud.konghq.com](https://cloud.konghq.com)
   - In the left sidebar, click **API Gateway**
   - Click on your Control Plane to open the Overview dashboard
   - Click **Data Plane Nodes** in the sidebar to see connected nodes
   - Your data plane node(s) should show status **"Connected"**
   - The Enterprise license is automatically applied — no manual license file needed
   
2. **Verify from Kubernetes**
   ```bash
   # Check Kong pod logs for successful Konnect connection
   kubectl logs -n kong -l app.kubernetes.io/name=kong --tail=50 | grep -i konnect

   # Verify pods are running with Enterprise image
   kubectl get pods -n kong -o jsonpath='{.items[0].spec.containers[0].image}'
   # Should show: kong/kong-gateway:3.9

   # Check for any connection errors
   kubectl logs -n kong -l app.kubernetes.io/name=kong | grep -i "error\|failed"
   ```

3. **Verify Enterprise Features**
   - Analytics will start appearing in the Konnect dashboard within 1-2 minutes
   - Enterprise plugins (OpenID Connect, OPA, Vault, etc.) are now available
   - Configuration changes in Konnect UI sync to data planes within seconds

## Testing

### Test Endpoints

```bash
# When CloudFront is enabled, use the CloudFront URL:
CF_URL=$(cd terraform && terraform output -raw cloudfront_url)

# Test App 1 (no plugins)
curl ${CF_URL}/app1

# Test App 2 (no plugins)
curl ${CF_URL}/app2

# Test Users API (with rate limiting)
curl ${CF_URL}/api/users

# Test health endpoint
curl ${CF_URL}/healthz/ready

# Verify NLB target health (Kong pods should be healthy)
TG_ARN=$(cd terraform && terraform output -raw nlb_target_group_arn)
aws elbv2 describe-target-health --target-group-arn ${TG_ARN}

# Verify TargetGroupBinding
kubectl get targetgroupbindings -n kong
```

### Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin
# Password: terraform output -raw argocd_admin_password
```

---

## Kong Konnect Platform Overview

Kong Konnect is a unified API platform that provides centralized management for APIs, LLMs, events, and microservices. It combines a cloud-hosted control plane with flexible data plane deployment options.

### Konnect Applications & Features

#### 1. API Gateway Management
- **Control Plane Management**: Centralized configuration for all Kong Gateway instances
- **Data Plane Monitoring**: Real-time health and status of all connected data planes
- **Configuration Sync**: Automatic propagation of routes, services, and plugins to data planes
- **Version Compatibility**: Control planes support data planes with the same major version

#### 2. Konnect Observability (Analytics)
Real-time, highly contextual analytics platform providing deep insights into API health, performance, and usage.

| Capability | Description |
|------------|-------------|
| **Traffic Metrics** | Request counts, throughput, and bandwidth analytics |
| **Latency Analysis** | P50, P95, P99 latency percentiles with breakdown |
| **Error Tracking** | 4xx/5xx error rates with detailed error codes |
| **Consumer Analytics** | Per-consumer usage patterns and quotas |
| **Custom Dashboards** | Build custom dashboards with saved queries |
| **API Request Logs** | Near real-time access to detailed request records |

#### 3. Developer Portal
A customizable website for developers to locate, access, and consume API services.

| Feature | Description |
|---------|-------------|
| **API Discovery** | Searchable catalog of available APIs |
| **Interactive Docs** | OpenAPI/Swagger-based "Try It Out" functionality |
| **Self-Service Registration** | Developers can self-register for API access |
| **API Key Management** | Self-service API key generation and rotation |
| **Application Management** | Developers manage their own applications |
| **Customization** | Full portal theming and branding support |

#### 4. Service Catalog
Centralized catalog of all services running in your organization.

- Automatic service discovery from multiple sources
- Integration with Konnect Analytics for service health
- Service ownership and documentation management
- Cross-reference with Developer Portal APIs

#### 5. Kong Identity
OAuth 2.0 and OpenID Connect identity provider for machine-to-machine authentication.

```mermaid
sequenceDiagram
    participant Client as Client App
    participant Identity as Kong Identity
    participant Gateway as Kong Gateway
    participant API as Backend API

    Client->>Identity: Request access token (client credentials)
    Identity->>Identity: Validate credentials
    Identity-->>Client: Access token + scope + expiry
    Client->>Gateway: API request + access token
    Gateway->>Identity: Validate token
    Identity-->>Gateway: Token valid
    Gateway->>API: Forward request
    API-->>Client: Response
```

**Supported Plugins:**
- OpenID Connect plugin
- OAuth 2.0 Introspection plugin
- Upstream OAuth plugin

#### 6. Metering & Billing
Full system for tracking real-time usage, pricing products, enforcing entitlements, and generating invoices.

#### 7. Konnect Debugger
Real-time trace-level visibility into API traffic for troubleshooting.

| Feature | Description |
|---------|-------------|
| **On-Demand Tracing** | Targeted deep traces on specific data planes |
| **Request Lifecycle** | Visualize entire request processing pipeline |
| **Plugin Execution** | See order and timing of all plugin executions |
| **Sampling Criteria** | Filter traces by method, path, status, latency |
| **Log Correlation** | Traces correlated with Kong Gateway logs |
| **7-Day Retention** | Debug sessions retained for up to 7 days |

### Data Plane Hosting Options

Kong Konnect supports multiple data plane hosting options:

| Option | Description | Best For |
|--------|-------------|----------|
| **Dedicated Cloud Gateways** | Fully-managed by Kong in AWS, Azure, or GCP | Zero-ops, automatic scaling |
| **Serverless Gateways** | Lightweight, auto-provisioned gateways | Dev/test, rapid experimentation |
| **Self-Hosted** | Deploy on your infrastructure (K8s, VMs, bare metal) | Data sovereignty, compliance |

**This demo uses Self-Hosted data planes on EKS.**

### Supported Geographic Regions

Konnect Control Planes are available in these regions:

| Region | Code | API Endpoint |
|--------|------|--------------|
| United States | `us` | `us.api.konghq.com` |
| Europe | `eu` | `eu.api.konghq.com` |
| Australia | `au` | `au.api.konghq.com` |
| Middle East | `me` | `me.api.konghq.com` |
| India | `in` | `in.api.konghq.com` |
| Singapore (Beta) | `sg` | `sg.api.konghq.com` |

### AI Gateway Capabilities

Kong AI Gateway is built on top of Kong Gateway, designed for AI/LLM adoption:

- **AI Rate Limiting**: Rate limit by tokens, requests, or cost
- **AI Prompt Guard**: Filter and moderate prompts
- **AI Request Transformer**: Transform requests for different LLM providers
- **Multi-Provider Support**: OpenAI, Anthropic, Azure OpenAI, and more
- **MCP Tool Aggregation**: Aggregate MCP tools from multiple sources

### Security & Compliance

| Feature | Description |
|---------|-------------|
| **SSO/SAML/OIDC** | Enterprise identity provider integration |
| **Teams & Roles** | RBAC with custom teams and permissions |
| **Audit Logging** | Comprehensive audit logs for Konnect and Dev Portal |
| **CMEK** | Customer-Managed Encryption Keys |
| **Data Localization** | Geo-specific data storage and processing |
| **Multi-Geo Federation** | Federated API management across regions |

### Management Tools

| Tool | Use Case |
|------|----------|
| **decK** | Declarative configuration management via YAML/JSON |
| **Terraform Provider** | Infrastructure as Code for Konnect resources |
| **Kong Ingress Controller** | Kubernetes-native configuration via CRDs |
| **Konnect APIs** | Full programmatic control over all Konnect features |
| **KAi** | Kong's AI assistant for issue detection and fixes |

---

## Alternative: Kong Gateway OSS (Without Konnect)

If you don't have a Kong Konnect subscription and don't need Enterprise features, you can deploy with the **open-source Kong Gateway** instead.

### What You Lose Without Konnect

| Feature | Enterprise (Konnect) | OSS |
|---------|---------------------|-----|
| Enterprise plugins (OIDC, OPA, Vault, mTLS) | Yes | No |
| Centralized analytics dashboard | Yes | No — use Prometheus/Grafana |
| Developer Portal | Yes | No |
| Automatic license management | Yes | N/A |
| Kong Manager UI | Full | Limited |
| **Gateway API support** | **Full** | **Full** |
| **Core plugins (rate limiting, JWT, CORS, etc.)** | **Yes** | **Yes** |

### OSS Deployment Steps

**Skip Step 4** (Konnect Integration) and make these changes:

1. **Use the OSS Helm values** (`k8s/kong/values.yaml` instead of `konnect-values.yaml`):
   ```yaml
   image:
     repository: kong/kong    # OSS image (not kong/kong-gateway)
     tag: "3.9"

   ingressController:
     enabled: true
     # No konnect section needed

   gateway:
     env:
       database: "off"        # DB-less mode
       # No konnect_mode, cluster_*, or role settings needed
   ```

2. **Update the ArgoCD app** to reference `values.yaml` instead of `konnect-values.yaml`

3. **Deploy as normal** (Steps 1-3, then Step 5-6), skipping the Konnect verification

> **Note:** The Gateway API resources (GatewayClass, Gateway, HTTPRoute) work identically with both editions. Only the available plugin set and management capabilities differ.

---

## Cleanup

```bash
# Delete ArgoCD apps first
kubectl delete -f argocd/apps/root-app.yaml

# Wait for resources to be cleaned up
sleep 60

# Destroy infrastructure
cd terraform
terraform destroy
```

## Related Projects

- [EKS Istio Gateway API POC](https://github.com/shanaka-versent/EKS-Istio-GatewayAPI-Demo) - Implementation 2: Istio + AWS API Gateway
- [AKS Istio Gateway API POC](https://github.com/shanaka-versent/AKS-Istio-GatewayAPI-Demo) - Azure AKS implementation with Istio

## Resources

- [Kong Gateway Documentation](https://developer.konghq.com/gateway/)
- [Kong Kubernetes Ingress Controller](https://developer.konghq.com/kubernetes-ingress-controller/)
- [Kong Konnect Platform](https://developer.konghq.com/konnect/)
- [Kong AI Gateway](https://developer.konghq.com/ai-gateway/)
- [Kong Developer Portal](https://developer.konghq.com/dev-portal/)
- [Kong Identity](https://developer.konghq.com/kong-identity/)
- [Konnect APIs Reference](https://developer.konghq.com/api/)
- [Kubernetes Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [CloudFront VPC Origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
