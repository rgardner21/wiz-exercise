terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.60" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    local      = { source = "hashicorp/local", version = "~> 2.5" }
  }

  # Remote state. Bootstrap this bucket + DynamoDB table once, out of band,
  # then supply values with `terraform init -backend-config=backend.hcl`.
  backend "s3" {}
}
