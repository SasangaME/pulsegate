variable "location" {
  description = "Azure region. The choice is reasoned in ROADMAP.md."
  type        = string
  default     = "westus3"
}

variable "project" {
  description = "Project name. Used in resource names and the Project tag."
  type        = string
  default     = "pulsegate"
}
