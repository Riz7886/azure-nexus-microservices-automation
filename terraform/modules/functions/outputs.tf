output "default_hostname" {
  value = azurerm_linux_function_app.functions.default_hostname
}

output "id" {
  value = azurerm_linux_function_app.functions.id
}

output "identity_principal_id" {
  value = azurerm_linux_function_app.functions.identity[0].principal_id
}
