###############################################################################
# modules/keyvault/variables.tf
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

# --- Networking inputs (from modules/networking outputs) --------------------

variable "private_endpoints_subnet_id" {
  description = "Subnet ID for the Key Vault private endpoint NIC"
  type        = string
}

variable "dns_zone_id_keyvault" {
  description = "Private DNS zone ID for Key Vault (privatelink.vaultcore.azure.net)"
  type        = string
}

# --- AKS workload identity --------------------------------------------------

variable "aks_oidc_issuer_url" {
  description = "OIDC issuer URL from the AKS cluster (from modules/aks outputs)"
  type        = string
}

variable "agent_names" {
  description = "List of agent names to create managed identities and federated credentials for (e.g. ['orchestrator', 'research-agent', 'analysis-agent', 'writer-agent'])"
  type        = list(string)
  default     = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
}

# --- RBAC -------------------------------------------------------------------

variable "admin_principal_id" {
  description = "Object ID of the principal (user, group, or SP) that gets Key Vault Secrets Officer — typically your CI/CD identity or your own AAD object ID"
  type        = string
}

# --- Observability ----------------------------------------------------------

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings (from modules/aks outputs)"
  type        = string
}

# --- Tags -------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "suffix" {
  description = "Short unique suffix for globally unique resource names (e.g. your initials + digits: jp001)"
  type        = string
  default     = ""
}
