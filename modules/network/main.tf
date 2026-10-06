locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Milestone   = "v1-network"
  }

  # The subnet layout, as offsets into the /16. Fixed positions rather than
  # packed ones, so adding a subnet later never renumbers an existing one --
  # a subnet's range cannot change while anything is attached to it.
  #
  #   nodes              10.x.0.0/22    AKS nodes. CNI Overlay puts pods outside
  #                                     the VNet, so this only counts nodes:
  #                                     ~1000 is far past any pool here.
  #   ingress            10.x.4.0/24    The ingress controller's internal load
  #                                     balancer, and v9-edge's private origin.
  #   database           10.x.5.0/24    PostgreSQL Flexible Server, v5-state.
  #                                     Delegated now: delegation cannot be
  #                                     added to a subnet that has anything in it.
  #   private-endpoints  10.x.6.0/24    Key Vault, Blob, Service Bus endpoints.
  #
  # 10.x.7.0 onward is free.
  subnets = {
    nodes = {
      newbits    = 6
      netnum     = 0
      delegation = null
    }
    ingress = {
      newbits    = 8
      netnum     = 4
      delegation = null
    }
    database = {
      newbits    = 8
      netnum     = 5
      delegation = "Microsoft.DBforPostgreSQL/flexibleServers"
    }
    private-endpoints = {
      newbits    = 8
      netnum     = 6
      delegation = null
    }
  }
}

# -----------------------------------------------------------------------------
# Resource group: this unit's own, so destroying the network removes the group
# with it. See "Resource group layout" in ROADMAP.md.
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-${local.name}-network"
  location = var.location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# The VNet and its subnets.
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = var.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space[0], each.value.newbits, each.value.netnum)]

  # No implicit outbound. The only way out is the NAT Gateway, so every
  # outbound request leaves from one known address.
  default_outbound_access_enabled = false

  # NSGs and UDRs apply to private endpoints too, not only to the NICs beside
  # them. Matters only on the endpoint subnet; harmless on the rest.
  private_endpoint_network_policies = each.key == "private-endpoints" ? "Enabled" : "Disabled"

  dynamic "delegation" {
    for_each = each.value.delegation == null ? [] : [each.value.delegation]

    content {
      name = "delegation"

      service_delegation {
        name    = delegation.value
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}
