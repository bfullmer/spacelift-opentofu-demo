terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned below v6.61.0 (shipped 2026-08-19 with no linux_amd64
      # package on the registry).
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

# Kept during teardown even though no resources reference it: Terraform
# needs a provider's config present to destroy resources created with it.
# The previous commit removed this alias while west resources were still
# in state, which orphaned them and failed the run - re-added here so the
# full teardown can actually destroy them. Drop both this and the east
# provider in a follow-up only after the destroy completes clean.
provider "aws" {
  alias  = "west"
  region = "us-west-1"
}

# Full lab teardown (2026-08-20): Moonlight multi-region lab is done.
# Everything - production included - is removed. The full two-region,
# three-environment configuration lives in git history (commit 4dea573
# and earlier); ~/.claude/skills/orbit-labs has the general rebuild
# lessons (stack dependency wiring, AMI pinning, provider-kept-during-
# teardown, EIP behavior).
