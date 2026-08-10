###############################################################################
# MongoDB virtual machine
#
# INTENTIONAL MISCONFIGURATIONS (exercise requirements):
#   - Ubuntu 20.04 LTS (April 2020) => operating system 1+ years outdated
#   - MongoDB 4.4 (EOL February 2024) => database engine 1+ years outdated
#   - SSH (22/tcp) open to the public internet
#   - Instance profile carries AdministratorAccess => can create VMs, IAM users,
#     and anything else in the account
#
# CONTROLS STILL APPLIED (these are the deliberate exceptions):
#   - 27017/tcp reachable only from the EKS node security group
#   - MongoDB authorization enabled; the app authenticates with a scoped user
#   - IMDSv2 required, which blunts credential theft via SSRF (preventative control)
###############################################################################

# Ubuntu 20.04 LTS - deliberately old.
data "aws_ami" "ubuntu_outdated" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-${var.ubuntu_release}-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "mongo" {
  key_name   = "${local.name}-mongo"
  public_key = var.ssh_public_key
  tags       = local.tags
}

# --- Credentials -------------------------------------------------------------

resource "random_password" "mongo_admin" {
  length  = 24
  special = false
}

resource "random_password" "mongo_app" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "mongo" {
  name                    = "${local.name}/mongodb/credentials"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "mongo" {
  secret_id = aws_secretsmanager_secret.mongo.id
  secret_string = jsonencode({
    admin_user     = "wizadmin"
    admin_password = random_password.mongo_admin.result
    app_user       = "todoapp"
    app_password   = random_password.mongo_app.result
    database       = "wizdemo"
  })
}

# --- Networking --------------------------------------------------------------

resource "aws_security_group" "mongo" {
  name        = "${local.name}-mongo"
  description = "MongoDB VM: SSH open to internet (intentional), 27017 limited to EKS nodes"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(local.tags, { Name = "${local.name}-mongo" })
}

# INTENTIONAL: SSH exposed to the public internet.
resource "aws_security_group_rule" "mongo_ssh_public" {
  type              = "ingress"
  security_group_id = aws_security_group.mongo.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_ingress_cidr]
  description       = "INTENTIONAL EXERCISE FINDING: SSH open to the internet"
}

# CONTROL: database port reachable only from Kubernetes worker nodes.
resource "aws_security_group_rule" "mongo_from_eks_nodes" {
  type                     = "ingress"
  security_group_id        = aws_security_group.mongo.id
  from_port                = 27017
  to_port                  = 27017
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
  description              = "MongoDB access restricted to EKS worker nodes only"
}

resource "aws_security_group_rule" "mongo_egress" {
  type              = "egress"
  security_group_id = aws_security_group.mongo.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Outbound for package installs and S3 backup uploads"
}

# --- IAM: deliberately over-permissive --------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongo" {
  name               = "${local.name}-mongo-vm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge(local.tags, {
    ExerciseRequirement = "overly-permissive-instance-role"
  })
}

# INTENTIONAL: full administrator on the instance profile. This is what lets a
# compromise of the VM pivot to creating EC2 instances, IAM users, etc.
resource "aws_iam_role_policy_attachment" "mongo_admin" {
  role       = aws_iam_role.mongo.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "mongo" {
  name = "${local.name}-mongo-vm"
  role = aws_iam_role.mongo.name
  tags = local.tags
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "mongo" {
  ami                         = data.aws_ami.ubuntu_outdated.id
  instance_type               = var.mongo_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.mongo.id]
  key_name                    = aws_key_pair.mongo.key_name
  iam_instance_profile        = aws_iam_instance_profile.mongo.name
  associate_public_ip_address = true

  # PREVENTATIVE CONTROL: IMDSv2 only.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/mongo_bootstrap.sh.tftpl", {
    mongo_version  = var.mongo_version
    ubuntu_release = var.ubuntu_release
    backup_bucket  = aws_s3_bucket.backups.id
    region         = var.region
    admin_user     = "wizadmin"
    admin_password = random_password.mongo_admin.result
    app_user       = "todoapp"
    app_password   = random_password.mongo_app.result
    app_database   = "wizdemo"
  })

  tags = merge(local.tags, {
    Name                = "${local.name}-mongodb"
    ExerciseRequirement = "outdated-os-and-database"
  })
}

locals {
  mongodb_uri = format(
    "mongodb://%s:%s@%s:27017/%s?authSource=%s",
    "todoapp",
    random_password.mongo_app.result,
    aws_instance.mongo.private_ip,
    "wizdemo",
    "wizdemo"
  )
}
