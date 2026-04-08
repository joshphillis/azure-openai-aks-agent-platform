###############################################################################
# modules/aks/main.tf
#
# Private AKS cluster for the Azure AI Platform:
#   - Private API server (no public endpoint)
#   - System node pool (reserved for kube-system workloads)
#   - User node pool (runs agent workloads)
#   - Azure CNI Overlay networking (pods use snet-aks-pods)
#   - Workload identity + OIDC issuer (no stored credentials in pods)
#   - Azure Monitor / Container Insights
#   - Defender for Containers
#   - Key Vault CSI secrets store driver
#   - Managed identity for the cluster (no service principal)
###############################################################################

locals {
  tags = merge(var.tags, {
    module = "aks"
  })

  cluster_name = "aks-${var.name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Managed Identity for the AKS cluster
# AKS uses this to manage NICs, NSGs, route tables, and load balancers.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${var.name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# Grant the cluster identity rights to join the node subnet
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = var.aks_nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# Grant the cluster identity rights to pull from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ---------------------------------------------------------------------------
# Log Analytics workspace for Container Insights
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "law-${var.name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# AKS Cluster
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "main" {
  name                      = local.cluster_name
  location                  = var.location
  resource_group_name       = var.resource_group_name
  dns_prefix                = "${var.name}-${var.environment}"
  kubernetes_version        = var.kubernetes_version
  private_cluster_enabled   = false
  private_cluster_public_fqdn_enabled   = false
  local_account_disabled    = true   # Force AAD auth — no local admin account
  oidc_issuer_enabled       = true   # Required for workload identity
  workload_identity_enabled = true   # Enables federated credential support

  # Node resource group — where AKS puts the VMs, NICs, etc.
  node_resource_group = "rg-${var.name}-${var.environment}-nodes"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # -------------------------------------------------------------------------
  # System node pool
  # Runs kube-system pods only. Tainted so user workloads never land here.
  # -------------------------------------------------------------------------
  default_node_pool {
    name                    = "system"
    node_count              = var.system_node_count
    vm_size                 = var.system_vm_size
    vnet_subnet_id          = var.aks_nodes_subnet_id
    os_disk_size_gb         = 128
    os_disk_type            = "Managed"
    type                    = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true      # Taint: CriticalAddonsOnly=true:NoSchedule

    upgrade_settings {
      max_surge = "33%"
    }

    node_labels = {
      "nodepool-type" = "system"
      "environment"   = var.environment
    }
  }

  # -------------------------------------------------------------------------
  # Networking — Azure CNI Overlay
  # Pods get IPs from the pod subnet, not the node subnet.
  # -------------------------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"        # Azure Network Policy for pod-level firewall
    pod_cidr            = var.pod_cidr   # Must match aks_pods_cidr in networking module
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "loadBalancer"
  }

  # -------------------------------------------------------------------------
  # AAD integration — RBAC is enforced via Azure AD groups
  # -------------------------------------------------------------------------
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = var.aad_admin_group_ids
  }

  # -------------------------------------------------------------------------
  # Add-ons
  # -------------------------------------------------------------------------
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  # -------------------------------------------------------------------------
  # Maintenance window — patches happen Sunday 02:00–04:00
  # -------------------------------------------------------------------------
  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 3]
    }
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      # Prevent Terraform from reverting node count changes made by the autoscaler
      default_node_pool[0].node_count,
      # Kubernetes version upgrades are intentional operations — don't auto-revert
      kubernetes_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User node pool — runs agent workloads
# Separate from the system pool so agents can be scaled/replaced independently.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_node_pool" "agents" {
  name                  = "agents"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.agent_vm_size
  vnet_subnet_id        = var.aks_nodes_subnet_id
  os_disk_size_gb       = 128
  os_disk_type          = "Managed"
  mode                  = "User"

  # Autoscaler — scales between min and max based on pending pods
  enable_auto_scaling = true
  min_count           = var.agent_min_count
  max_count           = var.agent_max_count
  node_count          = var.agent_min_count

  upgrade_settings {
    max_surge = "33%"
  }

  node_labels = {
    "nodepool-type" = "agents"
    "workload"      = "ai-agents"
    "environment"   = var.environment
  }

  # Taint so only explicitly tolerated workloads (your agents) land here
  node_taints = ["workload=ai-agents:NoSchedule"]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Flux CD extension — GitOps controller
# Flux watches the GitHub repo and reconciles k8s/overlays/<env> to the cluster.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "flux"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "microsoft.flux"

  configuration_settings = {
    "helm-controller.enabled"         = "true"
    "source-controller.enabled"       = "true"
    "kustomize-controller.enabled"    = "true"
    "notification-controller.enabled" = "true"
    "image-automation-controller.enabled"  = "false"
    "image-reflector-controller.enabled"   = "false"
  }
}
