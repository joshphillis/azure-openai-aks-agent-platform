###############################################################################
# modules/networking/outputs.tf
#
# Downstream modules (aks, openai, keyvault, acr, servicebus) consume these
# outputs to wire their resources into this VNet without hardcoding IDs.
###############################################################################

output "vnet_id" {
  description = "Resource ID of the VNet"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the VNet"
  value       = azurerm_virtual_network.main.name
}

output "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node pools"
  value       = azurerm_subnet.aks_nodes.id
}

output "aks_pods_subnet_id" {
  description = "Subnet ID for AKS pod overlay"
  value       = azurerm_subnet.aks_pods.id
}

output "private_endpoints_subnet_id" {
  description = "Subnet ID to place all private endpoint NICs into"
  value       = azurerm_subnet.private_endpoints.id
}

# DNS zone IDs — passed into the openai, keyvault, acr, servicebus modules
# so they can register their private endpoint A records in the correct zone.

output "dns_zone_id_keyvault" {
  description = "Private DNS zone ID for Key Vault"
  value       = azurerm_private_dns_zone.keyvault.id
}

output "dns_zone_id_acr" {
  description = "Private DNS zone ID for ACR"
  value       = azurerm_private_dns_zone.acr.id
}

output "dns_zone_id_openai" {
  description = "Private DNS zone ID for Azure OpenAI"
  value       = azurerm_private_dns_zone.openai.id
}

output "dns_zone_id_servicebus" {
  description = "Private DNS zone ID for Service Bus"
  value       = azurerm_private_dns_zone.servicebus.id
}
