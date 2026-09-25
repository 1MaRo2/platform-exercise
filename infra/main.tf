data "azurerm_resource_group" "env" {
  name = var.resource_group_name
}

locals {
  tags = merge({
    project    = var.project
    env        = var.environment
    managed_by = "terraform"
  }, var.tags)
}

module "app" {
  source = "./modules/container-app"

  name                = "${var.project}-${var.environment}"
  resource_group_name = data.azurerm_resource_group.env.name
  location            = data.azurerm_resource_group.env.location
  environment         = var.environment

  image        = var.image
  cpu          = var.cpu
  memory       = var.memory
  min_replicas = var.min_replicas
  max_replicas = var.max_replicas

  log_daily_quota_gb = var.log_daily_quota_gb
  tags               = local.tags
}
