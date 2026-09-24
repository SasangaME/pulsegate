data "azuread_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = var.state_resource_group_name
}

locals {
  # The two values every GitHub federated credential for Azure carries. The
  # issuer is GitHub's OIDC provider; the audience is the one azure/login
  # requests by default.
  github_issuer   = "https://token.actions.githubusercontent.com"
  github_audience = "api://AzureADTokenExchange"

  # Subjects are compared as exact strings, with no wildcards. A job presents
  # exactly one of these shapes:
  #
  #   repo:OWNER/NAME:pull_request          a pull_request-triggered job
  #   repo:OWNER/NAME:ref:refs/heads/main   a push to main, with no environment
  #   repo:OWNER/NAME:environment:dev       any job that declares an environment
  #
  # The last one wins whenever it applies: a job bound to an environment
  # presents the environment subject, whatever its branch or trigger. That is
  # what lets the apply identity be per environment.
  subject_prefix = "repo:${var.github_repository}"

  plan_subjects = {
    pull-request = "${local.subject_prefix}:pull_request"
    main         = "${local.subject_prefix}:ref:refs/heads/main"
  }

  # Data-plane RBAC at container scope. The account has shared keys disabled,
  # so this role assignment is the only way to read or write state.
  state_container_scope = "${data.azurerm_storage_account.state.id}/blobServices/default/containers/${var.state_container_name}"

  owners = [data.azuread_client_config.current.object_id]
}

# -----------------------------------------------------------------------------
# Plan: one identity for every environment, because a plan is read-only and the
# same everywhere.
# -----------------------------------------------------------------------------

resource "azuread_application" "plan" {
  display_name = "${var.project}-ci-plan"
  owners       = local.owners
}

resource "azuread_service_principal" "plan" {
  client_id = azuread_application.plan.client_id
  owners    = local.owners
}

resource "azuread_application_federated_identity_credential" "plan" {
  for_each = local.plan_subjects

  application_id = azuread_application.plan.id
  display_name   = "github-${each.key}"
  description    = "GitHub Actions, ${each.value}"
  issuer         = local.github_issuer
  audiences      = [local.github_audience]
  subject        = each.value
}

resource "azurerm_role_assignment" "plan_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.plan.object_id

  # Skips the directory lookup that fails with PrincipalNotFound while a new
  # service principal is still replicating.
  principal_type = "ServicePrincipal"
}

# Contributor, not Reader: `plan` takes the blob lease that is the backend's
# lock, and taking a lease is a write.
resource "azurerm_role_assignment" "plan_state" {
  scope                = local.state_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.plan.object_id
  principal_type       = "ServicePrincipal"
}

# -----------------------------------------------------------------------------
# Apply: one identity per environment, so a job targeting prod presents a
# different subject, and gets a different principal, than one targeting dev.
# -----------------------------------------------------------------------------

resource "azuread_application" "apply" {
  for_each = var.environments

  display_name = "${var.project}-ci-apply-${each.key}"
  owners       = local.owners
}

resource "azuread_service_principal" "apply" {
  for_each = var.environments

  client_id = azuread_application.apply[each.key].client_id
  owners    = local.owners
}

resource "azuread_application_federated_identity_credential" "apply" {
  for_each = var.environments

  application_id = azuread_application.apply[each.key].id
  display_name   = "github-environment-${each.key}"
  description    = "GitHub Actions, environment ${each.key}"
  issuer         = local.github_issuer
  audiences      = [local.github_audience]
  subject        = "${local.subject_prefix}:environment:${each.key}"
}

# The v0 baseline. Each milestone adds the assignments its resources need, at
# the narrowest scope that works -- the environment's resource groups from
# v1-network on, not the subscription.
resource "azurerm_role_assignment" "apply_reader" {
  for_each = var.environments

  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.apply[each.key].object_id
  principal_type       = "ServicePrincipal"
}

# Every environment shares one container, so this reaches every environment's
# state, not only its own. Narrowing it to a key prefix is an ABAC condition on
# the assignment, and it is recorded as v10-harden work rather than done here.
resource "azurerm_role_assignment" "apply_state" {
  for_each = var.environments

  scope                = local.state_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.apply[each.key].object_id
  principal_type       = "ServicePrincipal"
}
