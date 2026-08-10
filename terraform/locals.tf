locals {
  name = var.project

  tags = merge(
    {
      Project     = var.project
      Environment = "exercise"
      ManagedBy   = "terraform"
      Purpose     = "intentionally-vulnerable-security-demo"
      Owner       = "Rich Gardner"
    },
    var.tags
  )

  account_id = data.aws_caller_identity.current.account_id
}
