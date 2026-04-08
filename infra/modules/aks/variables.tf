###############################################################################
# modules/aks/variables.tf
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

# --- Networking inputs (consumed from modules/networking outputs) -----------

variable "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node NICs (from networking module)"
  type        = string
}

variable "aks_pods_subnet_id" {
  description = "Subnet ID for AKS pod overlay (from networking module)"
  type        = string
  default     = null
}

variable "acr_id" {
  description = "Resource ID of the ACR (grants AcrPull to the cluster identity)"
  type        = string
}

# --- Kubernetes version -------------------------------------------------------

variable "kubernetes_version" {
  description = "AKS Kubernetes version (e.g. '1.29'). Pin to a supported minor version."
  type        = string
  default     = "1.29"
}

# --- System node pool ---------------------------------------------------------

variable "system_node_count" {
  description = "Fixed node count for the system pool (3 for HA in prod, 1-2 for dev)"
  type        = number
  default     = 2
}

variable "system_vm_size" {
  description = "VM size for system nodes"
  type        = string
  default     = "Standard_D2s_v5"
}

# --- Agent node pool ----------------------------------------------------------

variable "agent_vm_size" {
  description = "VM size for agent workload nodes"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "agent_min_count" {
  description = "Minimum node count for the agents autoscaler"
  type        = number
  default     = 1
}

variable "agent_max_count" {
  description = "Maximum node count for the agents autoscaler"
  type        = number
  default     = 5
}

# --- Networking CIDRs (must not overlap with VNet subnets) --------------------

variable "pod_cidr" {
  description = "CIDR for pod IPs in CNI overlay mode. Must match aks_pods_cidr in networking module."
  type        = string
  default     = "10.0.2.0/23"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes ClusterIP services (must not overlap with VNet)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "dns_service_ip" {
  description = "IP for the kube-dns service — must be within service_cidr"
  type        = string
  default     = "10.1.0.10"
}

# --- AAD ----------------------------------------------------------------------

variable "aad_admin_group_ids" {
  description = "List of AAD group object IDs granted cluster-admin via Azure RBAC"
  type        = list(string)
  default     = []
}

# --- Observability ------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics workspace retention in days"
  type        = number
  default     = 30
}

# --- Tags ---------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
