###############################################################################
# modules/keyvault/outputs.tf
###############################################################################

output "keyvault_id" {
  description = "Resource ID of the Key Vault"
  value       = azurerm_key_vault.main.id
}

output "keyvault_uri" {
  description = "URI of the Key Vault (e.g. https://kv-aiplatform-dev.vault.azure.net/)"
  value       = azurerm_key_vault.main.vault_uri
}

output "keyvault_name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.main.name
}

# Agent identity outputs — consumed by the agents Kubernetes manifests
# to set the azure.workload.identity/client-id annotation on each ServiceAccount.

output "agent_identity_client_ids" {
  description = "Map of agent name → managed identity client ID. Use as the azure.workload.identity/client-id annotation on each Kubernetes ServiceAccount."
  value       = { for k, v in azurerm_user_assigned_identity.agents : k => v.client_id }
}

output "agent_identity_principal_ids" {
  description = "Map of agent name → managed identity principal ID"
  value       = { for k, v in azurerm_user_assigned_identity.agents : k => v.principal_id }
}
