<#
.SYNOPSIS
  Devuelve la sesion interactiva a la CONSOLA para que Sunshine pueda capturar pantalla.
.DESCRIPTION
  Problema real y conocido: un servicio de game streaming captura la sesion de consola.
  Al entrar por RDP, Windows desconecta la consola y deja la pantalla "bloqueada": el stream
  se ve negro o congelado. Este script mueve la sesion RDP activa a la consola con `tscon`,
  lo que mantiene el escritorio visible para Sunshine... y CORTA tu conexion RDP (es el
  precio: la misma sesion no puede estar en dos sitios).

  Uso previsto: lanzarlo desde la propia sesion remota justo antes de jugar por Moonlight,
  o dejarlo atado a una tarea (lo hace Set-Sunshine.ps1 con keepConsoleSession=true).

  Alternativa sin tscon: desconectar de RDP y conectar por VNC/consola del proveedor, o
  usar Windows App solo para escritorio y jugar desde otro dispositivo.
.NOTES
  No es magia: es el truco documentado de la comunidad (tscon /dest:console) y solo tiene
  efecto en ediciones con sesion de consola disponible.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$Sesion = 0,
    [int]$EsperaSegundos = 3
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force
Initialize-GvmRuntime -Nombre 'consola' | Out-Null

# Sesion a mover: por defecto la actual (la de RDP). Con -Sesion <id> se fuerza otra.
$sid = if ($Sesion -gt 0) { $Sesion } else { (Get-Process -Id $PID).SessionId }
$argos = @($sid, '/dest:console')
Write-GvmLog -Mensaje "tscon $sid /dest:console  (espera $EsperaSegundos s antes de ejecutar para que puedas guardar)"
Start-Sleep -Seconds $EsperaSegundos
if ($PSCmdlet.ShouldProcess("sesion $sid", 'devolver a consola')) {
    & query.exe session | Out-String | ForEach-Object { Write-GvmLog -Mensaje $_ }
    & $env:SystemRoot\System32\tscon.exe @argos
    Write-GvmLog -Nivel OK -Mensaje "tscon devolvio la sesion a consola (codigo $LASTEXITCODE). La conexion RDP se ha cortado: conecta ahora con Moonlight."
}
