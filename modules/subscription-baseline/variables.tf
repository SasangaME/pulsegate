variable "project" {
  description = "Project name. Used in resource names and the Project tag."
  type        = string
}

variable "location" {
  description = "Azure region for the shared resource group, the workspace and the policy assignment's identity."
  type        = string
  default     = "westus3"
}

variable "inherited_tags" {
  description = "Tag keys a resource inherits from its resource group when it lacks them. The tag set is reasoned in COST.md."
  type        = list(string)
  default     = ["Project", "Environment", "ManagedBy", "Milestone"]
}

variable "daily_quota_gb" {
  description = "Daily cap on billable ingestion into the shared workspace, in GB."
  type        = number
  default     = 0.1
}
