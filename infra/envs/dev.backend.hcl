# Fill storage_account_name from `terraform -chdir=infra/bootstrap output backend_config`.
resource_group_name  = "rg-platex-tfstate"
storage_account_name = "platexstate1999"
container_name       = "tfstate"
key                  = "dev/platform-exercise.tfstate"
use_azuread_auth     = true
