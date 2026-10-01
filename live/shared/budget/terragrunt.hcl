# The subscription budget: one monthly number across dev, stage and prod, with
# an action group that emails and does nothing else. Step 5 of v0-bootstrap.
#
# Applied by hand, like live/shared/identity. The alert address is read from
# the environment, so CI -- which does not have it -- never plans this unit.
# See COST.md for the amount and the thresholds.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/modules/budget"
}

# The action group needs a resource group, and the baseline owns it.
dependency "baseline" {
  config_path = "../baseline"

  mock_outputs = {
    shared_resource_group_name = "rg-pulsegate-shared"
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  project             = include.root.locals.project
  resource_group_name = dependency.baseline.outputs.shared_resource_group_name
  start_date          = "2026-09-01T00:00:00Z"

  # No default: a missing address should fail the plan, not create a budget
  # that alerts nobody.
  alert_email = get_env("AZURE_BUDGET_EMAIL")
}
