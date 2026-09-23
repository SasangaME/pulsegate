output "resource_group_name" {
  description = "Resource group holding the state account. Consumed by the root terragrunt.hcl in step 3."
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "State storage account. Consumed by the root terragrunt.hcl in step 3."
  value       = azurerm_storage_account.state.name
}

output "container_name" {
  description = "The single state container. Environments are separated by state key, not by container."
  value       = azurerm_storage_container.state.name
}
