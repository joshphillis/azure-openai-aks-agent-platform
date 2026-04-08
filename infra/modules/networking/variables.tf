###############################################################################
# modules/networking/variables.tf
###############################################################################

variable "name" {
  description = "Short platform name used in resource naming (e.g. 'aiplatform')"
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
  description = "Azure region for all networking resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group to deploy into"
  type        = string
}

variable "vnet_address_space" {
  description = "CIDR block for the VNet (e.g. '10.0.0.0/16')"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aks_nodes_cidr" {
  description = "CIDR for the AKS node subnet (e.g. '10.0.1.0/24')"
  type        = string
  default     = "10.0.1.0/24"
}

variable "aks_pods_cidr" {
  description = "CIDR for AKS pod overlay (e.g. '10.0.2.0/23'). Must not overlap with nodes or PEs."
  type        = string
  default     = "10.0.2.0/23"
}

variable "private_endpoints_cidr" {
  description = "CIDR for the private endpoints subnet (e.g. '10.0.4.0/27')"
  type        = string
  default     = "10.0.4.0/27"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
