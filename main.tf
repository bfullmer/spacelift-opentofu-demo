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

variable "subnet_id" {
  type        = string
  description = "ID of the subnet from networking stack"
}

variable "web_environments" {
  type        = list(string)
  description = "Environments to run a WordPress server for."
  default     = ["sandbox", "staging", "production"]
}

variable "admin_ingress_cidr" {
  type        = string
  description = "CIDR allowed to reach the web servers over HTTP, HTTPS, and SSH."
  # Brett's public IP as of 2026-08-19. Override with
  # TF_VAR_admin_ingress_cidr in the Spacelift environment if it changes.
  default = "164.152.178.200/32"
}

variable "dns_zone" {
  type        = string
  description = "Domain suffix used for each environment's self-signed cert and local /etc/hosts entry."
  default     = "brettfullmer.com"
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_key_pair" "app" {
  key_name   = "moonlight-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"

  tags = {
    Name    = "Moonlight App Key"
    project = "Moonlight"
  }
}

resource "aws_security_group" "web" {
  name        = "moonlight-web-sg"
  description = "WordPress servers: HTTP/HTTPS/SSH from approved admin IP only"
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    description = "HTTP from approved admin IP only (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "HTTPS from approved admin IP only"
    from_port   = 443
    to_port     = 443
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
    Name    = "Moonlight Web SG"
    project = "Moonlight"
  }
}

# AMI is PINNED (not most_recent) - a most_recent lookup silently replaced
# an entire running fleet mid-session once already (2026-08-19) when AWS
# published a new image. See ~/.claude/skills/orbit-labs for the story.
variable "ami_id" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI for the web fleet."
  default     = "ami-02b3d83d84b07786d"
}

locals {
  # Each environment is fully self-contained: its own local MariaDB, its
  # own on-box-generated password (never leaves the instance, never touches
  # Terraform state), its own WordPress install. No shared DB tier - this
  # is a theme-development lab, not a durability exercise, so the simpler
  # conservative pattern wins over Orbit Labs' prod/dedicated-DB split.
  #
  # The hostname is baked into the self-signed cert AND the HTTPS redirect
  # at boot time (env.brettfullmer.com), rather than generated against the
  # instance's public IP and fixed up after the fact - this lab's hostnames
  # are known in advance, so there's no need for the extra manual step.
  web_user_data = {
    for env in var.web_environments : env => <<-EOF
      #!/bin/bash
      HOSTNAME="${env}.${var.dns_zone}"

      dnf install -y httpd php php-mysqlnd mod_ssl openssl mariadb105-server
      systemctl enable --now mariadb

      DBPASS=$(openssl rand -base64 18)
      mysql <<SQL
      CREATE DATABASE IF NOT EXISTS wordpress;
      CREATE USER IF NOT EXISTS 'wpuser'@'localhost' IDENTIFIED BY '$DBPASS';
      GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
      FLUSH PRIVILEGES;
      SQL

      cd /tmp
      curl -sO https://wordpress.org/latest.tar.gz
      tar xzf latest.tar.gz
      rm -f /var/www/html/index.html /var/www/html/index.php
      cp -rf wordpress/* /var/www/html/
      cd /var/www/html
      cp -f wp-config-sample.php wp-config.php
      sed -i "s/database_name_here/wordpress/; s/username_here/wpuser/; s#password_here#$DBPASS#" wp-config.php

      python3 - <<'PY'
      import urllib.request
      salts = urllib.request.urlopen('https://api.wordpress.org/secret-key/1.1/salt/').read().decode()
      p = '/var/www/html/wp-config.php'
      out = []
      done = False
      for l in open(p):
          if 'put your unique phrase here' in l:
              if not done:
                  out.append(salts + '\n')
                  done = True
              continue
          out.append(l)
      open(p, 'w').write(''.join(out))
      PY

      echo '<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0; url=index.php"></head><body>Redirecting...</body></html>' > /var/www/html/index.html

      chown -R apache:apache /var/www/html

      # wp-cli, for theme scaffolding/activation/debugging from the shell.
      curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
      chmod +x wp-cli.phar
      mv wp-cli.phar /usr/local/bin/wp

      # Self-signed cert keyed to the real hostname, known up front.
      openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -keyout /etc/pki/tls/private/localhost.key \
        -out /etc/pki/tls/certs/localhost.crt \
        -subj "/CN=$HOSTNAME" -addext "subjectAltName=DNS:$HOSTNAME"

      cat > /etc/httpd/conf.d/redirect-https.conf <<CONF
      <VirtualHost *:80>
        RewriteEngine On
        RewriteRule ^(.*)$ https://$HOSTNAME\$1 [R=301,L]
      </VirtualHost>
      CONF

      systemctl enable --now httpd
    EOF
  }
}

resource "aws_instance" "web" {
  for_each = toset(var.web_environments)

  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.app.key_name

  user_data                   = local.web_user_data[each.key]
  user_data_replace_on_change = false

  tags = {
    Name        = "moonlight-web-${each.key}"
    environment = each.key
    project     = "Moonlight"
  }
}

output "web_urls" {
  description = "WordPress URL per environment (hostname, HTTPS, self-signed cert)"
  value = {
    for env in var.web_environments : env => "https://${env}.${var.dns_zone}/"
  }
}

output "web_public_ips" {
  description = "Public IP per environment"
  value = {
    for env, inst in aws_instance.web : env => inst.public_ip
  }
}

output "web_hosts_entries" {
  description = "Lines to add to /etc/hosts for local warning-free HTTPS access"
  value = {
    for env, inst in aws_instance.web : env => "${inst.public_ip} ${env}.${var.dns_zone}"
  }
}
