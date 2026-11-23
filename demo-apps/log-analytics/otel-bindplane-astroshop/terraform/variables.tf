# lab.sh passes every value from lab.env as TF_VAR_*; the defaults only matter when running terraform by hand.

variable "lab_name" {
  description = "Prefix for every AWS resource (lowercase letters, digits, hyphens)"
  type        = string
}

variable "owner" {
  description = "Owner tag on every resource"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile; empty = default credential chain"
  type        = string
  default     = ""
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "az" {
  description = "Availability zone for the shop host; empty = first AZ of the region"
  type        = string
  default     = ""
}

variable "ui_allowed_cidr" {
  description = "Who can reach the shop UI (port 8080). Use your own IP/32 unless the demo must be public"
  type        = string
}

variable "shop_instance_type" {
  type    = string
  default = "m6i.xlarge"
}

variable "shop_disk_gb" {
  type    = number
  default = 60
}

variable "demo_ref" {
  description = "opentelemetry-demo git tag (the overlay files are written for 3.1.0)"
  type        = string
  default     = "3.1.0"
}

variable "deployment_env" {
  description = "deployment.environment added to the shop's resource attributes"
  type        = string
}

variable "bindplane_opamp_url" {
  description = "OpAMP endpoint the collector connects to"
  type        = string
  default     = "wss://app.bindplane.com/v1/opamp"
}

variable "bindplane_secret_key" {
  description = "Bindplane collector secret key; stored as an SSM SecureString, never in user data"
  type        = string
  sensitive   = true
}

variable "collector_labels" {
  description = "Labels the collector registers with; configuration=<name> attaches it to its Bindplane configuration"
  type        = string
  default     = "configuration=otel-shop-agent,role=shop"
}

variable "bindplane_collector_version" {
  type    = string
  default = "1.110.2"
}

variable "enable_s3_archive" {
  type    = bool
  default = true
}

variable "enable_elastic_ip" {
  description = "Fixed public IP for the shop (uses one of the account's few Elastic IPs per region)"
  type        = bool
  default     = false
}
