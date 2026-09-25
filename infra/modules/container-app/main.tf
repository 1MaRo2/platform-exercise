# Reusable module: a public HTTPS service on Azure Container Apps (Consumption).

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.name}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = var.tags
}

# Runtime identity for the app. It deliberately has NO role assignments: the
# service calls no Azure APIs. Giving it an identity now means future access
# (Key Vault, storage) is a role assignment, never a secret.
resource "azurerm_user_assigned_identity" "runtime" {
  name                = "id-${var.name}-runtime"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.name}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  ingress {
    external_enabled           = true
    target_port                = var.target_port
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "app"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      startup_probe {
        transport = "HTTP"
        path      = "/health"
        port      = var.target_port
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = var.target_port
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/ready"
        port      = var.target_port
      }
    }

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = tostring(var.concurrent_requests_per_replica)
    }
  }
}
