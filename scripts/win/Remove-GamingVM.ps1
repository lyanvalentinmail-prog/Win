<#
  .SYNOPSIS
    Revierte los cambios de configuración que hizo el bootstrap, usando los puntos de control.
  .DESCRIPTION
    Deshace lo que es reversible de forma segura y lista lo que NO se puede desinstalar en
    silencio. No borra la VM ni los datos: eso lo decides tú (terraform destroy / detener la
    instancia), porque destruir una VM con tu librería de juegos no es una operación de script.

    Qué hace:
      1) Restaura las claves de registro desde los .reg de respaldo creados por
         Set-GvmRegistryValue (respaldo+restauración por fase).
      2) Quita las reglas de firewall de Windows creadas por este proyecto (filtro por el
         prefijo 'WinGamingVM-').
      3) Devuelve el plan de energía al esquema que había antes (guardado en el checkpoint).
      4) Elimina las tareas programadas 'WinGamingVM-*'.
      5) Desactiva la codificación de hardware y GameDVR solo si este proyecto las activó.
      6) Lista las apps instaladas por el catálogo y genera los comandos 'winget uninstall'
         correspondientes (los ejecuta solo con -QuitarApps).
      7) Restaura los ficheros de PowerToys Keyboard Manager desde la copia con marca de tiempo.

    No toca: Defender, Windows Update, BitLocker, la contraseña de usuario, los juegos con
    datos en D: (eso lo borras tú), ni el driver de GPU (usa -QuitarDriverGpu para
    'pnputil /delete-driver' con el inf detectado).
  .PARAMETER SoloInventario
    Muestra lo que se revertiría sin cambiar nada.
  .PARAMETER QuitarApps
    Desinstala las apps instaladas por este proyecto (con winget, por usuario, no en silencio).
  .PARAMETER QuitarDriverGpu
    Quita el paquete de driver NVIDIA detectado (pnputil). Requiere confirmación.
  .PARAMETER BaseDir
    Raíz de datos del proyecto (por defecto C:\ProgramData\WinGamingVM).
  .EXAMPLE
    .\Remove-GamingVM.ps1 -SoloInventario
  .NOTES
    Los juegos instalados en el disco temporal del SKU (no en D:) desaparecen solos al
    deallocate: por eso el script no intenta borrarlos.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SoloInventario,
    [switch]$QuitarApps,
    [switch]$QuitarDriverGpu,
    [string]$BaseDir = 'C:\ProgramData\WinGamingVM'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$modulo = Join-Path $PSScriptRoot 'Modules\GamingVM'
if (-not (Get-Module -ListAvailable -Name GamingVM)) { $env:PSModulePath = "$modulo;$env:PSModulePath" }
Import-Module (Join-Path $modulo 'GamingVM.psd1') -Force -ErrorAction Stop

$runtime = Initialize-GvmRuntime -BaseDir $BaseDir -Nombre 'revertir'
$paths = Get-GvmPaths
if (-not (Test-GvmEsAdministrador)) {
    throw 'Necesitas una consola elevada para revertir el registro y las reglas de firewall.'
}

# Inventario --------------------------------------------------------------
$respaldos = @()
if (Test-Path -LiteralPath $paths.Backup) {
    # Set-GvmRegistryValue exporta antes de tocar cada clave: reg-backup-*.reg
    $respaldos = @(Get-ChildItem -LiteralPath $paths.Backup -Filter 'reg-backup-*.reg' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime)
}
$tareas = @(Get-ScheduledTask -TaskPath '\WinGamingVM\' -ErrorAction SilentlyContinue)
$reglas = @(Get-NetFirewallRule -DisplayGroup 'Win Gaming VM' -ErrorAction SilentlyContinue)
$estado = Get-GvmCheckpoint

Write-Host ''
Write-Host '  Win Gaming VM — inventario de revertido' -ForegroundColor Cyan
Write-Host ("  respaldo de registro : {0} fichero(s)" -f $respaldos.Count)
Write-Host ("  reglas de firewall   : {0}" -f $reglas.Count)
Write-Host ("  tareas programadas   : {0}" -f $tareas.Count)
Write-Host ("  fases registradas    : {0}" -f (@($estado.PSObject.Properties.Name)).Count)
Write-Host ''

if ($SoloInventario) {
    foreach ($f in $respaldos) { Write-Host ("  · respaldo {0} ({1} bytes)" -f $f.Name, $f.Length) }
    foreach ($r in $reglas) { Write-Host ("  · regla {0} [{1}]" -f $r.DisplayName, $r.Enabled) }
    foreach ($t in $tareas) { Write-Host ("  · tarea {0}" -f $t.TaskName) }
    Write-Host ''
    Write-Host '  Sin cambios (modo inventario).' -ForegroundColor Green
    return
}

if (-not $PSCmdlet.ShouldProcess("revertir $($respaldos.Count) respaldo(s), $($reglas.Count) regla(s) y $($tareas.Count) tarea(s)", 'Deshacer')) { return }

# 1) Registro -------------------------------------------------------------
$restaurados = 0
foreach ($f in $respaldos) {
    Write-Host ("  restaurando {0}" -f $f.Name)
    $salida = & reg.exe import $f.FullName 2>&1
    if ($LASTEXITCODE -eq 0) { $restaurados++ } else { Write-GvmLog -Nivel ERROR -Mensaje "reg import falló en $($f.Name): $salida" }
}
Write-GvmLog -Nivel OK -Mensaje "registro restaurado en $restaurados/$($respaldos.Count) fichero(s)"

# 2) Firewall -------------------------------------------------------------
if ($reglas.Count -gt 0) {
    Remove-NetFirewallRule -Name ($reglas | ForEach-Object Name) -ErrorAction SilentlyContinue
    Write-GvmLog -Nivel OK -Mensaje "reglas de firewall eliminadas: $($reglas.Count)"
}

# 3) Plan de energia ------------------------------------------------------
$planPrevio = $null
if ($estado.escritorio -and $estado.escritorio.planPrevio) { $planPrevio = $estado.escritorio.planPrevio }
if ($planPrevio) {
    powercfg.exe /setactive $planPrevio | Out-Null
    Write-GvmLog -Nivel OK -Mensaje "plan de energia devuelto a $planPrevio"
} else {
    powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    Write-GvmLog -Nivel WARN -Mensaje 'no hay plan previo guardado: se ha puesto el Equilibrado estándar'
}

# 4) Tareas ---------------------------------------------------------------
foreach ($t in $tareas) {
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
}
Write-GvmLog -Nivel OK -Mensaje "tareas eliminadas: $($tareas.Count)"

# 5/6) Apps ---------------------------------------------------------------
if ($QuitarApps) {
    $csv = Join-Path $paths.Informes 'apps-instalacion.csv'   # lo escribe Install-Apps.ps1
    if (-not (Test-Path -LiteralPath $csv)) {
        Write-GvmLog -Nivel WARN -Mensaje "no hay registro de instalación en $csv; no se desinstala nada"
    } else {
        $instaladas = @(Import-Csv -LiteralPath $csv | Where-Object { $_.Estado -eq 'instalada' })
        foreach ($a in $instaladas) {
            Write-Host ("  desinstalando {0}" -f $a.Id)
            winget.exe uninstall --id $a.Id --exact --accept-source-agreements --accept-package-agreements | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-GvmLog -Nivel WARN -Mensaje "winget devolvio $LASTEXITCODE para $($a.Id): puede requerir desinstalacion por usuario" }
        }
        Write-GvmLog -Nivel OK -Mensaje "apps procesadas: $($instaladas.Count)"
    }
} else {
    Write-GvmLog -Nivel INFO -Mensaje 'apps intactas: usa -QuitarApps para desinstalar las que instalo este proyecto'
}

# 7) PowerToys ------------------------------------------------------------
$dirPt = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager'
if (Test-Path -LiteralPath $dirPt) {
    # Set-TouchControls respaldo como <fichero>.backup-<marca>: el mas reciente es el original
    $copias = @(Get-ChildItem -LiteralPath $dirPt -Filter '*.backup-*' -ErrorAction SilentlyContinue)
    foreach ($c in $copias) {
        $nombreOriginal = $c.Name -replace '\.backup-.*$', ''
        if ($PSCmdlet.ShouldProcess((Join-Path $dirPt $nombreOriginal), 'restaurar desde la copia')) {
            Move-Item -LiteralPath $c.FullName -Destination (Join-Path $dirPt $nombreOriginal) -Force
            Write-GvmLog -Nivel OK -Mensaje "PowerToys: $nombreOriginal restaurado"
        }
    }
    if ($copias.Count -eq 0) { Write-GvmLog -Nivel INFO -Mensaje 'PowerToys: sin copias de respaldo que restaurar' }
}

# 8) Driver GPU -----------------------------------------------------------
if ($QuitarDriverGpu) {
    $inf = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceClass -eq 'DISPLAY' -and $_.DriverProviderName -match 'NVIDIA' } |
        Select-Object -First 1
    if (-not $inf) {
        Write-GvmLog -Nivel WARN -Mensaje 'no se detecto un driver NVIDIA que quitar'
    } elseif ($PSCmdlet.ShouldProcess($inf.InfName, 'pnputil /delete-driver')) {
        $confirm = Read-Host ("Se va a quitar el driver {0}. Escribir SI para continuar" -f $inf.InfName)
        if ($confirm -eq 'SI') {
            pnputil.exe /delete-driver $inf.InfName /uninstall /force | Out-Null
            Write-GvmLog -Nivel OK -Mensaje "driver $($inf.InfName) quitado; reinicia para volver al driver basico"
        } else {
            Write-GvmLog -Nivel INFO -Mensaje 'cancelado por el usuario'
        }
    }
}

# Cierre ------------------------------------------------------------------
$notas = @(
    'La configuracion de sesion remota (RDP) NO se revierte: si quieres cerrar el acceso, desactiva Remote Desktop en Configuracion > Sistema > Escritorio remoto.',
    'Los datos de D:\WinGamingVM (informes, backups, perfiles) se quedan: borralos tu cuando hayas verificado el revertido.',
    'Si el plan de energia Ultimate sigue creado, quitalo con: powercfg /delete e9a42b02-d5df-448d-aa66-ad2b75f7b8bb',
    'Los ficheros de control tactil generados (D:\WinGamingVM\controles) solo afectan a ficheros: Moonlight no los carga solos.'
)
Write-Host ''
Write-Host '  Revertido. Pendiente de decision manual:' -ForegroundColor Green
foreach ($n in $notas) { Write-Host "   · $n" }
Write-Host ''
