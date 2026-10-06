output "resource_group_name" {
  description = "The network's resource group."
  value       = azurerm_resource_group.network.name
}

output "vnet_id" {
  description = "The VNet. Private DNS zones link to it."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "The VNet's name."
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Subnet IDs by role: nodes, ingress, database, private-endpoints."
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}

output "subnet_prefixes" {
  description = "Subnet address prefixes by role."
  value       = { for k, s in azurerm_subnet.this : k => s.address_prefixes[0] }
}
