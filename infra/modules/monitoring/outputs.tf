###############################################################################
# modules/monitoring/outputs.tf
###############################################################################

output "action_group_id" {
  description = "Resource ID of the monitor action group"
  value       = azurerm_monitor_action_group.platform.id
}
