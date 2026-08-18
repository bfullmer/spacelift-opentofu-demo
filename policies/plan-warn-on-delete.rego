# Spacelift plan policy: warn on any resource deletion, deny deletes in
# production. Attach as a "Plan" policy type. Reference:
# https://docs.spacelift.io/concepts/policy/terraform-plan-policy
package spacelift

deletes[resource] {
  some resource
  input.terraform.resource_changes[resource].change.actions[_] == "delete"
}

warn[sprintf("resource will be deleted: %s", [r])] {
  deletes[r]
}

deny[sprintf("deletions are blocked in production: %s", [r])] {
  deletes[r]
  input.spacelift.stack.labels[_] == "env:production"
}
