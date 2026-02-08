# EKS Kong Gateway POC - Route53 Hosted Zone Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a Route53 public hosted zone for the Kong subdomain.
# Used by cert-manager for DNS-01 ACME challenge (Let's Encrypt).
#
# CROSS-ACCOUNT SUBDOMAIN DELEGATION:
# The parent domain (e.g., esharps.co.nz) is in a different AWS account.
# This module creates a subdomain zone (e.g., kong.esharps.co.nz) in the
# platform account. After terraform apply:
#
#   1. Run: terraform output route53_name_servers
#   2. In the parent account's Route53 zone for esharps.co.nz, create an NS record:
#      Name:  kong.esharps.co.nz
#      Type:  NS
#      Value: <the 4 name servers from step 1>
#
# This delegates DNS authority for kong.esharps.co.nz to this account,
# allowing cert-manager to create TXT records for Let's Encrypt validation.

resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Subdomain zone for ${var.domain_name} - managed by Terraform (Kong Gateway POC)"

  tags = merge(var.tags, {
    Name   = var.domain_name
    Layer  = "Layer2-Infrastructure"
    Module = "route53"
  })
}

# ALIAS A record at zone apex pointing to Internal NLB
# This allows CloudFront to use kong.esharps.co.nz as the origin domain_name
# for correct TLS SNI matching with the Let's Encrypt certificate
resource "aws_route53_record" "nlb_alias" {
  count   = var.nlb_dns_name != "" ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.nlb_dns_name
    zone_id                = var.nlb_zone_id
    evaluate_target_health = true
  }
}
