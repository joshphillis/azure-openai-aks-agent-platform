###############################################################################
# modules/openai/main.tf
#
# Azure OpenAI Service for the AI Platform:
#   - Private endpoint (no public access)
#   - GPT-4o deployment with configurable capacity
#   - Text embedding deployment (agents need embeddings for retrieval)
#   - RBAC authorization — no API keys, managed identity only
#   - Diagnostic logs to Log Analytics
###############################################################################

locals {
  tags = merge(var.tags, {
    module = "openai"
  })

  account_name = "aoai-${var.name}-${var.environment}-${var.suffix}"
}

# ---------------------------------------------------------------------------
# Azure OpenAI account
# ---------------------------------------------------------------------------

resource "azurerm_cognitive_account" "openai" {
  name                          = local.account_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  kind                          = "OpenAI"
  sku_name                      = "S0"
  public_network_access_enabled = false
  custom_subdomain_name         = local.account_name  # Required when network_acls is set

  # Disable local auth — forces all callers to use managed identity + RBAC
  local_auth_enabled = false

  identity {
    type = "SystemAssigned"
  }

  network_acls {
    default_action = "Deny"
    ip_rules       = []
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Model deployments
# ---------------------------------------------------------------------------

# Primary reasoning model — used by orchestrator + analysis agent
resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = var.gpt4o_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = var.gpt4o_model_version
  }

  scale {
    type     = "Standard"
    capacity = var.gpt4o_capacity_tpm  # Tokens per minute in thousands
  }
}

# Embedding model — used by research agent for vector retrieval
resource "azurerm_cognitive_deployment" "embeddings" {
  name                 = var.embeddings_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "text-embedding-3-large"
    version = "1"
  }

  scale {
    type     = "Standard"
    capacity = var.embeddings_capacity_tpm
  }
}

# ---------------------------------------------------------------------------
# Private endpoint
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "openai" {
  name                = "pe-${local.account_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoints_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.account_name}"
    private_connection_resource_id = azurerm_cognitive_account.openai.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${local.account_name}"
    private_dns_zone_ids = [var.dns_zone_id_openai]
  }
}

# ---------------------------------------------------------------------------
# RBAC — Cognitive Services OpenAI User for each agent identity
# This role allows: list deployments, submit completions/embeddings requests.
# It does NOT allow: read API keys, manage the account, create deployments.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "agent_openai_user" {
  for_each = var.agent_identity_principal_ids

  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = each.value
}

# ---------------------------------------------------------------------------
# Diagnostic settings
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "openai" {
  name                       = "diag-${local.account_name}"
  target_resource_id         = azurerm_cognitive_account.openai.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "Audit"
  }

  enabled_log {
    category = "RequestResponse"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ---------------------------------------------------------------------------
# Store endpoint + deployment names in Key Vault
# Agents read these at runtime via the CSI secrets store driver —
# no hardcoded endpoints in container images or manifests.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "openai_endpoint" {
  name         = "openai-endpoint"
  value        = azurerm_cognitive_account.openai.endpoint
  key_vault_id = var.keyvault_id

  tags = local.tags
}

resource "azurerm_key_vault_secret" "openai_gpt4o_deployment" {
  name         = "openai-gpt4o-deployment"
  value        = var.gpt4o_deployment_name
  key_vault_id = var.keyvault_id

  tags = local.tags
}

resource "azurerm_key_vault_secret" "openai_embeddings_deployment" {
  name         = "openai-embeddings-deployment"
  value        = var.embeddings_deployment_name
  key_vault_id = var.keyvault_id

  tags = local.tags
}
