# Minimal, credential-free config: safe to plan/apply from any Spacelift
# worker with no cloud account attached. Cloud resources come later via a
# Spacelift AWS integration (OIDC), not static keys.

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
