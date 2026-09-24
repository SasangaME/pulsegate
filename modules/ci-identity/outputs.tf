output "plan_client_id" {
  description = "Client ID of the plan identity. The repository variable AZURE_CLIENT_ID in RUNBOOK.md operation 3."
  value       = azuread_application.plan.client_id
}

output "apply_client_ids" {
  description = "Client ID of each environment's apply identity. The AZURE_APPLY_CLIENT_ID variable of the matching GitHub Environment."
  value       = { for env, app in azuread_application.apply : env => app.client_id }
}
