<#
.SYNOPSIS
  Prepara el host de escritorio remoto (RDP) para 'Windows App'.
.DESCRIPTION
  - Habilita RDP con NLA y capa de seguridad negociada (TLS cuando hay certificado).
  - Aplica las politicas de config/remote-session.json: profundidad de color, AVC 4:4:4
    y codificador de hardware SOLO si existe GPU util (no se escriben politicas que
    dependan de un hardware inexistente).
  - Ajusta timeouts de sesion para que una caida de red no destruya la partida.
  - Regla de firewall limitada a las CIDR declaradas; si no hay CIDR y no hay tunel,
    deja la regla deshabilitada y lo avisa (no abre 3389 a Internet).
  - Genera la documentacion de cliente (guia de Windows App en Android) en el disco de datos.

  No genera certificados, no crea usuarios y no guarda credenciales.
.OUTPUTS
  PSCustomObject: Puerto, Nla, Udp, Avc444, RequiereReinicio, Detallado
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [string]$RutaRemotoSession,
    [string]$RepoDir
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
$Fase = 'remoto'
$requiereReinicio = $false
$detallado = New-Object System.Collections.Generic.List[object]
function Add-Item { param([string]$i, [string]$e, [string]$d) $null = $detallado.Add([pscustomobject]@{ item = $i; estado = $e; detalle = $d }) }

if (-not $RepoDir) {
    foreach ($c in @($env:GVM_REPO_DIR, 'C:\ProgramData\WinGamingVM\repo', (Join-Path $PSScriptRoot '..\..'))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'config\remote-session.json'))) { $RepoDir = $c; break }
    }
    if (-not $RepoDir) { Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'no se localiza el arbol del repo (config/remote-session.json): usa -RepoDir o GVM_REPO_DIR' }
}
if (-not $RutaRemotoSession) { $RutaRemotoSession = Join-Path $RepoDir 'config\remote-session.json' }

$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$politicas = [ordered]@{}
if (Test-Path -LiteralPath $RutaRemotoSession) {
    $rs = Get-Content -LiteralPath $RutaRemotoSession -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $rs.politicasBase.PSObject.Properties) { $politicas[$p.Name] = $p.Value }
    $presetCfg = Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.quality' -PorDefecto 'balanced'
    $preset = $rs.presets.$presetCfg
    if ($preset -and $preset.politicas) {
        foreach ($p in $preset.politicas.PSObject.Properties) { $politicas[$p.Name] = $p.Value }
        Add-Item 'preset de sesion' 'aplicado' "$presetCfg -> $($preset.politicas.PSObject.Properties.Name -join ', ')"
    } else { Add-Item 'preset de sesion' 'aviso' "preset '$presetCfg' no encontrado en config/remote-session.json" }
} else {
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'no se encontro config/remote-session.json; se aplica el minimo seguro'
    $politicas = [ordered]@{ fDenyTSConnections = 0; UserAuthentication = 1; SecurityLayer = 1; MinEncryptionLevel = 3; ColorDepth = 4; fSingleSessionPerUser = 1 }
}

# --- Ajustes segun el config del usuario --------------------------------------
$port = [int](Get-GvmConfigValor -Config $cfg -Ruta 'remote.port' -PorDefecto 3389)
$nla = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.requireNla' -PorDefecto $true)
$politicas['UserAuthentication'] = $(if ($nla) { 1 } else { 0 })
$politicas['fDenyTSConnections'] = 0

$sesion = Get-GvmConfigValor -Config $cfg -Ruta 'remote.session'
if ($sesion) {
    if ($null -ne $sesion.colorDepth) { $politicas['ColorDepth'] = @{ 16 = 2; 24 = 3; 32 = 4 }[[int]$sesion.colorDepth] }
    $idle = [int](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.idleDisconnectMinutes' -PorDefecto 0)
    $politicas['MaxIdleTime'] = $idle * 60000
    $clip = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.clipboard' -PorDefecto $true)
    $politicas['fDisableClip'] = $(if ($clip) { 0 } else { 1 })
    $drives = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.driveRedirection' -PorDefecto $false)
    $politicas['fDisableCdm'] = $(if ($drives) { 0 } else { 1 })
    $print = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.printerRedirection' -PorDefecto $false)
    $politicas['fDisablePrint'] = $(if ($print) { 0 } else { 1 })
}

# --- AVC444 / codificador de hardware: solo con GPU real ---------------------
$gpu = Get-GvmGpuInfo
$quiere444 = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.avc444' -PorDefecto $true)
$quiereHw = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.hardwareEncoding' -PorDefecto $true)
if ($gpu.Presente) {
    $politicas['AVC444ModePreferred'] = $(if ($quiere444) { 1 } else { 0 })
    $politicas['AVCHardwareEncodePreferred'] = $(if ($quiereHw) { 1 } else { 0 })
    $politicas['bEnumerateHWBeforeSW'] = 1
    $politicas['fEnableWddmDriver'] = 1
    $avc444 = $quiere444
    Add-Item 'AVC 4:4:4 / codificador HW' 'aplicado' "GPU '$($gpu.Nombre)' presente; politicas escritas"
} else {
    $politicas['AVC444ModePreferred'] = 0
    $politicas['AVCHardwareEncodePreferred'] = 0
    $politicas['fEnableWddmDriver'] = 0
    $avc444 = $false
    Add-Item 'AVC 4:4:4 / codificador HW' 'omitido' 'no hay GPU util: se desactivan explicitamente en lugar de dejar politicas apuntando a un hardware que no existe'
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'sin GPU: la sesion remota usara el camino XDDM/software (vale para escritorio, no para jugar)'
}

# --- Escritura de politicas ---------------------------------------------------
foreach ($k in $politicas.Keys) {
    $v = $politicas[$k]
    if ($v -is [bool]) { $v = [int]$v }
    $tipo = if ($v -is [string]) { 'String' } else { 'DWord' }
    Set-GvmRegistryValue -Path $ts -Name $k -Value $v -Type $tipo -Comentario 'config/remote-session.json' | Out-Null
}
Add-Item 'politicas de Terminal Services' 'aplicado' "$($politicas.Count) valores"

# --- Habilitar conexiones de escritorio remoto (el rol RDS no hace falta) -----
if ($PSCmdlet.ShouldProcess('RDP-Tcp', 'configurar listener')) {
    Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Type DWord | Out-Null
    Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fSingleSessionPerUser' -Value 1 -Type DWord -Comentario 'una sola sesion por usuario: reconectar reanuda la misma' | Out-Null
    if ($port -ne 3389) {
        Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'PortNumber' -Value $port -Type DWord -Comentario 'puerto personalizado declarado en remote.port' | Out-Null
        $requiereReinicio = $true
        Add-Item 'puerto RDP' 'aplicado' "$port (requiere reinicio y abrir ese puerto en el firewall del proveedor)"
    } else {
        Add-Item 'puerto RDP' 'omitido' '3389 por defecto'
    }
}

# --- Reconexion ---------------------------------------------------------------
$intentos = [int](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.reconnectRetries' -PorDefecto 5)
Set-GvmRegistryValue -Path $ts -Name 'MaxReconnectionTime' -Value ([Math]::Max(60000, $intentos * 60000)) -Type DWord -Comentario 'ventana de reconexion tras cortes de red' | Out-Null
Add-Item 'reconexion' 'aplicado' "MaxReconnectionTime = $([Math]::Max(60000, $intentos * 60000)) ms"

# --- Firewall -----------------------------------------------------------------
$cidrs = @(Get-GvmConfigValor -Config $cfg -Ruta 'remote.allowedCidrs' -PorDefecto @())
$tunel = Get-GvmConfigValor -Config $cfg -Ruta 'remote.tunnel' -PorDefecto 'none'
$reglas = 'Remote Desktop - User Mode (TCP-In)', 'Remote Desktop - User Mode (UDP-In)'
foreach ($r in $reglas) {
    $existe = Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue
    if (-not $existe) { Add-Item "firewall: $r" 'aviso' 'la regla integrada no existe en esta edicion' ; continue }
    if ($PSCmdlet.ShouldProcess($r, 'configurar alcance')) {
        if ($cidrs.Count -gt 0) {
                Set-NetFirewallRule -DisplayName $r -Enabled True -Profile Any -RemoteAddress $cidrs | Out-Null
            Add-Item "firewall: $r" 'aplicado' "activada solo para: $($cidrs -join ', ')"
        } elseif ($tunel -ne 'none') {
            Set-NetFirewallRule -DisplayName $r -Enabled True -Profile Private -RemoteAddress 'LocalSubnet' | Out-Null
            Add-Item "firewall: $r" 'aplicado' "acceso solo desde la red del tunel ($tunel)"
        } else {
            Set-NetFirewallRule -DisplayName $r -Enabled False | Out-Null
            Add-Item "firewall: $r" 'aviso' 'sin allowedCidrs y sin tunel: regla DESACTIVADA a proposito. Abre el acceso por tunel (remote.tunnel) o lista tu IP en remote.allowedCidrs.'
        }
    }
}
$udp = $true
if (Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.udp' -PorDefecto $true) {
    $udpRule = Get-NetFirewallRule -DisplayName 'Remote Desktop - User Mode (UDP-In)' -ErrorAction SilentlyContinue
    $udp = [bool]($udpRule -and [bool]$udpRule.Enabled)
}

# --- Audio del escritorio remoto ---------------------------------------------
# Claves documentadas por la GPO "Remote Desktop Session Host > Device and Resource
# Redirection": "Allow audio and video playback redirection" se guarda como fDisableCam
# (0 = permitida, 1 = no permitida) y "Allow audio recording redirection" como
# fDisableAudioCapture (0 = permitido, 1 = bloqueado). No se usa ningun otro nombre:
# las variantes que circulan por foros no tienen respaldo en la politica.
$audio = Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.audio' -PorDefecto 'play'
if ($audio -eq 'no-play') {
    Set-GvmRegistryValue -Path $ts -Name 'fDisableCam' -Value 1 -Type DWord -Comentario 'audio desactivado por config (no permitir redireccion de reproduccion)' | Out-Null
    Add-Item 'audio remoto' 'aplicado' 'redireccion de reproduccion bloqueada (remote.session.audio=no-play)'
} else {
    Set-GvmRegistryValue -Path $ts -Name 'fDisableCam' -Value 0 -Type DWord -Comentario 'permitir redireccion de audio y video al cliente' | Out-Null
    Add-Item 'audio remoto' 'aplicado' "reproduccion permitida al cliente ($audio); si no oyes nada, revisa el servicio Windows Audio en la VM y el modo de audio del cliente"
}
# El micro NO se redirige por defecto: en una VM personal es un micro siempre encendido.
Set-GvmRegistryValue -Path $ts -Name 'fDisableAudioCapture' -Value 1 -Type DWord -Comentario 'captura de audio bloqueada; para chat de voz ponlo a 0 y habilitalo en el cliente' | Out-Null
Add-Item 'microfono del cliente' 'aplicado' 'bloqueado (fDisableAudioCapture=1) de forma deliberada'

# --- Restringir a administradores --------------------------------------------
if (Get-GvmConfigValor -Config $cfg -Ruta 'security.restrictRdpToAdministrators' -PorDefecto $true) {
    $grupo = Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction SilentlyContinue
    if ($grupo) {
        Add-Item 'Remote Desktop Users' 'aviso' "hay miembros no administradores: $($grupo.Name -join ', '). Retiralos si no deben poder conectarse"
    } else {
        Add-Item 'Remote Desktop Users' 'aplicado' 'grupo vacio: solo Administradores entra por RDP'
    }
}

# --- Guia para el cliente (Android) -------------------------------------------
$destino = if (Test-Path -LiteralPath 'D:\') { 'D:\WinGamingVM\acceso-windows-app.md' } else { 'C:\WinGamingVM\acceso-windows-app.md' }
if ($PSCmdlet.ShouldProcess($destino, 'escribir guia de acceso')) {
    $dir = Split-Path $destino -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $guia = @"
# Acceder desde Android con Windows App

1. Google Play > instalar **Windows App** (com.microsoft.rdc.androidx). Android 11 o superior.
2. Abrir la app > pestana **Devices/Equipos** > **Add PC**:
   - PC name: la IP publica de la VM, o la IP del tunel ($tunel) - NUNCA dejes 0.0.0.0/32 abierta.
   - User account: Ask when needed (la contraseña no se guarda en este proyecto).
   - Group: WinGamingVM (opcional).
3. Antes de conectar, en la conexion:
   - **Display**: resolucion "Use my device resolution" (recomendado) o fija;
     escala 125-150 % para pantallas de movil.
   - **Mouse**: elige 'Direct touch' para tocar iconos, 'Mouse pointer' para arrastrar ventanas.
   - **Keyboard**: activa 'Use scancode input when available' si vas a jugar con teclado Bluetooth.
4. Limitaciones reales de este cliente (no son configurables desde la VM):
   - NO redirige mandos Bluetooth/USB: para jugar con mando usa el canal Moonlight (docs/09).
   - NO tiene joystick ni botones en pantalla: la capa tactil vive en el cliente de juego.
   - RDP no ofrece VRR/HDR/10 bits; para 60-120 fps usa el canal de juego.
5. Indicadores de conexion: Windows App no muestra latencia. En la VM:
   powershell -File C:\ProgramData\WinGamingVM\repo\scripts\win\Get-SystemMetrics.ps1 -Modo ping

Canal de juego (opcional, si la VM tiene GPU): instalar **Moonlight Game Streaming** (paquete de Android com.limelight, codigo en github.com/moonlight-stream/moonlight-android)
en el mismo movil y conectar a la VM por la IP del tunel; el PIN de pairing se genera en la UI
de Sunshine (https://VM:47990) que solo escucha en la red local o del tunel.
"@
    $guia | Set-Content -LiteralPath $destino -Encoding UTF8
    Add-Item 'guia de acceso' 'aplicado' $destino
}

$hallazgos = @(
    New-GvmHallazgo -Item 'RDP' -Nivel OK -Detalle "escuchando en TCP $port con NLA=$nla y $udp UDP"
    New-GvmHallazgo -Item 'AVC 4:4:4' -Nivel $(if ($avc444) { 'OK' } else { 'WARN' }) -Detalle $(if ($avc444) { 'politica habilitada (negociada con el cliente)' } else { 'desactivada: no hay GPU que codifique' })
    New-GvmHallazgo -Item 'Exposicion' -Nivel $(if ($cidrs.Count -or $tunel -ne 'none') { 'OK' } else { 'ERROR' }) -Detalle $(if ($cidrs.Count) { "limitado a $($cidrs.Count) CIDR" } elseif ($tunel -ne 'none') { "tunel $tunel" } else { 'sin CIDR y sin tunel: no se abrio el puerto' })
)
New-GvmInforme -Nombre 'escritorio-remoto' -Datos ([pscustomobject]@{ puerto = $port; nla = $nla; udp = $udp; avc444 = $avc444; politicas = $politicas; tunel = $tunel; cidrs = $cidrs; items = $detallado }) -Hallazgos $hallazgos | Out-Null

Write-GvmLog -Nivel OK -Fase $Fase -Mensaje "RDP listo en el puerto $port (NLA=$nla, UDP=$udp, AVC444=$avc444)"
[pscustomobject]@{
    Puerto           = $port
    Nla              = $nla
    Udp              = $udp
    Avc444           = $avc444
    RequiereReinicio = $requiereReinicio
    Detallado        = $detallado
}
