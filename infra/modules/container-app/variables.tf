variable "name" {
  description = "Base name for resources (lowercase, <= 24 chars)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must start with a letter and contain 2-24 lowercase letters, digits or hyphens."
  }
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment" {
  description = "Environment name, exposed to the app as APP_ENV."
  type        = string
}

variable "image" {
  description = "Container image reference."
  type        = string
}

variable "target_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "vCPU per replica."
  type        = number
}

variable "memory" {
  description = "Memory per replica (e.g. 0.5Gi)."
  type        = string
}

variable "min_replicas" {
  description = "Minimum replicas."
  type        = number
}

variable "max_replicas" {
  description = "Maximum replicas."
  type        = number
}

variable "concurrent_requests_per_replica" {
  description = "HTTP scale rule threshold."
  type        = number
  default     = 50
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap in GB."
  type        = number
}

variable "log_retention_days" {
  description = "Log Analytics retention in days (30 is included at no extra retention cost)."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
