# EKS Kong Gateway POC - CloudFront Distribution Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

# NLB Origin Configuration (VPC Origin)
variable "nlb_arn" {
  description = "Internal NLB ARN for CloudFront VPC Origin"
  type        = string
}

variable "nlb_dns_name" {
  description = "Internal NLB DNS name for origin domain"
  type        = string
}

variable "origin_domain_name" {
  description = "Domain name for CloudFront origin SNI (must match the TLS certificate on the origin). Falls back to nlb_dns_name if empty."
  type        = string
  default     = ""
}

# S3 Origin Configuration (optional)
variable "enable_s3_origin" {
  description = "Enable S3 origin for static assets"
  type        = bool
  default     = false
}

variable "s3_bucket_regional_domain_name" {
  description = "S3 bucket regional domain name"
  type        = string
  default     = ""
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN (for OAC policy)"
  type        = string
  default     = ""
}

# WAF Configuration
variable "enable_waf" {
  description = "Enable WAF Web ACL on CloudFront"
  type        = bool
  default     = true
}

variable "enable_rate_limiting" {
  description = "Enable rate limiting rule in WAF"
  type        = bool
  default     = true
}

variable "rate_limit" {
  description = "Rate limit threshold (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

# SSL/TLS Configuration
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for custom domain (must be in us-east-1)"
  type        = string
  default     = ""
}

variable "custom_domain" {
  description = "Custom domain for CloudFront distribution"
  type        = string
  default     = ""
}

# Cache Configuration
variable "price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100" # US, Canada, Europe
}

# Geo Restriction
variable "geo_restriction_type" {
  description = "Geo restriction type (none, whitelist, blacklist)"
  type        = string
  default     = "none"
}

variable "geo_restriction_locations" {
  description = "List of country codes for geo restriction"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
