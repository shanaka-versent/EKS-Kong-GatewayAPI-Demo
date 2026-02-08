# EKS Kong Gateway POC - CloudFront Distribution with WAF + VPC Origin
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 2: Base EKS Cluster Setup (Terraform)
#
# This module creates a CloudFront distribution with:
# - VPC Origin for private connectivity to Internal NLB (no public endpoints)
# - WAF Web ACL with AWS Managed Rules (SQLi, XSS, Bad Inputs, Rate Limiting)
# - Security response headers (HSTS, X-Frame-Options, X-Content-Type-Options)
# - Optional S3 origin for static assets with Origin Access Control (OAC)
#
# Architecture:
# CloudFront --> VPC Origin (AWS backbone/PrivateLink) --> Internal NLB --> Kong Pods
#
# CloudFront VPC Origin (launched Nov 2024):
# - Creates AWS-managed ENIs in private subnets
# - End-to-end private connectivity without any public endpoints
# - No need for prefix list hacks, IP allowlisting, or custom header verification
# - Leverages AWS PrivateLink under the hood

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.82" # Required for aws_cloudfront_vpc_origin
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# ==============================================================================
# WAF WEB ACL
# ==============================================================================

resource "aws_wafv2_web_acl" "main" {
  count    = var.enable_waf ? 1 : 0
  name     = "${var.name_prefix}-waf-acl"
  scope    = "CLOUDFRONT"
  provider = aws.us_east_1 # WAF for CloudFront must be in us-east-1

  default_action {
    allow {}
  }

  # AWS Managed Rules - Common Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules - SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting rule (dynamic - only created if enabled)
  dynamic "rule" {
    for_each = var.enable_rate_limiting ? [1] : []
    content {
      name     = "RateLimitRule"
      priority = 10

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.rate_limit
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name_prefix}-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-waf-acl"
    Layer  = "Layer2-Infrastructure"
    Module = "cloudfront"
  })
}

# ==============================================================================
# CLOUDFRONT VPC ORIGIN
# ==============================================================================

# VPC Origin enables private connectivity from CloudFront to Internal NLB
# via AWS-managed ENIs in private subnets (uses PrivateLink under the hood)
# End-to-End TLS: CloudFront connects via HTTPS to NLB, which passes through
# to Kong pods on port 8443 where TLS is terminated with a Let's Encrypt cert
resource "aws_cloudfront_vpc_origin" "nlb" {
  vpc_origin_endpoint_config {
    name                   = "${var.name_prefix}-vpc-origin-tls"
    arn                    = var.nlb_arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  # VPC Origins can take 15+ minutes to deploy
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  # Create new VPC Origin before destroying old one — AWS prevents updating
  # a VPC Origin while it's associated with a CloudFront distribution
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-vpc-origin-tls"
    Layer  = "Layer2-Infrastructure"
    Module = "cloudfront"
  })
}

# ==============================================================================
# CLOUDFRONT ORIGIN ACCESS CONTROL (for S3 static assets)
# ==============================================================================

resource "aws_cloudfront_origin_access_control" "s3" {
  count                             = var.enable_s3_origin ? 1 : 0
  name                              = "${var.name_prefix}-s3-oac"
  description                       = "OAC for S3 static assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ==============================================================================
# CLOUDFRONT CACHE POLICIES
# ==============================================================================

# Cache policy for static assets (aggressive caching)
resource "aws_cloudfront_cache_policy" "static_assets" {
  count   = var.enable_s3_origin ? 1 : 0
  name    = "${var.name_prefix}-static-cache"
  comment = "Cache policy for static assets (CSS, JS, images)"

  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# Use AWS managed CachingDisabled policy for API traffic (no caching)
# Managed policy ID: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# ==============================================================================
# CLOUDFRONT ORIGIN REQUEST POLICY
# ==============================================================================

# Use AWS managed AllViewerExceptHostHeader policy
# Forwards all viewer headers (including Authorization) except Host
# Managed policy ID: b689b0a0-8776-4c4d-943d-2588d6b6e5b8
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# ==============================================================================
# CLOUDFRONT RESPONSE HEADERS POLICY
# ==============================================================================

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name    = "${var.name_prefix}-security-headers"
  comment = "Security headers policy for Kong Gateway POC"

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
      preload                    = true
    }
    xss_protection {
      mode_block = true
      override   = true
      protection = true
    }
  }

  custom_headers_config {
    items {
      header   = "X-Served-By"
      override = true
      value    = "CloudFront-${var.name_prefix}"
    }
  }
}

# ==============================================================================
# CLOUDFRONT DISTRIBUTION
# ==============================================================================

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name_prefix} - CloudFront with VPC Origin to Kong Gateway"
  default_root_object = ""
  price_class         = var.price_class
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null

  aliases = var.custom_domain != "" ? [var.custom_domain] : []

  # ---------------------------------------------------------------------------
  # VPC Origin - Kong Gateway via Internal NLB (private connectivity)
  # For HTTPS origins, domain_name controls the SNI sent during TLS handshake.
  # The certificate on the origin (Kong) must have a CN/SAN matching this domain.
  # ---------------------------------------------------------------------------
  origin {
    domain_name = var.origin_domain_name != "" ? var.origin_domain_name : var.nlb_dns_name
    origin_id   = "VPCOrigin-Kong"

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.nlb.id
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  # ---------------------------------------------------------------------------
  # S3 Origin for static assets (optional)
  # ---------------------------------------------------------------------------
  dynamic "origin" {
    for_each = var.enable_s3_origin ? [1] : []
    content {
      domain_name              = var.s3_bucket_regional_domain_name
      origin_id                = "S3-static-assets"
      origin_access_control_id = aws_cloudfront_origin_access_control.s3[0].id
    }
  }

  # ---------------------------------------------------------------------------
  # Default behavior - All traffic routes to Kong Gateway via VPC Origin
  # Kong handles all routing via HTTPRoutes (Gateway API)
  # ---------------------------------------------------------------------------
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "VPCOrigin-Kong"

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  # ---------------------------------------------------------------------------
  # Static assets behavior (/static/*) - optional
  # ---------------------------------------------------------------------------
  dynamic "ordered_cache_behavior" {
    for_each = var.enable_s3_origin ? [1] : []
    content {
      path_pattern     = "/static/*"
      allowed_methods  = ["GET", "HEAD", "OPTIONS"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "S3-static-assets"

      cache_policy_id            = aws_cloudfront_cache_policy.static_assets[0].id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

      viewer_protocol_policy = "redirect-to-https"
      compress               = true
    }
  }

  # ---------------------------------------------------------------------------
  # Restrictions
  # ---------------------------------------------------------------------------
  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  # ---------------------------------------------------------------------------
  # TLS Certificate
  # ---------------------------------------------------------------------------
  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == ""
    acm_certificate_arn            = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.acm_certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-cloudfront"
    Layer  = "Layer2-Infrastructure"
    Module = "cloudfront"
  })

  depends_on = [aws_cloudfront_vpc_origin.nlb]
}
