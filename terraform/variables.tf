variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "wizex"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "eks_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "Instance type for EKS managed node group."
  type        = string
  default     = "t3.medium"
}

variable "mongo_instance_type" {
  description = "Instance type for the MongoDB VM."
  type        = string
  default     = "t3.small"
}

variable "mongo_version" {
  description = <<-EOT
    MongoDB major.minor to install. INTENTIONALLY OUT OF DATE for this exercise.
    4.4 reached end of life in February 2024, so it is well over a year outdated.
  EOT
  type        = string
  default     = "4.4"
}

variable "ubuntu_release" {
  description = <<-EOT
    Ubuntu codename for the MongoDB VM AMI. INTENTIONALLY OUT OF DATE.
    focal = Ubuntu 20.04 LTS, released April 2020.
  EOT
  type        = string
  default     = "focal"
}

variable "ssh_ingress_cidr" {
  description = <<-EOT
    CIDR permitted to reach SSH on the MongoDB VM. The exercise calls for SSH
    exposed to the public internet (0.0.0.0/0). Narrow this to your own /32 if
    you want the same finding with far less real-world risk.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  description = "OpenSSH public key installed on the MongoDB VM for the ubuntu user."
  type        = string
}

variable "alert_email" {
  description = "Email subscribed to the detective-control SNS topic."
  type        = string
}

variable "app_image" {
  description = "Container image for the todo app. Set by the app pipeline; placeholder on first apply."
  type        = string
  default     = ""
}

variable "backup_retention_days" {
  description = "Days before MongoDB backups expire from the public bucket."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
