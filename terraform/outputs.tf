output "shop_instance_id" {
  value = aws_instance.shop.id
}

locals {
  shop_public_ip = var.enable_elastic_ip ? aws_eip.shop[0].public_ip : aws_instance.shop.public_ip
}

output "shop_url" {
  value = "http://${local.shop_public_ip}:8080"
}

output "shop_host_name" {
  description = "host.name the collector reports (resource detection uses the FQDN)"
  value       = aws_instance.shop.private_dns
}

output "archive_bucket" {
  value = var.enable_s3_archive ? aws_s3_bucket.archive[0].id : ""
}

output "account_id" {
  value = data.aws_caller_identity.me.account_id
}
