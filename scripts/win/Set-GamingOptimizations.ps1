<#
.SYNOPSIS
  Ajustes de Windows orientados a rendimiento en sesion remota.
.DESCRIPTION
  Aplica, de forma idempotente y documentada, lo que describe gaming/ajustes/README.md:
  plan de energia, sueno/hibernacion, Game Bar/Game DVR, HAGS (solo si hay GPU),
  exclusions de indexado, servicios innecesarios y cierre de procesos.

  Nunca desactiva Defender, Windows Update, el firewall ni los servicios de seguridad:
  hay una lista negra dura en $PROHIBIDOS que aborta si el config intenta incluirlos.
.PARAMETER Config
  Ruta o objeto de config/vm.json.
.OUTPUTS
  PSCustomObject: Aplicados, Omitidos, Advertencias, RequiereReinicio, Detallado
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [switch]$SinReinicio
)
# StrictMode 1.0: pilla variables sin inicializar. No se usa 'Latest' porque la
# configuracion viene de JSON con campos opcionales y 2.0+ lanza al leer una propiedad
# ausente (el bootstrap debe tolerar configs parciales y aplicar valores por defecto).
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force

# Cada fase puede ejecutarse suelta (o como proceso hijo del bootstrap): inicializa su
# propio log/estado. Si quien llama es el bootstrap, el fichero de log sera el de esta fase,
# que es lo util cuando hay que relanzar solo una.
[void](Initialize-GvmRuntime -Nombre ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)))

$cfg = Resolve-GvmConfig -Entrada $Config
$Fase = 'escritorio'
$WhatIfPreference = [bool]$WhatIfPreference
$aplicados = 0; $omitidos = 0; $avisos = 0
$detallado = New-Object System.Collections.Generic.List[object]
$requiereReinicio = $false

function Add-Resultado {
    param([string]$Item, [string]$Estado, [string]$Detalle)
    $detallado.Add([pscustomobject]@{ item = $Item; estado = $Estado; detalle = $Detalle })
    switch ($Estado) {
        'aplicado' { $script:aplicados++ }
        'omitido' { $script:omitidos++ }
        'aviso' { $script:avisos++ }
    }
}

# Lista negra: si algo de esto aparece en disableUnusedServices, se aborta la fase.
$PROHIBIDOS = 'WinDefend', 'SecurityHealthService', 'wuauserv', 'mpssvc', 'BFE', 'MpsSvc', 'Sense', 'Appinfo', 'LsaIso', 'KeyIso', 'VaultSvc', 'TermService', 'RpcSs', 'DcomLaunch', 'Schedule', 'EventLog'

$gpu = Get-GvmGpuInfo
$hayGpu = [bool]$gpu.Presente

# --- 1. Plan de energia -------------------------------------------------------
$plan = Get-GvmConfigValor -Config $cfg -Ruta 'power.plan' -PorDefecto 'ultimate-performance'
$planes = @{
    'ultimate-performance' = 'e9a42b02-d5df-448d-aa66-ad2b75f7b8bb'
    'high-performance'     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    'balanced'             = '381b4222-f694-41f0-9685-ff5bb260df2e'
}
$guid = $planes[$plan]
if (-not $guid) { $plan = 'high-performance'; $guid = $planes[$plan]; Add-Resultado 'plan de energia' 'aviso' "plan desconocido en el config: se usa $plan" }
try {
    if ($PSCmdlet.ShouldProcess($plan, 'activar plan de energia')) {
        $r = powercfg.exe /setactive $guid 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -and $plan -eq 'ultimate-performance') {
            # En algunas imagenes de Server el plan ultimo no esta importado: se duplica High Performance.
            $duplicado = (powercfg.exe -duplicatescheme '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>&1 | Out-String)
            if ($duplicado -match '([a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12})') {
                $guid = $Matches[1]
                powercfg.exe /setactive $guid | Out-Null
                Add-Resultado 'plan de energia' 'aplicado' "High Performance duplicado y activado ($guid) porque Ultimate no existe en la imagen"
            } else {
                Add-Resultado 'plan de energia' 'aviso' "powercfg devolvio error: $($r.Trim())"
            }
        } else {
            Add-Resultado 'plan de energia' 'aplicado' "$plan ($guid)"
        }
    }
    if ($plan -ne 'balanced') {
        powercfg.exe -setacvalueindex $guid SUB_PROCESSOR CPMINCORES 100 | Out-Null
        powercfg.exe -setdcvalueindex $guid SUB_PROCESSOR CPMINCORES 100 | Out-Null
        Add-Resultado 'aparcamiento de nucleos' 'aplicado' 'CPMINCORES=100 % (menos migracion de hilos)'
    }
} catch {
    Add-Resultado 'plan de energia' 'aviso' "excepcion: $($_.Exception.Message)"
}

# --- 2. Sueno / hibernacion ---------------------------------------------------
if (Get-GvmConfigValor -Config $cfg -Ruta 'power.disableSleep' -PorDefecto $true) {
    foreach ($sub in @(
        @{ g = 'SUB_SLEEP'; s = 'STANDBYIDLE'; v = 0 },
        @{ g = 'SUB_SLEEP'; s = 'HIBERNATEIDLE'; v = 0 },
        @{ g = 'SUB_SLEEP'; s = 'HYBRIDSLEEP'; v = 0 },
        @{ g = 'SUB_VIDEO'; s = 'VIDEOIDLE'; v = 0 },
        @{ g = 'SUB_VIDEO'; s = 'CONSOLELOCK'; v = 0 }
    )) {
        if ($PSCmdlet.ShouldProcess("$($sub.g)/$($sub.s)", 'powercfg')) {
            powercfg.exe -setacvalueindex $guid $sub.g $sub.s $sub.v | Out-Null
            powercfg.exe -setdcvalueindex $guid $sub.g $sub.s $sub.v | Out-Null
        }
    }
    Add-Resultado 'sueno/apagado de pantalla' 'aplicado' '0 (nunca) en sesiones AC y DC'
}
if (Get-GvmConfigValor -Config $cfg -Ruta 'power.disableHibernate' -PorDefecto $true) {
    if ($PSCmdlet.ShouldProcess('hibernacion', 'desactivar')) { powercfg.exe /h off 2>&1 | Out-Null }
    Add-Resultado 'hibernacion' 'aplicado' 'powercfg /h off (en la nube no aporta y conserva imagen en el disco)'
}

# --- 3. Game Bar / Game DVR ---------------------------------------------------
$dvr = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'power.disableGameDvr' -PorDefecto $false)
foreach ($kv in @(
    @{ p = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; n = 'AppCaptureEnabled'; v = $(if ($dvr) { 0 } else { 1 }) },
    @{ p = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; n = 'HistoricalCaptureEnabled'; v = $(if ($dvr) { 0 } else { 1 }) },
    @{ p = 'HKCU:\Software\Microsoft\GameBar'; n = 'AutoGameModeEnabled'; v = 1 },
    @{ p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; n = 'NoGameBar'; v = 0 }
)) {
    Set-GvmRegistryValue -Path $kv.p -Name $kv.n -Value $kv.v -Type DWord -Comentario $(if ($dvr) { 'captura de juego desactivada por config' } else { 'captura de juego deja activa' }) | Out-Null
}
Add-Resultado 'Game Bar / Game DVR' $(if ($dvr) { 'aplicado' } else { 'omitido' }) $(if ($dvr) { 'DVR apagado: menos overhead, sin capturas nativas (usa el cliente o OBS)' } else { 'DVR encendido; puede restar 2-6 % de rendimiento en GPU pequenas' })

# --- 4. HAGS (programacion de GPU por hardware) ------------------------------
if (Get-GvmConfigValor -Config $cfg -Ruta 'power.hardwareAcceleratedGpuScheduling' -PorDefecto $true) {
    if ($hayGpu) {
        $antes = Get-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
        Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Type DWord -Comentario 'HAGS activada (requiere WDDM 2.7+ y driver compatible)' | Out-Null
        if ($antes -ne 2) { $requiereReinicio = $true }
        Add-Resultado 'HAGS' 'aplicado' 'HwSchMode=2; si el driver de la GPU particionada no lo soporta, Windows lo ignorara sin dano'
    } else {
        Add-Resultado 'HAGS' 'omitido' 'sin GPU util no hay HAGS que activar: no se escribe la clave'
    }
} else {
    Add-Resultado 'HAGS' 'omitido' 'desactivado en config (power.hardwareAcceleratedGpuScheduling=false)'
}

# --- 5. Menos E/S de fondo y exclusions del antivirus -------------------------
if ($PSCmdlet.ShouldProcess('ultima hora de acceso', 'desactivar actualizacion')) {
    fsutil.exe behavior set DisableLastAccess 1 2>&1 | Out-Null
}
Add-Resultado 'ultima hora de acceso (NTFS)' 'aplicado' 'fsutil DisableLastAccess=1: menos escrituras al navegar librerias de juegos'

# Windows Search: excluir carpetas NO es automatizable de forma fiable desde script
# (la lista vive en la base del servicio Search, no en una clave estable). Se registra
# como accion pendiente para el usuario en lugar de fingir que se ha aplicado.
Add-Resultado 'Windows Search' 'aviso' 'excluir D:\Juegos del indexado se hace a mano: Opciones de indexacion > Modificar (o apaga el servicio WSearch desde config)'

$defConf = Get-GvmConfigValor -Config $cfg -Ruta 'security.defender' -PorDefecto 'enable'
if ($defConf -eq 'enable-with-exclusions') {
    $rutasExc = @(Get-GvmConfigValor -Config $cfg -Ruta 'security.defenderExclusions' -PorDefecto @()) | Where-Object { $_ }
    if ($rutasExc.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess("$($rutasExc.Count) exclusiones", 'Add-MpPreference')) {
            try {
                Add-MpPreference -ExclusionPath $rutasExc -ErrorAction Stop
                Add-Resultado 'exclusiones Defender' 'aplicado' "$($rutasExc -join '; ') -> MENOS proteccion en esas rutas; usalo solo para carpetas de juego grandes"
            } catch { Add-Resultado 'exclusiones Defender' 'aviso' "el endpoint no permitio exclusiones (posible proteccion contra manipulacion): $($_.Exception.Message)" }
        }
    }
} else {
    Add-Resultado 'exclusiones Defender' 'omitido' "security.defender=$defConf : no se anaden exclusiones"
}

# --- 6. Servicios innecesarios (lista blanca cerrada) -------------------------
$services = @(Get-GvmConfigValor -Config $cfg -Ruta 'security.disableUnusedServices' -PorDefecto @())
$inutil = @($services | Where-Object { $PROHIBIDOS -contains $_ })
if ($inutil.Count -gt 0) { throw "El config intenta desactivar servicios de seguridad/sistema: $($inutil -join ', '). Eliminalos de security.disableUnusedServices." }
foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Add-Resultado "servicio $svc" 'omitido' 'no existe en esta edicion'; continue }
    if ($PSCmdlet.ShouldProcess($svc, 'detener y deshabilitar inicio manual')) {
        try {
            if ($s.Status -eq 'Running') { Stop-Service -Name $svc -Force -ErrorAction Stop }
            Set-Service -Name $svc -StartupType Manual -ErrorAction Stop
            Add-Resultado "servicio $svc" 'aplicado' "detenido, inicio=Manual (no Disabled, para poder revertir)"
        } catch { Add-Resultado "servicio $svc" 'aviso' $_.Exception.Message }
    }
}
if ($services.Count -eq 0) { Add-Resultado 'servicios' 'omitido' 'security.disableUnusedServices vacio: no se toca nada' }

# --- 7. Cierre de procesos innecesarios ---------------------------------------
$cleanup = Get-GvmConfigValor -Config $cfg -Ruta 'power.processCleanup'
if ($cleanup -and $cleanup.enabled) {
    $protegidos = 'csrss', 'wininit', 'services', 'lsass', 'svchost', 'MsMpEng', 'NisSrv', 'MpDefenderCoreService', 'Memory Compression', 'dwm', 'explorer', 'LogonUI', 'SearchIndexer', 'Sunshine'
    $lista = @($cleanup.processes | Where-Object { $_ })
    foreach ($p in $lista) {
        $nom = ($p -replace '\.exe$', '')
        if ($PROHIBIDOS -contains $nom -or $protegidos -contains $nom) { Add-Resultado "proceso $p" 'aviso' 'protegido: nunca se cierra'; continue }
        $procs = @(Get-Process -Name $nom -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { Add-Resultado "proceso $p" 'omitido' 'no estaba en ejecucion'; continue }
        if ($PSCmdlet.ShouldProcess($nom, 'detener proceso y quitar de inicio automatico')) {
            $procs | Stop-Process -Force
            foreach ($hive in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
                $item = Get-Item -LiteralPath $hive -ErrorAction SilentlyContinue
                if ($item -and ($item.Property -contains $nom)) {
                    Remove-ItemProperty -LiteralPath $hive -Name $nom
                    Add-Resultado "autostart $nom" 'aplicado' "entrada eliminada de $hive"
                }
            }
            Add-Resultado "proceso $p" 'aplicado' "$($procs.Count) instancia(s) cerrada(s)"
        }
    }
} else {
    Add-Resultado 'cierre de procesos' 'omitido' 'power.processCleanup.enabled=false (predeterminado: no matar nada por sorpresa)'
}

# --- 8. Personalizacion del escritorio (fondo, tema, escala) ------------------
$wp = Get-GvmConfigValor -Config $cfg -Ruta 'windows.wallpaper'
if ($wp) {
    $fuente = $wp.source
    switch ($fuente) {
        'url' {
            $o = Test-GvmOrigenPermitido -Url $wp.path
            if (-not $o.Permitido) { Add-Resultado 'fondo de pantalla' 'aviso' "url no autorizada: $($o.Motivo)" }
            else {
                $dest = Join-Path (Get-GvmPaths).BaseDir 'wallpaper.jpg'
                if ($PSCmdlet.ShouldProcess($wp.path, 'descargar fondo')) {
                    $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                    try { Invoke-WebRequest -Uri $wp.path -OutFile $dest -UseBasicParsing -TimeoutSec 60 } finally { $ProgressPreference = $prev }
                    Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value $dest -Type String | Out-Null
                    Add-Resultado 'fondo de pantalla' 'aplicado' "descargado y fijado ($dest)"
                }
            }
        }
        'local-file' {
            if (Test-Path -LiteralPath $wp.path) {
                Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value $wp.path -Type String | Out-Null
                Add-Resultado 'fondo de pantalla' 'aplicado' $wp.path
            } else { Add-Resultado 'fondo de pantalla' 'aviso' "no existe $($wp.path)" }
        }
        'solid-color' {
            $hex = if ($wp.color) { $wp.color } else { '#0F172A' }
            $bgr = ('{0},{1},{2}' -f [Convert]::ToInt32($hex.Substring(5, 2), 16), [Convert]::ToInt32($hex.Substring(3, 2), 16), [Convert]::ToInt32($hex.Substring(1, 2), 16))
            Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Colors' -Name 'Background' -Value $bgr -Type String | Out-Null
            Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value '' -Type String | Out-Null
            Add-Resultado 'fondo de pantalla' 'aplicado' "color solido $hex ($bgr en BGR)"
        }
        default { Add-Resultado 'fondo de pantalla' 'omitido' 'windows.wallpaper.source=default' }
    }
    $estilo = switch ($wp.style) { 'fit' { 6 } 'stretch' { 2 } 'tile' { 0 } 'center' { 6 } default { 10 } }
    Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle' -Value "$estilo" -Type String | Out-Null
    # Notificar al escritorio para que relance el wallpaper (equivalente a SPI_SETDESKWALLPAPER).
    if (-not $WhatIfPreference) {
        try { & "$env:SystemRoot\System32\rundll32.exe" user32.dll,UpdatePerUserSystemParameters 1, True } catch { }
    }
}
$tema = Get-GvmConfigValor -Config $cfg -Ruta 'windows.theme' -PorDefecto 'dark'
$valorTema = if ($tema -eq 'light') { 1 } elseif ($tema -eq 'dark') { 0 } else { 2 }
if ($valorTema -ne 2) {
    Set-GvmRegistryValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value $valorTema -Type DWord | Out-Null
    Set-GvmRegistryValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Value $valorTema -Type DWord | Out-Null
    Add-Resultado 'tema claro/oscuro' 'aplicado' $tema
}
$acento = Get-GvmConfigValor -Config $cfg -Ruta 'windows.accentColor'
if ($acento) {
    Add-Resultado 'color de enfasis' 'aviso' 'no se puede fijar de forma fiable por registro (Windows usa un color generado por DWM); hazlo en Configuracion > Personalizacion > Color'
}

# --- 9. Reduccion de telemetria de indexado/visuales (opcional, seguro) -------
if ($hayGpu) {
    Set-GvmRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord -Comentario 'efectos visuales minimos para no gastar GPU en animaciones' | Out-Null
    Add-Resultado 'efectos visuales' 'aplicado' 'ajuste minimo (efectos desactivados) para ganar relleno en la GPU'
} else {
    Add-Resultado 'efectos visuales' 'omitido' 'sin GPU: se dejan los efectos como estan'
}

# --- Informe ------------------------------------------------------------------
$hallazgos = @(
    New-GvmHallazgo -Item 'Optimizaciones' -Nivel OK -Detalle "$aplicados aplicadas / $omitidos omitidas / $avisos avisos"
    if ($hayGpu) { New-GvmHallazgo -Item 'HAGS/efectos' -Nivel OK -Detalle 'GPU presente: ajustes dependientes de GPU aplicados' }
    else { New-GvmHallazgo -Item 'HAGS/efectos' -Nivel WARN -Detalle 'sin GPU: los ajustes dependientes de GPU se omitieron a proposito' }
)
New-GvmInforme -Nombre 'optimizaciones' -Datos ([pscustomobject]@{ plan = $plan; gpuPresente = $hayGpu; items = $detallado }) -Hallazgos $hallazgos | Out-Null

if ($requiereReinicio -and -not $SinReinicio) {
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'algun ajuste (HAGS) necesita reinicio para surtir efecto'
}
Write-GvmLog -Nivel OK -Fase $Fase -Mensaje "optimizaciones: $aplicados aplicadas, $omitidos omitidas, $avisos avisos"

[pscustomobject]@{
    Aplicados        = $aplicados
    Omitidos         = $omitidos
    Advertencias     = $avisos
    RequiereReinicio = $requiereReinicio
    Detallado        = $detallado
}
