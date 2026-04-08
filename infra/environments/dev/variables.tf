###############################################################################
# environments/dev/variables.tf
###############################################################################

variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "eastus2"
}

variable "owner_tag" {
  description = "Owner tag value for cost tracking (your name or team)"
  type        = string
  default     = "joshua"
}

variable "admin_principal_id" {
  description = "Your AAD object ID — grants Key Vault Secrets Officer so you can populate secrets. Run: az ad signed-in-user show --query id -o tsv"
  type        = string
}

variable "alert_email" {
  description = "Email address for monitoring alerts and budget notifications"
  type        = string
}

variable "acr_suffix" {
  description = "Short unique suffix for the ACR name — ACR names are globally unique (e.g. your initials + 3 digits: jp001)"
  type        = string
  default     = ""
}
