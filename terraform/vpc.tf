data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private subnets host the EKS worker nodes (exercise requirement).
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]

  # Public subnets host the internet-facing ALB and the MongoDB VM,
  # which must expose SSH to the internet for this exercise.
  public_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # cost control for a short-lived lab
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC flow logs feed the detective controls.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 14

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}
