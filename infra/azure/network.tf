resource "azurerm_virtual_network" "win" {
  name                = "vnet-${var.name}"
  location            = azurerm_resource_group.win.location
  resource_group_name = azurerm_resource_group.win.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "win" {
  name                 = "snu-${var.name}"
  resource_group_name  = azurerm_resource_group.win.name
  virtual_network_name = azurerm_virtual_network.win.name
  address_prefixes     = [var.subnet_cidr]
}

# Diagnostico de arranque (arranque fallido = pantallazo): usa el storage de la VM.
resource "azurerm_storage_account" "diag" {
  count = var.boot_diagnostics ? 1 : 0

  name                     = replace(substr("st${var.name}", 0, 24), "[^a-z0-9]", "")
  resource_group_name      = azurerm_resource_group.win.name
  location                 = azurerm_resource_group.win.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}
