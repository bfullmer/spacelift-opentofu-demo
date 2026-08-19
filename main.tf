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

resource "aws_s3_bucket" "orbit_storage" {
  bucket_prefix = "orbit-storage-"

  tags = {
    name        = "Orbit Labs Storage"
    managedBy   = "Spacelift"
    mission     = "First Launch"
    project     = "Orbit-labs"
    environment = "demo"
  }
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to SSH to the app instances (Brett's IP /32)."
  # Brett's public IP as of 2026-08-18. Update if your ISP reassigns it,
  # or override with TF_VAR_ssh_ingress_cidr in the Spacelift environment.
  default = "164.152.178.200/32"
}

resource "aws_key_pair" "app" {
  key_name   = "orbit-labs-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"

  tags = {
    name    = "Orbit Labs App Key"
    project = "Orbit-labs"
  }
}

resource "aws_security_group" "app" {
  name        = "orbit-labs-app-sg"
  description = "Security group for Orbit Labs app"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "SSH from Brett's IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    name    = "Orbit Labs App SG"
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

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.app.key_name

  tags = {
    name    = "Orbit Labs App Server"
    project = "Orbit-labs"
  }
}

output "instance_id" {
  value       = aws_instance.app.id
  description = "ID of the app EC2 instance"
}

output "instance_private_ip" {
  value       = aws_instance.app.private_ip
  description = "Private IP of the app EC2 instance"
}

output "instance_public_ip" {
  value       = aws_instance.app.public_ip
  description = "Public IP of the app EC2 instance"
}

resource "aws_instance" "app_2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.app.key_name

  tags = {
    name    = "Orbit Labs App Server 2"
    project = "Orbit-labs"
  }
}

output "instance_2_id" {
  value       = aws_instance.app_2.id
  description = "ID of the second app EC2 instance"
}

output "instance_2_private_ip" {
  value       = aws_instance.app_2.private_ip
  description = "Private IP of the second app EC2 instance"
}

output "instance_2_public_ip" {
  value       = aws_instance.app_2.public_ip
  description = "Public IP of the second app EC2 instance"
}
