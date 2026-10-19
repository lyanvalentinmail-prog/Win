# -----------------------------------------------------------------------------
# VM Windows + discos. Nota de honestidad: no se configura "OS en disco temporal"
# desde aqui porque el soporte exacto depende del SKU y de la imagen; si quieres
# economizar, arranca el SO desde el disco temporal del SKU y MUEVE los juegos a D:
# (el disco gestionado de este modulo), que es lo que configuran los scripts.
# -----------------------------------------------------------------------------

locals {
  edition_conf = {
    windows-server-2025-desktop = {
      publisher = "MicrosoftWindowsServer", offer = "WindowsServer", sku = "2025-datacenter-azure-edition"
    }
    windows-server-2022-desktop = {
      publisher = "MicrosoftWindowsServer", offer = "WindowsServer", sku = "2022-datacenter-azure-edition"
    }
    windows-11-pro = {
      publisher = "MicrosoftWindowsDesktop", offer = "windows-11", sku = "win11-25h2-pro"
    }
    windows-11-enterprise = {
      publisher = "MicrosoftWindowsDesktop", offer = "windows-11", sku = "win11-25h2-ent"
    }
  }
  img      = lookup(local.edition_conf, var.windows_edition, local.edition_conf["windows-server-2025-desktop"])
  gpu_sku  = startswith(var.vm_size, "Standard_NV")
  limites  = { Standard_NV6ads_A10_v5 = 6, Standard_NV12ads_A10_v5 = 12, Standard_NV18ads_A10_v5 = 18, Standard_NV36ads_A10_v5 = 36 }
}

resource "azurerm_network_interface" "win" {
  name                          = "nic-${var.name}"
  location                      = azurerm_resource_group.win.location
  resource_group_name           = azurerm_resource_group.win.name
  enable_accelerated_networking = var.accelerated_networking

  ip_configuration {
    name                          = "ipcfg1"
    subnet_id                     = azurerm_subnet.win.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.win.id
  }
  tags = var.tags
}

resource "azurerm_windows_virtual_machine" "win" {
  name                       = var.name
  location                   = azurerm_resource_group.win.location
  resource_group_name        = azurerm_resource_group.win.name
  network_interface_ids      = [azurerm_network_interface.win.id]
  size                       = var.vm_size
  admin_username             = var.vm_admin_user
  admin_password             = var.vm_admin_password
  computer_name              = var.name
  timezone                   = var.timezone
  provision_vm_agent         = true
  enable_automatic_updates   = var.automatic_updates
  priority                   = var.spot_priority ? "Spot" : "Regular"
  eviction_policy            = var.spot_priority ? "Deallocate" : null
  patch_mode                 = var.automatic_updates ? "AutomaticByPlatform" : "Manual"
  security_type              = "TrustedLaunch"
  vtpm_enabled               = true

  source_image_reference {
    publisher = local.img.publisher
    offer     = local.img.offer
    sku       = local.img.sku
    version   = var.image_version
  }

  os_disk {
    name                 = "os-${var.name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_sku
    disk_size_gb         = var.os_disk_gb
  }

  boot_diagnostics {
    storage_account_uri = var.boot_diagnostics ? azurerm_storage_account.diag[0].primary_blob_endpoint : null
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(var.vm_admin_password) >= 12
      error_message = "vm_admin_password debe tener 12+ caracteres: Azure exige 3 categorias de complejidad y este proyecto pide un minimo mas alto."
    }
    precondition {
      condition     = var.data_disk_gb == 0 || var.data_disk_gb >= 128
      error_message = "El disco de datos gestionado empieza en 128 GiB (los tamaños validos son 128, 256, 512, 1024, 2048, 4096, ...)."
    }
    precondition {
      condition     = var.os_disk_gb >= 64
      error_message = "La instalacion de Windows + apps + juegos no cabe en menos de 64 GiB; el schema de config/vm.json lo impide tambien."
    }
    precondition {
      condition     = !var.enable_game_stream || local.gpu_sku
      error_message = "enable_game_stream=true pide un SKU de la serie NV: sin GPU no hay codificador por hardware y Moonlight/Sunshine no tendria sentido (los scripts lo reportan igual, pero aqui se corta antes de facturar)."
    }
  }
}

# Disco de datos PERSISTENTE. El disco temporal del SKU (180-720 GiB segun tamano)
# se pierde al deallocate/relocate: aqui vive lo que debe durar.
resource "azurerm_managed_disk" "datos" {
  count = var.data_disk_gb > 0 ? 1 : 0

  name                 = "disk-datos-${var.name}"
  location             = azurerm_resource_group.win.location
  resource_group_name  = azurerm_resource_group.win.name
  storage_account_type = var.data_disk_sku
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "datos" {
  count = var.data_disk_gb > 0 ? 1 : 0

  managed_disk_ref    = azurerm_managed_disk.datos[0].id
  virtual_machine_id  = azurerm_windows_virtual_machine.win.id
  lun                 = 0
  caching             = "None"
}

# Spot (var.spot_priority): barato y ADECUADO SOLO PARA PRUEBAS — Azure puede
# desalojar la VM en cualquier momento. Se configura con `priority`/`eviction_policy`
# en el propio recurso azurerm_windows_virtual_machine (ver arriba), no con un
# recurso aparte, para que el disco de datos y el NSG no se queden huerfanos.
# --- Preparacion del SO: se hace con Run Command (no con user_data) -------------
# user_data tiene 64 KB y no es idempotente; el patrón soportado es lanzar el
# bootstrap con `az vm run-command invoke`, que ademas nos deja reintentar fase
# a fase. Ver scripts/deploy/azure-deploy.ps1 (hace apply + run-command + espera).
