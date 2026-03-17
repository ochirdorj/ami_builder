variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment label used for resource naming and tagging (e.g. build, dev, prod)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "Environment must be lowercase alphanumeric and hyphens only."
  }
}

variable "vpc_id" {
  description = "VPC ID where the builder instance will be launched"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the builder instance will be launched (private subnet recommended)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "instance_type" {
  description = "Instance type for the AMI builder (t3.medium recommended for faster installs)"
  type        = string
}
