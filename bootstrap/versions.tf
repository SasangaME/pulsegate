terraform {
  required_version = ">= 1.9"

  # No backend block. This module creates the backend, so it runs on local
  # state, and its state moves into the container it made in step 3 of
  # v0-bootstrap. `init` runs before `apply`, so a backend declared here
  # would be reached before anything had created it.
  #
  # As of step 3 the backend is generated into backend.tf by root.hcl, which
  # derives the account name rather than storing it. A rebuild from nothing
  # deletes the generated backend.tf, applies on local state again, and
  # re-migrates.

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

# The provider configuration lives in root.hcl, which generates it into
# provider.tf on every init. Declaring it here as well is a duplicate
# provider configuration and a hard error -- and the three arguments it
# carries apply to every environment, not only to this module.
