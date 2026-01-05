output "resource_groups" {
  description = "Created resource group names"
  value = {
    core       = azurerm_resource_group.nexus_core.name
    data       = azurerm_resource_group.nexus_data.name
    compute    = azurerm_resource_group.nexus_compute.name
    security   = azurerm_resource_group.nexus_security.name
    monitoring = azurerm_resource_group.nexus_monitoring.name
  }
}

output "aks_cluster_name" {
  description = "AKS cluster name"
  value       = module.aks.cluster_name
}

output "aks_cluster_id" {
  description = "AKS cluster ID"
  value       = module.aks.cluster_id
}

output "aks_kube_config" {
  description = "AKS kubeconfig"
  value       = module.aks.kube_config
  sensitive   = true
}

output "app_service_default_hostname" {
  description = "App Service default hostname"
  value       = module.app_service.default_hostname
}

output "function_app_default_hostname" {
  description = "Function App default hostname"
  value       = module.functions.default_hostname
}

output "sql_server_fqdn" {
  description = "SQL Server FQDN"
  value       = module.sql.server_fqdn
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = module.security.key_vault_uri
}

output "apim_gateway_url" {
  description = "API Management gateway URL"
  value       = module.apim.gateway_url
}

output "app_insights_instrumentation_key" {
  description = "Application Insights instrumentation key"
  value       = module.monitoring.app_insights_instrumentation_key
  sensitive   = true
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = module.monitoring.log_analytics_workspace_id
}

output "vnet_id" {
  description = "Virtual network ID"
  value       = module.networking.vnet_id
}