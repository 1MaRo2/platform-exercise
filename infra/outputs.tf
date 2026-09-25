output "app_url" {
  description = "Public HTTPS URL of the app."
  value       = module.app.url
}

output "latest_revision_name" {
  description = "Active Container Apps revision."
  value       = module.app.latest_revision_name
}

output "runtime_identity_client_id" {
  description = "Client ID of the app's runtime managed identity (no role assignments)."
  value       = module.app.runtime_identity_client_id
}
