variable "project" {
  description = "Project name. Prefixes the application display names."
  type        = string
}

variable "github_repository" {
  description = "The repository whose workflows may exchange a token, as OWNER/NAME. Part of every federated subject."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be OWNER/NAME."
  }
}

variable "environments" {
  description = "Environments that get their own apply identity. Each must match a GitHub Environment of the same name."
  type        = set(string)
}

variable "state_resource_group_name" {
  description = "Resource group holding the state account."
  type        = string
}

variable "state_storage_account_name" {
  description = "The state account. Both identities get data-plane access to its container."
  type        = string
}

variable "state_container_name" {
  description = "The single state container."
  type        = string
}
