variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "project" {
  description = "Short project prefix used in resource names."
  type        = string
  default     = "platex"
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of dev, stg, prod."
  }
}

variable "resource_group_name" {
  description = "Existing resource group for this environment (created by bootstrap)."
  type        = string
}

variable "image" {
  description = "Container image reference, ideally pinned by digest (ghcr.io/owner/repo@sha256:...)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(@sha256:[a-f0-9]{64}|:[A-Za-z0-9._-]+)$", var.image))
    error_message = "image must be a full reference with a tag or @sha256 digest."
  }
}

variable "cpu" {
  description = "vCPU per replica (Consumption plan pairs: 0.25/0.5Gi, 0.5/1Gi, ...)."
  type        = number
  default     = 0.25
}

variable "memory" {
  description = "Memory per replica, matching the cpu pairing."
  type        = string
  default     = "0.5Gi"
}

variable "min_replicas" {
  description = "Minimum replicas; 0 scales to zero (no cost when idle)."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas; caps spend and blast radius."
  type        = number
  default     = 2

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 10
    error_message = "max_replicas must be between 1 and 10."
  }
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap for Log Analytics, keeps us inside the free allowance."
  type        = number
  default     = 0.1
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
