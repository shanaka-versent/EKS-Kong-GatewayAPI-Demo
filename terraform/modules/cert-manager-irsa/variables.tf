# EKS Kong Gateway POC - cert-manager IRSA Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA role federation"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL without https:// for trust policy conditions"
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS-01 challenge"
  type        = string
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
