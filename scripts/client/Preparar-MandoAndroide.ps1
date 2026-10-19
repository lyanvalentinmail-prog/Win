<#
  .SYNOPSIS
    Lista de comprobaciones reales para jugar desde un movil/tablet Android (no cambia nada).
  .DESCRIPTION
    Es un script de VERIFICACION y guia, no un configurador: desde Windows no se puede
    tocar la pantalla ni los permisos de un dispositivo Android, ni instalar un perfil
    de controles en el cliente. Lo que si puede hacer es comprobar lo que se comprueba
    desde el PC y recordarte los pasos exactos en el dispositivo, sin inventar funciones.

    Comprobaciones:
      · conectividad y RTT al endpoint del canal de juego (Moonlight/Sunshine) y a RDP;
      · que el canal de juego este escuchando en el puerto esperado;
      · si el perfil de control elegido tiene layout tactile y que ese layout declara;
      · que no estas en una red con AP-Isolation (el clasico "no veo la VM");
      · emite la lista de pasos del lado Android con la advertencia de antitrampas.
  .PARAMETER HostVM
  .PARAMETER Canal            rdp | moonlight | both
  .PARAMETER Perfil          id de perfil en gaming/profiles (para el recordatorio de layout)
  .PARAMETER PuertosMoonlight
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostVM,
    [ValidateSet('rdp', 'moonlight', 'both')][string]$Canal = 'both',
    [string]$Perfil = '',
    [int[]]$PuertosMoonlight = 47984, 47989, 48010
)

Set-StrictMode -Version 1.0   # 1.0: se leen propiedades opcionales de JSON
# 'Continue' a proposito: son scripts de medicion/diagnostico y deben informar de todo,
# no abortar en la primera comprobacion que falle (un puerto cerrado no es un error).
$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Test-TcpAbierto {
    param([string]$h, [int]$p, [int]$timeoutMs = 2500)
    $c = New-Object Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($h, $p); return [bool]($t.Wait($timeoutMs)) } catch { return $false } finally { $c.Dispose() }
}

Write-Host ''
Write-Host "  Win Gaming VM — comprobaciones para jugar desde Android ($Canal)" -ForegroundColor Cyan
Write-Host ''

# 1) Puertos ---------------------------------------------------------------
$lista = @()
if ($Canal -in 'rdp', 'both') { $lista += [pscustomobject]@{ Canal = 'rdp'; Puerto = 3389; Esperado = 'abierto solo si no usas tunel' } }
if ($Canal -in 'moonlight', 'both') { foreach ($p in $PuertosMoonlight) { $lista += [pscustomobject]@{ Canal = 'moonlight'; Puerto = $p; Esperado = 'escuchando en la VM' } } }
foreach ($e in $lista) {
    $abierto = Test-TcpAbierto -h $HostVM -p $e.Puerto
    $marca = if ($abierto) { '[OK]  ' } else { '[--]  ' }
    Write-Host ("  {0}{1,-10} {2,-6} {3}" -f $marca, $e.Canal, $e.Puerto, $e.Esperado)
    if (-not $abierto -and $e.Canal -eq 'moonlight') {
        Write-Host '         => Sunshine no escucha ahi: revisa la fase gaming (Set-Sunshine.ps1) y si el host tiene GPU.' -ForegroundColor Yellow
    }
}

# 2) Latencia --------------------------------------------------------------
$valores = @()
try {
    $ping = New-Object Net.NetworkInformation.Ping
    1..10 | ForEach-Object { $r = $ping.Send($HostVM, 800); if ($r.Status -eq 'Success') { $valores += $r.RoundtripTime } }
} catch { }
if ($valores.Count -ge 3) {
    $media = [math]::Round(($valores | Measure-Object -Average).Average, 1)
    $jugable = if ($media -lt 35) { 'comoda para 60 fps si la GPU y el bitrate acompanan' }
               elseif ($media -lt 70) { 'usable; sube el bitrate y baja el todo-ultra para mantener el frame time' }
               else { 'la red manda: plantéate otra region o una conexion por cable/5G dedicada' }
    Write-Host ("  [INFO] RTT media {0} ms sobre {1} sondas => {2}" -f $media, $valores.Count, $jugable)
} else {
    Write-Host '  [AVISO] ICMP sin respuesta (normal en muchos hosts): mide desde el propio movil con ping o con el overlay de Moonlight.' -ForegroundColor Yellow
}

# 3) Perfil de control ------------------------------------------------------
if ($Perfil) {
    $ruta = Join-Path $repo "gaming\profiles\$Perfil.json"
    if (-not (Test-Path -LiteralPath $ruta)) {
        Write-Host "  [ERROR] perfil '$Perfil' no existe en gaming\profiles\" -ForegroundColor Red
    } else {
        $pf = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        # gaming-profile.schema.json: controles.mapeoTactil.layout es una ruta RELATIVA al perfil
        $layoutRef = $null
        if ($pf.controles -and $pf.controles.mapeoTactil -and $pf.controles.mapeoTactil.layout) {
            $layoutRef = $pf.controles.mapeoTactil.layout
        }
        $rutaLayout = if ($layoutRef) { (Resolve-Path (Join-Path (Split-Path $ruta -Parent) $layoutRef) -ErrorAction SilentlyContinue).Path } else { $null }
        $antichat = if ($pf.compatibilidadVm -and $pf.compatibilidadVm.antitrampas) { $pf.compatibilidadVm.antitrampas.vm } else { 'desconocida' }
        Write-Host ''
        Write-Host ("  perfil: {0} · modo tactil: {1} · layout: {2}" -f $pf.nombre, $(if ($pf.controles.mapeoTactil) { $pf.controles.mapeoTactil.modo } else { 'no definido' }), $(if ($layoutRef) { Split-Path $layoutRef -Leaf } else { 'ninguno' }))
        if ($rutaLayout -and (Test-Path -LiteralPath $rutaLayout)) {
            $l = Get-Content -LiteralPath $rutaLayout -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ("  [OK]  layout {0} con {1} elementos ({2})" -f $l.nombre, @($l.elementos).Count, ($l.elementos | Group-Object tipo | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')
            Write-Host '        Reproducilo a mano en Moonlight segun gaming/touch/README.md (no hay importacion desde el host).'
        } elseif ($layoutRef) {
            Write-Host "  [AVISO] el perfil referencia el layout '$layoutRef' y el fichero no existe" -ForegroundColor Yellow
        } else {
            Write-Host '  [INFO] el perfil no declara layout: se juega con teclado/raton fisicos o mando Bluetooth.' -ForegroundColor Yellow
        }
        if ($antichat -eq 'restringida') {
            Write-Host '  [ADVERTENCIA] este juego declara antitrampas NO compatibles con VM: el proyecto no recomienda jugarlo en la VM y el informe de preparacion lo marca como bloqueo.' -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host '  Pasos en el dispositivo Android (los unicos que existen):' -ForegroundColor Green
Write-Host '   1. Windows App: anade la VM > Ajustes del equipo > resolucion y calidad,'
Write-Host '      teclado en pantalla, "Usar raton" si prefieres puntero relativo.'
Write-Host '   2. Moonlight: Anadir PC (IP de la VM o del tunel) > empareja con el PIN que'
Write-Host '      muestra la web de Sunshine (https://IP:47990, solo en la red permitida).'
Write-Host '   3. Moonlight > Ajustes > Controles en pantalla > elegir/disenar el layout'
Write-Host '      (stick, botones, gatillos, opacidad) > por-app: "Usar configuracion propia".'
Write-Host '   4. Mando Bluetooth: emparejalo con el Android (Ajustes > Bluetooth) y elige'
Write-Host '      en Moonlight "Tipo de mando" (Xbox); en Windows App NO se redirige.'
Write-Host '   5. Teclado/raton fisicos por USB-OTG o Bluetooth: funcionan en Windows App.'
Write-Host ''
Write-Host '  Limites: el overlay tactil solo existe en el canal Moonlight; los juegos con'
Write-Host '  antitrampas de kernel no funcionan en VM; sin GPU no hay codificador por'
Write-Host '  hardware y la experiencia de juego no es comparable (docs/06 y docs/07).'
Write-Host ''
