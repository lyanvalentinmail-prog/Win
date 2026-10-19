# -----------------------------------------------------------------------------
# Win Gaming VM — Azure (via primaria)
#
# Crea: grupo de recursos, VNet/subred, NSG con RDP limitado a tus CIDR (o cerrado),
# IP publica, disco de datos gestionado persistente, VM Windows con GPU (serie NV*)
# y la extension del driver NVIDIA GRID cuando el SKU la admite.
#
# NO guarda credenciales: vm_admin_password es una variable sin valor por defecto.
# Pasala por entorno:  export TF_VAR_vm_admin_password='...'  (o usa -var-file local,
# que esta en .gitignore).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  skip_provider_registration = var.skip_provider_registration
}

resource "azurerm_resource_group" "win" {
  name     = var.resource_group_name != null ? var.resource_group_name : "rg-${var.name}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_public_ip" "win" {
  name                = "pip-${var.name}"
  location            = azurerm_resource_group.win.location
  resource_group_name = azurerm_resource_group.win.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.dns_prefix
  tags                = var.tags
}

resource "azurerm_network_security_group" "win" {
  name                = "nsg-${var.name}"
  location            = azurerm_resource_group.win.location
  resource_group_name = azurerm_resource_group.win.name
  tags                = var.tags
}

# RDP: solo desde las CIDR declaradas. Si la lista esta vacia NO se crea la regla y
# el acceso tiene que ir por tunel (Bastion/Tailscale/SSH) — decision deliberada.
resource "azurerm_network_security_rule" "rdp" {
  count = length(var.rdp_allowed_cidrs) > 0 ? 1 : 0

  name                        = "allow-rdp-from-allowed-cidrs"
  resource_group_name         = azurerm_resource_group.win.name
  network_security_group_name = azurerm_network_security_group.win.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.rdp_port)
  source_address_prefixes     = var.rdp_allowed_cidrs
  destination_address_prefix  = "*"
  description                 = "Windows App (RDP) desde las IP del usuario; gestionado por infra/azure"
}

resource "azurerm_network_security_rule" "rdp_udp" {
  count = length(var.rdp_allowed_cidrs) > 0 && var.enable_rdp_udp ? 1 : 0

  name                        = "allow-rdp-udp-from-allowed-cidrs"
  resource_group_name         = azurerm_resource_group.win.name
  network_security_group_name = azurerm_network_security_group.win.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.rdp_port)
  source_address_prefixes     = var.rdp_allowed_cidrs
  destination_address_prefix  = "*"
  description                 = "Canal UDP de RDP (mejora la fluidez; se negocia con el cliente)"
}

# Sunshine/Moonlight: solo si el canal de juego esta pedido Y hay CIDR explicitas.
resource "azurerm_network_security_rule" "game_stream" {
  count = var.enable_game_stream && length(var.rdp_allowed_cidrs) > 0 ? 1 : 0

  name                        = "allow-game-stream-tcp-udp"
  resource_group_name         = azurerm_resource_group.win.name
  network_security_group_name = azurerm_network_security_group.win.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_ranges     = ["47984", "47989", "47990", "48010"]
  source_address_prefixes     = var.rdp_allowed_cidrs
  destination_address_prefix  = "*"
  description                 = "Sunshine (canal de juego). Los puertos UDP 47998-48002 se abren dentro de la VM via Set-Sunshine.ps1"
}

resource "azurerm_subnet_network_security_group_association" "win" {
  subnet_id                 = azurerm_subnet.win.id
  network_security_group_id = azurerm_network_security_group.win.id
}
