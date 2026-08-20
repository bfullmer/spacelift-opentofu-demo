terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned below v6.61.0 (shipped 2026-08-19 with no linux_amd64
      # package on the registry).
      version = "~> 6.60.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Single self-contained stack this time: own VPC, one instance. No second
# networking stack, no Spacelift stack-dependency wiring - that pattern
# was exercised thoroughly in the Moonlight lab (see git history); this
# build optimizes for simplicity instead.

variable "admin_ingress_cidr" {
  type        = string
  description = "CIDR allowed to SSH in. HTTPS (443) is open to the internet by design; SSH stays admin-only."
  # Brett's public IP as of 2026-08-20.
  default = "164.152.178.200/32"
}

# Pinned AMI (never most_recent - an unpinned lookup once replaced an
# entire running fleet mid-session when AWS published a new image).
variable "ami_id" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI, us-east-1."
  default     = "ami-02b3d83d84b07786d"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name    = "pulsar-vpc"
    project = "Pulsar"
  }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.40.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
    Name    = "pulsar-subnet"
    project = "Pulsar"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "pulsar-igw"
    project = "Pulsar"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "pulsar-rt"
    project = "Pulsar"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.public.id
}

resource "aws_key_pair" "main" {
  key_name   = "pulsar-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"
  tags = {
    Name    = "Pulsar App Key"
    project = "Pulsar"
  }
}

resource "aws_security_group" "web" {
  name        = "pulsar-web-sg"
  description = "HTTPS open to the internet; SSH from admin IP only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from anywhere - intentionally public"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere - required for Lets Encrypt HTTP-01 validation and the 80-443 redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from admin IP only"
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
    Name    = "Pulsar Web SG"
    project = "Pulsar"
  }
}

resource "aws_instance" "web" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.main.key_name

  user_data                   = <<-EOF
    #!/bin/bash
    dnf install -y httpd mod_ssl openssl

    TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    PUBIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout /etc/pki/tls/private/localhost.key \
      -out /etc/pki/tls/certs/localhost.crt \
      -subj "/CN=$PUBIP" -addext "subjectAltName=IP:$PUBIP"

    cat > /var/www/html/index.html <<HTMLEOF
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Pulsar</title>
    <style>
      :root { color-scheme: light dark; }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 1.5rem;
        font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
        background: #0f172a;
        color: #e2e8f0;
      }
      main {
        max-width: 32rem;
        width: 100%;
        text-align: center;
      }
      h1 {
        font-size: clamp(1.75rem, 6vw, 2.75rem);
        margin: 0 0 0.5rem;
      }
      p {
        font-size: clamp(0.95rem, 3vw, 1.1rem);
        color: #94a3b8;
        word-break: break-word;
      }
    </style>
    </head>
    <body>
    <main>
      <h1>Pulsar</h1>
      <p>Served over HTTPS from $PUBIP</p>
    </main>
    </body>
    </html>
    HTMLEOF

    systemctl enable --now httpd
  EOF
  user_data_replace_on_change = false

  tags = {
    Name    = "pulsar-web"
    project = "Pulsar"
  }
}

# Elastic IP so the public address survives stop/starts, resizes, and
# AMI swaps. Attaching an EIP replaces the instance's original
# auto-assigned public IP with the EIP's address - the old IP is
# released, so anything pointing at it (like the boot-time self-signed
# cert's CN) refers to a dead address afterward and needs regenerating.
resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
  tags = {
    Name    = "pulsar-web-eip"
    project = "Pulsar"
  }
}

# Instance power state, managed declaratively. "stopped" halts compute
# billing while keeping the instance, its disk, and the Elastic IP
# association intact - flip back to "running" and apply to bring it up
# on the same address. Note: an EIP attached to a STOPPED instance
# accrues AWS's idle-EIP charge (~$0.005/hr) until the instance runs
# again or the EIP is released.
resource "aws_ec2_instance_state" "web" {
  instance_id = aws_instance.web.id
  state       = "running"
}

output "public_ip" {
  description = "Stable Elastic IP."
  value       = aws_eip.web.public_ip
}

output "https_url" {
  description = "Open to the internet (self-signed cert, expect a browser warning)."
  value       = "https://${aws_eip.web.public_ip}/"
}

output "ssh_command" {
  description = "SSH access, admin IP only."
  value       = "ssh -i ~/.ssh/orbit-labs-app ec2-user@${aws_eip.web.public_ip}"
}
