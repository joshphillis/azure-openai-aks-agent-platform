###############################################################################
# modules/servicebus/variables.tf
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

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into"
  type        = string
}

# --- Networking -------------------------------------------------------------

variable "private_endpoints_subnet_id" {
  description = "Subnet ID for the Service Bus private endpoint NIC"
  type        = string
}

variable "dns_zone_id_servicebus" {
  description = "Private DNS zone ID for Service Bus (privatelink.servicebus.windows.net)"
  type        = string
}

# --- Topics -----------------------------------------------------------------

variable "topic_names" {
  description = "List of topic names to create"
  type        = list(string)
  default     = ["research-tasks", "analysis-tasks", "writer-tasks", "agent-results"]
}

# --- Identity ---------------------------------------------------------------

variable "agent_identity_principal_ids" {
  description = "Map of agent name → managed identity principal ID (from keyvault module)"
  type        = map(string)
}

# --- Key Vault --------------------------------------------------------------

variable "keyvault_id" {
  description = "Resource ID of the Key Vault — namespace hostname stored here"
  type        = string
}

# --- Observability ----------------------------------------------------------

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings"
  type        = string
}

# --- Tags -------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "suffix" {
  description = "Short unique suffix for globally unique resource names"
  type        = string
  default     = ""
}
