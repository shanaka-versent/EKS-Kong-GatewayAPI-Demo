# EKS Kong Gateway POC - Route53 Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "domain_name" {
  description = "Domain name for the Route53 hosted zone"
  type        = string
}

variable "nlb_dns_name" {
  description = "Internal NLB DNS name for ALIAS record (optional - creates A record at zone apex)"
  type        = string
  default     = ""
}

variable "nlb_zone_id" {
  description = "Internal NLB hosted zone ID for ALIAS record (required if nlb_dns_name is set)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
