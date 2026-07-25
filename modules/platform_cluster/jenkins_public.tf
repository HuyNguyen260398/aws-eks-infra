// Public HTTPS exposure for the Jenkins workload.
//
// Ownership split follows the repository invariant: Terraform owns the AWS
// resources (ACM certificate, Route 53 records), Argo CD owns the Ingress that
// makes the load balancer. Because the ALB is created by the load balancer
// controller and not by Terraform, the alias record cannot be planned until the
// Ingress has reconciled at least once. That is why the record is behind its own
// flag - see docs/operations/public-workload-access.md for the ordering.

locals {
  jenkins_public_enabled = length(trimspace(var.jenkins_public_hostname)) > 0
}

data "aws_route53_zone" "public" {
  count = local.jenkins_public_enabled ? 1 : 0

  name         = var.route53_hosted_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "jenkins" {
  count = local.jenkins_public_enabled ? 1 : 0

  domain_name       = var.jenkins_public_hostname
  validation_method = "DNS"

  tags = merge(var.tags, { Name = var.jenkins_public_hostname })

  lifecycle {
    create_before_destroy = true
  }
}

// Deliberately count-based rather than for_each over domain_validation_options.
// The certificate has exactly one domain and no SANs, so a single record is
// sufficient, and for_each over an unknown set would repeat the apply-time-key
// failure documented in docs/operations/first-deployment-defects.md.
resource "aws_route53_record" "jenkins_certificate_validation" {
  count = local.jenkins_public_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = tolist(aws_acm_certificate.jenkins[0].domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.jenkins[0].domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.jenkins[0].domain_validation_options)[0].resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "jenkins" {
  count = local.jenkins_public_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.jenkins[0].arn
  validation_record_fqdns = [aws_route53_record.jenkins_certificate_validation[0].fqdn]
}

// Second phase. The ALB name is pinned by
// alb.ingress.kubernetes.io/load-balancer-name on the Jenkins Ingress so this
// lookup is deterministic, but the load balancer must already exist.
data "aws_lb" "jenkins" {
  count = var.jenkins_dns_record_enabled ? 1 : 0

  name = var.jenkins_alb_name
}

resource "aws_route53_record" "jenkins_alias" {
  count = var.jenkins_dns_record_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.jenkins_public_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.jenkins[0].dns_name
    zone_id                = data.aws_lb.jenkins[0].zone_id
    evaluate_target_health = true
  }
}

check "jenkins_public_access_inputs" {
  assert {
    condition     = !var.jenkins_dns_record_enabled || local.jenkins_public_enabled
    error_message = "jenkins_dns_record_enabled requires jenkins_public_hostname to be set."
  }

  assert {
    condition     = !local.jenkins_public_enabled || length(trimspace(var.route53_hosted_zone_name)) > 0
    error_message = "jenkins_public_hostname requires route53_hosted_zone_name to be set."
  }

  assert {
    condition     = !local.jenkins_public_enabled || endswith(var.jenkins_public_hostname, trimsuffix(var.route53_hosted_zone_name, "."))
    error_message = "jenkins_public_hostname must be a name inside route53_hosted_zone_name."
  }
}
