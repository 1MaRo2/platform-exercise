# One-time bootstrap, applied manually by a subscription Owner:
#   - resource providers the stack needs
#   - Terraform remote state (Entra ID auth only, no access keys)
#   - GitHub OIDC identities (plan + deploy per environment) and their roles
#   - a cost budget guardrail
# All role assignments live here so CI never needs Owner/User Access Admin.

data "azurerm_client_config" "current" {}

locals {
  tags = {
    project    = var.project
    managed_by = "terraform"
    stack      = "bootstrap"
  }
  github_issuer = "https://token.actions.githubusercontent.com"
  github_aud    = ["api://AzureADTokenExchange"]
  github_sub    = coalesce(var.github_oidc_subject_prefix, "repo:${var.github_repository}")
}

# ---- Resource providers -----------------------------------------------------
resource "azurerm_resource_provider_registration" "this" {
  for_each = toset([
    "Microsoft.App",
    "Microsoft.OperationalInsights",
    "Microsoft.ManagedIdentity",
    "Microsoft.Storage",
    "Microsoft.Consumption",
  ])
  name = each.value
}

# ---- Resource groups --------------------------------------------------------
resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.project}-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "env" {
  for_each = var.environments
  name     = "rg-${var.project}-${each.key}"
  location = var.location
  tags     = merge(local.tags, { env = each.key })
}

# ---- Remote state -----------------------------------------------------------
resource "azurerm_storage_account" "tfstate" {
  name                            = var.state_storage_account_name
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags

  depends_on = [azurerm_resource_provider_registration.this]
  lifecycle {
    prevent_destroy = true # holds all Terraform state
  }
}

# The person running bootstrap needs data-plane access to create the container.
resource "azurerm_role_assignment" "bootstrap_user_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.bootstrap_user_blob]
  lifecycle {
    prevent_destroy = true # holds all Terraform state
  }
}

# ---- GitHub OIDC identities -------------------------------------------------
# Plan identity: used by pull requests. It reads state without taking a lock,
# so it needs no state-container write permissions.
resource "azurerm_user_assigned_identity" "gh_plan" {
  name                = "id-${var.project}-gh-plan"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "gh_plan_pr" {
  name      = "github-pull-request"
  parent_id = azurerm_user_assigned_identity.gh_plan.id
  issuer    = local.github_issuer
  audience  = local.github_aud
  subject   = "${local.github_sub}:pull_request" # in gh_plan_pr
}

resource "azurerm_role_assignment" "gh_plan_reader" {
  for_each             = azurerm_resource_group.env
  scope                = each.value.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.gh_plan.principal_id
}

resource "azurerm_role_assignment" "gh_plan_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.gh_plan.principal_id
}

# Deploy identity per environment: only usable from the matching GitHub
# Environment, Contributor on that environment's resource group only.
resource "azurerm_user_assigned_identity" "gh_deploy" {
  for_each            = var.environments
  name                = "id-${var.project}-gh-deploy-${each.key}"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tags                = merge(local.tags, { env = each.key })
}

resource "azurerm_federated_identity_credential" "gh_deploy_env" {
  for_each  = var.environments
  name      = "github-environment-${each.key}"
  parent_id = azurerm_user_assigned_identity.gh_deploy[each.key].id
  issuer    = local.github_issuer
  audience  = local.github_aud
  subject   = "${local.github_sub}:environment:${each.key}" # in gh_deploy_env
}

resource "azurerm_role_assignment" "gh_deploy_contributor" {
  for_each             = var.environments
  scope                = azurerm_resource_group.env[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.gh_deploy[each.key].principal_id
}

resource "azurerm_role_assignment" "gh_deploy_state" {
  for_each             = var.environments
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gh_deploy[each.key].principal_id
}

# ---- Cost guardrail ---------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-${var.project}-monthly"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_contact_emails
  }

  depends_on = [azurerm_resource_provider_registration.this]

  lifecycle {
    ignore_changes = [time_period] # start_date must not move on every apply
  }
}