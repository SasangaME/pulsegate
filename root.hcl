# The configuration every unit in live/ inherits, and the one bootstrap/ adopts
# once it has created the account this points at.
#
# Two jobs: derive each unit's state key from its path, and generate the
# provider, so that no .tf file in this repository declares either.

locals {
  project = "pulsegate"

  # The state account's name is rebuilt here rather than read from anywhere.
  # bootstrap/main.tf derives it the same way from the same input, so the two
  # agree by construction -- and the subscription ID stays in the environment,
  # which is what keeps the account name out of this public repository.
  suffix               = substr(sha256(get_env("ARM_SUBSCRIPTION_ID")), 0, 6)
  storage_account_name = "st${local.project}state${local.suffix}"
}

remote_state {
  backend = "azurerm"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    resource_group_name  = "rg-${local.project}-tfstate"
    storage_account_name = local.storage_account_name
    container_name       = "tfstate"

    # One container, one key per unit, derived from the directory path:
    # bootstrap/terraform.tfstate, live/dev/network/terraform.tfstate, and so
    # on. Environments cannot collide in the backend because the filesystem
    # will not let two units share a path.
    key = "${path_relative_to_include()}/terraform.tfstate"

    # Shared keys are disabled on the account, so the backend authenticates
    # with the same Entra token as the provider. Without this the backend
    # reaches for an account key that does not exist.
    use_azuread_auth = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "azurerm" {
      features {}

      # subscription_id and tenant_id come from ARM_SUBSCRIPTION_ID and
      # ARM_TENANT_ID. Nothing identifying is written into a tracked file.

      # The CI plan identity is Reader and holds no register/action, so the
      # provider's registration pass fails for it. RUNBOOK.md operation 1
      # registered all 21 namespaces already, so there is nothing to do.
      resource_provider_registrations = "none"

      # Every data-plane call carries an Entra token, because the state
      # account has shared_access_key_enabled = false.
      storage_use_azuread = true
    }
  EOF
}
