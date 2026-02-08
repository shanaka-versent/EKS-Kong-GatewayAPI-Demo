# EKS Kong Gateway POC - Terraform Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

# AWS Region
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "poc"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "kong-gw"
}

# Network
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

# EKS Configuration
variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "eks_node_count" {
  description = "Number of EKS system nodes"
  type        = number
  default     = 2
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS system nodes"
  type        = string
  default     = "t3.medium"
}

# User Node Pool (optional)
variable "enable_user_node_pool" {
  description = "Enable separate user node pool"
  type        = bool
  default     = true
}

variable "user_node_count" {
  description = "Number of user nodes"
  type        = number
  default     = 2
}

variable "user_node_instance_type" {
  description = "Instance type for user nodes"
  type        = string
  default     = "t3.medium"
}

# EKS Autoscaling
variable "enable_eks_autoscaling" {
  description = "Enable EKS cluster autoscaler"
  type        = bool
  default     = false
}

variable "system_node_min_count" {
  description = "Minimum number of system nodes (when autoscaling enabled)"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of system nodes (when autoscaling enabled)"
  type        = number
  default     = 3
}

variable "user_node_min_count" {
  description = "Minimum number of user nodes (when autoscaling enabled)"
  type        = number
  default     = 1
}

variable "user_node_max_count" {
  description = "Maximum number of user nodes (when autoscaling enabled)"
  type        = number
  default     = 5
}

# EKS Logging
variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

# ==============================================================================
# CLOUDFRONT + WAF + VPC ORIGIN CONFIGURATION
# ==============================================================================

variable "enable_cloudfront" {
  description = "Enable CloudFront + WAF + VPC Origin edge layer for private connectivity to Kong Gateway"
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Enable WAF Web ACL on CloudFront (requires enable_cloudfront = true)"
  type        = bool
  default     = true
}

variable "enable_waf_rate_limiting" {
  description = "Enable rate limiting rule in WAF"
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "WAF rate limit threshold (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

variable "cloudfront_price_class" {
  description = "CloudFront price class (PriceClass_100 = US/Canada/Europe)"
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate ARN for CloudFront custom domain (must be in us-east-1)"
  type        = string
  default     = ""
}

variable "cloudfront_custom_domain" {
  description = "Custom domain for CloudFront distribution"
  type        = string
  default     = ""
}

# ==============================================================================
# END-TO-END TLS (Let's Encrypt via cert-manager)
# ==============================================================================

variable "domain_name" {
  description = "Subdomain for Route53 hosted zone and Let's Encrypt certificate (e.g., kong.esharps.co.nz)"
  type        = string
  default     = "kong.esharps.co.nz"
}

# ArgoCD Configuration
variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "argocd_service_type" {
  description = "ArgoCD server service type (LoadBalancer or ClusterIP)"
  type        = string
  default     = "ClusterIP"
}

# Tags
variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default = {
    Project   = "Kong-Gateway-POC"
    Purpose   = "Gateway-API-EKS-Kong-Integration"
    ManagedBy = "Terraform"
  }
}
