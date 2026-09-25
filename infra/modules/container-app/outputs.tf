output "url" {
  description = "Public HTTPS URL."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "latest_revision_name" {
  description = "Latest revision name."
  value       = azurerm_container_app.this.latest_revision_name
}

output "runtime_identity_client_id" {
  description = "Runtime managed identity client ID."
  value       = azurerm_user_assigned_identity.runtime.client_id
}

output "container_app_id" {
  description = "Container App resource ID."
  value       = azurerm_container_app.this.id
}
