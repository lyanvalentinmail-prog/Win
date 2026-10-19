<#
  .SYNOPSIS
    Respaldos: instantanea del disco de datos (Azure) o del volumen (AWS) antes de tocar nada.
  .DESCRIPTION
    El riesgo real de este proyecto no es perder la VM: es perder la libreria de juegos y los
    perfiles que tardan horas en reinstalarse. Este script documenta y ejecuta el respaldo
    barato (instantanea del disco, no copia de ficheros) y el snapshot de KVM.
  .PARAMETER Proveedor        azure | aws | kvm
  .PARAMETER Recurso          Nombre/ID del disco (Azure), volume-id (AWS) o dominio (KVM).
  .PARAMETER Etiqueta
  .EXAMPLE
    .\backup-disk.ps1 -Proveedor azure -Recurso disk-datos-wingamingvm01 -Etiqueta pre-actualizacion
  .NOTES
    Una instantanea de un disco con escrituras en curso puede ser incoherente: pausa el
    lanzador y cierra los juegos (o apaga la VM) antes de respaldar.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('azure', 'aws', 'kvm')][string]$Proveedor,
    [Parameter(Mandatory)][string]$Recurso,
    [string]$Etiqueta = (Get-Date -Format 'yyyyMMdd-HHmm'),
    [string]$ResourceGroup = ''
)
Set-StrictMode -Version 1.0   # 1.0 y no Latest: se leen propiedades opcionales de JSON
$ErrorActionPreference = 'Stop'

switch ($Proveedor) {
    'azure' {
        if (-not $ResourceGroup) { throw 'Azure necesita -ResourceGroup.' }
        Write-Host '  APAGA la VM antes de respaldar para evitar un snapshot incoherente:' -ForegroundColor Yellow
        Write-Host "    az vm deallocate -g $ResourceGroup -n <vm>"
        Write-Host '  Instantanea (se cobra por GB/mes, es el respaldo barato):' -ForegroundColor Cyan
        Write-Host "    az snapshot create -g $ResourceGroup -n snap-$Recurso-$Etiqueta --source /subscriptions/.../disks/$Recurso"
        Write-Host '  Restaurar: az disk create --source snapshot ... y reenganchar a la VM.'
        if (Get-Command az -ErrorAction SilentlyContinue) {
            & az vm list -d --query "[].{Nombre:name, Poder:powerState.code, Disco:storageProfile.dataDisks[0].name}" -o table
        }
    }
    'aws' {
        Write-Host '  AWS: los EBS snapshots son consistents si usas la API de snapshot de volumen:' -ForegroundColor Cyan
        Write-Host "    aws ec2 create-snapshot --volume-id $Recurso --description ""win-gaming $Etiqueta"""
        Write-Host '  Antes: detener la instancia (o al menos desmontar D: desde dentro).'
    }
    'kvm' {
        Write-Host '  KVM: instantanea externa del disco de datos (no suspende la VM):' -ForegroundColor Cyan
        Write-Host "    virsh snapshot-create-as --domain $Recurso --name $Etiqueta --disk-only --atomic"
        Write-Host '  Volver: virsh snapshot-revert --domain' $Recurso '-n' $Etiqueta
        Write-Host '  O respaldo frio: qemu-img convert -c -O qcow2 disco-datos.qcow2 respaldo-'$Etiqueta'.qcow2'
    }
}
Write-Host ''
Write-Host '  Recordatorio: el disco TEMPORAL del SKU de Azure NO se respalda: se pierde con el deallocate.' -ForegroundColor Yellow
Write-Host '  Por eso el proyecto instala los juegos en D: (disco gestionado persistente).'
