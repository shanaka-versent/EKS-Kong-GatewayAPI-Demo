# EKS Kong Gateway POC - Internal NLB Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a Terraform-managed Internal NLB for Kong Gateway.
# This NLB is the target for CloudFront VPC Origin — enabling fully private
# connectivity from CloudFront to Kong Gateway without any public endpoints.
#
# Why Terraform-managed (not auto-created by LB Controller)?
# CloudFront VPC Origin requires the NLB ARN at terraform apply time.
# The LB Controller would only create the NLB after Kong deploys via ArgoCD,
# creating a chicken-and-egg problem. By managing the NLB in Terraform,
# we can wire it to CloudFront VPC Origin in a single apply.
#
# Kong Gateway pods are registered with this NLB via TargetGroupBinding CRD
# (provided by AWS Load Balancer Controller).
#
# Traffic flow (End-to-End TLS):
# CloudFront --> VPC Origin (PrivateLink, HTTPS) --> Internal NLB :443 (TCP passthrough) --> Kong Pods :8443 (TLS, Let's Encrypt cert)

# ==============================================================================
# SECURITY GROUP
# ==============================================================================

# CloudFront VPC Origin creates a managed SG "CloudFront-VPCOrigins-Service-SG"
# in the VPC. Traffic arrives via PrivateLink from CloudFront's origin-facing IPs
# (NOT from the VPC CIDR). We reference the CloudFront-managed SG for tightest security.
# The NLB setting enforce_security_group_inbound_rules_on_private_link_traffic = "on"
# ensures only authorized CloudFront VPC Origin PrivateLink traffic is accepted.

# Look up the CloudFront-managed SG (created when VPC Origin is deployed)
data "aws_security_group" "cloudfront_vpc_origin" {
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }
  vpc_id = var.vpc_id
}

resource "aws_security_group" "nlb" {
  name        = "nlb-${var.name_prefix}"
  description = "Security group for Internal NLB - allows traffic from CloudFront VPC Origin"
  vpc_id      = var.vpc_id

  # Inbound: Allow HTTPS from CloudFront VPC Origin managed SG
  ingress {
    description     = "HTTPS from CloudFront VPC Origin"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [data.aws_security_group.cloudfront_vpc_origin.id]
  }

  # Inbound: Allow health check traffic from CloudFront VPC Origin managed SG
  ingress {
    description     = "Health check from CloudFront VPC Origin"
    from_port       = var.health_check_port
    to_port         = var.health_check_port
    protocol        = "tcp"
    security_groups = [data.aws_security_group.cloudfront_vpc_origin.id]
  }

  # Outbound: Allow all traffic to VPC CIDR (for target health checks and Kong pods)
  egress {
    description = "All traffic to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name   = "sg-nlb-${var.name_prefix}"
    Layer  = "Layer2-Infrastructure"
    Module = "nlb"
  })
}

# ==============================================================================
# INTERNAL NETWORK LOAD BALANCER
# ==============================================================================

resource "aws_lb" "internal" {
  name               = "nlb-${var.name_prefix}"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  subnets            = var.private_subnet_ids

  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing

  # Required for CloudFront VPC Origin
  enforce_security_group_inbound_rules_on_private_link_traffic = "on"

  tags = merge(var.tags, {
    Name   = "nlb-${var.name_prefix}"
    Layer  = "Layer2-Infrastructure"
    Module = "nlb"
  })
}

# ==============================================================================
# TARGET GROUP
# ==============================================================================

resource "aws_lb_target_group" "kong" {
  name        = "tg-kong-${var.name_prefix}"
  port        = 8443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = var.health_check_port
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name   = "tg-kong-${var.name_prefix}"
    Layer  = "Layer2-Infrastructure"
    Module = "nlb"
  })
}

# ==============================================================================
# LISTENER
# ==============================================================================

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong.arn
  }

  tags = merge(var.tags, {
    Name = "listener-kong-${var.name_prefix}"
  })
}
