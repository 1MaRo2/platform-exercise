variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "project" {
  description = "Short project prefix used in resource names."
  type        = string
  default     = "platex"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.project))
    error_message = "project must be 3-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region for all resources (must offer Container Apps)."
  type        = string
  default     = "swedencentral"
}

variable "environments" {
  description = "Environments to create a resource group and deploy identity for."
  type        = set(string)
  default     = ["dev"]
}

variable "state_storage_account_name" {
  description = "Globally unique name for the Terraform state storage account (3-24 lowercase alphanumerics)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.state_storage_account_name))
    error_message = "Storage account names must be 3-24 lowercase alphanumeric characters."
  }
}

variable "github_repository" {
  description = "GitHub repository allowed to federate, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_oidc_subject_prefix" {
  description = "Subject prefix GitHub puts in its OIDC tokens. Newer repos include IDs: repo:<owner>@<owner-id>/<repo>@<repo-id>. Defaults to repo:<owner>/<repo>."
  type        = string
  default     = null
}

variable "budget_amount" {
  description = "Monthly subscription budget in the billing currency."
  type        = number
  default     = 1
}

variable "budget_contact_emails" {
  description = "Emails notified when the budget thresholds are crossed."
  type        = list(string)
}