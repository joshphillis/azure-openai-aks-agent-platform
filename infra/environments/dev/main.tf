###############################################################################
# environments/dev/main.tf
#
# Dev environment entrypoint. Calls each module with dev-appropriate sizing.
# Networking is wired first; all other modules consume its outputs.
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100.0, < 4.0.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-aiplatform"
    storage_account_name = "sttfstateaiplatformjp001"
    container_name       = "tfstate"
    key                  = "dev.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

locals {
  name        = "aiplatform"
  environment = "dev"
  location    = var.location

  common_tags = {
    project     = "azure-ai-platform"
    environment = local.environment
    managed_by  = "terraform"
    owner       = var.owner_tag
  }
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}-${local.environment}"
  location = local.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Networking (foundation — all other modules depend on this)
# ---------------------------------------------------------------------------

module "networking" {
  source = "../../modules/networking"

  name                   = local.name
  environment            = local.environment
  location               = local.location
  resource_group_name    = azurerm_resource_group.main.name
  vnet_address_space     = "10.0.0.0/16"
  aks_nodes_cidr         = "10.0.1.0/24"
  aks_pods_cidr          = "10.0.2.0/23"
  private_endpoints_cidr = "10.0.4.0/27"
  tags                   = local.common_tags
}

# ---------------------------------------------------------------------------
# ACR — provisioned before AKS so we can pass acr_id into the cluster module.
# Full ACR config lives in modules/acr (coming next); this stub gets us unblocked.
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "main" {
  name                = "cr${replace(local.name, "-", "")}${local.environment}${var.acr_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  sku                 = "Premium"   # Required for private endpoints + geo-replication
  admin_enabled       = false       # Never use admin credentials — use managed identity
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

module "aks" {
  source = "../../modules/aks"

  name                = local.name
  environment         = local.environment
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name

  # Networking — pod_subnet_id removed, CNI Overlay manages pod IPs internally
  aks_nodes_subnet_id = module.networking.aks_nodes_subnet_id
  acr_id              = azurerm_container_registry.main.id

  # Dev sizing — smaller and cheaper than prod
  kubernetes_version = "1.32"
  system_node_count  = 2
  system_vm_size     = "Standard_D2s_v3"
  agent_vm_size      = "Standard_D2s_v3"
  agent_min_count    = 1
  agent_max_count    = 3
  pod_cidr           = "10.244.0.0/16"

  # AAD admin group — replace with your actual group object ID
  # aad_admin_group_ids = ["<your-aad-group-object-id>"]

  log_retention_days = 30
  tags               = local.common_tags
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

module "keyvault" {
  source = "../../modules/keyvault"

  name                        = local.name
  environment                 = local.environment
  location                    = local.location
  resource_group_name         = azurerm_resource_group.main.name
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  dns_zone_id_keyvault        = module.networking.dns_zone_id_keyvault
  aks_oidc_issuer_url         = module.aks.oidc_issuer_url
  log_analytics_workspace_id  = module.aks.log_analytics_workspace_id

  # Your AAD object ID — run: az ad signed-in-user show --query id -o tsv
  admin_principal_id = var.admin_principal_id

  suffix      = var.acr_suffix
  agent_names = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
  tags        = local.common_tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "vnet_id" {
  value = module.networking.vnet_id
}

output "aks_nodes_subnet_id" {
  value = module.networking.aks_nodes_subnet_id
}

output "private_endpoints_subnet_id" {
  value = module.networking.private_endpoints_subnet_id
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_oidc_issuer_url" {
  description = "Needed when creating federated credentials for workload identity"
  value       = module.aks.oidc_issuer_url
}

output "keyvault_uri" {
  value = module.keyvault.keyvault_uri
}

output "agent_identity_client_ids" {
  description = "Annotate each Kubernetes ServiceAccount with these client IDs"
  value       = module.keyvault.agent_identity_client_ids
}

# ---------------------------------------------------------------------------
# Azure OpenAI
# ---------------------------------------------------------------------------

module "openai" {
  source = "../../modules/openai"

  name                         = local.name
  environment                  = local.environment
  location                     = local.location
  resource_group_name          = azurerm_resource_group.main.name
  private_endpoints_subnet_id  = module.networking.private_endpoints_subnet_id
  dns_zone_id_openai           = module.networking.dns_zone_id_openai
  keyvault_id                  = module.keyvault.keyvault_id
  agent_identity_principal_ids = module.keyvault.agent_identity_principal_ids
  log_analytics_workspace_id   = module.aks.log_analytics_workspace_id

  suffix                       = var.acr_suffix
  gpt4o_capacity_tpm      = 30
  embeddings_capacity_tpm = 30
  tags                    = local.common_tags
}

output "openai_endpoint" {
  value = module.openai.openai_endpoint
}

# ---------------------------------------------------------------------------
# Service Bus
# ---------------------------------------------------------------------------

module "servicebus" {
  source = "../../modules/servicebus"

  name                         = local.name
  environment                  = local.environment
  location                     = local.location
  resource_group_name          = azurerm_resource_group.main.name
  suffix                       = var.acr_suffix
  private_endpoints_subnet_id  = module.networking.private_endpoints_subnet_id
  dns_zone_id_servicebus       = module.networking.dns_zone_id_servicebus
  keyvault_id                  = module.keyvault.keyvault_id
  agent_identity_principal_ids = module.keyvault.agent_identity_principal_ids
  log_analytics_workspace_id   = module.aks.log_analytics_workspace_id
  tags                         = local.common_tags
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

module "monitoring" {
  source = "../../modules/monitoring"

  name                       = local.name
  environment                = local.environment
  resource_group_name        = azurerm_resource_group.main.name
  resource_group_id          = azurerm_resource_group.main.id
  aks_cluster_id             = module.aks.cluster_id
  servicebus_namespace_id    = module.servicebus.namespace_id
  openai_account_id          = module.openai.openai_id
  log_analytics_workspace_id = module.aks.log_analytics_workspace_id
  alert_email_addresses      = [var.alert_email]
  monthly_budget_usd         = 50
  tags                       = local.common_tags
}

output "servicebus_hostname" {
  value = module.servicebus.namespace_hostname
}
