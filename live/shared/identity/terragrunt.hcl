# The CI identities: one plan identity, one apply identity per environment, all
# federated to GitHub and none holding a secret. Step 4 of v0-bootstrap.
#
# Applied by hand, as the break-glass admin, and never by CI -- creating an
# Entra application needs directory permissions the pipeline must not hold.
# Temporary: v12-govern replaces it with managed identities vended by the
# platform layer, and this unit is destroyed. See ROADMAP.md.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/modules/ci-identity"
}

# root.hcl generates only azurerm. This is the one unit that talks to Graph.
generate "provider_azuread" {
  path      = "provider_azuread.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "azuread" {
      # tenant_id comes from ARM_TENANT_ID.
    }
  EOF
}

inputs = {
  project           = include.root.locals.project
  github_repository = "SasangaME/pulsegate"
  environments      = ["dev", "stage", "prod"]

  state_resource_group_name  = include.root.locals.state_resource_group_name
  state_storage_account_name = include.root.locals.storage_account_name
  state_container_name       = include.root.locals.state_container_name
}
