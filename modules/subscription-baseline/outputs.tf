output "shared_resource_group_name" {
  description = "The shared tier's resource group. live/shared/budget puts its action group here."
  value       = azurerm_resource_group.shared.name
}

output "log_analytics_workspace_id" {
  description = "The default destination for diagnostic settings."
  value       = azurerm_log_analytics_workspace.shared.id
}

output "tag_policy_assignment_id" {
  description = "The tag inheritance assignment. A remediation task, when one is needed, is created against it."
  value       = azurerm_subscription_policy_assignment.inherit_tags.id
}
