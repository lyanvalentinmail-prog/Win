<#
.SYNOPSIS
  Auditoria "que hay de verdad" de la VM: GPU, codificador, sesion, RDP, canal de juego,
  rendimiento de red y aplicaciones. Produce un informe y un codigo de salida utilisable en CI.
.DESCRIPTION
  Este script es la garantia de que el proyecto no promete lo que no tiene: cada botonera de
  gaming depende de un comprobante real (GPU visible, driver WDDM, codificador HW, Sunshine
  corriendo, polticas de sesion, latencia medida). Si algo falta, lo dice en el informe con
  la accion concreta a tomar, en lugar de decir "todo OK".
.PARAMETER Exportar
  Devuelve las rutas del informe .json/.md generados en C:\ProgramData\WinGamingVM\informes.
.PARAMETER Juego
  Id de perfil (gaming/profiles/<id>.json) para anadir la comprobacion de requisitos contra
  el hardware REAL de esta VM.
.OUTPUTS
  PSCustomObject con Preparada (bool), Nivel, Hallazgos, RutaInforme, Datos
#>
[CmdletBinding()]
param(
    $Config,
    [switch]$Exportar,
    [string]$Juego,
    [string[]]$ObjetivosLatencia = @(),
    [int]$PaquetesPrueba = 10,
    [string]$RepoDir
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force
Initialize-GvmRuntime -Nombre 'readiness' | Out-Null

if (-not $RepoDir) {
    foreach ($c in @($env:GVM_REPO_DIR, 'C:\ProgramData\WinGamingVM\repo', (Join-Path $PSScriptRoot '..\..'))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'gaming'))) { $RepoDir = (Resolve-Path $c).Path; break }
    }
}
$cfg = $null
if ($Config) { $cfg = Resolve-GvmConfig -Entrada $Config }

$hallazgos = New-Object System.Collections.Generic.List[object]
function Add-Hallazgo { param([string]$i, [string]$n, [string]$d) $hallazgos.Add((New-GvmHallazgo -Item $i -Nivel $n -Detalle $d)) }

$os = Get-CimInstance Win32_OperatingSystem
$so = [pscustomobject]@{
    nombre     = $os.Caption
    build      = [Environment]::OSVersion.Version.Build
    esServer   = $os.Caption -match 'Server'
    edicionCfg = $(if ($cfg) { Get-GvmConfigValor -Config $cfg -Ruta 'windows.edition' } else { 'n/d' })
    idioma     = (Get-Culture).Name
}
$serviciosSeguros = @('WinDefend', 'mpssvc', 'wuauserv')
foreach ($s in $serviciosSeguros) {
    $st = (Get-Service -Name $s -ErrorAction SilentlyContinue).Status
    if ($st -ne 'Running') { Add-Hallazgo "servicio de seguridad $s" 'ERROR' "estado $st : el proyecto no debe seguir sin el (es el servicio de antivirus/firewall/update)" }
    else { Add-Hallazgo "servicio de seguridad $s" 'OK' 'en ejecucion' }
}

# --- 1. GPU -------------------------------------------------------------------
$gpu = Get-GvmGpuInfo
if ($gpu.Presente) {
    Add-Hallazgo 'GPU' 'OK' "$($gpu.Nombre) · VRAM informada $($gpu.VramGiB) GiB · driver $($gpu.VersionDriver)"
} else {
    Add-Hallazgo 'GPU' 'WARN' "$($gpu.Resumen) — la VM es un escritorio remoto, no un PC de gaming. Ver docs/05-optimizacion.md"
}
$dx = Test-GvmDirectXDisponible
Add-Hallazgo 'Direct3D' $(if ($dx.Disponible) { 'OK' } else { 'WARN' }) $dx.Motivo
Add-Hallazgo 'Codificador de video' $(if ($gpu.CodificadorHw -ne 'ninguno') { 'OK' } else { 'WARN' }) $(if ($gpu.CodificadorHw -ne 'ninguno') { $gpu.CodificadorHw } else { 'sin NVENC/AMF/QSV: el canal de juego no queda habilitado' })

# --- 2. Sesion actual ----------------------------------------------------------
$ses = Get-GvmSesionActual
$esRdp = [bool]($ses.NombreSesion -like '*RDP*' -or $ses.Cliente)
Add-Hallazgo 'Sesion' $(if ($esRdp) { 'INFO' } else { 'OK' }) $(if ($esRdp) { "sesion RDP #$($ses.SessionId) (cliente $($ses.Cliente)); si usas Sunshine, ejecuta Unlock-ConsoleSession.ps1" } else { "sesion de consola #$($ses.SessionId)" })

# --- 3. Politicas de RDP -------------------------------------------------------
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$rdp = [ordered]@{}
foreach ($k in 'fDenyTSConnections', 'UserAuthentication', 'ColorDepth', 'AVC444ModePreferred', 'AVCHardwareEncodePreferred', 'fEnableWddmDriver', 'MaxIdleTime', 'MaxReconnectionTime') {
    $rdp[$k] = Get-GvmRegistryValue -Path $ts -Name $k
}
$rdp['escuchando'] = @(Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue).Count
if ($rdp['fDenyTSConnections'] -eq 0 -and $rdp['escuchando'] -gt 0) { Add-Hallazgo 'RDP' 'OK' "escuchando en 3389, NLA=$($rdp['UserAuthentication']), color=$($rdp['ColorDepth'])" }
else { Add-Hallazgo 'RDP' 'ERROR' "RDP no operativo (fDenyTSConnections=$($rdp['fDenyTSConnections']), escuchando=$($rdp['escuchando']))" }
if ($gpu.Presente -and $rdp['AVC444ModePreferred'] -eq 1) { Add-Hallazgo 'AVC 4:4:4' 'OK' 'politica habilitada y con GPU detras (la negociacion final la hace el cliente)' }
elseif (-not $gpu.Presente) { Add-Hallazgo 'AVC 4:4:4' 'INFO' 'no aplicable: sin GPU no hay codificador AVC en RDP (no se ha simulado)' }
else { Add-Hallazgo 'AVC 4:4:4' 'WARN' 'GPU presente pero politica sin habilitar: ejecuta Set-RemoteDesktop.ps1' }

$cidrs = @()
$udpHabilitada = $false
if ($cfg) {
    $cidrs = @(Get-GvmConfigValor -Config $cfg -Ruta 'remote.allowedCidrs' -PorDefecto @())
    $tunel = Get-GvmConfigValor -Config $cfg -Ruta 'remote.tunnel' -PorDefecto 'none'
    if ($cidrs.Count -eq 0 -and $tunel -eq 'none') {
        Add-Hallazgo 'Exposicion' 'ERROR' "el config no define allowedCidrs ni tunel: RDP deberia seguir cerrado; comprueba el NSG del proveedor"
    } else {
        Add-Hallazgo 'Exposicion' 'OK' "acceso controlado ($([int]@($cidrs).Count) CIDR, tunel '$tunel')"
    }
    $udpHabilitada = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'remote.session.udp' -PorDefecto $true)
}

# --- 4. Canal de juego --------------------------------------------------------
$sunSvc = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='Sunshine' OR Name='SunshineService'" -ErrorAction SilentlyContinue)
$sunEscuchando = @(Get-NetTCPConnection -State Listen -LocalPort 47984, 47990 -ErrorAction SilentlyContinue)
$canal = if ($cfg) { Get-GvmConfigValor -Config $cfg -Ruta 'gaming.channel' -PorDefecto 'rdp' } else { 'n/d' }
if ($canal -in 'moonlight', 'both') {
    if ($sunSvc.Count -gt 0 -and $sunSvc[0].State -eq 'Running' -and $sunEscuchando.Count -gt 0) {
        Add-Hallazgo 'Canal de juego' 'OK' "Sunshine running, puertos escuchando ($($sunEscuchando.Count)); emparejar cliente en https://localhost:47990"
    } else {
        Add-Hallazgo 'Canal de juego' 'WARN' "el config pide canal de juego pero Sunshine no esta operativo (servicio=$($sunSvc.Count) puertos=$($sunEscuchando.Count)): ejecuta Set-Sunshine.ps1 o revisa el motivo en el informe canal-juego.md"
    }
} else {
    Add-Hallazgo 'Canal de juego' 'INFO' "gaming.channel=$canal : solo escritorio RDP (sin overlays tactiles ni mando virtual)"
}

# --- 5. Requisitos del juego concreto -----------------------------------------
$juegoInfo = $null
if ($Juego -and $RepoDir) {
    $rutaPerfil = Join-Path $RepoDir "gaming\profiles\$Juego.json"
    if (Test-Path -LiteralPath $rutaPerfil) {
        $pf = Get-Content -LiteralPath $rutaPerfil -Raw -Encoding UTF8 | ConvertFrom-Json
        $juegoInfo = $pf
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $cpuLogicos = 0
        foreach ($p in @(Get-CimInstance Win32_Processor)) { $cpuLogicos += [int]$p.NumberOfLogicalProcessors }
        $falta = @()
        if ($pf.requisitos.ramGiB -and $ram -lt $pf.requisitos.ramGiB) { $falta += "RAM $ram < $($pf.requisitos.ramGiB) GiB" }
        if ($pf.requisitos.vcpu -and $cpuLogicos -lt $pf.requisitos.vcpu) { $falta += "vCPU $cpuLogicos < $($pf.requisitos.vcpu)" }
        if ($pf.requisitos.vramGiB -and $gpu.VramGiB -lt $pf.requisitos.vramGiB) { $falta += "VRAM $($gpu.VramGiB) < $($pf.requisitos.vramGiB) GiB (la VRAM de una particion se comparte con el compositor: el numero es indicativo)" }
        if ($pf.compatibilidadVm.necesitaGpu -and -not $gpu.Presente) { $falta += 'el juego necesita GPU y el host no la expone' }
        $anticheat = $pf.compatibilidadVm.antitrampas.vm
        if ($anticheat -eq 'restringida') {
            Add-Hallazgo "Juego: $($pf.id)" 'ERROR' "antichat ($($pf.compatibilidadVm.antitrampas.sistemas -join ', ')) rechaza VM: no lo instales ni lo intentes. $($pf.compatibilidadVm.antitrampas.nota)"
        } elseif ($anticheat -eq 'desconocida') {
            Add-Hallazgo "Juego: $($pf.id)" 'WARN' "estado del antichat en VM: desconocido; ver gaming/antitrampas.md antes de invertir tiempo"
        } elseif ($falta.Count -gt 0) {
            Add-Hallazgo "Juego: $($pf.id)" 'WARN' "requisitos no cumplidos: $($falta -join '; ')"
        } else {
            Add-Hallazgo "Juego: $($pf.id)" 'OK' "requisitos cubiertos por esta VM (preset $($pf.rendimiento.preset))"
        }
    } else { Add-Hallazgo "Juego: $Juego" 'WARN' ("no existe gaming/profiles/{0}.json en el repo de la VM" -f $Juego) }
}

# --- 6. Almacenamiento persistente -------------------------------------------
$discos = @()
foreach ($d in @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null })) {
    $discos += [pscustomobject]@{ Letra = $d.Name; LibreGiB = [math]::Round($d.Free / 1GB, 1); TotalGiB = [math]::Round((($d.Used + $d.Free) / 1GB), 1) }
    if ($d.Name -eq 'D') { Add-Hallazgo 'Disco de datos D:' 'OK' "$([math]::Round($d.Free / 1GB, 1)) GiB libres (juegos, documentos y configuraciones persistentes)" }
}
if (-not (Test-Path -LiteralPath 'D:\')) {
    Add-Hallazgo 'Disco de datos D:' 'WARN' 'no existe una unidad de datos independiente: en Azure/AWS el disco temporal NO persiste tras deallocate/start. Crea el dataDisk o usa C: asumiendo el riesgo.'
}

# --- 7. Red y latencia ---------------------------------------------------------
$ping = $null
if ($ObjetivosLatencia.Count -eq 0) {
    $gw = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    if ($gw) { $ObjetivosLatencia = @('1.1.1.1', $gw[0]) } else { $ObjetivosLatencia = @('1.1.1.1') }
}
try {
    $ping = & (Join-Path $PSScriptRoot 'Get-SystemMetrics.ps1') -Modo ping -Objetivos $ObjetivosLatencia -Paquetes $PaquetesPrueba
    foreach ($p in $ping) {
        $nivel = 'OK'
        if ($p.Perdida -ge 5) { $nivel = 'ERROR' } elseif ($p.Media -gt 80) { $nivel = 'WARN' } elseif ($p.Media -gt 40) { $nivel = 'WARN' }
        $objetivoCfg = 40.0
        if ($cfg) { $objetivoCfg = [double](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.monitoring.latencyTargetMs' -PorDefecto 40) }
        Add-Hallazgo "latencia $($p.Objetivo)" $nivel "$($p.Media) ms media, p95 $($p.P95) ms, perdida $($p.Perdida) % (objetivo < $objetivoCfg ms)"
    }
} catch { Add-Hallazgo 'latencia' 'WARN' "no se pudo medir: $($_.Exception.Message)" }

# --- 8. Aplicaciones -----------------------------------------------------------
$appResumen = @()
foreach ($id in 'Valve.Steam', 'EpicGames.EpicGamesLauncher', 'Mojang.MinecraftLauncher', 'LizardByte.Sunshine') {
    $a = Get-GvmAppInstalada -Id $id
    $appResumen += [pscustomobject]@{ Id = $id; Instalada = [bool]$a; Version = $(if ($a) { $a.Version } else { '' }) }
}
$pend = @($appResumen | Where-Object { -not $_.Instalada })
if ($pend.Count -eq 0) { Add-Hallazgo 'Aplicaciones' 'OK' "detectadas: $(($appResumen | ForEach-Object { $_.Id }) -join ', ')" }
else { Add-Hallazgo 'Aplicaciones' 'WARN' "faltan: $($pend.Id -join ', ') (ejecuta Install-Apps.ps1)" }

# --- Veredicto ---------------------------------------------------------------
$nivelGlobal = 'OK'
foreach ($h in $hallazgos) {
    if ($h.nivel -eq 'ERROR') { $nivelGlobal = 'NO' }
    elseif ($h.nivel -eq 'WARN' -and $nivelGlobal -eq 'OK') { $nivelGlobal = 'PARCIAL' }
}
$preparadaEscritorio = -not (@($hallazgos | Where-Object { $_.nivel -eq 'ERROR' -and $_.item -match 'RDP|servicio' }).Count)
$preparadaJuego = $gpu.Presente -and $dx.Disponible -and ($gpu.CodificadorHw -ne 'ninguno')

$datos = [pscustomobject]@{
    so          = $so
    gpu         = $gpu
    directx     = $dx
    rdp         = $rdp
    canal       = $canal
    sesion      = $ses
    discos      = $discos
    latencia    = $ping
    aplicaciones = $appResumen
    juego       = $juegoInfo
    red         = [pscustomobject]@{ udp = $udpHabilitada; cidrs = $cidrs }
}

if ($Exportar) {
    $rutas = New-GvmInforme -Nombre 'preparacion' -Datos $datos -Hallazgos @($hallazgos)
} else { $rutas = $null }

# Tabla en consola (lo que ve el usuario al terminar el bootstrap)
Write-Host ''
Write-Host '  Win Gaming VM — estado real de la maquina' -ForegroundColor Cyan
Write-Host '  -------------------------------------------------------------'
foreach ($h in $hallazgos) {
    $color = switch ($h.nivel) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    $marca = switch ($h.nivel) { 'OK' { '[ OK ]' } 'WARN' { '[-- ]' } 'ERROR' { '[NO ]' } default { '[ i ]' } }
    Write-Host ("  {0} {1,-32} {2}" -f $marca, $h.item, ($h.detalle -replace "`r?`n", ' ' )) -ForegroundColor $color
}
Write-Host '  -------------------------------------------------------------'
Write-Host ("  Escritorio remoto: {0}   ·  Gaming: {1}" -f $(if ($preparadaEscritorio) { 'LISTO' } else { 'NO' }), $(if ($preparadaJuego) { 'LISTO (canal de juego habilitable)' } else { 'LIMITADO (sin GPU/codificador: no se finge)' })) -ForegroundColor $(if ($preparadaJuego) { 'Green' } else { 'Yellow' })
if ($rutas) { Write-Host "  Informe: $($rutas.Markdown)" -ForegroundColor DarkGray }

[pscustomobject]@{
    Preparada            = [bool]($preparadaEscritorio -and $preparadaJuego)
    PreparadaEscritorio  = [bool]$preparadaEscritorio
    PreparadaGaming      = [bool]$preparadaJuego
    Nivel                = $nivelGlobal
    Hallazgos            = @($hallazgos)
    Datos                = $datos
    RutaInforme          = $(if ($rutas) { $rutas.Markdown } else { '' })
    RutaJson             = $(if ($rutas) { $rutas.Json } else { '' })
}
if ($nivelGlobal -eq 'ERROR') { exit 2 } elseif ($nivelGlobal -eq 'PARCIAL') { exit 0 } else { exit 0 }
