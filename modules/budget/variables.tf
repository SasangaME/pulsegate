variable "project" {
  description = "Project name. Used in resource names and the Project tag."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group. The action group itself is global."
  type        = string
  default     = "westus3"
}

variable "amount" {
  description = "Monthly budget in the billing currency. The number is reasoned in COST.md."
  type        = number
  default     = 20
}

variable "start_date" {
  description = "First day of the first budgeted month, RFC 3339. Fixed, not computed: a changed start date replaces the budget."
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-01T00:00:00Z$", var.start_date))
    error_message = "start_date must be the first of a month, as YYYY-MM-01T00:00:00Z."
  }
}

variable "alert_email" {
  description = "Where budget alerts go. Read from the environment, never a tracked file."
  type        = string
  sensitive   = true
}
