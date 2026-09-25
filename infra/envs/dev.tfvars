# Non-secret environment settings. subscription_id and image are passed by CI
# (TF_VAR_subscription_id / -var image=...).
environment         = "dev"
resource_group_name = "rg-platex-dev"
min_replicas        = 0
max_replicas        = 2
