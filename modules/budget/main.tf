data "azurerm_subscription" "current" {}

locals {
  tags = {
    Project     = var.project
    Environment = "shared"
    ManagedBy   = "terraform"
    Milestone   = "v0-bootstrap"
  }
}

# The action group has to live in a resource group. Not the state backend's:
# that one belongs to bootstrap/, and a unit that can be destroyed should not
# share a group with the one that cannot.
resource "azurerm_resource_group" "shared" {
  name     = "rg-${var.project}-shared"
  location = var.location
  tags     = local.tags
}

resource "azurerm_monitor_action_group" "budget" {
  name                = "ag-${var.project}-budget"
  resource_group_name = azurerm_resource_group.shared.name
  short_name          = "budget" # 12 characters at most; it is the SMS sender name
  tags                = local.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# One budget across the whole subscription, so dev, stage and prod count
# against the same number. Which environment spent it is Cost Analysis's
# question, answered by the Environment tag. See COST.md.
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-${var.project}-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.amount
  time_grain      = "Monthly"

  time_period {
    start_date = var.start_date
    # No end_date: Azure defaults it to ten years out.
  }

  # Forecast first, because month-to-date actual is low early in the month
  # whatever is running. This is the alert that catches a forgotten stack.
  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThanOrEqualTo"
    contact_groups = [azurerm_monitor_action_group.budget.id]
  }

  # The backstop. It trips within a day of a stack left running.
  notification {
    enabled        = true
    threshold      = 50
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"
    contact_groups = [azurerm_monitor_action_group.budget.id]
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"
    contact_groups = [azurerm_monitor_action_group.budget.id]
  }
}
