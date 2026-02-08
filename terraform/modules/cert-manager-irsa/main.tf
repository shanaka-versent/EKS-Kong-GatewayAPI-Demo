# EKS Kong Gateway POC - cert-manager IRSA Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates an IRSA (IAM Roles for Service Accounts) role for cert-manager.
# This allows cert-manager to manage Route53 DNS records for DNS-01 ACME
# challenge validation (Let's Encrypt certificate issuance).
#
# The cert-manager service account in the cluster is annotated with this role ARN,
# enabling it to assume the role via EKS OIDC federation.

# ==============================================================================
# CERT-MANAGER IAM POLICY - Route53 DNS-01 Challenge
# ==============================================================================

resource "aws_iam_policy" "cert_manager" {
  name        = "policy-cert-manager-${var.name_prefix}"
  description = "IAM policy for cert-manager DNS-01 challenge via Route53"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetChange"
        ]
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

# ==============================================================================
# CERT-MANAGER IRSA ROLE
# ==============================================================================

resource "aws_iam_role" "cert_manager" {
  name = "role-cert-manager-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cert_manager" {
  policy_arn = aws_iam_policy.cert_manager.arn
  role       = aws_iam_role.cert_manager.name
}
