output "action_group_id" {
  description = "The budget's action group. v10-harden points a second, resource-group budget at it."
  value       = azurerm_monitor_action_group.budget.id
}
