variable "subnet_id" {
  type        = string
  description = "ID of the subnet from networking stack"
}

terraform {
  # Written for OpenTofu (tofu >= 1.6); also valid HCL for Terraform >= 1.5.
  # Single required_providers block for the whole module - OpenTofu allows
  # only one, so aws/random/local all live here.
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Read-only proof the Spacelift AWS integration works: queries the caller
# identity, creates nothing, costs nothing.
data "aws_caller_identity" "current" {}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

resource "random_pet" "release_name" {
  length    = 2
  separator = "-"
  keepers = {
    environment = var.environment
  }
}

resource "random_integer" "port" {
  min = 3000
  max = 3999
  keepers = {
    environment = var.environment
  }
}

resource "local_file" "release_manifest" {
  filename = "${path.module}/release-manifest.json"
  content = jsonencode({
    service     = var.service_name
    environment = var.environment
    release     = random_pet.release_name.id
    port        = random_integer.port.result
  })
}

variable "web_environments" {
  type        = list(string)
  description = "Environments to run a web server for."
  default     = ["prod", "dev", "test"]
}

variable "admin_ingress_cidr" {
  type        = string
  description = "CIDR allowed to reach the web servers over HTTP and SSH."
  # Brett's public IP as of 2026-08-19. Override with
  # TF_VAR_admin_ingress_cidr in the Spacelift environment if it changes.
  default = "164.152.178.200/32"
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_key_pair" "app" {
  key_name   = "orbit-labs-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"

  tags = {
    name    = "Orbit Labs App Key"
    project = "Orbit-labs"
  }
}

resource "aws_security_group" "web" {
  name        = "orbit-labs-web-sg"
  description = "Web servers: HTTP and SSH from approved admin IP only"
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    description = "HTTP from approved admin IP only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "SSH from approved admin IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  egress {
    description = "All outbound (package installs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    name    = "Orbit Labs Web SG"
    project = "Orbit-labs"
  }
}

# Latest Amazon Linux 2023 AMI, resolved at plan time - no hardcoded IDs.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web" {
  for_each = toset(var.web_environments)

  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.app.key_name

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y httpd php
    echo "<?php phpinfo();" > /var/www/html/index.php
    echo "<html><body><h1>Orbit Labs - ${each.key}</h1><a href=index.php>phpinfo</a></body></html>" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF

  tags = {
    name        = "orbit-labs-web-${each.key}"
    environment = each.key
    project     = "Orbit-labs"
  }
}

output "web_urls" {
  description = "phpinfo URL per environment"
  value = {
    for env, inst in aws_instance.web : env => "http://${inst.public_ip}/index.php"
  }
}

output "web_public_ips" {
  description = "Public IP per environment"
  value = {
    for env, inst in aws_instance.web : env => inst.public_ip
  }
}
