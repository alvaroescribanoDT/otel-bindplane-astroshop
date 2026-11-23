terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project = var.lab_name
      Owner   = var.owner
    }
  }

  # Some accounts stamp their own tags (e.g. ACE:CREATED-BY) on new resources; without this every plan would try to
  # remove them again.
  ignore_tags {
    key_prefixes = ["ACE:"]
  }
}
