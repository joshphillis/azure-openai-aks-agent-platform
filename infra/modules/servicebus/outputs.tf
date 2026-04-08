###############################################################################
# modules/servicebus/outputs.tf
###############################################################################

output "namespace_id" {
  description = "Resource ID of the Service Bus namespace"
  value       = azurerm_servicebus_namespace.main.id
}

output "namespace_hostname" {
  description = "Fully qualified hostname of the namespace (e.g. sb-aiplatform-dev.servicebus.windows.net)"
  value       = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "topic_ids" {
  description = "Map of topic name → resource ID"
  value       = { for k, v in azurerm_servicebus_topic.topics : k => v.id }
}
