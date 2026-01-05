terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.45"
    }
  }
  backend "azurerm" {
    resource_group_name  = "nexus-terraform-state-rg"
    storage_account_name = "nexusterraformstate"
    container_name       = "tfstate"
    key                  = "nexus-microservices.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    Environment      = var.environment
    Project          = "Nexus-Microservices"
    ManagedBy        = "Terraform"
    CostCenter       = var.cost_center
    DataClassification = "PHI"
    Compliance       = "HIPAA-SOC2"
    CreatedDate      = timestamp()
  }
  
  resource_prefix = "nexus-${var.environment}"
  location        = var.location
}

resource "azurerm_resource_group" "nexus_core" {
  name     = "${local.resource_prefix}-core-rg"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "nexus_data" {
  name     = "${local.resource_prefix}-data-rg"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "nexus_compute" {
  name     = "${local.resource_prefix}-compute-rg"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "nexus_security" {
  name     = "${local.resource_prefix}-security-rg"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "nexus_monitoring" {
  name     = "${local.resource_prefix}-monitoring-rg"
  location = local.location
  tags     = local.common_tags
}

module "networking" {
  source = "./modules/networking"
  
  resource_group_name = azurerm_resource_group.nexus_core.name
  location            = local.location
  environment         = var.environment
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

module "aks" {
  source = "./modules/aks"
  
  resource_group_name     = azurerm_resource_group.nexus_compute.name
  location                = local.location
  environment             = var.environment
  vnet_subnet_id          = module.networking.aks_subnet_id
  dns_service_ip          = var.aks_dns_service_ip
  service_cidr            = var.aks_service_cidr
  node_count              = var.aks_node_count
  vm_size                 = var.aks_vm_size
  max_pods                = var.aks_max_pods
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                    = local.common_tags
  
  depends_on = [module.networking]
}

module "app_service" {
  source = "./modules/app-service"
  
  resource_group_name = azurerm_resource_group.nexus_compute.name
  location            = local.location
  environment         = var.environment
  subnet_id           = module.networking.app_service_subnet_id
  key_vault_id        = module.security.key_vault_id
  app_insights_key    = module.monitoring.app_insights_instrumentation_key
  tags                = local.common_tags
  
  depends_on = [module.networking, module.security, module.monitoring]
}

module "functions" {
  source = "./modules/functions"
  
  resource_group_name = azurerm_resource_group.nexus_compute.name
  location            = local.location
  environment         = var.environment
  subnet_id           = module.networking.functions_subnet_id
  storage_account_name = "${replace(local.resource_prefix, "-", "")}funcsa"
  key_vault_id        = module.security.key_vault_id
  app_insights_key    = module.monitoring.app_insights_instrumentation_key
  tags                = local.common_tags
  
  depends_on = [module.networking, module.security, module.monitoring]
}

module "sql" {
  source = "./modules/sql"
  
  resource_group_name     = azurerm_resource_group.nexus_data.name
  location                = local.location
  environment             = var.environment
  subnet_id               = module.networking.sql_subnet_id
  admin_username          = var.sql_admin_username
  admin_password          = var.sql_admin_password
  key_vault_id            = module.security.key_vault_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                    = local.common_tags
  
  depends_on = [module.networking, module.security]
}

module "data_factory" {
  source = "./modules/data-factory"
  
  resource_group_name = azurerm_resource_group.nexus_data.name
  location            = local.location
  environment         = var.environment
  key_vault_id        = module.security.key_vault_id
  tags                = local.common_tags
  
  depends_on = [module.security]
}

module "databricks" {
  source = "./modules/databricks"
  
  resource_group_name = azurerm_resource_group.nexus_data.name
  location            = local.location
  environment         = var.environment
  vnet_id             = module.networking.vnet_id
  private_subnet_name = module.networking.databricks_private_subnet_name
  public_subnet_name  = module.networking.databricks_public_subnet_name
  tags                = local.common_tags
  
  depends_on = [module.networking]
}

module "security" {
  source = "./modules/security"
  
  resource_group_name = azurerm_resource_group.nexus_security.name
  location            = local.location
  environment         = var.environment
  tenant_id           = var.tenant_id
  tags                = local.common_tags
}

module "apim" {
  source = "./modules/apim"
  
  resource_group_name = azurerm_resource_group.nexus_core.name
  location            = local.location
  environment         = var.environment
  subnet_id           = module.networking.apim_subnet_id
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  key_vault_id        = module.security.key_vault_id
  app_insights_id     = module.monitoring.app_insights_id
  tags                = local.common_tags
  
  depends_on = [module.networking, module.security, module.monitoring]
}

module "service_bus" {
  source = "./modules/service-bus"
  
  resource_group_name = azurerm_resource_group.nexus_core.name
  location            = local.location
  environment         = var.environment
  subnet_id           = module.networking.service_bus_subnet_id
  tags                = local.common_tags
  
  depends_on = [module.networking]
}

module "event_grid" {
  source = "./modules/event-grid"
  
  resource_group_name = azurerm_resource_group.nexus_core.name
  location            = local.location
  environment         = var.environment
  tags                = local.common_tags
}

module "monitoring" {
  source = "./modules/monitoring"
  
  resource_group_name = azurerm_resource_group.nexus_monitoring.name
  location            = local.location
  environment         = var.environment
  tags                = local.common_tags
}

module "storage" {
  source = "./modules/storage"
  
  resource_group_name = azurerm_resource_group.nexus_data.name
  location            = local.location
  environment         = var.environment
  subnet_id           = module.networking.storage_subnet_id
  tags                = local.common_tags
  
  depends_on = [module.networking]
}
