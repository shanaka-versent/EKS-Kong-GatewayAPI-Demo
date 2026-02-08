# EKS Kong Gateway POC - Main Terraform Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Architecture Layers:
# ===================
# Layer 1: Cloud Foundations (Terraform)
#   - VPC, Subnets, NAT Gateway, Internet Gateway
#
# Layer 2: Base EKS Cluster Setup (Terraform)
#   - EKS Cluster, Node Groups, OIDC Provider
#   - IAM Roles (Cluster, Node, LB Controller IRSA)
#   - AWS Load Balancer Controller (for TargetGroupBinding CRD)
#   - Internal NLB (Terraform-managed, for CloudFront VPC Origin)
#   - CloudFront Distribution + WAF + VPC Origin (optional)
#   - ArgoCD Installation
#
# Layer 3: EKS Customizations (ArgoCD)
#   - Gateway API CRDs
#   - Kong Gateway (ClusterIP, registered via TargetGroupBinding)
#   - Gateway and HTTPRoutes (K8s Gateway API)
#
# Layer 4: Application Deployment (ArgoCD)
#   - Sample Applications (app1, app2)
#   - Users API with Kong Plugins
#   - Health Responder
#
# Traffic Flow (with CloudFront enabled):
# Internet --> CloudFront (WAF) --> VPC Origin (AWS backbone/PrivateLink)
#          --> Internal NLB --> Kong Gateway Pods --> Backend Services

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "eks-${local.name_prefix}"
}

# ==============================================================================
# LAYER 1: CLOUD FOUNDATIONS
# ==============================================================================

# VPC Module - Network infrastructure
module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  cluster_name       = local.cluster_name
  enable_nat_gateway = var.enable_nat_gateway
  tags               = var.tags
}

# ==============================================================================
# LAYER 2: BASE EKS CLUSTER SETUP
# ==============================================================================

# EKS Module - Kubernetes cluster
module "eks" {
  source = "./modules/eks"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # Use private subnets for cluster, private for nodes
  subnet_ids      = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  node_subnet_ids = module.vpc.private_subnet_ids

  # System Node Pool
  system_node_count         = var.eks_node_count
  system_node_instance_type = var.eks_node_instance_type
  system_node_min_count     = var.system_node_min_count
  system_node_max_count     = var.system_node_max_count

  # User Node Pool (optional)
  enable_user_node_pool   = var.enable_user_node_pool
  user_node_count         = var.user_node_count
  user_node_instance_type = var.user_node_instance_type
  user_node_min_count     = var.user_node_min_count
  user_node_max_count     = var.user_node_max_count

  # Autoscaling
  enable_autoscaling = var.enable_eks_autoscaling

  # Logging
  enable_logging = var.enable_logging

  tags = var.tags
}

# IAM Module - AWS Load Balancer Controller IRSA role
module "iam" {
  source = "./modules/iam"

  name_prefix       = local.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = var.tags
}

# AWS Load Balancer Controller - Provides TargetGroupBinding CRD
# Used to register Kong Gateway pods with the Terraform-managed NLB target group
module "lb_controller" {
  source = "./modules/lb-controller"

  cluster_name       = module.eks.cluster_name
  iam_role_arn       = module.iam.lb_controller_role_arn
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  cluster_dependency = module.eks.cluster_name
}

# Wait for LB Controller to be ready and CRDs to be registered
resource "time_sleep" "wait_for_lb_controller" {
  depends_on      = [module.lb_controller]
  create_duration = "30s"
}

# ==============================================================================
# CLOUDFRONT EDGE LAYER (optional - gated behind enable_cloudfront)
# Creates: Internal NLB + CloudFront VPC Origin + WAF + Route53 + cert-manager IRSA
# ==============================================================================

# Route53 Subdomain Hosted Zone for Let's Encrypt DNS-01 challenge
# After apply, create NS delegation in parent account: terraform output route53_name_servers
module "route53" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/route53"

  domain_name  = var.domain_name
  nlb_dns_name = module.nlb[0].nlb_dns_name
  nlb_zone_id  = module.nlb[0].nlb_zone_id
  tags         = var.tags
}

# cert-manager IRSA role for Route53 DNS-01 challenge (Let's Encrypt)
module "cert_manager_irsa" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/cert-manager-irsa"

  name_prefix       = local.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  route53_zone_id   = module.route53[0].zone_id
  tags              = var.tags
}

# Internal NLB for Kong Gateway (Terraform-managed for CloudFront VPC Origin)
# The NLB is internal with security groups allowing only CloudFront VPC Origin traffic
module "nlb" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/nlb"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  health_check_path  = "/status"
  health_check_port  = 8100
  tags               = var.tags
}

# CloudFront Distribution with WAF + VPC Origin to Internal NLB
# VPC Origin provides end-to-end private connectivity via AWS backbone
module "cloudfront" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/cloudfront"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix       = local.name_prefix
  nlb_arn           = module.nlb[0].nlb_arn
  nlb_dns_name      = module.nlb[0].nlb_dns_name
  origin_domain_name = var.domain_name # SNI must match the Let's Encrypt cert CN

  # WAF Configuration
  enable_waf           = var.enable_waf
  enable_rate_limiting = var.enable_waf_rate_limiting
  rate_limit           = var.waf_rate_limit

  # TLS Configuration
  acm_certificate_arn = var.cloudfront_certificate_arn
  custom_domain       = var.cloudfront_custom_domain
  price_class         = var.cloudfront_price_class

  tags = var.tags
}

# ==============================================================================
# TARGET GROUP BINDING
# Registers Kong Gateway pods with the Terraform-managed NLB target group
# The TargetGroupBinding CRD is provided by the AWS Load Balancer Controller
# ==============================================================================

# Pre-create kong namespace so TargetGroupBinding can be applied before ArgoCD
resource "kubernetes_namespace" "kong" {
  count = var.enable_cloudfront ? 1 : 0

  metadata {
    name = "kong"
    labels = {
      "app.kubernetes.io/name"    = "kong"
      "app.kubernetes.io/part-of" = "kong-gateway"
    }
  }

  depends_on = [module.eks]
}

# TargetGroupBinding: Binds Kong ClusterIP service to Terraform-managed NLB target group
# The LB Controller reconciler automatically registers/deregisters Kong pod IPs
resource "kubernetes_manifest" "target_group_binding" {
  count = var.enable_cloudfront ? 1 : 0

  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = "kong-nlb-binding"
      namespace = "kong"
      labels = {
        "app.kubernetes.io/name"      = "kong"
        "app.kubernetes.io/component" = "target-group-binding"
      }
    }
    spec = {
      targetGroupARN = module.nlb[0].target_group_arn
      targetType     = "ip"
      serviceRef = {
        name = "kong-gateway-kong-proxy" # Kong Helm chart proxy service (release: kong-gateway)
        port = 443
      }
      networking = {
        ingress = [{
          from = [{
            securityGroup = {
              groupID = module.nlb[0].security_group_id
            }
          }]
          ports = [
            {
              port     = 8443 # Kong proxy TLS container port
              protocol = "TCP"
            },
            {
              port     = 8100 # Kong status/health port
              protocol = "TCP"
            }
          ]
        }]
      }
    }
  }

  depends_on = [
    time_sleep.wait_for_lb_controller,
    kubernetes_namespace.kong
  ]
}

# ==============================================================================
# PRE-DESTROY CLEANUP
# Use ./scripts/destroy.sh for clean teardown. It deletes ArgoCD apps,
# removes orphaned LoadBalancer services/NLBs, and runs terraform destroy.
# ==============================================================================

# ==============================================================================
# ARGOCD - GITOPS CONTINUOUS DELIVERY
# ==============================================================================

# ArgoCD - GitOps continuous delivery
module "argocd" {
  source = "./modules/argocd"

  argocd_version     = var.argocd_version
  service_type       = var.argocd_service_type
  insecure_mode      = true
  cluster_dependency = module.eks.cluster_name
}
