# spacelift-opentofu-demo

A small OpenTofu configuration for learning Spacelift hands-on: create a
stack, run plans and applies, attach policies, and practice the full
PR-driven workflow — all without needing any cloud credentials.

## What it does

Generates a release name and port with the `random` provider and renders a
`release-manifest.json` with the `local` provider. Trivial on purpose: every
resource is safe, free, and visible in the plan output, so the focus stays
on the workflow (proposed vs tracked runs, confirmation, policies) rather
than on the infrastructure itself.

## Using it with Spacelift

1. Create a stack pointing at this repo, branch `main`, project root `/`.
2. Choose **OpenTofu** as the vendor.
3. Trigger a run: review the plan, confirm, and watch the apply.
4. Open a PR changing `environment` or `service_name` to see a proposed
   run post its plan back to the PR.
5. Attach `policies/plan-warn-on-delete.rego` as a **Plan** policy, then
   remove a resource in a branch and watch the warning fire.

## Layout

- `main.tf` — the resources (random + local providers only)
- `variables.tf` — environment/service inputs, with validation
- `outputs.tf` — release name, port, manifest path
- `versions.tf` — OpenTofu/provider version constraints
- `policies/` — example Spacelift OPA policies (not applied automatically;
  attach through Spacelift)
