###############################################################################
# modules/openai/outputs.tf
###############################################################################

output "openai_id" {
  description = "Resource ID of the Azure OpenAI account"
  value       = azurerm_cognitive_account.openai.id
}

output "openai_endpoint" {
  description = "Endpoint URL for the Azure OpenAI account"
  value       = azurerm_cognitive_account.openai.endpoint
}

output "openai_account_name" {
  description = "Name of the Azure OpenAI account"
  value       = azurerm_cognitive_account.openai.name
}

output "gpt4o_deployment_name" {
  description = "Name of the GPT-4o deployment — agents reference this at runtime"
  value       = azurerm_cognitive_deployment.gpt4o.name
}

output "embeddings_deployment_name" {
  description = "Name of the embeddings deployment"
  value       = azurerm_cognitive_deployment.embeddings.name
}
