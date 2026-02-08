# EKS Kong Gateway POC - Route53 Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "domain_name" {
  description = "Domain name for the Route53 hosted zone"
  type        = string
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
