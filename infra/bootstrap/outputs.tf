output "tenant_id" {
  description = "Set as GitHub variable AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Set as GitHub variable AZURE_SUBSCRIPTION_ID."
  value       = data.azurerm_client_config.current.subscription_id
}

output "plan_client_id" {
  description = "Set as GitHub repository variable AZURE_PLAN_CLIENT_ID."
  value       = azurerm_user_assigned_identity.gh_plan.client_id
}

output "deploy_client_ids" {
  description = "Set as GitHub Environment variable AZURE_DEPLOY_CLIENT_ID in each environment."
  value       = { for env, id in azurerm_user_assigned_identity.gh_deploy : env => id.client_id }
}

output "backend_config" {
  description = "Values for infra/envs/<env>.backend.hcl."
  value = {
    resource_group_name  = azurerm_resource_group.tfstate.name
    storage_account_name = azurerm_storage_account.tfstate.name
    container_name       = azurerm_storage_container.tfstate.name
  }
}

output "environment_resource_groups" {
  description = "Resource group per environment, consumed by the main stack."
  value       = { for env, rg in azurerm_resource_group.env : env => rg.name }
}
