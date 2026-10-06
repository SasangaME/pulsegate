locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  root = read_terragrunt_config(find_in_parent_folders("root.hcl")).locals

  # The address plan, all three environments side by side, because overlap is
  # only visible when they are read together. One /16 each, ten apart, so a
  # fourth environment or a v12-govern hub has room without renumbering.
  #
  # Kept off 10.0.0.0/16 and 10.244.0.0/16, AKS's default service and pod
  # CIDRs. With CNI Overlay neither range lives in the VNet, but both must not
  # overlap it, and v2-cluster should not have to move them to make room.
  address_spaces = {
    dev   = ["10.10.0.0/16"]
    stage = ["10.20.0.0/16"]
    prod  = ["10.30.0.0/16"]
  }
}

terraform {
  source = "${get_repo_root()}/modules/network"
}

# NSG flow and diagnostic settings go to the shared workspace, which the
# baseline owns.
dependency "baseline" {
  config_path = "${get_repo_root()}/live/shared/baseline"

  mock_outputs = {
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pulsegate-shared/providers/Microsoft.OperationalInsights/workspaces/log-pulsegate-shared"
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  project                    = local.root.project
  environment                = local.env.environment
  address_space              = local.address_spaces[local.env.environment]
  log_analytics_workspace_id = dependency.baseline.outputs.log_analytics_workspace_id
}
