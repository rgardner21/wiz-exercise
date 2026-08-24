###############################################################################
# EKS cluster
#   - Worker nodes live in the private subnets (exercise requirement)
#   - Kubernetes control plane audit logging enabled and shipped to CloudWatch
#   - Public API endpoint is left on so GitHub Actions can run kubectl. Flip
#     cluster_endpoint_public_access_cidrs to your runner egress range, or move
#     to a self-hosted runner inside the VPC, if you want that tightened.
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  cluster_name    = "${local.name}-eks"
  cluster_version = var.eks_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Kubernetes-level audit logging, complementing CloudTrail at the CSP level.
  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 30

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
    # PREVENTATIVE CONTROL: IMDSv2 required on worker nodes, hop limit allows
    # the kubelet but not pods reaching node credentials by default.
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      subnet_ids     = module.vpc.private_subnets

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 30
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }
    }
  }

  tags = local.tags
}

###############################################################################
# AWS Load Balancer Controller - turns the Kubernetes Ingress into an ALB
###############################################################################

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${local.name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.iam_role_arn
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}

###############################################################################
# Container registry for the todo app
###############################################################################

resource "aws_ecr_repository" "app" {
  name                 = "${local.name}/wiz-todo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # PREVENTATIVE/DETECTIVE: registry-side vulnerability scanning on every push,
  # in addition to the Trivy gate in the pipeline.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}
