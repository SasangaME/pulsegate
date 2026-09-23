data "azurerm_client_config" "current" {}

locals {
  # Storage account names are globally unique, 3-24 characters, lowercase
  # alphanumeric. The suffix is derived from the subscription rather than
  # random: if this state file is ever lost, a deterministic name is one
  # `terraform import` away, where a random one leaves an orphan behind.
  suffix = substr(sha256(data.azurerm_client_config.current.subscription_id), 0, 6)

  tags = {
    Project     = var.project
    Environment = "shared"
    ManagedBy   = "terraform"
    Milestone   = "v0-bootstrap"
  }
}

resource "azurerm_resource_group" "state" {
  name     = "rg-${var.project}-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  name                = "st${var.project}state${local.suffix}"
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"

  # The boundary around this account is identity, not network.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true

  # Public endpoint, reachable only with an Entra token. This is a decision,
  # not a default -- closing it locks CI out of state. See ROADMAP.md.
  public_network_access_enabled = true

  blob_properties {
    # The recovery story for a corrupted or truncated state file.
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags

  # This account holds the state for every environment in the project, and is
  # the tier that is deliberately never destroyed with the rest.
  lifecycle {
    prevent_destroy = true
  }
}

# With shared keys disabled, subscription Owner does not let you read a blob.
# Data-plane access is a separate RBAC plane and needs its own assignment --
# including to create the container two resources below.
resource "azurerm_role_assignment" "state_blob" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC is eventually consistent, and a fresh assignment takes some
# seconds to be honoured on the data plane. Without this wait the first apply
# fails on the container with a 403 and the second one succeeds, which is the
# kind of flake that gets diagnosed as something else entirely.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.state_blob]
  create_duration = "60s"
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  depends_on = [time_sleep.rbac_propagation]

  lifecycle {
    prevent_destroy = true
  }
}
