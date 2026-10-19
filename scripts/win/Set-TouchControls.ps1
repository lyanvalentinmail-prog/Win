<#
.SYNOPSIS
  Aplica los perfiles de control (teclado/raton, sensibilidad, remapeos y fichas tactiles).
.DESCRIPTION
  QUE HACE (y solo eso):
   1. Lee gaming/profiles/<perfil>.json de los perfiles listados en
      config gaming.touchControls.profiles.
   2. Ajusta la sensibilidad y la aceleracion del puntero del escritorio (registro HKCU).
   3. Genera en D:\WinGamingVM\controles\ una FICHA por juego con el layout tactil
      (posiciones, tamanos y opacidad normalizados) para reproducirlo en el cliente
      Moonlight, y un .json "de bolsillo" con las mismas cifras.
   4. Si PowerToys esta instalado y se pide -AplicarEnPowerToys, escribe los remapeos de
      teclado/atajos por aplicacion (Keyboard Manager). Se copian a la carpeta de
      PowerToys SOLO con backup previo y con el formato observado en la version actual.
   5. Registra en el informe que NO se ha tocado y porque (para no vender magia).

  QUE NO HACE (porque no existe el mecanismo):
   - No inyecta controles tactiles en Windows App: el cliente de Microsoft no tiene capas
     de botones y no se puede anadir desde el servidor.
   - No redirige mandos por RDP: Windows App en Android no soporta gamepad; por eso el
     mapeo de mando virtual vive en el canal de juego (Moonlight) y se documenta.
   - No edita los ajustes privados de la app cliente (SharedPreferences de Android): no hay
     API expuesta. La ficha es una guia exacta, no un archivo importable.
.PARAMETER Perfil
  Nombre(s) de perfil sin extension (por defecto: los del config).
.PARAMETER AplicarEnPowerToys
  Escribe los remapeos en %LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager (con backup).
.OUTPUTS
  PSCustomObject: Perfiles, Sensibilidad, Remapeos, Fichas
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [string[]]$Perfil,
    [string]$RepoDir,
    [switch]$AplicarEnPowerToys,
    [switch]$RestaurarSensibilidad
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force

# Cada fase puede ejecutarse suelta (o como proceso hijo del bootstrap): inicializa su
# propio log/estado. Si quien llama es el bootstrap, el fichero de log sera el de esta fase,
# que es lo util cuando hay que relanzar solo una.
[void](Initialize-GvmRuntime -Nombre ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)))

$cfg = Resolve-GvmConfig -Entrada $Config
$Fase = 'controles'

if (-not $RepoDir) {
    foreach ($c in @($env:GVM_REPO_DIR, 'C:\ProgramData\WinGamingVM\repo', (Join-Path $PSScriptRoot '..\..'))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'gaming\profiles'))) { $RepoDir = (Resolve-Path $c).Path; break }
    }
}
if (-not $RepoDir) { throw 'No se encontro gaming/profiles. Pasa -RepoDir con el arbol del repo.' }

$dirSalida = Join-Path $(if (Test-Path -LiteralPath 'D:\') { 'D:' } else { "$env:SystemDrive" }) 'WinGamingVM\controles'
if (-not (Test-Path -LiteralPath $dirSalida)) { New-Item -ItemType Directory -Path $dirSalida -Force | Out-Null }

# VK codes para los remapeos (teclas usadas en los perfiles del repositorio).
$VK = @{
    'a' = 65; 'b' = 66; 'c' = 67; 'd' = 68; 'e' = 69; 'f' = 70; 'g' = 71; 'h' = 72; 'i' = 73; 'j' = 74
    'k' = 75; 'l' = 76; 'm' = 77; 'n' = 78; 'o' = 79; 'p' = 80; 'q' = 81; 'r' = 82; 's' = 83; 't' = 84
    'u' = 85; 'v' = 86; 'w' = 87; 'x' = 88; 'y' = 89; 'z' = 90
    '0' = 48; '1' = 49; '2' = 50; '3' = 51; '4' = 52; '5' = 53; '6' = 54; '7' = 55; '8' = 56; '9' = 57
    'space' = 32; 'esc' = 27; 'escape' = 27; 'tab' = 9; 'enter' = 13; 'backspace' = 8; 'delete' = 46
    'insert' = 45; 'home' = 36; 'end' = 35; 'pageup' = 33; 'pagedown' = 34; 'printscreen' = 44
    'up' = 38; 'down' = 40; 'left' = 37; 'right' = 39
    'f1' = 112; 'f2' = 113; 'f3' = 114; 'f4' = 115; 'f5' = 116; 'f6' = 117; 'f7' = 118; 'f8' = 119
    'f9' = 120; 'f10' = 121; 'f11' = 122; 'f12' = 123
    'ctrl' = 17; 'control' = 17; 'shift' = 16; 'alt' = 18; 'win' = 91; 'menu' = 93
}

function Get-VkCode { param([string]$Tecla)
    $t = $Tecla.Trim().ToLowerInvariant()
    if ($VK.ContainsKey($t)) { return $VK[$t] }
    if ($t -match '^f(\d{1,2})$') { $n = [int]$Matches[1]; if ($n -ge 1 -and $n -le 24) { return 111 + $n } }
    if ($t.Length -eq 1) { return [int][char]$t.ToUpperInvariant() }
    $null
}

# 0) Restaurar valores por defecto y salir (para no dejar ajustes colgados) ----
if ($RestaurarSensibilidad) {
    foreach ($kv in @{ MouseSpeed = 1; MouseSensitivity = 10; MouseThreshold1 = 0; MouseThreshold2 = 0; SmoothMouseX = 1 }) {
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name $kv.Key -Value $kv.Value -Type String | Out-Null
    }
    Write-GvmLog -Nivel OK -Fase $Fase -Mensaje 'sensibilidad del puntero restaurada a valores de fabrica'
    return [pscustomobject]@{ Perfiles = 0; Sensibilidad = 'restaurada'; Remapeos = 0; Fichas = 0 }
}

# 1) Que perfiles ---------------------------------------------------------------
if (-not $Perfil) { $Perfil = @(Get-GvmConfigValor -Config $cfg -Ruta 'gaming.touchControls.profiles' -PorDefecto @()) }
$perfilActivado = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'gaming.touchControls.enabled' -PorDefecto $true)
if (-not $perfilActivado -or $Perfil.Count -eq 0) {
    Write-GvmLog -Fase $Fase -Mensaje 'gaming.touchControls sin perfiles activos: no se aplica sensibilidad ni remapeos'
    return [pscustomobject]@{ Perfiles = 0; Sensibilidad = 'intocada'; Remapeos = 0; Fichas = 0 }
}

$gpu = Get-GvmGpuInfo
$canal = Get-GvmConfigValor -Config $cfg -Ruta 'gaming.channel' -PorDefecto 'rdp'

# 2) Sensibilidad: se toma del primer perfil aplicable (Windows tiene UNA sensibilidad global;
#    la por-juego la aplica el propio juego o el cliente: esto queda documentado, no simulado)
$sensAplicada = 'n/d'
$remapeosGenerados = 0
$fichas = 0
$pendientes = New-Object System.Collections.Generic.List[string]

$primero = $null
foreach ($p in $Perfil) {
    $rutaPerfil = Join-Path $RepoDir "gaming\profiles\$p.json"
    if (-not (Test-Path -LiteralPath $rutaPerfil)) { Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "perfil inexistente: $rutaPerfil"; continue }
    if (-not $primero) { $primero = Get-Content -LiteralPath $rutaPerfil -Raw -Encoding UTF8 | ConvertFrom-Json }
}
if (-not $primero) { throw "Ningun perfil de gaming.touchControls.profiles existe en $RepoDir\gaming\profiles" }

$s = $primero.controles.sensibilidad
if ($s) {
    $sens = 1.0
    if ($s.raton) { $sens = [double]$s.raton }
    $base = 10
    if ($s.mouseSensitivity) { $base = [int]$s.mouseSensitivity }
    # MouseSensitivity es entero 1..20 en Windows; escalamos el factor pedido sin inventar
    # un ajuste sub-yer: redondeo a la unidad mas cercana.
    $nuevo = [Math]::Max(1, [Math]::Min(20, [Math]::Round($base * $sens)))
    $acel = [bool]$s.aceleracion
    if ($PSCmdlet.ShouldProcess('HKCU\Control Panel\Mouse', 'ajustar sensibilidad del puntero')) {
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSensitivity' -Value $nuevo -Type String -Comentario "perfil '$($primero.id)': sensibilidad $base x $sens" | Out-Null
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value $(if ($acel) { 1 } else { 0 }) -Type String | Out-Null
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value $(if ($acel) { 6 } else { 0 }) -Type String | Out-Null
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value $(if ($acel) { 10 } else { 0 }) -Type String | Out-Null
        Set-GvmRegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'SmoothMouseX' -Value $(if ($acel) { 1 } else { 0 }) -Type String | Out-Null
        $sensAplicada = "MouseSensitivity=$nuevo, aceleracion=$acel (perfil $($primero.id))"
        Write-GvmLog -Nivel OK -Fase $Fase -Mensaje "sensibilidad del puntero: $sensAplicada" -Detalle 'afecta a todo el escritorio, no solo al juego: Windows no tiene sensibilidad por aplicacion'
    }
}

# 3) Remapeos con PowerToys Keyboard Manager -----------------------------------
$powertoys = Get-GvmAppInstalada -Id 'Microsoft.PowerToys'
$powertoysDir = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager'
if ($AplicarEnPowerToys -and -not $powertoys) {
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'PowerToys no esta instalado: los remapeos se dejan escritos para importarlos cuando lo este'
}
$keys = New-Object System.Collections.Generic.List[object]
$shortcuts = New-Object System.Collections.Generic.List[object]
$targetApp = ''
if ($primero.juego -and @($primero.juego.procesos).Count -gt 0) { $targetApp = (@($primero.juego.procesos)[0] -replace '\.exe$', '') + '.exe' }

foreach ($t in @($primero.controles.teclas)) {
    $origen = Get-VkCode ([string]$t.original)
    $destino = Get-VkCode ([string]$t.nuevo)
    if ($null -eq $destino) { $pendientes.Add("el destino '$($t.nuevo)' no es una tecla reconocible (puede ser un boton de raton: configurar en el cliente o con AntiMicroX)") ; continue }
    if ($null -eq $origen) {
        # Botones de mando (gamepad-*) NO son remapeables por Keyboard Manager: eso es trabajo
        # de Steam Input / AntiMicroX. Se registra como pendiente en lugar de perder el mapeo.
        $pendientes.Add("el origen '$($t.original)' es un boton de mando: usar Steam Input o AntiMicroX (ver gaming/steam/README.md)")
        continue
    }
    $keys.Add([pscustomobject]@{ originalKey = $origen; newKey = $destino })
}
foreach ($a in @($primero.controles.atajos)) {
    if ($a.via -ne 'powertoys-keyboard-manager') { continue }
    $partes = @($a.teclas -split '\+')
    $orig = @(); foreach ($p in $partes) { $c = Get-VkCode $p; if ($null -ne $c) { $orig += $c } else { $pendientes.Add("atajo '$($a.nombre)': tecla '$p' no reconocida") } }
    if ($orig.Count -lt 2) { $pendientes.Add("atajo '$($a.nombre)' ignorado: se necesitan al menos 2 teclas para un acceso directo"); continue }
    # pscustomobject, no [ordered]: dentro de una coleccion ConvertTo-Json no sabe que hacer
    # con un OrderedDictionary y el fichero de PowerToys no se escribe; la regla esta anotada junto a New-GvmInforme en GamingVM.psm1.
    $shortcuts.Add([pscustomobject]@{ originalKeys = $orig; targetApp = $targetApp; newRemapKeys = @(112) })   # F2: abrir menu de captura
}

if ($keys.Count -gt 0 -or $shortcuts.Count -gt 0) {
    $staging = Join-Path (Get-GvmPaths).BaseDir 'controles-powertoys'
    if (-not (Test-Path -LiteralPath $staging)) { New-Item -ItemType Directory -Path $staging -Force | Out-Null }
    $archivoKeys = Join-Path $staging 'remapkeys.json'
    $archivoShort = Join-Path $staging 'remapshortcuts.json'
    # Statements separados a proposito: si algo de aqui falla, la pila tiene que decir cual de
    # los tres (el documento, la conversion o la escritura), y no una linea con tres operaciones.
    Write-GvmLog -Nivel DEBUG -Fase $Fase -Mensaje "documento de remapeo: $($keys.Count) teclas, $($shortcuts.Count) atajos"
    $docKeys = [pscustomobject]@{ version = '1.0.0'; remapKeys = [pscustomobject]@{ inOrder = @($keys) } }
    $jsonKeys = ConvertTo-Json -InputObject $docKeys -Depth 6
    Set-Content -LiteralPath $archivoKeys -Value $jsonKeys -Encoding UTF8
    $docShort = [pscustomobject]@{ version = '1.0.0'; remapShortcuts = [pscustomobject]@{ global = @(); appSpecific = @($shortcuts) } }
    $jsonShort = ConvertTo-Json -InputObject $docShort -Depth 6
    Set-Content -LiteralPath $archivoShort -Value $jsonShort -Encoding UTF8
    $remapeosGenerados = $keys.Count + $shortcuts.Count
    Write-GvmLog -Nivel OK -Fase $Fase -Mensaje "remapeos generados en $staging ($remapeosGenerados entradas)" -Detalle 'PowerToys lee estos ficheros al arrancar; el esquema es el observado en la version actual'
    if ($AplicarEnPowerToys -and $powertoys) {
        if (-not (Test-Path -LiteralPath $powertoysDir)) { New-Item -ItemType Directory -Path $powertoysDir -Force | Out-Null }
        foreach ($f in 'remapkeys.json', 'remapshortcuts.json') {
            $dst = Join-Path $powertoysDir $f
            if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination "$dst.backup-$(Get-Date -Format yyyyMMdd-HHmmss)" }
            if ($PSCmdlet.ShouldProcess($dst, 'copiar remapeo')) { Copy-Item -LiteralPath (Join-Path $staging $f) -Destination $dst -Force }
        }
        Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'PowerToys debe reiniciarse para leer los ficheros (cierra y vuelve a abrir Keyboard Manager)'
    }
}

# 4) Fichas por perfil (lo que el usuario reproduce en el cliente) --------------
foreach ($p in $Perfil) {
    $rutaPerfil = Join-Path $RepoDir "gaming\profiles\$p.json"
    if (-not (Test-Path -LiteralPath $rutaPerfil)) { continue }
    $pf = Get-Content -LiteralPath $rutaPerfil -Raw -Encoding UTF8 | ConvertFrom-Json
    $layoutRel = $pf.controles.mapeoTactil.layout
    $layout = $null
    if ($layoutRel) {
        $rutaLayout = Join-Path $RepoDir ((Join-Path 'gaming\profiles' $layoutRel) -replace '\\+', '\')
        try { $rutaLayout = (Resolve-Path -LiteralPath $rutaLayout).Path } catch { }
        if (Test-Path -LiteralPath $rutaLayout) { $layout = Get-Content -LiteralPath $rutaLayout -Raw -Encoding UTF8 | ConvertFrom-Json }
        else { $pendientes.Add("el layout '$layoutRel' del perfil '$p' no existe: la ficha se genera sin el") }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Ficha de control · $($pf.nombre)")
    [void]$sb.AppendLine("")
    # Igual que abajo con las etiquetas: una propiedad ausente llega como AutomationNull y
    # mezclarla con un literal en un condicional revienta al compilar.
    $gpuFicha = 'sin GPU'
    if ($gpu.Presente -and $gpu.Nombre) { $gpuFicha = [string]$gpu.Nombre }
    [void]$sb.AppendLine("Perfil: ``$($pf.id)`` · Canal recomendado: ``$canal`` · GPU: ``$gpuFicha``")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Antes de tocar nada")
    [void]$sb.AppendLine($pf.compatibilidadVm.antitrampas.nota)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Punto | Valor |")
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine("| FPS objetivo | $($pf.rendimiento.fpsObjetivo) |")
    [void]$sb.AppendLine("| Preset | $($pf.rendimiento.preset) |")
    [void]$sb.AppendLine("| Antichat | $($pf.compatibilidadVm.antitrampas.sistemas -join ', ') → VM: $($pf.compatibilidadVm.antitrampas.vm) |")
    [void]$sb.AppendLine("")
    if ($layout) {
        [void]$sb.AppendLine("## Layout tactil ($($layout.id)) — reproducir en el cliente")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Destino del cliente: ``$($layout.destino)``. Coordenadas y tamanos en porcentaje de pantalla.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| Elemento | Tipo | x % | y % | tamano % | opacidad % | Asignacion |")
        [void]$sb.AppendLine('|---|---|---:|---:|---:|---:|---|')
        foreach ($e in $layout.elementos) {
            $asig = "$($e.asignacion.tipo):$($e.asignacion.valor)"
            # Nada de condicionales con propiedades opcionales dentro del interpolado: PowerShell
            # arma un Expression.Condition y si una rama es AutomationNull (clave ausente en el
            # JSON) y la otra string, el arbol no se construye -> 'Argument types do not match'.
            $etiqueta = [string]$e.id
            if ($e.etiqueta) { $etiqueta = [string]$e.etiqueta }
            $xPct = [math]::Round([double]$e.x * 100)
            $yPct = [math]::Round([double]$e.y * 100)
            $tPct = [math]::Round([double]$e.tamano * 100)
            $opPct = [string]$e.opacidad
            [void]$sb.AppendLine("| $etiqueta | ``$($e.tipo)`` | $xPct | $yPct | $tPct | $opPct | ``$asig`` |")
        }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Pasos en Moonlight para Android: Ajustes → *Show on-screen controls* → durante la partida, engranaje → *Move/Resize buttons*.")
        if (@($layout.limitaciones).Count) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine('### Limitaciones de este layout')
            foreach ($l in $layout.limitaciones) { [void]$sb.AppendLine("- $l") }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine('## Pendientes de accion manual (el host no puede hacer esto)')
    foreach ($m in @($pf.aplicacion.pasosManuales)) { [void]$sb.AppendLine("- $m") }
    foreach ($m in $pendientes) { [void]$sb.AppendLine("- $m") }
    $ficha = Join-Path $dirSalida "$p.moonlight.md"
    $sb.ToString() | Set-Content -LiteralPath $ficha -Encoding UTF8
    $layout | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dirSalida "$p.layout.json") -Encoding UTF8
    $fichas++
    Write-GvmLog -Fase $Fase -Mensaje "ficha generada: $ficha"
}

$hallazgos = @(
    New-GvmHallazgo -Item 'Controles tactiles' -Nivel WARN -Detalle 'la capa de botones se configura en el cliente (Moonlight); la ficha de la VM es la especificacion exacta'
    New-GvmHallazgo -Item 'Sensibilidad del raton' -Nivel OK -Detalle $sensAplicada
    if ($canal -eq 'rdp') { New-GvmHallazgo -Item 'Canal actual' -Nivel WARN -Detalle 'gaming.channel=rdp: no habra overlays ni mando virtual (limitacion del cliente, no de la VM)' }
    if ($pendientes.Count) { New-GvmHallazgo -Item 'Pendientes' -Nivel WARN -Detalle ($pendientes -join ' | ') }
)
New-GvmInforme -Nombre 'controles' -Datos ([pscustomobject]@{
    perfiles = $Perfil; perfilActivo = $primero.id; sensibilidad = $sensAplicada; powertoys = [bool]$powertoys
    remapeos = $remapeosGenerados; fichas = $fichas; pendientes = @($pendientes); salida = $dirSalida
}) -Hallazgos $hallazgos | Out-Null

[pscustomobject]@{
    Perfiles     = @($Perfil).Count
    Sensibilidad = $sensAplicada
    Remapeos     = $remapeosGenerados
    Fichas       = $fichas
    Salida       = $dirSalida
}
