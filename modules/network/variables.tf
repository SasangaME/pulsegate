variable "project" {
  description = "Project name. Used in resource names and the Project tag."
  type        = string
}

variable "environment" {
  description = "The environment this network belongs to. Used in resource names and the Environment tag."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of dev, stage, prod."
  }
}

variable "location" {
  description = "Azure region for the resource group and everything in it."
  type        = string
  default     = "westus3"
}

variable "address_space" {
  description = "The VNet's address space. One /16; the subnets are carved from it by position, so the layout is the same in every environment."
  type        = list(string)

  validation {
    condition     = length(var.address_space) == 1 && endswith(var.address_space[0], "/16")
    error_message = "address_space must be a single /16. The subnet layout in main.tf assumes it."
  }
}
