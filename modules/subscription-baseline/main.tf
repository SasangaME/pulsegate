data "azurerm_subscription" "current" {}

# Looked up by display name rather than pasted as a GUID, so the dependency on
# a built-in reads as what it is.
data "azurerm_policy_definition" "inherit_tag" {
  display_name = "Inherit a tag from the resource group if missing"
}

locals {
  tags = {
    Project     = var.project
    Environment = "shared"
    ManagedBy   = "terraform"
    Milestone   = "v0-bootstrap"
  }

  # Everything the subscription's activity log can emit. Activity log
  # ingestion into Log Analytics is free, so there is no category worth
  # dropping to save money.
  activity_log_categories = [
    "Administrative",
    "Security",
    "ServiceHealth",
    "Alert",
    "Recommendation",
    "Policy",
    "Autoscale",
    "ResourceHealth",
  ]
}

# -----------------------------------------------------------------------------
# Resource group: the shared tier's one group for things that are not state.
# The budget's action group lives here, and so does the workspace below. It
# used to be created by modules/budget; it moved here because a group holding
# resources from several units should belong to none of them but the baseline.
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "shared" {
  name     = "rg-${var.project}-shared"
  location = var.location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# Tag inheritance: one initiative wrapping the built-in once per tag key, and
# one assignment of it. One assignment means one managed identity and one role
# assignment, however many keys there are.
# -----------------------------------------------------------------------------

resource "azurerm_policy_set_definition" "inherit_tags" {
  name         = "${var.project}-inherit-tags"
  policy_type  = "Custom"
  display_name = "${var.project}: inherit tags from the resource group"
  description  = "Copies ${join(", ", var.inherited_tags)} from a resource's group onto the resource when the resource does not already carry them."

  dynamic "policy_definition_reference" {
    for_each = toset(var.inherited_tags)

    content {
      policy_definition_id = data.azurerm_policy_definition.inherit_tag.id
      reference_id         = "inherit-${lower(policy_definition_reference.value)}"
      parameter_values = jsonencode({
        tagName = { value = policy_definition_reference.value }
      })
    }
  }
}

resource "azurerm_subscription_policy_assignment" "inherit_tags" {
  name                 = "${var.project}-inherit-tags"
  display_name         = azurerm_policy_set_definition.inherit_tags.display_name
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_set_definition.inherit_tags.id

  # A modify policy has to name an identity, and a system-assigned identity
  # has to name a region. The region is where the identity lives, not a
  # limit on what the policy covers.
  location = var.location

  identity {
    type = "SystemAssigned"
  }

  non_compliance_message {
    content = "Resources inherit ${join(", ", var.inherited_tags)} from their resource group. See COST.md."
  }
}

# The built-in declares Contributor, which is what Azure grants when the
# assignment is made in the portal. Every operation this policy performs is a
# tag write, so Tag Contributor is enough, and a policy identity with
# Contributor on the subscription is a standing privilege nothing here needs.
#
# The identity is used only by remediation tasks. Modifying a resource as it
# is created or updated happens inline on the caller's request and needs no
# role at all.
resource "azurerm_role_assignment" "inherit_tags" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Tag Contributor"
  principal_id         = azurerm_subscription_policy_assignment.inherit_tags.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# -----------------------------------------------------------------------------
# Diagnostics: the subscription's activity log, kept past Azure's own 90 days
# and made queryable. The workspace is the default destination for later
# diagnostic settings, which read its ID from this unit's outputs.
# -----------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "shared" {
  name                = "log-${var.project}-shared"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  tags                = local.tags

  sku = "PerGB2018"

  # Set at creation, per the first standing rule in COST.md. Thirty days is
  # inside the free retention window; activity log data is kept 90 days at
  # no charge whatever this says.
  retention_in_days = 30

  # The cap on anything billable that is ever routed here. The activity log
  # is not billable, so today this bounds nothing -- it is here so that the
  # first diagnostic setting pointed at this workspace cannot grow silently.
  # Raising it is a decision, not a default.
  daily_quota_gb = var.daily_quota_gb

  # Queries go through Entra ID, like the state account.
  local_authentication_enabled = false
}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "diag-${var.project}-activity-log"
  target_resource_id         = data.azurerm_subscription.current.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  dynamic "enabled_log" {
    for_each = toset(local.activity_log_categories)

    content {
      category = enabled_log.value
    }
  }
}
