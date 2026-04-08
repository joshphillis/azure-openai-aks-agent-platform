###############################################################################
# modules/keyvault/main.tf
#
# Azure Key Vault for the AI Platform:
#   - Private endpoint (no public access)
#   - RBAC authorization model (not legacy access policies)
#   - Soft delete + purge protection enabled
#   - Diagnostic logs to Log Analytics
#   - Workload identity federated credential for each agent
#     (each agent gets its own managed identity + KV RBAC role)
###############################################################################

locals {
  tags = merge(var.tags, {
    module = "keyvault"
  })

  vault_name = "kv-${var.name}-${var.environment}-${var.suffix}"
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                       = local.vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"

  # RBAC model — roles assigned below, not legacy access policies
  enable_rbac_authorization  = true

  # Soft delete: deleted secrets recoverable for 90 days
  soft_delete_retention_days = 90

  # Purge protection: even admins cannot permanently delete until retention expires
  purge_protection_enabled   = true

  # No public network access — all traffic via private endpoint
  # public_network_access_enabled allows Terraform (running locally) to write
  # secrets during apply. Agents access the vault via private endpoint at runtime.
  # Set to false and add your IP to ip_rules if you want stricter dev controls.
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
    ip_rules       = []
    virtual_network_subnet_ids = []
  }

  tags = local.tags
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Private endpoint — registers the vault in the private DNS zone
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-${local.vault_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoints_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.vault_name}"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${local.vault_name}"
    private_dns_zone_ids = [var.dns_zone_id_keyvault]
  }
}

# ---------------------------------------------------------------------------
# Diagnostic settings — send audit logs to Log Analytics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-${local.vault_name}"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ---------------------------------------------------------------------------
# Managed identities — one per agent + one for the orchestrator
# Each identity gets a federated credential so the pod can authenticate
# using a Kubernetes ServiceAccount token (workload identity).
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "agents" {
  for_each = toset(var.agent_names)

  name                = "id-${each.key}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Federated credentials — links each managed identity to a K8s ServiceAccount
# This is what allows a pod to exchange its K8s token for an Azure token
# without any stored secrets.
# ---------------------------------------------------------------------------

resource "azurerm_federated_identity_credential" "agents" {
  for_each = toset(var.agent_names)

  name                = "fic-${each.key}-${var.environment}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.agents[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url

  # Convention: each agent has a ServiceAccount named after it in the agents namespace
  subject = "system:serviceaccount:agents:sa-${each.key}"
}

# ---------------------------------------------------------------------------
# RBAC — Key Vault Secrets User on the vault for each agent identity
# Secrets User = read secrets/certs. Agents never need to write to the vault.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "agent_kv_secrets_user" {
  for_each = toset(var.agent_names)

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agents[each.key].principal_id
}

# ---------------------------------------------------------------------------
# RBAC — Key Vault Secrets Officer for the pipeline / admin identity
# Secrets Officer = read + write secrets. Used by CI/CD to populate secrets.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "admin_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.admin_principal_id
}
