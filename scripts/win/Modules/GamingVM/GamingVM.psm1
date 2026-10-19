# -----------------------------------------------------------------------------
# Modulo GamingVM — funciones comunes del bootstrap de la VM de gaming.
# Requisitos: PowerShell 5.1+ (Windows Server 2022/2025, Windows 10/11).
# Ninguna funcion escribe secretos en disco ni envia telemetria fuera de la VM.
# -----------------------------------------------------------------------------
# StrictMode 1.0: pilla variables sin inicializar. No se usa 'Latest' porque la
# configuracion viene de JSON con campos opcionales y 2.0+ lanza al leer una propiedad
# ausente (el bootstrap debe tolerar configs parciales y aplicar valores por defecto).
Set-StrictMode -Version 1.0

$script:GvmLogDir = $null
$script:GvmLogFile = $null
$script:GvmStateDir = $null
$script:GvmBaseDir = $null

# --- Utilidades de rutas y estado --------------------------------------------

function Initialize-GvmRuntime {
    <#
      .SYNOPSIS
        Prepara carpetas de trabajo, log y estado idempotente.
      .PARAMETER BaseDir
        Raiz de datos del proyecto en la VM. Por defecto C:\ProgramData\WinGamingVM.
    #>
    [CmdletBinding()]
    param(
        [string]$BaseDir = 'C:\ProgramData\WinGamingVM',
        [string]$Nombre = 'bootstrap'
    )
    $script:GvmBaseDir = $BaseDir
    foreach ($sub in 'logs', 'state', 'informes', 'backup') {
        $ruta = Join-Path $BaseDir $sub
        if (-not (Test-Path -LiteralPath $ruta)) {
            New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        }
    }
    $script:GvmLogDir = Join-Path $BaseDir 'logs'
    $script:GvmStateDir = Join-Path $BaseDir 'state'
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:GvmLogFile = Join-Path $script:GvmLogDir "$Nombre-$stamp.log"
    Write-GvmLog -Nivel INFO -Mensaje "Log: $script:GvmLogFile"
    return [pscustomobject]@{ BaseDir = $BaseDir; LogFile = $script:GvmLogFile }
}

function Get-GvmPaths {
    [CmdletBinding()] param()
    if (-not $script:GvmBaseDir) { Initialize-GvmRuntime | Out-Null }
    return [pscustomobject]@{
        BaseDir  = $script:GvmBaseDir
        Logs     = $script:GvmLogDir
        State    = $script:GvmStateDir
        Informes = Join-Path $script:GvmBaseDir 'informes'
        Backup   = Join-Path $script:GvmBaseDir 'backup'
    }
}

function Write-GvmLog {
    <#
      .SYNOPSIS
        Registro consola + fichero con nivel, marca de tiempo y contexto de fase.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'OK', 'WARN', 'ERROR')] [string]$Nivel = 'INFO',
        [Parameter(Mandatory)][string]$Mensaje,
        [string]$Fase = '',
        [string]$Detalle = '',
        [switch]$AlConsola
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $prefijo = if ($Fase) { "[$Fase] " } else { '' }
    $linea = "$ts $Nivel $($prefijo)$Mensaje"
    if ($Detalle) { $linea += " :: $($Detalle -replace '\r?\n', ' | ')" }

    $colores = @{ DEBUG = 'DarkGray'; INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    if ($AlConsola -or $Nivel -in 'WARN', 'ERROR') {
        Write-Host $linea -ForegroundColor $colores[$Nivel]
    }

    if ($script:GvmLogFile) {
        try { Add-Content -LiteralPath $script:GvmLogFile -Value $linea -Encoding UTF8 } catch { }
    }
}

function Set-GvmCheckpoint {
    <#
      .SYNOPSIS
        Guarda el resultado de una fase para poder reanudar tras un reinicio.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fase,
        [ValidateSet('pendiente', 'en-curso', 'completada', 'fallida', 'omitida')] [string]$Estado,
        [string]$Mensaje = '',
        [int]$Codigo = 0,
        [switch]$RequiereReinicio
    )
    if (-not $script:GvmStateDir) { Initialize-GvmRuntime | Out-Null }
    $archivo = Join-Path $script:GvmStateDir 'fases.json'
    $datos = @{}
    if (Test-Path -LiteralPath $archivo) {
        try {
            (Get-Content -LiteralPath $archivo -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
                $datos[$_.Name] = $_.Value
            }
        } catch { Write-GvmLog -Nivel WARN -Mensaje 'state de fases ilegible, se regenera' -Detalle $_.Exception.Message }
    }
    $datos[$Fase] = [pscustomobject]@{
        estado          = $Estado
        mensaje         = $Mensaje
        codigo          = $Codigo
        fecha           = (Get-Date).ToString('o')
        requiereReinicio = [bool]$RequiereReinicio
    }
    $datos | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $archivo -Encoding UTF8
    Write-GvmLog -Nivel OK -Mensaje "fase '$Fase' -> $Estado"
}

function Get-GvmCheckpoint {
    [CmdletBinding()]
    param([string]$Fase)
    if (-not $script:GvmStateDir) { Initialize-GvmRuntime | Out-Null }
    $archivo = Join-Path $script:GvmStateDir 'fases.json'
    if (-not (Test-Path -LiteralPath $archivo)) { return $null }
    $datos = Get-Content -LiteralPath $archivo -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Fase) {
        $prop = $datos.PSObject.Properties[$Fase]
        if ($prop) { return $prop.Value }
        return $null
    }
    return $datos
}

# --- Validaciones del entorno -------------------------------------------------

function Test-GvmEsAdministrador {
    <#
      .SYNOPSIS
        True si la sesion actual es administrativa.
      .DESCRIPTION
        Excepcion para CI: con GVM_PERMISOS_SIN_ADMIN=1 se devuelve true para que las rutas
        de lectura (validacion, informe, -WhatIf) puedan ejercitarse en un runner sin
        elevacion. Las operaciones que escriben FOLLOW fallando en el propio SO, no aqui:
        esta variable NO desbloquea nada, solo evita un abort temprano en pruebas.
    #>
    [CmdletBinding()] param()
    if ($env:GVM_PERMISOS_SIN_ADMIN -eq '1') {
        Write-GvmLog -Nivel WARN -Mensaje 'GVM_PERMISOS_SIN_ADMIN=1: se omite la comprobacion de elevacion (modo CI/lectura).' -Detalle 'Las fases que escriben pueden fallar igualmente por el SO.'
        return $true
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-GvmAdministrador {
    [CmdletBinding()]
    param([string]$Contexto = 'la operacion')
    if (-not (Test-GvmEsAdministrador)) {
        throw "Se necesita una consola elevada para $Contexto. Ejecuta 'Windows PowerShell (Administrador)'."
    }
}

function Test-GvmRequisito {
    <#
      .SYNOPSIS
        Comprueba requisitos (comando existente, build de SO, disco libre) sin abortar:
        devuelve una lista de resultados que el bootstrap agrega en el informe.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('comando', 'modulo', 'build', 'disco-libre', 'ram', 'servicio', 'gpu')] [string]$Tipo,
        [string]$Nombre,
        $Valor,
        [string]$Fase = 'requisitos'
    )
    $res = [ordered]@{ Tipo = $Tipo; Nombre = $Nombre; Cumple = $false; Detalle = '' }
    switch ($Tipo) {
        'comando' {
            $c = Get-Command -Name $Nombre -ErrorAction SilentlyContinue
            $res.Cumple = [bool]$c
            $res.Detalle = if ($c) { $c.Source } else { 'no encontrado en PATH' }
        }
        'modulo' {
            $m = Get-Module -ListAvailable -Name $Nombre | Select-Object -First 1
            $res.Cumple = [bool]$m
            $res.Detalle = if ($m) { "$($m.Name) $($m.Version)" } else { 'modulo no disponible' }
        }
        'build' {
            $actual = [Environment]::OSVersion.Version.Build
            $minimo = [int]$Valor
            $res.Cumple = $actual -ge $minimo
            $res.Detalle = "build $actual (minimo $minimo)"
        }
        'disco-libre' {
            $unidad = $Valor
            $d = Get-PSDrive -Name $unidad -ErrorAction SilentlyContinue
            if ($d) {
                $libreGiB = [math]::Round($d.Free / 1GB, 1)
                $res.Cumple = $libreGiB -ge 40
                $res.Detalle = "$libreGiB GiB libres en $unidad`:"
            } else { $res.Detalle = "unidad $unidad no existe" }
        }
        'ram' {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $totalGiB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
                $res.Cumple = $totalGiB -ge [double]$Valor
                $res.Detalle = "$totalGiB GiB visibles (minimo $Valor GiB)"
            }
        }
        'servicio' {
            $s = Get-Service -Name $Nombre -ErrorAction SilentlyContinue
            $res.Cumple = [bool]$s -and $s.Status -eq 'Running'
            $res.Detalle = if ($s) { $s.Status.ToString() } else { 'servicio no instalado' }
        }
        'gpu' {
            $g = Get-GvmGpuInfo
            $res.Cumple = $g.Presente
            $res.Detalle = $g.Resumen
        }
    }
    Write-GvmLog -Nivel $(if ($res.Cumple) { 'OK' } else { 'WARN' }) -Fase $Fase -Mensaje "requisito $Tipo '$Nombre'" -Detalle $res.Detalle
    [pscustomobject]$res
}

# --- Configuracion ------------------------------------------------------------

function Get-GvmConfig {
    <#
      .SYNOPSIS
        Carga config/vm.json (o el path indicado) y aplica valores por defecto.
      .DESCRIPTION
        Busca en: -Ruta explicita, \$env:GVm_CONFIG, C:\ProgramData\WinGamingVM\config\vm.json,
        .\config\vm.json (cuando se ejecuta desde el arbol del repo).
    #>
    [CmdletBinding()]
    param([string]$Ruta)
    $candidatos = @()
    if ($Ruta) { $candidatos += $Ruta }
    if ($env:GVM_CONFIG) { $candidatos += $env:GVM_CONFIG }
    $candidatos += 'C:\ProgramData\WinGamingVM\config\vm.json'
    $candidatos += (Join-Path (Get-Location) 'config\vm.json')
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            Write-GvmLog -Nivel INFO -Mensaje "config: $c"
            try { return (Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json) }
            catch { throw "El JSON de configuracion '$c' no es valido: $($_.Exception.Message)" }
        }
    }
    throw "No se encontro config/vm.json. Copia config/vm.example.json a config/vm.json y ejecuta 'make push-config' o pasa -Ruta."
}

function Resolve-GvmConfig {
    <#
      .SYNOPSIS
        Acepta un objeto de configuracion ya cargado (el bootstrap) o una ruta a JSON,
        y devuelve siempre el objeto. Evita que cada script tenga su propia copia logica.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entrada)
    if ($Entrada -is [string]) { return Get-GvmConfig -Ruta $Entrada }
    if ($Entrada.PSObject.Properties['schemaVersion']) { return $Entrada }
    throw 'El objeto recibido no parece la configuracion de la VM (falta schemaVersion).'
}

function Get-GvmConfigValor {
    <#  .SYNOPSIS  Lectura tolerante de rutas tipo 'gaming.sunshine.fps' con valor por defecto. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Ruta, $PorDefecto = $null)
    $actual = $Config
    foreach ($parte in $Ruta.Split('.')) {
        if ($null -eq $actual) { return $PorDefecto }
        $prop = $actual.PSObject.Properties[$parte]
        if (-not $prop) { return $PorDefecto }
        $actual = $prop.Value
    }
    if ($null -eq $actual) { return $PorDefecto }
    $actual
}

# --- Registro -----------------------------------------------------------------

function Set-GvmRegistryValue {
    <#
      .SYNOPSIS
        Escribe un valor de registro idempotente, con copia de seguridad .reg previa
        de la clave afectada y registro en el log.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'QWord', 'Binary', 'MultiString', 'ExpandString')][string]$Type = 'DWord',
        [string]$Comentario = ''
    )
    $rutaPs = $Path -replace '^HKLM:', 'HKLM:\' -replace '^HKCU:', 'HKCU:\'
    if ($rutaPs -notmatch '^[A-Z]+:\\') { $rutaPs = "HKLM:\$rutaPs" }

    if (-not (Test-Path -LiteralPath $rutaPs)) {
        if ($PSCmdlet.ShouldProcess($rutaPs, 'crear clave')) {
            New-Item -Path $rutaPs -Force | Out-Null
        }
    }
    $actual = $null
    try {
        $item = Get-Item -LiteralPath $rutaPs -ErrorAction Stop
        if ($item.Property -contains $Name) { $actual = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
    } catch { }

    $mismoTipo = ($actual -is [int] -and $Type -eq 'DWord') -or ($actual -is [long] -and $Type -ne 'DWord') -or ($actual -is [string] -and $Type -eq 'String')
    if ($null -ne $actual -and $mismoTipo -and ("$actual" -eq "$Value")) {
        Write-GvmLog -Nivel DEBUG -Mensaje "registro ya en valor deseado: $rutaPs\$Name = $Value"
        return [pscustomobject]@{ Ruta = $rutaPs; Nombre = $Name; Antes = $actual; Despues = $Value; Cambio = $false }
    }

    if ($PSCmdlet.ShouldProcess("$rutaPs\$Name = $Value ($Type)", 'escribir')) {
        $backup = Join-Path (Get-GvmPaths).Backup ("reg-backup-{0}.reg" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        $claveReg = $rutaPs -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
        try { reg.exe export "$claveReg" "$backup" /y | Out-Null } catch { Write-GvmLog -Nivel WARN -Mensaje 'no se pudo exportar la clave antes de tocarla' -Detalle $_.Exception.Message }
        New-ItemProperty -LiteralPath $rutaPs -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-GvmLog -Nivel OK -Mensaje "registro: $rutaPs\$Name = $Value" -Detalle $(if ($Comentario) { $Comentario } elseif ($actual -ne $null) { "anterior: $actual" } else { 'nuevo' })
        return [pscustomobject]@{ Ruta = $rutaPs; Nombre = $Name; Antes = $actual; Despues = $Value; Cambio = $true; Backup = $backup }
    }
}

function Get-GvmRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# --- Red / URL ---------------------------------------------------------------

function Test-GvmOrigenPermitido {
    <#
      .SYNOPSIS
        Comprueba que una URL pertenece a un host oficial declarado en apps/sources.json.
      .OUTPUTS
        [pscustomobject] with Permitido, Host, Motivo
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [string]$SourcesPath)
    $resultado = [pscustomobject]@{ Url = $Url; Permitido = $false; Host = ''; Motivo = '' }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        $resultado.Motivo = 'URL no absoluta'
        return $resultado
    }
    if ($uri.Scheme -ne 'https') { $resultado.Motivo = "esquema '$($uri.Scheme)' no permitido (solo https)"; return $resultado }
    $resultado.Host = $uri.Host.ToLowerInvariant()
    if (-not $SourcesPath) {
        $posibles = @('apps\sources.json', 'C:\ProgramData\WinGamingVM\repo\apps\sources.json')
        $SourcesPath = $posibles | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $SourcesPath -or -not (Test-Path -LiteralPath $SourcesPath)) {
        $resultado.Motivo = 'apps/sources.json no encontrado: se deniega por precaucion'
        return $resultado
    }
    $sources = Get-Content -LiteralPath $SourcesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($sources.hostsPermitidos.PSObject.Properties.Name -contains $resultado.Host) {
        $resultado.Permitido = $true
        $resultado.Motivo = 'host en la lista de fuentes oficiales'
    } else {
        $resultado.Motivo = "host '$($resultado.Host)' no esta en apps/sources.json"
    }
    $resultado
}

# --- GPU / rendimiento --------------------------------------------------------

function Get-GvmGpuInfo {
    <#
      .SYNOPSIS
        Describe la GPU REAL visible en el SO invitado. No inventa nada: si no hay
        adaptador con driver WDDM util, lo dice.
    #>
    [CmdletBinding()]
    param([switch]$IncluirNvidiaSmi)
    $vps = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $filtro = 'Microsoft Basic Render|Remote Desktop|Game Viewer|RDP Display|Red Hat QXL|VirtIO GPU|Parallels|VMware SVGA|Base Video'
    $candidatas = @($vps | Where-Object { $_.Name -notmatch $filtro })
    $info = [ordered]@{
        Presente    = $false
        Nombre      = ''
        VramGiB     = 0.0
        Driver      = ''
        VersionDriver = ''
        ModoRender  = 'desconocido'
        CodificadorHw = 'ninguno'
        Direct3D    = 'desconocido'
        Resumen     = 'sin GPU util detectada'
        Fuentes     = @()
    }
    if ($candidatas.Count -eq 0) {
        $info.Resumen = 'Solo hay adaptadores basicos/remotos: no hay aceleracion 3D que ofrecer'
        return [pscustomobject]$info
    }
    $g = $candidatas[0]
    $info.Presente = $true
    $info.Nombre = $g.Name
    if ($g.AdapterRAM) { $info.VramGiB = [math]::Round(($g.AdapterRAM / 1GB), 2) }
    $info.Driver = $g.DriverVersion
    $info.VersionDriver = $g.DriverVersion
    $info.Direct3D = if ($g.VideoModeDescription) { 'video mode: ' + $g.VideoModeDescription } else { 'n/d' }
    $info.ModosResumen = "$($g.Name), driver $($g.DriverVersion), VRAM informada $($info.VramGiB) GiB"
    $info.Fuentes += 'Win32_VideoController'
    if ($g.Name -match 'NVIDIA|Grid|A10|A10G|T4|RTX|GTX') { $info.CodificadorHw = 'nvenc' }
    elseif ($g.Name -match 'AMD|Radeon|R7xx|V710') { $info.CodificadorHw = 'amf' }
    elseif ($g.Name -match 'Intel|Arc|Iris|UHD|Quick') { $info.CodificadorHw = 'qsv' }
    else { $info.CodificadorHw = 'ninguno' }

    if ($g.Name -match 'NVIDIA') {
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if (-not $smi) {
            foreach ($p in "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:SystemRoot\System32\nvidia-smi.exe") {
                if (Test-Path -LiteralPath $p) { $smi = $p; break }
            }
        }
        if ($smi) {
            try {
                $salida = & $smi --query-gpu=name,memory.total,driver_model.current,encoder.stats.sessionCount --format=csv,noheader 2>$null
                if ($salida) {
                    $info.Resumen = ($salida | Select-Object -First 1)
                    $info.Fuentes += 'nvidia-smi'
                    $info.CodificadorHw = 'nvenc'
                }
            } catch { Write-GvmLog -Nivel WARN -Mensaje 'nvidia-smi fallo' -Detalle $_.Exception.Message }
        } else {
            Write-GvmLog -Nivel WARN -Mensaje 'GPU NVIDIA vista por WMI pero sin nvidia-smi: posible driver Grid/vGPU sin utilidades'
        }
    }
    if (-not $info.Resumen -or $info.Resumen -eq 'sin GPU util detectada') { $info.Resumen = $info.ModosResumen }
    # Comprobacion DirectX real (dxdiag) solo bajo peticion: es lento e interactivo.
    [pscustomobject]$info
}

function Test-GvmDirectXDisponible {
    <#
      .SYNOPSIS
        Verificacion ligera de que el pipeline D3D11 responde en la sesion actual.
        Usa SharpDX-style P/Invoke no es posible sin binarios: se comprueba mediante
        'dxdiag /t' (si existe) y la presencia de d3d10warp/UMD, y se informa.
    #>
    [CmdletBinding()]
    param([string]$SalidaTemporal)
    $exe = Join-Path $env:SystemRoot 'System32\dxdiag.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Disponible = $false; Motivo = 'dxdiag no esta en la imagen (Server Core?)' }
    }
    if (-not $SalidaTemporal) { $SalidaTemporal = Join-Path $env:TEMP ("dxdiag-{0}.txt" -f (Get-Random)) }
    try {
        Start-Process -FilePath $exe -ArgumentList @('/t', "`"$SalidaTemporal`"") -Wait -WindowStyle Hidden -ErrorAction Stop
        Start-Sleep -Seconds 1
        $txt = Get-Content -LiteralPath $SalidaTemporal -Raw -ErrorAction SilentlyContinue
        if (-not $txt) { return [pscustomobject]@{ Disponible = $false; Motivo = 'dxdiag no devolvio informe' } }
        $directx = ($txt -match '(?i)DirectX Version')
        $render = if ($txt -match '(?m)^Device Notes') { 'notas de dispositivo presentes' } else { 'sin notas' }
        $habilitado = $txt -match '(?i)Direct3D\s+Accelerated\s+:\s+Yes'
        return [pscustomobject]@{
            Disponible = [bool]$habilitado
            Motivo     = if ($habilitado) { 'D3D acelerado informado por dxdiag' } else { "dxdiag no confirma 'Direct3D Accelerated: Yes' ($render)" }
            Archivo    = $SalidaTemporal
            Extracto   = (($txt -split "`r?`n" | Select-String -Pattern '(?i)^(Card name|Direct3D|Driver Version|DDI Version|Display Memory)' | ForEach-Object { $_.Line.Trim() }) -join '; ')
        }
    } catch {
        [pscustomobject]@{ Disponible = $false; Motivo = "dxdiag fallo: $($_.Exception.Message)" }
    } finally {
        if ($SalidaTemporal -and (Test-Path -LiteralPath $SalidaTemporal)) {
            Move-Item -LiteralPath $SalidaTemporal -Destination (Join-Path (Get-GvmPaths).Informes 'dxdiag.txt') -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- winget -------------------------------------------------------------------

function Get-GvmWingetComando {
    [CmdletBinding()] param()
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $posible = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $posible) { return $posible }
    $null
}

function Install-GvmWingetApp {
    <#
      .SYNOPSIS
        Instala una aplicacion por winget con reintentos, y devuelve una estructura
        de resultado apta para el informe. NO usa fuentes extra ni repositorios propios.
      .PARAMETER Id
        PackageIdentifier exacto del repositorio comunitario 'winget'.
      .PARAMETER Modo
        instalar | actualizar | reparar | verificar
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Version,
        [ValidateSet('instalar', 'actualizar', 'verificar')][string]$Modo = 'instalar',
        # Vacio = "winget que elija el alcance". El catalogo solo declara 'scope' en
        # algunas apps, y un ValidateSet sobre '' hacia fallar la fase antes de instalar.
        [string]$Scope = '',
        [string[]]$SilentFlags = @(),
        [int]$MaxRetries = 2
    )
    $res = [ordered]@{
        Id = $Id; Modo = $Modo; Estado = 'pendiente'; Codigo = $null; Version = $Version
        Intentos = 0; DuracionSeg = 0; Error = ''; Salida = ''
    }
    $winget = Get-GvmWingetComando
    if (-not $winget) {
        $res.Estado = 'sin-dependencia'
        $res.Error = 'winget no esta disponible en esta edicion/imagen (ver docs/08-instalacion-apps.md)'
        return [pscustomobject]$res
    }

    switch ($Modo) {
        'instalar'   { $accion = 'install' }
        'actualizar' { $accion = 'upgrade' }
        'verificar'  { $accion = 'list' }
    }
    $argsBase = @('--id', $Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($accion -ne 'list' -and $Scope) {
        if ($Scope -notin @('machine', 'user')) {
            throw "Scope de instalacion invalido para '$Id': '$Scope' (winget solo acepta 'machine' o 'user'; dejalo vacio para que decida winget)."
        }
        $argsBase += @('--scope', $Scope.ToLowerInvariant())
    }
    if ($Version) { $argsBase += @('--version', $Version) }
    if ($accion -ne 'list') { $argsBase += @('--silent') }
    if ($SilentFlags) { $argsBase += $SilentFlags }

    for ($i = 0; $i -le $MaxRetries; $i++) {
        $res.Intentos = $i + 1
        $cmdArgs = @($accion) + $argsBase
        Write-GvmLog -Nivel DEBUG -Mensaje "winget $($cmdArgs -join ' ')"
        $ini = Get-Date
        $salida = ''
        $codigo = 0
        if ($PSCmdlet.ShouldProcess($Id, "winget $accion")) {
            try {
                $salida = & $winget @cmdArgs 2>&1 | Out-String
                $codigo = $LASTEXITCODE
            } catch {
                $salida = $_.Exception.Message
                $codigo = -1
            }
        } else {
            $salida = 'QUE-SE-HARIA: winget ' + ($cmdArgs -join ' ')
            $codigo = 0
        }
        $res.DuracionSeg = [math]::Round(((Get-Date) - $ini).TotalSeconds, 1)
        $res.Codigo = $codigo
        $res.Salida = (($salida -replace "`r", '' -split "`n" | Where-Object { $_ -match '(?i)(installed|failed|already|up to date|No installed|error|Found|Downloaded|Verified)' } | Select-Object -Last 4) -join ' | ').Trim()
        # winget no garantiza codigos estables entre versiones (0x8A150xxx): se clasifica
        # tambien por el texto de salida, que si es estable para los casos que importan.
        if ($codigo -eq 0) {
            $res.Estado = if ($accion -eq 'list') { 'instalada' } else { 'correcta' }
        } elseif ($res.Salida -match '(?i)(already installed|up to date|No new version|already up-to-date)') {
            $res.Estado = 'ya-instalada'
        } elseif ($res.Salida -match '(?i)No installed package found') {
            $res.Estado = 'no-instalada'
        } elseif ($codigo -eq 1602) {
            $res.Estado = 'cancelada-por-usuario'
        } elseif ($codigo -eq 1603) {
            $res.Estado = 'fallo-instalador'
        } else {
            $res.Estado = 'error'
        }
        if ($res.Estado -in 'correcta', 'instalada', 'ya-instalada') {
            $res.Estado = 'correcta'
            break
        }
        if ($i -lt $MaxRetries) {
            $espera = 10 * ($i + 1)
            Write-GvmLog -Nivel WARN -Mensaje "winget $accion '$Id' fallo (codigo $codigo); reintento en $espera s" -Detalle $res.Salida
            Start-Sleep -Seconds $espera
        }
    }
    if ($res.Estado -notin 'correcta', 'instalada', 'ya-instalada') {
        $res.Error = "codigo de salida $codigo"
        Write-GvmLog -Nivel ERROR -Mensaje "winget $accion '$Id' no pudo completarse" -Detalle $res.Salida
    } else {
        Write-GvmLog -Nivel OK -Mensaje "winget $accion '$Id' -> $($res.Estado)"
    }
    [pscustomobject]$res
}

function Get-GvmAppInstalada {
    <#  .SYNOPSIS  Devuelve version y ruta de instalacion de un PackageIdentifier via winget list. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-GvmWingetComando
    if (-not $winget) { return $null }
    try {
        $salida = & $winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return $null }
        $linea = ($salida -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($Id) } | Select-Object -First 1)
        if (-not $linea) { return $null }
        $cols = $linea -split '\s{2,}'
        [pscustomobject]@{ Nombre = $cols[0]; Id = $Id; Version = $cols[1]; Fuente = $cols[2] }
    } catch { $null }
}

function Test-GvmFirma {
    <#
      .SYNOPSIS
        Verifica la firma Authenticode del binario instalado y que el firmante este
        entre los esperados. Nunca instala 'a la fuerza' si la comprobacion falla.
      .PARAMETER Tolerancia
        error  -> el bootstrap marca la app como fallo
        aviso  -> se registra el riesgo pero la app se considera instalada
    #>
    [CmdletBinding()]
    param(
        [string]$Ruta,
        [string[]]$FirmantesEsperados = @(),
        [ValidateSet('error', 'aviso')][string]$Tolerancia = 'aviso',
        [string]$Id = ''
    )
    $res = [ordered]@{ Id = $Id; Ruta = $Ruta; Estado = 'no-verificable'; Firmante = ''; Detalle = ''; Tolerancia = $Tolerancia }
    if (-not $Ruta) { $res.Detalle = 'el catalogo no declara ejecutable que comprobar'; return [pscustomobject]$res }
    $expandida = [Environment]::ExpandEnvironmentVariables($Ruta)
    if (-not (Test-Path -LiteralPath $expandida)) {
        $res.Estado = 'no-encontrado'
        $res.Detalle = "no existe $expandida (instalacion por usuario, arquitectura distinta o ruta movida)"
        return [pscustomobject]$res
    }
    $sig = Get-AuthenticodeSignature -FilePath $expandida
    $asunto = ''
    if ($sig.SignerCertificate) { $asunto = [string]$sig.SignerCertificate.Subject }
    $res.Firmante = $asunto
    switch ($sig.Status) {
        'Valid' {
            if ($FirmantesEsperados.Count -gt 0) {
                $coinicide = $false
                foreach ($f in $FirmantesEsperados) {
                    if ($asunto -match [regex]::Escape($f)) { $coinicide = $true; break }
                }
                if ($coinicide) { $res.Estado = 'valida'; $res.Detalle = 'firmante dentro de la lista oficial' }
                else {
                    $res.Estado = 'firmante-no-esperado'
                    $res.Detalle = "el catalogo esperaba: $($FirmantesEsperados -join ', ')"
                }
            } else { $res.Estado = 'valida'; $res.Detalle = 'sin lista de firmantes en el catalogo' }
        }
        'NotSigned' { $res.Estado = 'sin-firma'; $res.Detalle = 'binario sin firmar (comun en proyectos GPL: la garantia es el SHA-256 del instalador)' }
        default { $res.Estado = "firma-$($sig.Status)"; $res.Detalle = 'la firma no es de confianza para esta maquina' }
    }
    $nivel = if ($res.Estado -eq 'valida') { 'OK' } elseif ($Tolerancia -eq 'aviso') { 'WARN' } else { 'ERROR' }
    Write-GvmLog -Nivel $nivel -Fase 'apps' -Mensaje "firma de '$Id' ($expandida): $($res.Estado)" -Detalle $res.Detalle
    [pscustomobject]$res
}

# --- Informes -----------------------------------------------------------------

function New-GvmInforme {
    <#
      .SYNOPSIS
        Escribe un informe .json y .md en C:\ProgramData\WinGamingVM\informes y devuelve
        las rutas. Los campos 'hallazgos' tienen nivel OK/WARN/ERROR para el resumen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)]$Datos,
        # Sin tipar a [pscustomobject[]]: convertir un List[object] a ese tipo puede reventar
        # con 'Argument types do not match' fuera de nuestro codigo, y el informe es justo lo
        # que tiene que sobrevivir a un fallo de las fases.
        $Hallazgos = @()
    )
    $Hallazgos = @(
        @($Hallazgos) | Where-Object { $null -ne $_ } | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [pscustomobject]$_ } else { $_ }
        }
    )
    $rutas = Get-GvmPaths
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $json = Join-Path $rutas.Informes "$Nombre-$stamp.json"
    $md = Join-Path $rutas.Informes "$Nombre-$stamp.md"
    # Copias "-latest" para que un pipeline o un run-command puedan leer el informe sin
    # adivinar la marca de tiempo. Se sobrescriben cada vez.
    $jsonLatest = Join-Path $rutas.Informes "$Nombre-latest.json"
    $mdLatest = Join-Path $rutas.Informes "$Nombre-latest.md"
    $meta = [ordered]@{
        informe    = $Nombre
        generadoEl = (Get-Date).ToString('o')
        equipo     = $env:COMPUTERNAME
        usuario    = "$env:USERDOMAIN\$env:USERNAME"
        host       = [pscustomobject]@{
            so       = (Get-CimInstance Win32_OperatingSystem).Caption
            build    = [Environment]::OSVersion.Version.Build
            cpu      = (Get-GvmCpuResumen)
            ramGiB   = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1)
            sesion   = (Get-Process -Id $PID).SessionId
            esRdp    = ($env:SESSIONNAME -like '*RDP*') -or ($env:CLIENTNAME)
        }
        contenido  = $Datos
        hallazgos  = $Hallazgos
    }
    $meta | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $json -Encoding UTF8

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine([string]"# Informe $Nombre")
    [void]$sb.AppendLine("")
    $encabezado = "Generado: $($meta.generadoEl)  ·  Equipo: $($meta.equipo)  ·  SO: $($meta.host.so) (build $($meta.host.build))"
    [void]$sb.AppendLine([string]$encabezado)
    if ($Hallazgos.Count) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("## Resumen")
        foreach ($h in $Hallazgos) {
            $marca = switch ($h.nivel) { 'OK' { '✅' } 'WARN' { '⚠️' } 'ERROR' { '❌' } default { '•' } }
            [void]$sb.AppendLine([string]"- $marca **$($h.item)** — $($h.detalle)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine('## Detalle')
    [void]$sb.AppendLine('```json')
    # [string] explicito: si $Datos es una coleccion, ConvertTo-Json emite varias lineas y
    # AppendLine(object[]) no resuelve sobrecarga -> 'Argument types do not match'.
    [void]$sb.AppendLine([string]($Datos | ConvertTo-Json -Depth 10))
    [void]$sb.AppendLine('```')
    $texto = $sb.ToString()
    $texto | Set-Content -LiteralPath $md -Encoding UTF8
    try { $texto | Set-Content -LiteralPath $mdLatest -Encoding UTF8 } catch { Write-GvmLog -Nivel WARN -Mensaje "no se pudo escribir la copia latest ($mdLatest)" }
    try { Copy-Item -LiteralPath $json -Destination $jsonLatest -Force } catch { Write-GvmLog -Nivel WARN -Mensaje "no se pudo escribir la copia latest ($jsonLatest)" }
    Write-GvmLog -Nivel OK -Mensaje "informe escrito: $md"
    [pscustomobject]@{ Json = $json; Markdown = $md; JsonLatest = $jsonLatest; MarkdownLatest = $mdLatest }
}

function New-GvmHallazgo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        # ValidateSet no distingue mayusculas, pero los scripts eligen el nivel con if/switch
        # y aqui debajo se normaliza a mayusculas para que el informe salga uniforme.
        [ValidateSet('OK', 'WARN', 'ERROR', 'INFO')][string]$Nivel = 'INFO',
        # Sin Mandatory: un hallazgo puede no tener detalle, y un string vacio obligatorio
        # aborta el binding del script entero con 'Cannot bind argument to parameter'.
        [string]$Detalle = ''
    )
    [pscustomobject]@{ item = $Item; nivel = $Nivel; detalle = $Detalle }
}

# --- Tareas / servicios / sesion ---------------------------------------------

function Set-GvmTareaProgramada {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$Comando,
        [ValidateSet('alIniciar', 'alSesion', 'desconectada')][string]$Disparo = 'alIniciar',
        [string]$Argumentos = '',
        [string]$Usuario = 'SYSTEM',
        [switch]$Elevada
    )
    if ($PSCmdlet.ShouldProcess($Nombre, 'crear tarea programada')) {
        $accion = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$Comando`" $Argumentos"
        $trigger = switch ($Disparo) {
            'alIniciar' { New-ScheduledTaskTrigger -AtStartup }
            'alSesion' { New-ScheduledTaskTrigger -AtLogOn }
            'desconectada' { New-ScheduledTaskTrigger -AtLogOn -User $Usuario }
        }
        $principal = if ($Usuario -eq 'SYSTEM') {
            New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        } elseif ($Elevada) {
            New-ScheduledTaskPrincipal -UserId $Usuario -LogonType S4U -RunLevel Highest
        } else {
            New-ScheduledTaskPrincipal -UserId $Usuario -LogonType Interactive -RunLevel Limited
        }
        $config = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(0))
        Register-ScheduledTask -TaskName "WinGamingVM - $Nombre" -Action $accion -Trigger $trigger -Principal $principal -Settings $config -Force | Out-Null
        Write-GvmLog -Nivel OK -Mensaje "tarea programada: WinGamingVM - $Nombre ($Disparo)"
    }
}

# Regla para cualquier documento que acabe en un ConvertTo-Json: dentro de una coleccion
# (array o List) solo puede haber [pscustomobject] o valores simples. Un OrderedDictionary —
# lo que produce [ordered]@{}-- dentro de una coleccion hace que el writer de .NET pida
# KeyValuePair<string,object>, reciba DictionaryEntry y lance ArgumentException 'Argument types
# do not match' sin dejar ni un marco de script util en la pila. De primer nivel o como valor
# suelto de una clave, si funciona; anidado en una coleccion, no.
#
function Get-GvmCpuResumen {
    [CmdletBinding()] param()
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $pr = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    $logicos = 0
    foreach ($p in $pr) { $logicos += [int]$p.NumberOfLogicalProcessors }
    if ($logicos -eq 0) { $logicos = [int]$cs.NumberOfLogicalProcessors }
    "vCPU logicos: $logicos (sockets $($pr.Count))"
}

function Get-GvmSesionActual {
    [CmdletBinding()] param()
    $query = $null
    try { $query = query.exe session 2>&1 | Out-String } catch { }
    $consola = $null
    if ($query) { $consola = ($query -split "`r?`n" | Where-Object { $_ -match '^\s*Console' } | Select-Object -First 1) }
    [pscustomobject]@{
        SessionId    = (Get-Process -Id $PID).SessionId
        EsConsola    = [bool]($env:SESSIONNAME -eq 'Console')
        Cliente      = $env:CLIENTNAME
        NombreSesion = $env:SESSIONNAME
        TablaQuery   = if ($consola) { $consola.Trim() } else { '' }
    }
}

Export-ModuleMember -Function * -Alias *
