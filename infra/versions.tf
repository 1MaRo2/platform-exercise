terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Partial configuration: values come from envs/<env>.backend.hcl so the same
  # code serves every environment. Auth is Entra ID (OIDC in CI, az login
  # locally); the state account has shared keys disabled.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  resource_provider_registrations = "none" # registered once by bootstrap
}
