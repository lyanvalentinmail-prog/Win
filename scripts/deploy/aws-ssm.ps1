<#
  .SYNOPSIS
    Entrega y ejecuta el bootstrap en una instancia EC2 por Systems Manager (sin RDP).
  .DESCRIPTION
    Usa SSM porque evita abrir el 3389 a Internet: la instancia no necesita puerto
    de entrada si tiene un rol de IAM con AmazonSSMManagedInstanceCore y salida a
    Internet (NAT o endpoint). Requisitos de la instancia:
      - rol IAM con `AmazonSSMManagedInstanceCore`
      - SSM Agent (viene en las AMIs de Amazon; si no, instalalo)
      - DNS y salida por 443
    El script sube el repo como zip (base64), ejecuta el bootstrap por fases y baja
    los informes. NO toca la contrasena del administrador: se obtiene con la clave
    privada por si la necesitas para RDP.
  .PARAMETER InstanceId        i-0123...
  .PARAMETER Region
  .PARAMETER Fases
  .PARAMETER SoloEstado        Consulta el estado de las fases y no cambia nada.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstanceId,
    [string]$Region = "",
    [string[]]$Fases,
    [switch]$SoloEstado
)
Set-StrictMode -Version 1.0   # 1.0 y no Latest: se leen propiedades opcionales de JSON
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$awsArgs = @()
if ($Region) { $awsArgs += @('--region', $Region) }

function Send-Command {
    param([Parameter(Mandatory)][string]$Comando, [string]$Descripcion = 'comando')
    $archivo = Join-Path $env:TEMP 'gvm-ssm.txt'
    Set-Content -LiteralPath $archivo -Value $Comando -Encoding ASCII
    $id = & aws ssm send-command --instance-ids $InstanceId --document-name 'AWS-RunPowerShellScript' `
        --parameters "commands=$(Get-Content -LiteralPath $archivo -Raw)" `
        --comment "WinGamingVM $Descripcion" --output text --query 'Command.CommandId' @awsArgs
    Remove-Item $archivo -Force -ErrorAction SilentlyContinue
    if (-not $id) { throw "SSM no acepto el comando ($Descripcion)" }
    for ($i = 0; $i -lt 120; $i++) {
        $estado = & aws ssm get-command-invocation --command-id $id --instance-id $InstanceId `
            --output text --query 'Status' @awsArgs 2>$null
        if ($estado -in @('Success', 'Failed', 'Cancelled', 'TimedOut')) {
            $salida = & aws ssm get-command-invocation --command-id $id --instance-id $InstanceId `
                --output text --query 'StandardOutputContent' @awsArgs 2>$null
            $error = & aws ssm get-command-invocation --command-id $id --instance-id $InstanceId `
                --output text --query 'StandardErrorContent' @awsArgs 2>$null
            if ($error) { Write-Host $error -ForegroundColor Red }
            if ($estado -ne 'Success') { throw "SSM: $estado en '$Descripcion'" }
            return $salida
        }
        Start-Sleep -Seconds 5
    }
    throw "SSM no termino '$Descripcion' a tiempo"
}

if ($SoloEstado) {
    Write-Host (Send-Command -Comando 'Get-Content C:\ProgramData\WinGamingVM\state\fases.json' -Descripcion 'estado de fases')
    return
}

$zip = Join-Path $env:TEMP 'win-gaming-vm.zip'
Push-Location $repo
Compress-Archive -Path 'apps', 'config', 'gaming', 'scripts' -DestinationPath $zip -Force
Pop-Location
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
Remove-Item $zip -Force

Write-Host '  entregando repo a C:\ProgramData\WinGamingVM ...' -ForegroundColor Cyan
[void](Send-Command -Comando @"
powershell -NoProfile -Command "`$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path 'C:\ProgramData\WinGamingVM' | Out-Null; [IO.File]::WriteAllBytes('C:\ProgramData\WinGamingVM\repo.zip',[Convert]::FromBase64String('$b64')); Expand-Archive 'C:\ProgramData\WinGamingVM\repo.zip' 'C:\ProgramData\WinGamingVM' -Force; Remove-Item 'C:\ProgramData\WinGamingVM\repo.zip' -Force"
"@ -Descripcion 'entrega')

$extra = ''
if ($Fases) { $extra = " -Fases $($Fases -join ',')" }
Write-Host '  ejecutando el bootstrap ...' -ForegroundColor Cyan
Send-Command -Comando "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WinGamingVM\scripts\win\Bootstrap-GamingVM.ps1$extra" -Descripcion 'bootstrap'
Write-Host ''
Write-Host '  informes:' -ForegroundColor Green
Send-Command -Comando 'Get-ChildItem C:\ProgramData\WinGamingVM\informes | Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name,Length | Format-Table' -Descripcion 'listar informes'
