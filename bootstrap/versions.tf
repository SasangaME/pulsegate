terraform {
  required_version = ">= 1.9"

  # No backend block. This module creates the backend, so it runs on local
  # state, and its state moves into the container it made in step 3 of
  # v0-bootstrap. `init` runs before `apply`, so a backend declared here
  # would be reached before anything had created it.

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}

provider "azurerm" {
  features {}

  # subscription_id and tenant_id come from ARM_SUBSCRIPTION_ID and
  # ARM_TENANT_ID. Nothing identifying is written into a tracked file.

  # Operation 1 in RUNBOOK.md registered all 21 namespaces already, so the
  # provider's own registration pass has nothing left to do. Step 3 needs
  # this same value for a harder reason: the CI plan identity is Reader and
  # holds no register/action.
  resource_provider_registrations = "none"

  # shared_access_key_enabled is false on the account below, so every
  # data-plane call -- including creating the container -- has to carry an
  # Entra token. Without this the provider reaches for an account key that
  # does not exist, and fails with a 403 that reads like a permissions bug.
  storage_use_azuread = true
}
