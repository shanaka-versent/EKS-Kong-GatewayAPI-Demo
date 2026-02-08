# EKS Kong Gateway POC - Terraform Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

# EKS Outputs
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_get_credentials_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

# ArgoCD Outputs
output "argocd_admin_password" {
  description = "ArgoCD admin password"
  value       = module.argocd.admin_password
  sensitive   = true
}

output "argocd_port_forward_command" {
  description = "Command to access ArgoCD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# ==============================================================================
# LB CONTROLLER OUTPUTS
# ==============================================================================

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = module.iam.lb_controller_role_arn
}

# ==============================================================================
# CLOUDFRONT + NLB OUTPUTS (only when enable_cloudfront = true)
# ==============================================================================

output "nlb_dns_name" {
  description = "Internal NLB DNS name"
  value       = var.enable_cloudfront ? module.nlb[0].nlb_dns_name : null
}

output "nlb_target_group_arn" {
  description = "NLB target group ARN (used by TargetGroupBinding)"
  value       = var.enable_cloudfront ? module.nlb[0].target_group_arn : null
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_id : null
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : null
}

output "cloudfront_url" {
  description = "CloudFront distribution URL"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : null
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_cloudfront ? module.cloudfront[0].waf_web_acl_arn : null
}

output "application_url" {
  description = "Application URL (CloudFront if enabled, otherwise direct NLB)"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : "Use: kubectl get svc -n kong kong-kong-proxy"
}

# ==============================================================================
# END-TO-END TLS OUTPUTS (Route53 + cert-manager IRSA)
# ==============================================================================

output "route53_zone_id" {
  description = "Route53 hosted zone ID for cert-manager DNS-01 challenge"
  value       = var.enable_cloudfront ? module.route53[0].zone_id : null
}

output "route53_name_servers" {
  description = "Route53 name servers — create NS delegation record in parent account's Route53 zone"
  value       = var.enable_cloudfront ? module.route53[0].name_servers : null
}

output "cert_manager_role_arn" {
  description = "cert-manager IAM role ARN for IRSA (use in ArgoCD cert-manager app)"
  value       = var.enable_cloudfront ? module.cert_manager_irsa[0].cert_manager_role_arn : null
}
