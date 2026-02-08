# EKS Kong Gateway POC - Route53 Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "Route53 hosted zone name servers (update at your domain registrar)"
  value       = aws_route53_zone.main.name_servers
}
