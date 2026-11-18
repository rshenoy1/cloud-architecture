terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "platform" {
  name     = "rg-enterprise-ai-prod"
  location = "East US"
}

resource "azurerm_storage_account" "docs_account" {
  name                            = "stenterpriseaidocsprod"
  resource_group_name             = azurerm_resource_group.platform.name
  location                        = azurerm_resource_group.platform.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "documents" {
  name                  = "enterprise-ai-docs"
  storage_account_id    = azurerm_storage_account.docs_account.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "app_identity" {
  name                = "id-ai-platform-app-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
}

resource "azurerm_role_assignment" "app_blob_access" {
  scope                = azurerm_storage_account.docs_account.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app_identity.principal_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "platform_kv" {
  name                       = "kv-enterprise-ai-prod01"
  location                   = azurerm_resource_group.platform.location
  resource_group_name        = azurerm_resource_group.platform.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "app_kv_secrets_user" {
  scope                = azurerm_key_vault.platform_kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app_identity.principal_id
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-enterprise-ai-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "public_appgw" {
  name                 = "snet-appgw-public"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private_app" {
  name                 = "snet-app-private"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.10.0/24"]
}

resource "azurerm_subnet" "private_db" {
  name                 = "snet-db-private"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.20.0/24"]
}

resource "azurerm_network_security_group" "appgw_nsg" {
  name                = "nsg-appgw-public"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw_nsg_assoc" {
  subnet_id                 = azurerm_subnet.public_appgw.id
  network_security_group_id = azurerm_network_security_group.appgw_nsg.id
}

resource "azurerm_network_security_group" "app_nsg" {
  name                = "nsg-app-private"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  security_rule {
    name                       = "AllowAppGWToApp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app_nsg_assoc" {
  subnet_id                 = azurerm_subnet.private_app.id
  network_security_group_id = azurerm_network_security_group.app_nsg.id
}

resource "azurerm_network_security_group" "db_nsg" {
  name                = "nsg-db-private"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  security_rule {
    name                       = "AllowAppToPostgres"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.0.10.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "db_nsg_assoc" {
  subnet_id                 = azurerm_subnet.private_db.id
  network_security_group_id = azurerm_network_security_group.db_nsg.id
}

resource "azurerm_postgresql_flexible_server" "postgres" {
  name                          = "psql-enterprise-ai-prod"
  resource_group_name           = azurerm_resource_group.platform.name
  location                      = azurerm_resource_group.platform.location
  version                       = "16"
  administrator_login           = "ai_admin"
  administrator_password        = "ReplaceWithKeyVaultSecret123!"
  zone                          = "1"
  storage_mb                    = 32768
  sku_name                      = "GP_Standard_D2s_v3"
  public_network_access_enabled = false

  high_availability {
    mode = "ZoneRedundant"
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-enterprise-ai-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  dns_prefix          = "enterprise-ai-aks"

  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D2s_v3"
    vnet_subnet_id       = azurerm_subnet.private_app.id
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 6
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app_identity.id]
  }
}

resource "azurerm_cognitive_account" "openai" {
  name                          = "oai-enterprise-ai-prod"
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  kind                          = "OpenAI"
  sku_name                      = "S0"
  custom_subdomain_name         = "oai-enterprise-ai-prod"
  public_network_access_enabled = false
}

resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = "gpt-4o"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-08-06"
  }

  sku {
    name     = "Standard"
    capacity = 30
  }
}

resource "azurerm_role_assignment" "aks_openai_user" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.app_identity.principal_id
}

resource "azurerm_private_endpoint" "openai_pe" {
  name                = "pe-openai-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = azurerm_subnet.private_app.id

  private_service_connection {
    name                           = "psc-openai-prod"
    private_connection_resource_id = azurerm_cognitive_account.openai.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "law-enterprise-ai-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "apm" {
  name                = "appi-enterprise-ai-prod"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  workspace_id        = azurerm_log_analytics_workspace.logs.id
  application_type    = "web"
}
