###############################################################################
# modules/aks/outputs.tf
###############################################################################

output "cluster_id" {
  description = "Resource ID of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL — used by the workload identity module to create federated credentials"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity (used for ACR pull role assignment)"
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the cluster managed identity"
  value       = azurerm_user_assigned_identity.aks.principal_id
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (consumed by monitoring module)"
  value       = azurerm_log_analytics_workspace.aks.id
}

output "node_resource_group" {
  description = "The auto-created resource group where AKS puts VMs and NICs"
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}
