###############################################################################
# modules/monitoring/variables.tf
###############################################################################

variable "name" {
  description = "Short platform name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment label: dev or prod"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "resource_group_id" {
  description = "Resource group ID (for cost budget scope)"
  type        = string
}

# --- Scopes for alerts ------------------------------------------------------

variable "aks_cluster_id" {
  description = "Resource ID of the AKS cluster (from modules/aks)"
  type        = string
}

variable "servicebus_namespace_id" {
  description = "Resource ID of the Service Bus namespace (from modules/servicebus)"
  type        = string
}

variable "openai_account_id" {
  description = "Resource ID of the Azure OpenAI account (from modules/openai)"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (from modules/aks)"
  type        = string
}

# --- Alert configuration ----------------------------------------------------

variable "alert_email_addresses" {
  description = "List of email addresses for alert notifications"
  type        = list(string)
}

variable "dlq_alert_threshold" {
  description = "Number of dead-lettered messages that triggers an alert"
  type        = number
  default     = 5
}

variable "openai_token_alert_threshold" {
  description = "Token transaction count per 10-minute window that triggers an alert (tune to your TPM quota)"
  type        = number
  default     = 250000
}

variable "monthly_budget_usd" {
  description = "Monthly spend budget in USD — alerts fire at 80% actual and 100% forecasted"
  type        = number
  default     = 50  # Conservative dev budget
}

# --- Tags -------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
