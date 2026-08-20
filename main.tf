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

data "aws_caller_identity" "current" {}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

variable "subnet_ids" {
  type        = map(string)
  description = "Subnet IDs from the networking stack, keyed '<env>_east'. West (us-west-1) was removed 2026-08-20 - see git history for the two-region version."
}

variable "environments" {
  type        = list(string)
  description = "Environments: sandbox, staging, production. Narrowed to production only 2026-08-20 - sandbox/staging were the tested/disposable tier, torn down after testing. Every resource here is for_each'd over this list, so restoring an entry just means adding it back."
  default     = ["production"]
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

# Production gets its own independently-pinned AMI, separate from
# sandbox/staging - this is the knob to turn for a real AMI-swap test
# (change the default below to any other valid us-east-1 AMI ID and
# apply; the Elastic IP added earlier should re-associate automatically
# to the replacement instance). Resolved once via a temporary
# most_recent lookup on 2026-08-20, which turned up the same AMI already
# pinned for sandbox/staging - no newer AL2023 image has shipped since
# yesterday's pin, so this apply caused no actual replacement.
variable "ami_id_east_production" {
  type        = string
  description = "Pinned Amazon Linux 2023 AMI for production, us-east-1. Change this and apply to test an AMI swap."
  default     = "ami-02b3d83d84b07786d"
}

locals {
  ami_id_east = {
    sandbox    = var.ami_id_east
    staging    = var.ami_id_east
    production = var.ami_id_east_production
  }
}

data "aws_subnet" "east" {
  for_each = toset(var.environments)
  id       = var.subnet_ids["${each.key}_east"]
}

# Region-scoped, so one per region (shared across every environment in
# that region, not per-environment).
resource "aws_key_pair" "east" {
  key_name   = "moonlight-east-app"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmsrERSIAmACx6uxiePMYWsEuaMf/UbreaHE5YjVSTo orbit-labs-app"
  tags = {
    Name    = "Moonlight East App Key"
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

# Shared secret between each environment's east-db and east-web (two
# independent instances, no coordination channel between their boot
# scripts) - Terraform-managed rather than on-box, same tradeoff made for
# Orbit Labs' prod tier. `special = false` avoids any quote-escaping risk
# in the generated SQL. WordPress *admin* passwords stay on-box generated
# (see boot script below) since SSH is available on every instance this
# time - no need to route them through Terraform state.
resource "random_password" "east_db" {
  for_each = toset(var.environments)
  length   = 24
  special  = false
}

locals {
  # Production runs a bigger instance than sandbox/staging. instance_type
  # is an in-place Terraform update (not ForceNew) - same instance ID,
  # same private IP, no replacement. The public IP would still churn on
  # the stop/start a resize requires, unless an Elastic IP is attached
  # (see aws_eip.east_web_prod below) - EIPs stay associated across a
  # stop/start by design.
  #
  # t3.medium was attempted 2026-08-20 and rejected outright by AWS:
  # "FreeTierRestrictionError: This operation is not available for free
  # plan accounts." Brett's own EC2 > Instance Types console page shows
  # t3.small (unlike t3.medium) marked "Free tier eligible: true" on this
  # account, so that's what's running now - a real step up (2x the memory
  # of micro) without assuming the blanket "nothing above micro"
  # conclusion drawn from the medium rejection alone.
  instance_type = {
    sandbox    = "t3.micro"
    staging    = "t3.micro"
    production = "t3.small"
  }

  # East web and db share one subnet (cidrsubnet(base, 8, 0)) in this
  # build - a leftover from an earlier draft with a separate private /24
  # briefly gave this the wrong octet (.1.%) and broke every db grant
  # until fixed live via RENAME USER; fixed here too so a rebuild doesn't
  # reintroduce it.
  east_db_host_pattern = {
    sandbox    = "10.10.0.%"
    staging    = "10.20.0.%"
    production = "10.30.0.%"
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
}

resource "aws_instance" "east_db" {
  for_each               = toset(var.environments)
  ami                    = local.ami_id_east[each.key]
  instance_type          = local.instance_type[each.key]
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
  ami                    = local.ami_id_east[each.key]
  instance_type          = local.instance_type[each.key]
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

# Production-only Elastic IP: nothing else in this build gets one -
# sandbox/staging stay disposable and cheap to churn. Without this, a
# future instance_type or AMI change on production would silently lose
# its public address the same way Orbit Labs' fleet did earlier this
# session. The db instance doesn't need one - nothing external connects
# to it directly.
resource "aws_eip" "east_web_prod" {
  instance = aws_instance.east_web["production"].id
  domain   = "vpc"
  tags = {
    Name    = "Moonlight production East Web EIP"
    project = "Moonlight"
  }
}

# Recovery from the rejected t3.medium attempt: AWS stops an instance
# before attempting an instance-type change, then rejects the change
# itself on a free-tier account, leaving the instance stopped with its
# type unchanged. A plain revert of instance_type doesn't undo that stop
# by itself (Terraform doesn't treat running/stopped as part of the
# instance_type diff), so this explicitly forces production's instances
# back to running regardless of which ones actually got stopped. No-op
# (and harmless) for any already running.
resource "aws_ec2_instance_state" "east_db_prod" {
  instance_id = aws_instance.east_db["production"].id
  state       = "running"
}

resource "aws_ec2_instance_state" "east_web_prod" {
  instance_id = aws_instance.east_web["production"].id
  state       = "running"
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

output "east_db_public_ips" {
  description = "Public IPs of the East db instances (SSH-reachable from admin IP only, for management)."
  value = {
    for env, inst in aws_instance.east_db : env => inst.public_ip
  }
}

output "all_hosts_entries" {
  description = "Lines to add to /etc/hosts for local warning-free HTTPS access."
  value = {
    for env, inst in aws_instance.east_web : "${env}-east" => "${inst.public_ip} ${env}-east.${var.dns_zone}"
  }
}
