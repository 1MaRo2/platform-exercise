terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Bootstrap uses local state on purpose: it creates the remote state
  # backend itself. Keep terraform.tfstate out of git (see .gitignore).
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true # shared keys are disabled on the state account
  resource_provider_registrations = "none"
}
