# One EC2 host: the Astronomy Shop (Docker Compose) plus the Bindplane-managed collector that collects everything on
# it and sends to Dynatrace. Access is SSM Session Manager only: no SSH key, no port 22.

data "aws_vpc" "default" {
  default = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_subnet" "lab" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.az != "" ? var.az : data.aws_availability_zones.available.names[0]
  default_for_az    = true
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_caller_identity" "me" {}

# ---------- Bindplane secret key: SecureString, read by the instance at boot ----------
resource "aws_ssm_parameter" "bindplane_secret" {
  name  = "/${var.lab_name}/bindplane-secret-key"
  type  = "SecureString"
  value = var.bindplane_secret_key
}

# ---------- IAM: SSM Session Manager + the secret parameter (+ S3 archive, see s3.tf) ----------
resource "aws_iam_role" "shop" {
  name = "${var.lab_name}-shop"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.shop.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The parameter uses the AWS-managed aws/ssm key, whose key policy already allows decryption through SSM.
resource "aws_iam_role_policy" "read_secret" {
  name = "${var.lab_name}-read-bindplane-secret"
  role = aws_iam_role.shop.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.bindplane_secret.arn
    }]
  })
}

resource "aws_iam_instance_profile" "shop" {
  name = "${var.lab_name}-shop"
  role = aws_iam_role.shop.name
}

# ---------- Security group: shop UI only ----------
resource "aws_security_group" "shop" {
  name        = "${var.lab_name}-shop"
  description = "Astronomy Shop: UI, load generator, feature flags, Grafana and Jaeger via envoy on 8080"
  vpc_id      = data.aws_vpc.default.id
  tags        = { Name = "${var.lab_name}-shop" }
}

resource "aws_vpc_security_group_ingress_rule" "shop_ui" {
  security_group_id = aws_security_group.shop.id
  cidr_ipv4         = var.ui_allowed_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "shop_all" {
  security_group_id = aws_security_group.shop.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- Shop host ----------
locals {
  # Overlay files travel inside the user data (gzip + base64) so the host needs nothing else from this repo.
  overlay = {
    "compose.override.yaml"     = base64gzip(file("${path.module}/../shop/compose.override.yaml"))
    "compose.lab-pii-logs.yaml" = base64gzip(file("${path.module}/../shop/compose.lab-pii-logs.yaml"))
    "pii-log-generator/gen.py"  = base64gzip(file("${path.module}/../shop/pii-log-generator/gen.py"))
  }
  # The PII generator's file is always listed; its service only starts with the "pii-demo" profile (./lab.sh pii on),
  # so switching it on or off never changes the user data (which would replace the instance).
  compose_files = join(":", [
    "compose.yaml", "compose.full.yaml", "compose.agent.yaml", "compose.observability.yaml", "compose.override.yaml",
    "compose.lab-pii-logs.yaml",
  ])
}

resource "aws_instance" "shop" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.shop_instance_type
  subnet_id                   = data.aws_subnet.lab.id
  vpc_security_group_ids      = [aws_security_group.shop.id]
  iam_instance_profile        = aws_iam_instance_profile.shop.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data_shop.sh.tftpl", {
    demo_ref          = var.demo_ref
    deployment_env    = var.deployment_env
    compose_files     = local.compose_files
    overlay           = local.overlay
    region            = var.region
    secret_param      = aws_ssm_parameter.bindplane_secret.name
    opamp_url         = var.bindplane_opamp_url
    collector_version = var.bindplane_collector_version
    collector_labels  = var.collector_labels
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.shop_disk_gb
    volume_type = "gp3"
  }

  tags = { Name = "${var.lab_name}-shop" }

  depends_on = [aws_iam_role_policy.read_secret]
}

# Optional stable public address (survives stop/start). Off by default: accounts have a small Elastic IP quota per
# region (AddressLimitExceeded), and the lab is built and destroyed on demand anyway.
resource "aws_eip" "shop" {
  count    = var.enable_elastic_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.shop.id
  tags     = { Name = "${var.lab_name}-shop" }
}
