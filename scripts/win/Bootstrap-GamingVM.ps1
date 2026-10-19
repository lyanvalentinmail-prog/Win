<#
.SYNOPSIS
  Punto de entrada del bootstrap de la VM de gaming con Windows.
.DESCRIPTION
  Orquesta las fases de preparacion de la VM. Es IDEMPOTENTE: cada fase guarda un
  checkpoint en C:\ProgramData\WinGamingVM\state\fases.json y se salta si ya esta
  completada (a menos que se fuerce). Puede reanudarse tras un reinicio.

  Fases:
    1 preflight        Requisitos, edicion de Windows, discos, red hacia fuentes oficiales
    2 gpu              Driver de GPU (GPU-Paravirtualization / GRID) y comprobacion DX
    3 escritorio       Optimizaciones de energia, GPU scheduling, GameDVR, servicios
    4 remoto           RDP para Windows App (politicas, NLA, UDP, AVC444) + firewall
    5 apps             Instalacion de aplicaciones seleccionadas via winget
    6 gaming           Canal de juego (Sunshine), perfiles de control, monitoreo
    7 seguridad        Linea base de seguridad (no desactiva Defender ni actualizaciones)
    8 informe          Auditoria final Test-GamingReadiness + resumen en informe\

  El guion NO crea usuarios, NO fija contrasenas y NO guarda secretos: la cuenta
  de administrador la crea la infraestructura (Azure/AWS) o la instalacion de KVM.
.PARAMETER Config
  Ruta al JSON de configuracion (config\vm.json en la VM).
.PARAMETER Fases
  Subconjunto de fases a ejecutar. Por defecto todas.
.PARAMETER Reanudar
  Ejecuta solo las fases pendientes o fallidas.
.PARAMETER Forzar
  Vuelve a ejecutar fases ya completadas.
.PARAMETER Simulacion
  WhatIf: muestra lo que haria sin tocar el sistema (ni instala).
.EXAMPLE
  .\Bootstrap-GamingVM.ps1 -Config C:\ProgramData\WinGamingVM\config\vm.json
.EXAMPLE
  .\Bootstrap-GamingVM.ps1 -Fases remoto,apps -Simulacion
.NOTES
  Ejecutar como Administrador. Registro: C:\ProgramData\WinGamingVM\logs\.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Config,
    [string[]]$Fases,
    [switch]$Reanudar,
    [switch]$Forzar,
    [switch]$Simulacion,
    [string]$BaseDir = 'C:\ProgramData\WinGamingVM'
)

# StrictMode 1.0: pilla variables sin inicializar. No se usa 'Latest' porque la
# configuracion viene de JSON con campos opcionales y 2.0+ lanza al leer una propiedad
# ausente (el bootstrap debe tolerar configs parciales y aplicar valores por defecto).
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$modulo = Join-Path $PSScriptRoot 'Modules\GamingVM'
if (-not (Get-Module -ListAvailable -Name GamingVM)) { $env:PSModulePath = "$modulo;$env:PSModulePath" }
Import-Module (Join-Path $modulo 'GamingVM.psd1') -Force -ErrorAction Stop

$TODAS = 'preflight', 'gpu', 'escritorio', 'remoto', 'apps', 'gaming', 'seguridad', 'informe'
if (-not $Fases) { $Fases = $TODAS }
$Fases = @($Fases | Where-Object { $TODAS -contains $_ })
if ($Fases.Count -eq 0) { throw "Ninguna fase valida. Valores: $($TODAS -join ', ')" }

$runtime = Initialize-GvmRuntime -BaseDir $BaseDir -Nombre 'bootstrap'
$que = if ($Simulacion) { ' (SIMULACION)' } else { '' }
Write-GvmLog -Nivel OK -Mensaje "=== Win Gaming VM bootstrap$que ===" -Detalle "fases: $($Fases -join ', ')"

if (-not (Test-GvmEsAdministrador)) { throw 'Ejecuta este script en una consola elevada (Administrador).' }
try { $cfg = Get-GvmConfig -Ruta $Config } catch { Write-GvmLog -Nivel ERROR -Mensaje $_.Exception.Message; throw }

$resumen = [ordered]@{}
$pendientesReinicio = New-Object System.Collections.Generic.List[string]

function Invoke-GvmFase {
    param([Parameter(Mandatory)][string]$Nombre, [Parameter(Mandatory)][scriptblock]$Cuerpo)
    if ($Fases -notcontains $Nombre) { return }
    $estado = Get-GvmCheckpoint -Fase $Nombre
    if (-not $Forzar -and $estado -and $estado.estado -eq 'completada') {
        Write-GvmLog -Nivel OK -Fase $Nombre -Mensaje 'fase ya completada, se omite (usa -Forzar para repetir)'
        $resumen[$Nombre] = 'omitida (completada)'
        return
    }
    if ($estado -and $estado.estado -eq 'en-curso' -and -not $Forzar) {
        Write-GvmLog -Nivel WARN -Fase $Nombre -Mensaje 'la fase anterior quedo en-curso (¿corte?); se repite'
    }
    Set-GvmCheckpoint -Fase $Nombre -Estado 'en-curso'
    $ini = Get-Date
    try {
        $resultado = & $Cuerpo
        $msg = if ($resultado -is [string]) { $resultado } elseif ($resultado) { ($resultado | ConvertTo-Json -Compress -Depth 4) } else { 'sin salida' }
        Set-GvmCheckpoint -Fase $Nombre -Estado 'completada' -Mensaje $msg
        $resumen[$Nombre] = 'completada'
        Write-GvmLog -Nivel OK -Fase $Nombre -Mensaje "fin de fase en $([math]::Round(((Get-Date) - $ini).TotalSeconds, 1)) s"
    } catch {
        Set-GvmCheckpoint -Fase $Nombre -Estado 'fallida' -Mensaje $_.Exception.Message
        $resumen[$Nombre] = "fallida: $($_.Exception.Message)"
        # Sin la posicion y la pila, 'fase abortada :: Argument types do not match' no dice
        # donde mirar: se añade el ScriptName:Line y las primeras lineas de la pila.
        $donde = 'n/d'
        if ($_.InvocationInfo) { $donde = "$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" }
        $pila = @($_.ScriptStackTrace -split "`n" | Select-Object -First 6) -join ' <- '
        # TargetSite/ParamName son lo unico que distingue 'el ConvertTo-Json' de 'el
        # Set-Content' cuando el mensaje viene del binder de .NET; la pila CLR remata.
        $sitio = 'n/d'
        if ($_.Exception.TargetSite) { $sitio = "$($_.Exception.TargetSite.DeclaringType.Name).$($_.Exception.TargetSite.Name)" }
        $param = if ($_.Exception.ParamName) { $_.Exception.ParamName } else { 'n/d' }
        $clr = @($_.Exception.StackTrace -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 5) -join ' <- '
        Write-GvmLog -Nivel ERROR -Fase $Nombre -Mensaje "fase abortada en $donde" -Detalle "$($_.Exception.GetType().Name): $($_.Exception.Message) | en: $sitio param: $param | pila: $pila | clr: $clr"
    }
}

# --- 1. preflight -------------------------------------------------------------
Invoke-GvmFase 'preflight' {
    $req = @()
    $req += Test-GvmRequisito -Tipo build -Nombre 'Windows 10+ / Server 2019+' -Valor 17763 -Fase preflight
    $req += Test-GvmRequisito -Tipo 'disco-libre' -Nombre 'sistema' -Valor 'C' -Fase preflight
    $req += Test-GvmRequisito -Tipo ram -Nombre 'RAM minima' -Valor 6 -Fase preflight
    $winget = Get-GvmWingetComando
    $req += [pscustomobject]@{ Tipo = 'comando'; Nombre = 'winget'; Cumple = [bool]$winget; Detalle = if ($winget) { $winget } else { 'no disponible en esta edicion: mira docs/08-instalacion-apps.md' } }

    $sesion = Get-GvmSesionActual
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    Write-GvmLog -Fase preflight -Mensaje "SO: $edition · sesion: $($sesion.NombreSesion) (id$($sesion.SessionId))"

    $url = Get-GvmConfigValor -Config $cfg -Ruta 'windows.wallpaper.path'
    if ($url) {
        $origen = Test-GvmOrigenPermitido -Url $url
        if (-not $origen.Permitido) { Write-GvmLog -Nivel WARN -Fase preflight -Mensaje 'wallpaper.url no procede de una fuente oficial declarada' -Detalle $origen.Motivo }
    }
    $pend = @($req | Where-Object { -not $_.Cumple } | ForEach-Object { "$($_.Tipo):$($_.Nombre)" })
    if ($pend.Count -gt 0) { Write-GvmLog -Nivel WARN -Fase preflight -Mensaje "requisitos pendientes: $($pend -join ', ')" }
    "requisitos: $($req.Count - $pend.Count)/$($req.Count) OK"
}

# --- 2. gpu -------------------------------------------------------------------
Invoke-GvmFase 'gpu' {
    $script = Join-Path $PSScriptRoot 'Install-GpuDriver.ps1'
    if (-not (Test-Path -LiteralPath $script)) { throw "falta $script" }
    $params = @{ Config = $cfg }
    if ($Simulacion) { $params['WhatIf'] = $true }
    $r = & $script @params
    if ($r.RequiereReinicio) { $pendientesReinicio.Add('gpu') }
    if ($r.Estado -eq 'sin-gpu') {
        Write-GvmLog -Nivel WARN -Fase gpu -Mensaje 'El host no tiene GPU util: no se simulera. Los canales que dependen de GPU quedan desactivados.' -Detalle $r.Detalle
    }
    "gpu: $($r.Estado)"
}

# --- 3. escritorio -------------------------------------------------------------
Invoke-GvmFase 'escritorio' {
    $params = @{}
    if ($Simulacion) { $params['WhatIf'] = $true }
    $r = & (Join-Path $PSScriptRoot 'Set-GamingOptimizations.ps1') -Config $cfg @params
    if ($r.RequiereReinicio) { $pendientesReinicio.Add('escritorio') }
    "optimizaciones: $($r.Aplicados) aplicados, $($r.Omitidos) omitidos, $($r.Advertencias) avisos"
}

# --- 4. remoto -----------------------------------------------------------------
Invoke-GvmFase 'remoto' {
    $params = @{}
    if ($Simulacion) { $params['WhatIf'] = $true }
    $r = & (Join-Path $PSScriptRoot 'Set-RemoteDesktop.ps1') -Config $cfg @params
    if ($r.RequiereReinicio) { $pendientesReinicio.Add('remoto') }
    "rdp: puerto $($r.Puerto), nla=$($r.Nla), udp=$($r.Udp), avc444=$($r.Avc444)"
}

# --- 5. apps -------------------------------------------------------------------
Invoke-GvmFase 'apps' {
    $params = @{}
    if ($Simulacion) { $params['WhatIf'] = $true }
    $r = & (Join-Path $PSScriptRoot 'Install-Apps.ps1') -Config $cfg @params
    "apps: $($r.Instaladas) instaladas, $($r.Omitidas) omitidas, $($r.Fallidas) fallidas, $($r.Pendientes) pendientes de accion manual"
}

# --- 6. gaming -----------------------------------------------------------------
Invoke-GvmFase 'gaming' {
    $params = @{}
    if ($Simulacion) { $params['WhatIf'] = $true }
    $s = & (Join-Path $PSScriptRoot 'Set-Sunshine.ps1') -Config $cfg @params
    $t = & (Join-Path $PSScriptRoot 'Set-TouchControls.ps1') -Config $cfg @params
    if ($s.RequiereReinicio) { $pendientesReinicio.Add('sunshine') }
    "canal-juego: $($s.Estado) · controles: $($t.Perfiles) perfiles aplicados"
}

# --- 7. seguridad --------------------------------------------------------------
Invoke-GvmFase 'seguridad' {
    $params = @{}
    if ($Simulacion) { $params['WhatIf'] = $true }
    $r = & (Join-Path $PSScriptRoot 'Set-SecurityBaseline.ps1') -Config $cfg @params
    "seguridad: $($r.Aplicados) medidas, $($r.Advertencias) avisos"
}

# --- 8. informe ----------------------------------------------------------------
Invoke-GvmFase 'informe' {
    $r = & (Join-Path $PSScriptRoot 'Test-GamingReadiness.ps1') -Config $cfg -Exportar
    $ruta = if ($r) { $r.RutaInforme } else { 'n/d' }
    "auditoria lista: $ruta (preparada=$($r.Preparada))"
}

# --- Resumen -------------------------------------------------------------------
Write-GvmLog -Nivel OK -Mensaje '=== resumen de fases ==='
foreach ($k in $resumen.Keys) { Write-GvmLog -Mensaje ("  {0,-12} {1}" -f $k, $resumen[$k]) -AlConsola }

$hayFallas = @($resumen.Values | Where-Object { $_ -like 'fallida*' }).Count -gt 0
$detalleFases = @($resumen.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object)
$hallazgosFin = @(New-GvmHallazgo -Item 'Fases' -Nivel $(if ($hayFallas) { 'WARN' } else { 'OK' }) -Detalle ($detalleFases -join ' | '))

$informe = New-GvmInforme -Nombre 'bootstrap' -Datos ([pscustomobject]@{
    config      = Get-GvmConfigValor -Config $cfg -Ruta 'name'
    proveedor   = Get-GvmConfigValor -Config $cfg -Ruta 'provider'
    fases       = $resumen
    simulacion  = [bool]$Simulacion
    log         = $runtime.LogFile
}) -Hallazgos $hallazgosFin

if ($pendientesReinicio.Count -and -not $Simulacion) {
    Write-GvmLog -Nivel WARN -Mensaje "reinicio necesario para: $($pendientesReinicio -join ', ')" -Detalle 'Si ejecutas el bootstrap desde un despliegue automatizado, el paso de reinicio lo lanza el propio script; en manual, reinicia y ejecuta con -Reanudar.'
    Set-GvmCheckpoint -Fase 'reinicio' -Estado 'pendiente' -Mensaje 'reinicio requerido' -RequiereReinicio
    if ($env:GVM_AUTO_REBOOT -eq '1') {
        schtasks.exe /Create /TN 'WinGamingVM-Reanudar' /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Reanudar" /SC ONSTART /RU SYSTEM /F | Out-Null
        Write-GvmLog -Mensaje 'tarea de reanudacion creada; reiniciando en 30 s'
        if ($PSCmdlet.ShouldProcess('VM', 'reiniciar')) { Restart-Computer -Force }
    }
}

$fallo = @($resumen.Values | Where-Object { $_ -like 'fallida*' }).Count
if ($fallo -gt 0) {
    Write-GvmLog -Nivel ERROR -Mensaje "$fallo fase(s) fallaron; revisa $($runtime.LogFile)"
    exit 2
}
Write-GvmLog -Nivel OK -Mensaje 'bootstrap completado sin fallos'
exit 0
