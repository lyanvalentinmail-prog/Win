output "ip_publica" {
  description = "IP publica para configurar Windows App (el FQDN si defines dns_prefix)."
  value       = azurerm_public_ip.win.ip_address
}

output "nombre_vm" {
  description = "Nombre de la VM en Azure, el mismo de la interfaz y del disco: es lo que espera la az CLI."
  value       = azurerm_windows_virtual_machine.win.name
}

output "region" {
  description = "Region aplicada (la usa scripts/deploy/azure-deploy.ps1 para comprobar capacidad del SKU)."
  value       = azurerm_resource_group.win.location
}

output "grupo_recursos" {
  description = "Grupo de recursos que contiene todo, para 'az ... -g' y para borrar la instalacion entera."
  value       = azurerm_resource_group.win.name
}

output "sku" {
  description = "Tamanho de VM real (el script de preparacion comprueba dentro de la VM que coincide con config/vm.json)."
  value       = azurerm_windows_virtual_machine.win.size
}

output "gpu_esperada" {
  description = "true si el SKU es de la serie NV; Install-GpuDriver.ps1 verificara que el driver esta activo y sin Code 43."
  value       = local.gpu_sku
}

output "comando_bootstrap" {
  description = "Comando exacto para preparar la VM desde tu estacion (requiere la az CLI autenticada)."
  value = join(" ", [
    "az vm run-command invoke",
    "-g ${azurerm_resource_group.win.name}",
    "-n ${azurerm_windows_virtual_machine.win.name}",
    "--command-id RunPowerShellScript",
    "--scripts @scripts/win/Bootstrap-GamingVM.ps1",
    "--parameters ConfigPath=C:\\\\ProgramData\\\\WinGamingVM\\\\config\\\\vm.json",
    "-o json"
  ])
}

output "advertencias_coste" {
  description = "Lo que se factura aunque no juegues, para que nadie lance 'terraform apply' con la duda."
  value = [
    "La VM, los discos gestionados, la IP publica Standard y el egreso se facturan por hora/GB aunque no juegues.",
    "deallocate libera la VM pero el disco de datos sigue facturandose; si no la usas en dias, deallocate y considera detener el facturamiento de la IP.",
    "Con spot_priority=true Azure puede desalojar la VM en cualquier momento.",
  ]
}

output "skus_gpu_y_vcpus" {
  description = "Tabla de SKU de la serie NVadsA10_v5 y sus vCPU reales, para no prometer mas nucleos de los que el SKU da (y para elegir tamano con criterio)."
  value       = local.limites
}
