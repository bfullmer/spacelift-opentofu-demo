terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned below the latest minor: v6.61.0 shipped 2026-08-19 with no
      # linux_amd64 package on the registry (upstream publishing issue).
      version = "~> 6.60.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "west"
  region = "us-west-1"
}

data "aws_caller_identity" "current" {}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

variable "subnet_ids" {
  type        = map(string)
  description = "Subnet IDs from the networking stack, keyed '<env>_east' / '<env>_west'."
}

variable "environments" {
  type        = list(string)
  description = "Environments: sandbox, staging, production."
  default     = ["sandbox", "staging", "production"]
}

variable "admin_ingress_cidr" {
  type        = string
  description = "CIDR allowed to reach every web/db server over HTTP/HTTPS/SSH."
  # Brett's public IP as of 2026-08-19.
  default = "164.152.178.200/32"
}

variable "dns_zone" {
  type        = string
  description = "Domain suffix for self-signed certs and /etc/hosts entries."
  default     = "brettfullmer.com"
}

# AMI is PINNED for us-east-1: same region, same ID proven across every
# build this session.
variable "ami_id_east" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI, us-east-1."
  default     = "ami-02b3d83d84b07786d"
}

# us-west-1 (California) is a brand-new region for this build - distinct
# from the us-west-2 (Oregon) region Moonlight used. One-time most_recent
# lookup to discover the current AL2023 AMI ID; the very next commit
# hardcodes the resolved value and deletes this data source - same
# discipline used for Oregon earlier, after an unpinned most_recent lookup
# once silently replaced an entire running fleet mid-session.
data "aws_ami" "al2023_west" {
  provider    = aws.west
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

output "ami_id_west_resolved" {
  description = "Pin this as a fixed default in the next commit, then delete the data source above."
  value       = data.aws_ami.al2023_west.id
}

data "aws_subnet" "east" {
  for_each = toset(var.environments)
  id       = var.subnet_ids["${each.key}_east"]
}

data "aws_subnet" "west" {
  for_each = toset(var.environments)
  provider = aws.west
  id       = var.subnet_ids["${each.key}_west"]
}

# Key pairs are region-scoped, so one per region (shared across all 3
# environments in that region, not per-environment).
resource "aws_key_pair" "east" {
  key_name   = "moonlight-east-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"
  tags = {
    Name    = "Moonlight East App Key"
    project = "Moonlight"
  }
}

resource "aws_key_pair" "west" {
  provider   = aws.west
  key_name   = "moonlight-west-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"
  tags = {
    Name    = "Moonlight West App Key"
    project = "Moonlight"
  }
}

resource "aws_security_group" "east_web" {
  for_each    = toset(var.environments)
  name        = "moonlight-${each.key}-east-web-sg"
  description = "East web tier: HTTP/HTTPS/SSH from admin IP only."
  vpc_id      = data.aws_subnet.east[each.key].vpc_id

  ingress {
    description = "HTTP from admin IP (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "HTTPS from admin IP"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "SSH from admin IP"
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
    Name    = "Moonlight ${each.key} East Web SG"
    project = "Moonlight"
  }
}

resource "aws_security_group" "east_db" {
  for_each    = toset(var.environments)
  name        = "moonlight-${each.key}-east-db-sg"
  description = "East db tier: MariaDB from east web SG only, SSH from admin IP."
  vpc_id      = data.aws_subnet.east[each.key].vpc_id

  ingress {
    description     = "MariaDB from east web SG only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.east_web[each.key].id]
  }

  ingress {
    description = "SSH from admin IP"
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
    Name    = "Moonlight ${each.key} East DB SG"
    project = "Moonlight"
  }
}

resource "aws_security_group" "west_web" {
  for_each    = toset(var.environments)
  provider    = aws.west
  name        = "moonlight-${each.key}-west-web-sg"
  description = "West web tier: HTTP/HTTPS/SSH from admin IP only."
  vpc_id      = data.aws_subnet.west[each.key].vpc_id

  ingress {
    description = "HTTP from admin IP (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "HTTPS from admin IP"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ingress_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "Moonlight ${each.key} West Web SG"
    project = "Moonlight"
  }
}

# Shared secret between each environment's east-db and east-web (two
# independent instances, no coordination channel between their boot
# scripts) - Terraform-managed rather than on-box, same tradeoff made for
# Orbit Labs' prod tier. `special = false` avoids any quote-escaping risk
# in the generated SQL. WordPress *admin* passwords stay on-box generated
# (see boot scripts below) since SSH is available on every instance this
# time - no need to route them through Terraform state.
resource "random_password" "east_db" {
  for_each = toset(var.environments)
  length   = 24
  special  = false
}

locals {
  east_db_host_pattern = {
    sandbox    = "10.10.1.%"
    staging    = "10.20.1.%"
    production = "10.30.1.%"
  }

  east_web_user_data = {
    for env in var.environments : env => <<-EOF
      #!/bin/bash
      HOSTNAME="${env}-east.${var.dns_zone}"

      dnf install -y httpd php php-mysqlnd mod_ssl openssl

      cd /tmp
      curl -sO https://wordpress.org/latest.tar.gz
      tar xzf latest.tar.gz
      rm -f /var/www/html/index.html /var/www/html/index.php
      cp -rf wordpress/* /var/www/html/
      cd /var/www/html
      cp -f wp-config-sample.php wp-config.php
      sed -i "s/database_name_here/wordpress/; s/username_here/wpuser/; s#password_here#${random_password.east_db[env].result}#; s/localhost/${aws_instance.east_db[env].private_ip}/" wp-config.php

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

  west_web_user_data = {
    for env in var.environments : env => <<-EOF
      #!/bin/bash
      HOSTNAME="${env}-west.${var.dns_zone}"

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

resource "aws_instance" "east_db" {
  for_each               = toset(var.environments)
  ami                    = var.ami_id_east
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_ids["${each.key}_east"]
  vpc_security_group_ids = [aws_security_group.east_db[each.key].id]
  key_name               = aws_key_pair.east.key_name

  user_data                   = <<-EOF
    #!/bin/bash
    dnf install -y mariadb105-server
    systemctl enable --now mariadb
    mysql <<SQL
    CREATE DATABASE IF NOT EXISTS wordpress;
    CREATE USER IF NOT EXISTS 'wpuser'@'${local.east_db_host_pattern[each.key]}' IDENTIFIED BY '${random_password.east_db[each.key].result}';
    GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'${local.east_db_host_pattern[each.key]}';
    FLUSH PRIVILEGES;
    SQL
  EOF
  user_data_replace_on_change = false

  tags = {
    Name    = "moonlight-${each.key}-east-db"
    env     = each.key
    tier    = "db"
    region  = "east"
    project = "Moonlight"
  }
}

resource "aws_instance" "east_web" {
  for_each               = toset(var.environments)
  ami                    = var.ami_id_east
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_ids["${each.key}_east"]
  vpc_security_group_ids = [aws_security_group.east_web[each.key].id]
  key_name               = aws_key_pair.east.key_name

  user_data                   = local.east_web_user_data[each.key]
  user_data_replace_on_change = false

  tags = {
    Name    = "moonlight-${each.key}-east-web"
    env     = each.key
    tier    = "web"
    region  = "east"
    project = "Moonlight"
  }
}

resource "aws_instance" "west_web" {
  for_each               = toset(var.environments)
  provider               = aws.west
  ami                    = data.aws_ami.al2023_west.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_ids["${each.key}_west"]
  vpc_security_group_ids = [aws_security_group.west_web[each.key].id]
  key_name               = aws_key_pair.west.key_name

  user_data                   = local.west_web_user_data[each.key]
  user_data_replace_on_change = false

  tags = {
    Name    = "moonlight-${each.key}-west-web"
    env     = each.key
    tier    = "web"
    region  = "west"
    project = "Moonlight"
  }
}

output "east_urls" {
  description = "WordPress URL per environment, East."
  value = {
    for env in var.environments : env => "https://${env}-east.${var.dns_zone}/"
  }
}

output "east_public_ips" {
  value = {
    for env, inst in aws_instance.east_web : env => inst.public_ip
  }
}

output "east_db_private_ips" {
  value = {
    for env, inst in aws_instance.east_db : env => inst.private_ip
  }
}

output "west_urls" {
  description = "WordPress URL per environment, West."
  value = {
    for env in var.environments : env => "https://${env}-west.${var.dns_zone}/"
  }
}

output "west_public_ips" {
  value = {
    for env, inst in aws_instance.west_web : env => inst.public_ip
  }
}

output "all_hosts_entries" {
  description = "Lines to add to /etc/hosts for local warning-free HTTPS access to all 6 web nodes."
  value = merge(
    { for env, inst in aws_instance.east_web : "${env}-east" => "${inst.public_ip} ${env}-east.${var.dns_zone}" },
    { for env, inst in aws_instance.west_web : "${env}-west" => "${inst.public_ip} ${env}-west.${var.dns_zone}" }
  )
}
