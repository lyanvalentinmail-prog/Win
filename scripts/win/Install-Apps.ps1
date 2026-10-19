<#
.SYNOPSIS
  Instalador automatizado y selectivo de aplicaciones (utilidades + gaming).
.DESCRIPTION
  Lee apps/catalog.json, resuelve apps/selections/<conjunto>.json y aplica las apps que el
  usuario eligio en config/vm.json (apps.selections). Reglas duras del proyecto:

   1. Solo se instalan las apps del conjunto elegido. Nada de "instalar todo por si acaso".
   2. El metodo de instalacion es 'winget --id X --exact --source winget' (el repositorio
      comunitario de Microsoft, que fija URL y SHA-256 del instalador).
   3. Antes de tocar nada, la URL oficial declarada en el catalogo se contrasta con
      apps/sources.json: si el host no esta, la app se RECHAZA (apps.blockNonOfficialSources).
   4. Se comprueba compatibilidad con la edicion de Windows y con la GPU presente:
      - requiereGpu=true sin GPU  -> omitida (no se instala algo que no va a funcionar)
      - requiereStore=true en Server -> omitida
      - bloqueadoEnVm=true        -> omitida con el motivo del antichat/Soporte
      - metodo=store/manual       -> 'pendiente': se documenta, no se finge instalado
   5. Tras instalar, se verifica la firma Authenticode del binario contra el catalogo.
   6. Todo queda en el log y en un informe JSON+MD; el script devuelve conteos.

  No se descargan ni ejecutan instaladores de terceros, no se parchea nada y no se
  aceptan licencias en nombre del usuario salvo las del propio repositorio de winget.
.PARAMETER Conjuntos
  Anulacion manual de apps.selections (p. ej. -Conjuntos utilities).
.PARAMETER SoloVerificar
  No instala: lista estado y verificaciones.
.OUTPUTS
  PSCustomObject con conteos y el detalle por app.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [string[]]$Conjuntos,
    [switch]$SoloVerificar,
    [switch]$ReintentarFallidas,
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
$Fase = 'apps'

if (-not $RepoDir) {
    foreach ($c in @($env:GVM_REPO_DIR, 'C:\ProgramData\WinGamingVM\repo', (Join-Path $PSScriptRoot '..\..'))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'apps\catalog.json'))) { $RepoDir = (Resolve-Path $c).Path; break }
    }
}
if (-not $RepoDir) { throw "No se encontro apps/catalog.json. Pasa -RepoDir apuntando al arbol del repo." }
$catalogo = (Get-Content -LiteralPath (Join-Path $RepoDir 'apps\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json).aplicaciones
$porId = @{}
foreach ($a in $catalogo) { $porId[$a.id.ToLowerInvariant()] = $a }

# --- Que se va a instalar ------------------------------------------------------
$select = if ($Conjuntos) { $Conjuntos } else { @(Get-GvmConfigValor -Config $cfg -Ruta 'apps.selections' -PorDefecto @('minimal')) }
$ids = New-Object System.Collections.Generic.List[string]
foreach ($s in $select) {
    if ($s -eq 'custom') { continue }
    $rutaSel = Join-Path $RepoDir "apps\selections\$s.json"
    if (-not (Test-Path -LiteralPath $rutaSel)) { Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "seleccion '$s' no existe ($rutaSel)"; continue }
    foreach ($e in (Get-Content -LiteralPath $rutaSel -Raw -Encoding UTF8 | ConvertFrom-Json).aplicaciones) { $null = $ids.Add($e.id) }
}
foreach ($c in @(Get-GvmConfigValor -Config $cfg -Ruta 'apps.custom' -PorDefecto @())) { if ($c.wingetId) { $null = $ids.Add($c.wingetId) } }
$ids = @($ids | Select-Object -Unique)
Write-GvmLog -Fase $Fase -Mensaje "conjuntos: $($select -join ', ') · apps a considerar: $($ids.Count)"

# --- Contexto de la maquina ---------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$esServer = $os.Caption -match 'Server'
$tieneStore = [bool](Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue)
$gpu = Get-GvmGpuInfo
$skipNoCompat = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'apps.skipUnsupported' -PorDefecto $true)
$bloquearNoOficial = [bool](Get-GvmConfigValor -Config $cfg -Ruta 'apps.blockNonOfficialSources' -PorDefecto $true)
$maxRetries = [int](Get-GvmConfigValor -Config $cfg -Ruta 'apps.maxRetries' -PorDefecto 2)
$wingetDisponible = [bool](Get-GvmWingetComando)

$resultados = New-Object System.Collections.Generic.List[object]
$instaladas = 0; $omitidas = 0; $fallidas = 0; $pendientes = 0

foreach ($id in $ids) {
    $app = $porId[$id.ToLowerInvariant()]
    if (-not $app) {
        $fallidas++
        $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'no-en-catalogo'; Detalle = 'el id no existe en apps/catalog.json: anadelo con su fuente oficial y su verificacion' })
        Write-GvmLog -Nivel ERROR -Fase $Fase -Mensaje "$id no esta en el catalogo (no se instala a ciegas)"
        continue
    }
    # 1) compatibilidad
    if ($app.compatibilidad) {
        $ediciones = @($app.compatibilidad.ediciones)
        if ($ediciones.Count -gt 0 -and $cfg.windows -and $cfg.windows.edition -notin $ediciones) {
            if ($skipNoCompat) {
                $omitidas++
                $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'omitida'; Detalle = "edicion '$($cfg.windows.edition)' no listada en el catalogo para esta app" })
                Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "$id : edicion no listada como compatible -> omitida (apps.skipUnsupported)"
                continue
            }
            Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "$id : edicion '$($cfg.windows.edition)' no listada como compatible; se intenta igualmente"
        }
        if ($app.compatibilidad.requiereGpu -and -not $gpu.Presente) {
            if ($skipNoCompat) { $omitidas++; $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'omitida'; Detalle = 'requiere GPU y el host no la ofrece' }); continue }
            Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "$($id): requiere GPU inexistente y skipUnsupported=false: se intentara igualmente"
        }
        if ($app.compatibilidad.requiereStore -and -not $tieneStore) {
            $omitidas++; $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'omitida'; Detalle = 'requiere Microsoft Store, no presente en esta edicion' }); continue
        }
        if ($app.compatibilidad.bloqueadoEnVm) {
            $pendientes++; $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'bloqueada-en-vm'; Detalle = $app.compatibilidad.nota })
            Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "$($id): bloqueada en VM ($($app.compatibilidad.nota))"
            continue
        }
    }
    # 2) metodo
    if ($app.instalacion.metodo -ne 'winget') {
        $pendientes++
        $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'pendiente-manual'; Detalle = "metodo '$($app.instalacion.metodo)': el proyecto no lo automatiza ($($app.instalacion.nota))" })
        Write-GvmLog -Fase $Fase -Mensaje "$($id): accion manual documentada ($($app.instalacion.metodo))"
        continue
    }
    if (-not $wingetDisponible) {
        $fallidas++; $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'sin-dependencia'; Detalle = 'winget no disponible en esta imagen' }); continue
    }
    # 3) fuente oficial declarada
    if ($app.fuente.descargaDirecta -and $bloquearNoOficial) {
        $o = Test-GvmOrigenPermitido -Url $app.fuente.descargaDirecta -SourcesPath (Join-Path $RepoDir 'apps\sources.json')
        if (-not $o.Permitido) {
            $fallidas++; $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = 'rechazada-fuente'; Detalle = $o.Motivo })
            Write-GvmLog -Nivel ERROR -Fase $Fase -Mensaje "$($id): fuente no autorizada" -Detalle $o.Motivo
            continue
        }
    }
    if ($SoloVerificar) {
        $act = Get-GvmAppInstalada -Id $id
        $null = $resultados.Add([pscustomobject]@{ Id = $id; Estado = $(if ($act) { 'instalada' } else { 'no-instalada' }); Detalle = $(if ($act) { "$($act.Version) ($($act.Fuente))" } else { 'winget list no la encuentra' }) })
        continue
    }

    # 4) instalar
    $r = Install-GvmWingetApp -Id $id -Version $app.instalacion.version -Scope $app.instalacion.scope -SilentFlags $app.instalacion.silentFlags -MaxRetries $maxRetries
    $registro = [ordered]@{ Id = $id; Estado = $r.Estado; Intentos = $r.Intentos; Segundos = $r.DuracionSeg; Salida = $r.Salida; Error = $r.Error; Firma = ''; Post = @() }

    if ($r.Estado -eq 'correcta') {
        $instaladas++
        # 5) verificacion de firma del binario instalado
        if ($app.verificacion -and $app.verificacion.comprobarFirmaPostInstalacion -ne $false) {
            $f = Test-GvmFirma -Ruta $app.verificacion.ejecutableRuta -FirmantesEsperados @($app.verificacion.firmanteEsperado) -Tolerancia 'aviso' -Id $id
            $registro.Firma = "$($f.Estado) :: $($f.Detalle)"
            if ($f.Estado -eq 'no-encontrado') { Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje "$id : no se encontro el binario declarado para verificar la firma" -Detalle $f.Detalle }
        }
        # 6) hooks post-instalacion soportados
        foreach ($hook in @($app.postInstalacion)) {
            switch ($hook) {
                'crear-carpeta-juegos' {
                    foreach ($dir in 'D:\Juegos', 'D:\Juegos\Biblioteca', 'D:\Documents') {
                        if ((Test-Path -LiteralPath 'D:\') -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    }
                    $registro.Post += 'crear-carpeta-juegos'
                }
                'crear-carpeta-capturas' {
                    $c = Join-Path $(if (Test-Path 'D:\') { 'D:\' } else { "$env:USERPROFILE\" }) 'Capturas'
                    if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
                    $registro.Post += "crear-carpeta-capturas -> $c"
                }
                'anadir-al-escritorio' {
                    $exe = if ($app.verificacion.ejecutableRuta) { [Environment]::ExpandEnvironmentVariables($app.verificacion.ejecutableRuta) } else { $null }
                    if ($exe -and (Test-Path -LiteralPath $exe)) {
                        $escritorio = [Environment]::GetFolderPath('CommonDesktopDirectory')
                        $lnk = Join-Path $escritorio ($app.nombre + '.lnk')
                        $ws = New-Object -ComObject WScript.Shell
                        $at = $ws.CreateShortcut($lnk); $at.TargetPath = $exe; $at.WorkingDirectory = Split-Path $exe -Parent; $at.Save()
                        $registro.Post += "anadir-al-escritorio -> $lnk"
                    } else { $registro.Post += 'anadir-al-escritorio (omiso: sin ejecutable declarado)' }
                }
                'quitar-de-autostart' {
                    $nom = ($id -replace '.*\.', '')
                    $hallado = $false
                    foreach ($hive in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
                        $it = Get-Item -LiteralPath $hive -ErrorAction SilentlyContinue
                        if ($it -and ($it.Property -contains $nom)) { Remove-ItemProperty -LiteralPath $hive -Name $nom; $hallado = $true }
                    }
                    $registro.Post += $(if ($hallado) { "quitar-de-autostart: $nom" } else { 'quitar-de-autostart: no hay clave Run con ese nombre' })
                }
                'fijar-biblioteca-steam' {
                    $bib = 'D:\SteamLibrary'
                    if ((Test-Path -LiteralPath 'D:\') -and -not (Test-Path -LiteralPath $bib)) { New-Item -ItemType Directory -Path (Join-Path $bib 'steamapps\common') -Force | Out-Null }
                    $registro.Post += 'fijar-biblioteca-steam: carpeta D:\SteamLibrary creada; anadirla en Steam > Ajustes > Almacenamiento (Steam no expone API para hacerlo por script)'
                }
                'aplicar-perfil-controles' { $registro.Post += 'aplicar-perfil-controles: delegada en Set-TouchControls.ps1 (fase gaming)' }
                'iniciar-como-servicio' { $registro.Post += 'iniciar-como-servicio: delegada en Set-Sunshine.ps1 (fase gaming)' }
                default { $registro.Post += "hook desconocido: $hook (no aplicado)" }
            }
        }
    } elseif ($r.Estado -in 'ya-instalada', 'instalada') {
        $instaladas++
    } else {
        $fallidas++
    }
    $null = $resultados.Add([pscustomobject]$registro)
}

$hallazgos = @(
    New-GvmHallazgo -Item 'Aplicaciones' -Nivel OK -Detalle "$instaladas instaladas, $omitidas omitidas, $fallidas fallidas, $pendientes pendientes de accion manual"
    if ($pendientes -gt 0) { New-GvmHallazgo -Item 'Accion manual' -Nivel WARN -Detalle 'hay apps marcadas como pendiente-manual/bloqueada: revisa el informe apps.md' }
    if (-not $wingetDisponible) { New-GvmHallazgo -Item 'winget' -Nivel ERROR -Detalle 'winget no disponible: instala App Installer (docs/08) o usa Server 2025' }
)
$informe = New-GvmInforme -Nombre 'apps' -Datos ([pscustomobject]@{
    conjuntos = $select
    contexto = [pscustomobject]@{ edicion = $cfg.windows.edition; esServer = $esServer; store = $tieneStore; winget = $wingetDisponible; gpu = $gpu.Resumen }
    resultados = $resultados
}) -Hallazgos $hallazgos

$resultados | ConvertTo-Csv -NoTypeInformation | Set-Content -LiteralPath (Join-Path (Get-GvmPaths).Informes 'apps-instalacion.csv') -Encoding UTF8
Write-GvmLog -Nivel $(if ($fallidas -gt 0) { 'WARN' } else { 'OK' }) -Fase $Fase -Mensaje "apps: $instaladas ok · $omitidas omitidas · $fallidas fallidas · $pendientes manuales"
[pscustomobject]@{
    Instaladas       = $instaladas
    Omitidas         = $omitidas
    Fallidas         = $fallidas
    Pendientes       = $pendientes
    Resultados       = $resultados
    Informe          = $informe
}
