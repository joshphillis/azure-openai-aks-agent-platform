###############################################################################
# modules/openai/variables.tf
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
  description = "Azure region. Note: Azure OpenAI is not available in all regions. Use eastus, eastus2, swedencentral, or australiaeast for best model availability."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into"
  type        = string
}

# --- Networking (from modules/networking outputs) ---------------------------

variable "private_endpoints_subnet_id" {
  description = "Subnet ID for the OpenAI private endpoint NIC"
  type        = string
}

variable "dns_zone_id_openai" {
  description = "Private DNS zone ID for OpenAI (privatelink.openai.azure.com)"
  type        = string
}

# --- Key Vault (from modules/keyvault outputs) ------------------------------

variable "keyvault_id" {
  description = "Resource ID of the Key Vault — endpoint and deployment names are stored here"
  type        = string
}

# --- Workload identity (from modules/keyvault outputs) ----------------------

variable "agent_identity_principal_ids" {
  description = "Map of agent name → managed identity principal ID (from keyvault module output). Each identity gets Cognitive Services OpenAI User on the account."
  type        = map(string)
}

# --- Model deployments ------------------------------------------------------

variable "gpt4o_deployment_name" {
  description = "Name for the GPT-4o deployment"
  type        = string
  default     = "gpt-4o"
}

variable "gpt4o_model_version" {
  description = "GPT-4o model version"
  type        = string
  default     = "2024-11-20"
}

variable "gpt4o_capacity_tpm" {
  description = "GPT-4o throughput capacity in thousands of tokens per minute"
  type        = number
  default     = 30  # 30K TPM — sufficient for dev; raise for prod
  validation {
    condition     = var.gpt4o_capacity_tpm >= 1 && var.gpt4o_capacity_tpm <= 450
    error_message = "Capacity must be between 1 and 450 (thousands of TPM)."
  }
}

variable "embeddings_deployment_name" {
  description = "Name for the text-embedding-3-large deployment"
  type        = string
  default     = "text-embedding-3-large"
}

variable "embeddings_capacity_tpm" {
  description = "Embeddings throughput capacity in thousands of tokens per minute"
  type        = number
  default     = 30
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
