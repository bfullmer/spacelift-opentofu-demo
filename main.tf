terraform {
  # Written for OpenTofu (tofu >= 1.6); also valid HCL for Terraform >= 1.5.
  # Single required_providers block for the whole module - OpenTofu allows
  # only one, so aws/random/local all live here.
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned below the latest minor: v6.61.0 shipped 2026-08-19 with no
      # linux_amd64 package on the registry (upstream publishing issue, not
      # a config problem here) and broke every run until pinned back.
      version = "~> 6.60.0"
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

provider "aws" {
  alias  = "oregon"
  region = "us-west-2"
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

variable "subnet_id_oregon" {
  type        = string
  description = "ID of the Oregon (us-west-2) subnet from networking stack"
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

data "aws_subnet" "selected_oregon" {
  provider = aws.oregon
  id       = var.subnet_id_oregon
}

resource "aws_key_pair" "app" {
  key_name   = "moonlight-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"

  tags = {
    Name    = "Moonlight App Key"
    project = "Moonlight"
  }
}

# Key pairs are region-scoped, so the Oregon duplicate needs its own -
# same public key material, same private key on Brett's machine works for
# both regions.
resource "aws_key_pair" "app_oregon" {
  provider   = aws.oregon
  key_name   = "moonlight-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"

  tags = {
    Name    = "Moonlight App Key (Oregon)"
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

# Security groups are region/VPC-scoped, so the Oregon duplicate needs its
# own, identical in rules.
resource "aws_security_group" "web_oregon" {
  provider    = aws.oregon
  name        = "moonlight-web-sg"
  description = "WordPress servers: HTTP/HTTPS/SSH from approved admin IP only"
  vpc_id      = data.aws_subnet.selected_oregon.vpc_id

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
    Name    = "Moonlight Web SG (Oregon)"
    project = "Moonlight"
  }
}

# AMI is PINNED (not most_recent) - a most_recent lookup silently replaced
# an entire running fleet mid-session once already (2026-08-19) when AWS
# published a new image. See ~/.claude/skills/orbit-labs for the story.
variable "ami_id" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI for the web fleet (us-east-1)."
  default     = "ami-02b3d83d84b07786d"
}

# AMI IDs are region-specific - the us-east-1 pin above doesn't exist in
# us-west-2. This data source is a ONE-TIME lookup to discover the current
# Oregon AL2023 AMI ID; the very next commit after this apply hardcodes the
# resolved value as a pinned default (see ami_id above) and removes this
# data source, so it never runs on a later apply and can't cause the same
# fleet-replacement surprise most_recent caused in us-east-1.
data "aws_ami" "al2023_oregon" {
  provider    = aws.oregon
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

output "ami_id_oregon_resolved" {
  description = "Oregon AMI ID resolved by the one-time lookup above - pin this as a fixed default in the next commit, then delete the data source."
  value       = data.aws_ami.al2023_oregon.id
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

      # No index.html redirect trick here (unlike the old phpinfo lab): WordPress's
      # own index.php already IS the front controller and 301-redirects back to
      # "/" on its own. An index.html meta-refreshing to index.php fights that
      # canonical redirect and creates an infinite loop.
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

  # Oregon duplicate: identical script, "-or" appended to each hostname so
  # sandbox-or.brettfullmer.com etc. never collides with the us-east-1
  # sandbox.brettfullmer.com already in use.
  web_user_data_oregon = {
    for env in var.web_environments : env => <<-EOF
      #!/bin/bash
      HOSTNAME="${env}-or.${var.dns_zone}"

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

      chown -R apache:apache /var/www/html

      curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
      chmod +x wp-cli.phar
      mv wp-cli.phar /usr/local/bin/wp

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

resource "aws_instance" "web_oregon" {
  provider = aws.oregon
  for_each = toset(var.web_environments)

  ami                    = data.aws_ami.al2023_oregon.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id_oregon
  vpc_security_group_ids = [aws_security_group.web_oregon.id]
  key_name               = aws_key_pair.app_oregon.key_name

  user_data                   = local.web_user_data_oregon[each.key]
  user_data_replace_on_change = false

  tags = {
    Name        = "moonlight-web-${each.key}-or"
    environment = each.key
    region      = "oregon"
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

output "web_urls_oregon" {
  description = "WordPress URL per environment, Oregon duplicate"
  value = {
    for env in var.web_environments : env => "https://${env}-or.${var.dns_zone}/"
  }
}

output "web_public_ips_oregon" {
  description = "Public IP per environment, Oregon duplicate"
  value = {
    for env, inst in aws_instance.web_oregon : env => inst.public_ip
  }
}

output "web_hosts_entries_oregon" {
  description = "Lines to add to /etc/hosts for the Oregon duplicate"
  value = {
    for env, inst in aws_instance.web_oregon : env => "${inst.public_ip} ${env}-or.${var.dns_zone}"
  }
}
