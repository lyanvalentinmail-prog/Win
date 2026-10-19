<#
  .SYNOPSIS
    Orquesta desde tu estacion: terraform apply + entrega del bootstrap + fases + informe.
  .DESCRIPTION
    No sustituye a Terraform: lo llama. Secuencia real:

      1) `terraform apply` en infra/azure (crea RG, red, NSG, IP, VM y disco de datos).
      2) Espera a que el agente de VM este listo (`az vm list-instance-view`).
      3) Copia config/vm.json y los scripts a la VM con `az vm run-command` (sin abrir
         puertos; usa el canal de la extension VM Access, que sale por 443).
      4) Ejecuta el bootstrap por fases y recupera los informes.

    Los ficheros de datos (config, catalogos, perfiles) viajan como JSON dentro del
    comando: no hay secretos en el repo y el run-command se borra al terminar.
  .PARAMETER ResourceGroup
  .PARAMETER Name              Nombre de la VM.
  .PARAMETER ConfigFile        config/vm.json local (se sube a ProgramData).
  .PARAMETER Fases             Fases a ejecutar (vacío = todas).
  .PARAMETER SaltarTerraform   Si la VM ya existe, solo entrega y ejecuta.
  .EXAMPLE
    .\azure-deploy.ps1 -ResourceGroup rg-wingamingvm01 -Name wingamingvm01 -ConfigFile ..\..\config\vm.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Name,
    [string]$ConfigFile = "",
    [string[]]$Fases,
    [switch]$SaltarTerraform,
    [int]$EsperaSegundos = 600
)

Set-StrictMode -Version 1.0   # 1.0 y no Latest: se leen propiedades opcionales de JSON
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Invoke-AzCLI {
    param([Parameter(Mandatory)][string[]]$Argumentos, [string]$Descripcion = 'comando az')
    Write-Host "·· $Descripcion" -ForegroundColor DarkGray
    $salida = & az @Argumentos 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Descripcion fallo (exit $LASTEXITCODE): $($salida -join ' | ')"
    }
    return $salida
}

# 0) Herramientas y sesion --------------------------------------------------
foreach ($cmd in 'az', 'terraform') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        if ($cmd -eq 'terraform' -and $SaltarTerraform) { continue }
        throw "Falta '$cmd' en el PATH. Instala la Azure CLI y Terraform en tu estacion."
    }
}
$sesion = Invoke-AzCLI -Argumentos @('account', 'show', '--output', 'json') -Descripcion 'cuenta activa' | ConvertFrom-Json
Write-Host ("  cuenta: {0} ({1})" -f $sesion.name, $sesion.id)

if (-not $SaltarTerraform) {
    # 1) Infraestructura ----------------------------------------------------
    Push-Location (Join-Path $repo 'infra\azure')
    try {
        # Capacidad: si el SKU no hay en la region, el apply falla con un error opaco de
        # la plataforma. Se lo decimos antes, sin bloquear (el usuario puede tener otra region).
        $region = & terraform output -raw region 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $region) { $region = '' }
        if ($region) {
            $skus = & az vm list-skus -r Microsoft.Compute -l $region --query "[?name=='Standard_NV6ads_A10_v5'].name" -o tsv 2>$null
            if (-not "$skus") { Write-Host "  AVISO: el SKU no aparece disponible en $region; 'az vm list-skus -l $region -r Microsoft.Compute' para ver opciones." -ForegroundColor Yellow }
        }
        Write-Host '  terraform plan' -ForegroundColor Cyan
        & terraform init -input=false
        & terraform plan -out='tf.plan'
        if ($LASTEXITCODE -ne 0) { throw 'terraform plan fallo' }
        & terraform apply 'tf.plan'
        if ($LASTEXITCODE -ne 0) { throw 'terraform apply fallo' }
    } finally { Pop-Location }
}

# 2) Esperar al agente ------------------------------------------------------
Write-Host "  esperando al agente de VM (max $EsperaSegundos s)" -ForegroundColor Cyan
$limite = (Get-Date).AddSeconds($EsperaSegundos)
$agenteListo = $false
while ((Get-Date) -lt $limite) {
    $vista = & az vm list-instance-view -g $ResourceGroup -n $Name --query "statuses[?contains(status, 'ProvisioningState/succeeded')].displayStatus" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and "$vista" -match 'Provisioning succeeded') { $agenteListo = $true; break }
    Start-Sleep -Seconds 15
}
if (-not $agenteListo) { throw "El agente de VM no reporto listo en $EsperaSegundos s; revisa 'az vm list-instance-view' y el diagnostico de arranque." }

# 3) Entregar scripts y configuracion --------------------------------------
$rutas = @(
    @{ Local = (Join-Path $repo 'scripts\win'); Remoto = 'C:\ProgramData\WinGamingVM\scripts' },
    @{ Local = (Join-Path $repo 'apps'); Remoto = 'C:\ProgramData\WinGamingVM\apps' },
    @{ Local = (Join-Path $repo 'gaming'); Remoto = 'C:\ProgramData\WinGamingVM\gaming' },
    @{ Local = (Join-Path $repo 'config'); Remoto = 'C:\ProgramData\WinGamingVM\config' }
)
foreach ($r in $rutas) {
    if (-not (Test-Path -LiteralPath $r.Local)) { Write-Host "  omito $($r.Local) (no existe)" -ForegroundColor DarkGray; continue }
    $zip = Join-Path $env:TEMP ("gvm-{0}.zip" -f $r.Local.Split('\')[-1])
    Compress-Archive -Path (Join-Path $r.Local '*') -DestinationPath $zip -Force
    # El zip se sube en base64 dentro del comando: sin puertos abiertos, sin SAS, sin disco.
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
    $script = @"
`$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force -Path '$($r.Remoto)' | Out-Null
`$tmp='C:\Windows\Temp\entrega.zip'
[IO.File]::WriteAllBytes(`$tmp,[Convert]::FromBase64String('$b64'))
Expand-Archive -Path `$tmp -DestinationPath '$($r.Remoto)' -Force
Remove-Item `$tmp -Force
"@
    $archivo = Join-Path $env:TEMP 'entrega.ps1'
    Set-Content -LiteralPath $archivo -Value $script -Encoding UTF8
    Invoke-AzCLI -Argumentos @('vm', 'run-command', 'invoke', '-g', $ResourceGroup, '-n', $Name, '--command-id', 'RunPowerShellScript', '--scripts', "@$archivo", '--output', 'none') -Descripcion "entregar $($r.Local.Split('\')[-1])" | Out-Null
    Remove-Item $zip, $archivo -Force -ErrorAction SilentlyContinue
}

# 4) Bootstrap -------------------------------------------------------------
$arg = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WinGamingVM\scripts\Bootstrap-GamingVM.ps1"
if ($Fases) { $arg += " -Fases $($Fases -join ',')" }
$resultado = Invoke-AzCLI -Argumentos @('vm', 'run-command', 'invoke', '-g', $ResourceGroup, '-n', $Name, '--command-id', 'RunPowerShellScript', '--scripts', $arg, '--query', 'value[0].message', '-o', 'tsv')
Write-Host ''
Write-Host '  --- salida del bootstrap ---' -ForegroundColor Cyan
"$resultado" -replace '\\n', "`n" | Write-Host
Write-Host '  --- fin ---' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Recoge los informes con:" -ForegroundColor Green
Write-Host "    az vm run-command invoke -g $ResourceGroup -n $Name --command-id RunPowerShellScript --scripts 'Get-Content C:\ProgramData\WinGamingVM\informes\preparacion-latest.md'"
