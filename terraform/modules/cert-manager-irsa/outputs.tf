# EKS Kong Gateway POC - cert-manager IRSA Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "cert_manager_role_arn" {
  description = "cert-manager IAM role ARN for IRSA"
  value       = aws_iam_role.cert_manager.arn
}
