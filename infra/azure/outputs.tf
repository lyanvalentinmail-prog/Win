output "ip_publica" {
  description = "IP publica para configurar Windows App (el FQDN si defines dns_prefix)."
  value       = azurerm_public_ip.win.ip_address
}

output "nombre_vm" {
  value = azurerm_windows_virtual_machine.win.name
}

output "region" {
  description = "Region aplicada (la usa scripts/deploy/azure-deploy.ps1 para comprobar capacidad del SKU)."
  value       = azurerm_resource_group.win.location
}

output "grupo_recursos" {
  value = azurerm_resource_group.win.name
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
  value       = join(" ", [
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
  value = [
    "La VM, los discos gestionados, la IP publica Standard y el egreso se facturan por hora/GB aunque no juegues.",
    "deallocate libera la VM pero el disco de datos sigue facturandose; si no la usas en dias, deallocate y considera detener el facturamiento de la IP.",
    "Con spot_priority=true Azure puede desalojar la VM en cualquier momento.",
  ]
}
