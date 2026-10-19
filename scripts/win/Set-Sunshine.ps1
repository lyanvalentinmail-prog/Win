<#
.SYNOPSIS
  Prepara el canal de juego (Sunshine + Moonlight) o lo desactiva con un motivo real.
.DESCRIPTION
  Sunshine captura la pantalla del invitado y la codifica (NVENC/AMF/QSV o x264) para
  enviarla a un cliente Moonlight, que es quien aporta los controles tactiles, el mando
  virtual, el overlay de estadisticas y el teclado especial. Es la UNICA via documentada
  de este proyecto para "jugar con el movil", y requiere que el host pueda codificar.

  Reglas duras:
   - Si gaming.channel esta en 'rdp', no se toca nada.
   - Si gpu.hardwareEncoderRequired=true y no hay codificador de hardware, la fase termina
     con Estado='desactivado-sin-gpu' y NO configura controles de juego: no se promete un
     stream que el hardware no puede sostener.
   - Se instala por winget (LizardByte.Sunshine) y se verifican firma y version.
   - El PIN de emparejamiento y las credenciales de la interfaz web SE CREAN EN LA VM por el
     usuario (https://localhost:47990). Este script nunca genera ni guarda credenciales.
   - El firewall se limita a gaming.sunshine.allowedCidrs (o a remote.allowedCidrs); si no
     hay ninguna y no hay tunel, la regla se crea DESHABILITADA y se avisa.
.PARAMETER Desinstalar
  Quita el servicio/tareas y deshabilita las reglas (no toca los datos del usuario).
.OUTPUTS
  PSCustomObject: Estado, Detalle, Datos
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [string]$RepoDir,
    [switch]$Desinstalar,
    [switch]$EscribirAppsJson
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force

# Cada fase puede ejecutarse suelta (o como proceso hijo del bootstrap): inicializa su
# propio log/estado. Si quien llama es el bootstrap, el fichero de log sera el de esta fase,
# que es lo util cuando hay que relanzar solo una.
[void](Initialize-GvmRuntime -Nombre ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)))

$cfg = Resolve-GvmConfig -Entrada $Config
$Fase = 'gaming'
$estado = 'desconocido'; $detalle = ''
$requiereReinicio = $false

$habilitado = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.enabled' -PorDefecto $true)
$canal = Get-GvmConfigValor -Config $cfg -Ruta 'gaming.channel' -PorDefecto 'rdp'
$sunCfg = Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine'
$puerto = [int](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.httpsPort' -PorDefecto 47990)

function Stop-Fase {
    param([string]$E, [string]$D)
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "canal de juego: $E" -Detalle $D
    [pscustomobject]@{ Estado = $E; Detalle = $D; RequiereReinicio = $false; Datos = $null }
}

if ($Desinstalar) {
    if ($PSCmdlet.ShouldProcess('Sunshine', 'retirar servicio, tareas y reglas')) {
        Get-ScheduledTask -TaskName 'WinGamingVM - *' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
        Get-NetFirewallRule -DisplayGroup 'WinGamingVM' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        winget.exe uninstall --id LizardByte.Sunshine --exact --silent 2>&1 | Out-Null
    }
    return Stop-Fase 'desinstalado' 'Se retiraron tareas y reglas de WinGamingVM; los datos de C:\ProgramData\Sunshine quedan intactos'
}
if (-not $habilitado -or $canal -eq 'rdp') {
    return Stop-Fase 'no-solicitado' "gaming.enabled=$habilitado y gaming.channel='$canal': no se configura el canal de juego (Windows App seguira funcionando para escritorio)"
}
if (-not $sunCfg -or -not [bool]$sunCfg.enabled) {
    return Stop-Fase 'desactivado' 'gaming.sunshine.enabled=false'
}

# --- GPU / codificador --------------------------------------------------------
$gpu = Get-GvmGpuInfo
$requiereHw = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'gpu.hardwareEncoderRequired' -PorDefecto $true)
$encoderCfg = Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.encoder' -PorDefecto 'auto'
if ($requiereHw -and ($gpu.CodificadorHw -eq 'ninguno' -or -not $gpu.Presente) -and $encoderCfg -ne 'software') {
    return Stop-Fase 'desactivado-sin-gpu' @"
El host no expone un codificador de video por hardware (gpu='$($gpu.Resumen)').
Sunshine funcionaria con x264 por CPU: 1-2 vCPU consumidas y mas latencia que el propio
RDP, asi que el proyecto NO lo activa por defecto. Opciones honestas:
  1) elegir un SKU con GPU (ver config/provider-limits.json),
  2) forzar gaming.sunshine.encoder='software' sabiendo que es degradado,
  3) quedarte solo con Windows App para escritorio y juegos ligeros.
"@
}

# --- Instalacion --------------------------------------------------------------
$instalada = Get-GvmAppInstalada -Id 'LizardByte.Sunshine'
if (-not $instalada) {
    $r = Install-GvmWingetApp -Id 'LizardByte.Sunshine' -Scope 'machine'
    if ($r.Estado -notin 'correcta', 'ya-instalada') {
        return Stop-Fase 'fallo-instalacion' "winget no pudo instalar Sunshine ($($r.Estado) $($r.Salida))"
    }
    $requiereReinicio = $true
    $instalada = Get-GvmAppInstalada -Id 'LizardByte.Sunshine'
}
$exe = "$env:ProgramFiles\Sunshine\sunshine.exe"
if (-not (Test-Path -LiteralPath $exe)) { $exe = (Get-Command sunshine.exe -ErrorAction SilentlyContinue).Source }
if ($exe) {
    $f = Test-GvmFirma -Ruta $exe -FirmantesEsperados @('LizardByte', 'Johannes Kauffmann') -Tolerancia 'aviso' -Id 'LizardByte.Sunshine'
    Write-GvmLog -Fase $Fase -Mensaje "firma de Sunshine: $($f.Estado)" -Detalle $f.Detalle
}

# --- Configuracion ------------------------------------------------------------
$confDir = Join-Path $env:ProgramData 'Sunshine\config'
$conf = Join-Path $confDir 'sunshine.conf'
if (-not (Test-Path -LiteralPath $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }

$fps = [int](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.fps' -PorDefecto 60)
$bitrate = [int](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.bitrateMbps' -PorDefecto 25)
$codec = Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.codec' -PorDefecto 'auto'
$encoder = if ($gpu.CodificadorHw -ne 'ninguno') { $gpu.CodificadorHw } else { 'software' }
$ancho = [int](Get-GvmConfigValor -Config $cfg -Ruta 'remote.resolution.width' -PorDefecto 1920)
$alto = [int](Get-GvmConfigValor -Config $cfg -Ruta 'remote.resolution.height' -PorDefecto 1080)
if ((Get-GvmConfigValor -Config $cfg -Ruta 'remote.resolution.mode' -PorDefecto 'client') -ne 'fixed') {
    $ancho = 0; $alto = 0   # 0 = Sunshine usa la resolucion real del modo actual del escritorio
}

if ($PSCmdlet.ShouldProcess($conf, 'escribir configuracion basica')) {
    $lineas = @(
        '# Generado por scripts/win/Set-Sunshine.ps1 (Win Gaming VM).'
        '# Ajuste fino (permisos, apps, upload de mandos): interfaz web https://localhost:47990'
        '# No borres: los cambios manuales en la web pisan esta seccion al relanzar el bootstrap.'
        '[general]'
        "port = 47984"
        "address_family = both"
        "upnp = disabled"          # en la nube no hay NAT que mapear; el alcance lo decide el firewall
        "origin_web_ui_allowed = pc"
        "min_log_level = 1"
        '[encoder]'
        "encoder = $encoder"
        "hevc = $(if ($codec -in 'hevc', 'auto') { 'true' } else { 'false' })"
        "av1 = $(if ($codec -eq 'av1') { 'true' } else { 'false' })"
        '[video]'
        "fps = $fps"
        "bitrate = $($bitrate * 1000)"
    )
    if ($ancho -gt 0) { $lineas += "resolutions[0] = ${ancho}x${alto}" }
    ($lineas -join "`r`n") + "`r`n" | Set-Content -LiteralPath $conf -Encoding UTF8
    $detalle = "sunshine.conf escrito (encoder=$encoder, $fps fps, $bitrate Mbps, codec=$codec)"
}

# --- apps.json (opcional y explícito) -----------------------------------------
$appsRuta = Join-Path $confDir 'apps.json'
if ($EscribirAppsJson) {
    $juegos = @()
    foreach ($libreria in @(
            @{ nombre = 'Steam'; exe = "${env:ProgramFiles(x86)}\Steam\steam.exe"; args = '-bigpicture' },
            @{ nombre = 'Epic Games'; exe = "${env:ProgramFiles}\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"; args = '' },
            @{ nombre = 'Minecraft'; exe = "${env:ProgramFiles(x86)}\Minecraft Launcher\MinecraftLauncher.exe"; args = '' }
        )) {
        $ruta = [Environment]::ExpandEnvironmentVariables($libreria.exe)
        if (Test-Path -LiteralPath $ruta) {
            $juegos += [ordered]@{
                'type' = 'app'; 'name' = $libreria.nombre; 'cmd' = "`"$ruta`""
                'params' = $libreria.args; 'workingDir' = (Split-Path $ruta -Parent)
                'excludeGlobalVars' = ''
            }
        }
    }
    if ($juegos.Count -gt 0) {
        [ordered]@{ env = [ordered]@{}; apps = $juegos } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $appsRuta -Encoding UTF8
        $detalle += " · apps.json con $($juegos.Count) accesos (formato observado en Sunshine 2026.x; si tu version cambia el esquema, usa la web)"
    } else {
        $detalle += ' · apps.json omitido: ningun lanzador instalado todavia'
    }
}

# --- Servicio -----------------------------------------------------------------
$svc = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='Sunshine' OR Name='SunshineService'" -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($svc) {
    if ($svc.StartMode -ne 'Auto') { Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue }
    if ($svc.State -ne 'Running') { try { Start-Service -Name $svc.Name } catch { Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'no se pudo arrancar el servicio de Sunshine' -Detalle $_.Exception.Message } }
    $estadoServicio = "servicio '$($svc.Name)' $(if ($svc.State -eq 'Running') { 'en ejecucion' } else { 'detenido' })"
} else {
    # Sunshine instala una tarea al iniciar sesion cuando no se usa el modo servicio.
    Set-GvmTareaProgramada -Nombre 'Sunshine (sesion de usuario)' -Comando "`"$exe`"" -Disparo 'alSesion'
    $estadoServicio = 'task-al-sesion'
    $requiereReinicio = $true
}

# --- Sesion de consola (el punto que rompe el streaming en una VM) -----------
# Sunshine captura la sesion de CONSOLA; al entrar por RDP, Windows bloquea la consola y el
# stream se queda en negro. La tarea 'Devolver sesion a consola' soluciona el caso RDP->consola
# desconectando la sesion RDP con tscon. Solo tiene efecto en Windows con sesion de consola
# disponible (KVM local, o VM con sesion desatendida), y es opcional.
if ([bool](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.keepConsoleSession' -PorDefecto $true)) {
    $desbloqueo = Join-Path $PSScriptRoot 'Unlock-ConsoleSession.ps1'
    if (Test-Path -LiteralPath $desbloqueo) {
        Set-GvmTareaProgramada -Nombre 'Devolver sesion a consola (post-RDP)' -Comando "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$desbloqueo`"" -Disparo 'alSesion'
        $detalle += ' · tarea de consola creada (ejecutar tambien a mano tras desconectar de RDP)'
    }
}

# --- Firewall -----------------------------------------------------------------
$cidrs = @(Get-GvmConfigValor -Config $cfg -Ruta 'gaming.sunshine.allowedCidrs' -PorDefecto @())
if ($cidrs.Count -eq 0) { $cidrs = @(Get-GvmConfigValor -Config $cfg -Ruta 'remote.allowedCidrs' -PorDefecto @()) }
$tunel = Get-GvmConfigValor -Config $cfg -Ruta 'remote.tunnel' -PorDefecto 'none'
$scope = @()
$tcp = 47984, 47989, 48010, $puerto
$udpPuertos = 47998, 47999, 48000, 48002, 48010
if ($PSCmdlet.ShouldProcess('reglas de firewall de Sunshine', 'crear')) {
    Get-NetFirewallRule -DisplayGroup 'WinGamingVM - Sunshine' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $habilitar = ($cidrs.Count -gt 0) -or ($tunel -ne 'none')
    $scope = if ($cidrs.Count -gt 0) { $cidrs } elseif ($tunel -ne 'none') { @('LocalSubnet') } else { @('Any') }
    New-NetFirewallRule -Name 'gvm-sunshine-tcp' -DisplayName 'WinGamingVM Sunshine (TCP)' -Group 'WinGamingVM - Sunshine' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $tcp -RemoteAddress $scope -Enabled $habilitar | Out-Null
    New-NetFirewallRule -Name 'gvm-sunshine-udp' -DisplayName 'WinGamingVM Sunshine (UDP)' -Group 'WinGamingVM - Sunshine' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $udpPuertos -RemoteAddress $scope -Enabled $habilitar | Out-Null
    if (-not $habilitar) {
        $detalle += ' · reglas de stream DESHABILITADAS: no hay allowedCidrs ni tunel (no se expone Sunshine a Internet)'
    } else {
        $detalle += " · reglas de stream para $($scope -join ', ')"
    }
}

$estado = 'activo'
$hallazgos = @(
    New-GvmHallazgo -Item 'Canal de juego' -Nivel OK -Detalle "Sunshine $estadoServicio · $($fps) fps · $($bitrate) Mbps · codificador $encoder"
    New-GvmHallazgo -Item 'Emparejamiento' -Nivel WARN -Detalle 'falta accion del usuario: abrir https://localhost:47990 (desde la propia VM o por tunel), crear usuario/PIN y emparejar el cliente Moonlight'
    if ($encoder -eq 'software') { New-GvmHallazgo -Item 'Codificador por software' -Nivel WARN -Detalle 'x264: mas CPU y mas latencia. No es "cloud gaming" de verdad.' }
    if ($requiereReinicio) { New-GvmHallazgo -Item 'Reinicio' -Nivel INFO -Detalle 'reinicio recomendado para completar el servicio' }
)
New-GvmInforme -Nombre 'canal-juego' -Datos ([pscustomobject]@{
    estado = $estado; servicio = $estadoServicio; conf = $conf; apps = $appsRuta; codificador = $encoder
    fps = $fps; bitrateMbps = $bitrate; codec = $codec; tcp = $tcp; udp = $udpPuertos; alcance = $scope
}) -Hallazgos $hallazgos | Out-Null

Write-GvmLog -Nivel OK -Fase $Fase -Mensaje 'canal de juego preparado' -Detalle $detalle
[pscustomobject]@{
    Estado           = $estado
    Detalle          = $detalle
    RequiereReinicio = $requiereReinicio
    Datos            = [pscustomobject]@{ codificador = $encoder; fps = $fps; bitrate = $bitrate }
}

# Nota de soporte: los nombres de servicio/puertos y las claves de sunshine.conf de este
# script se corresponden con Sunshine 2026.x (LizardByte). Si actualizas Sunshine y algo
# cambia, la interfaz web (https://localhost:47990) sigue siendo la via soportada: el
# bootstrap no intenta adivinar esquemas nuevos.
