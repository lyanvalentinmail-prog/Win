<#
.SYNOPSIS
  Monitor y medidor de latencia de la VM (CPU, RAM, GPU, disco, red).
.DESCRIPTION
  Cuatro modos:
    -Modo punto       : una muestra rapida de todo (por defecto).
    -Modo rendimiento : muestreo en bucle a CSV para dejarlo grabando durante una partida.
    -Modo ping        : latencia y perdida hacia objetivos (comprueba la parte del enlace
                        que depende del proveedor: la otra mitad, la del movil, se mide
                        desde el propio cliente Moonlight).
    -Modo sesion      : sesiones RDP activas, cliente, resolucion y tiempo de sesion.
  No inventa contadores: si un contador de rendimiento no existe en la edicion (p. ej.
  \\GPU Engine\\* en una VM sin driver WDDM), lo marca como 'no disponible' en lugar de
  devolver 0 y quedarte pensando que la GPU esta libre.
.OUTPUTS
  PSCustomObject(s) segun el modo.
#>
[CmdletBinding()]
param(
    [ValidateSet('punto', 'rendimiento', 'ping', 'sesion')][string]$Modo = 'punto',
    [int]$IntervaloSegundos = 5,
    [int]$Muestras = 120,
    [string]$SalidaCsv,
    [string[]]$Objetivos = @('1.1.1.1'),
    [int]$Paquetes = 20,
    [switch]$HastaQueCorte
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force

# Cada fase puede ejecutarse suelta (o como proceso hijo del bootstrap): inicializa su
# propio log/estado. Si quien llama es el bootstrap, el fichero de log sera el de esta fase,
# que es lo util cuando hay que relanzar solo una.
[void](Initialize-GvmRuntime -Nombre ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)))

function Get-Contradores {
    $candidatos = [ordered]@{
        cpu        = '\\Processor(_Total)\% Processor Time'
        ramLibreMB = '\\Memory\Available MBytes'
        ramTotalMB = '\\Memory\Committed Bytes'
        discoSeg   = '\\PhysicalDisk(_Total)\Avg. Disk sec/Read'
        colaDisco  = '\\PhysicalDisk(_Total)\Current Disk Queue Length'
        redKbps    = '\\Network Interface(*)\Bytes Total/sec'
        gpuEngine  = '\\GPU Engine(*)\Utilization Percentage'
    }
    $salida = [ordered]@{}
    foreach ($k in $candidatos.Keys) {
        try {
            $c = Get-Counter -Counter $candidatos[$k] -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $val = ($c.CounterSamples | Measure-Object -Property CookedValue -Average).Average
            $salida[$k] = [math]::Round($val, 2)
        } catch { $salida[$k] = 'no-disponible' }
    }
    $salida
}

switch ($Modo) {

    'punto' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cnt = Get-Contradores
        $gpu = Get-GvmGpuInfo
        $discos = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free } | ForEach-Object {
            [pscustomobject]@{ Letra = $_.Name; LibreGiB = [math]::Round($_.Free / 1GB, 1); UsadoGiB = [math]::Round($_.Used / 1GB, 1) }
        })
        [pscustomobject]@{
            Fecha        = (Get-Date).ToString('s')
            CpuPct       = $cnt.cpu
            RamLibreMB   = $cnt.ramLibreMB
            RamTotalGiB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            ColaDisco    = $cnt.colaDisco
            DiscoMsLectura = $cnt.discoSeg
            RedKbps      = $cnt.redKbps
            GpuPct       = $cnt.gpuEngine
            Gpu          = $gpu.Nombre
            GpuDetalle   = $gpu.Resumen
            Discos       = $discos
        }
    }

    'rendimiento' {
        if (-not $SalidaCsv) { $SalidaCsv = Join-Path (Get-GvmPaths).Informes ("rendimiento-{0}.csv" -f (Get-Date -Format yyyyMMdd-HHmmss)) }
        Write-GvmLog -Mensaje "grabando metricas en $SalidaCsv cada $IntervaloSegundos s ($Muestras muestras)"
        $fila = 0
        while ($fila -lt $Muestras) {
            $fila++
            $os = Get-CimInstance Win32_OperatingSystem
            $cnt = Get-Contradores
            $gpu = Get-GvmGpuInfo
            $r = [ordered]@{
                hora       = (Get-Date).ToString('s')
                muestra    = $fila
                cpuPct     = $cnt.cpu
                ramLibreMB = $cnt.ramLibreMB
                colaDisco  = $cnt.colaDisco
                discoLecMs = $cnt.discoSeg
                redKbps    = $cnt.redKbps
                gpuPct     = $cnt.gpuEngine
            }
            if ($fila -eq 1) { [pscustomobject]$r | Export-Csv -LiteralPath $SalidaCsv -NoTypeInformation -Encoding UTF8 }
            else { [pscustomobject]$r | Export-Csv -LiteralPath $SalidaCsv -NoTypeInformation -Append -Encoding UTF8 }
            if ($HastaQueCorte) {
                $sesiones = @(Get-NetTCPConnection -State Established -LocalPort 3389 -ErrorAction SilentlyContinue)
                if ($sesiones.Count -eq 0) { Write-GvmLog -Nivel WARN -Mensaje 'sin sesiones RDP establecidas: se detiene el registro'; break }
            }
            if (($fila % 12) -eq 0) {
                Write-Host ("  muestra {0}: cpu {1}% · ram {2} MB libres · gpu {3} · disco {4} ms" -f $fila, $r.cpuPct, $r.ramLibreMB, $r.gpuPct, $r.discoLecMs)
            }
            Start-Sleep -Seconds $IntervaloSegundos
        }
        Write-GvmLog -Nivel OK -Mensaje "registro terminado: $SalidaCsv"
        [pscustomobject]@{ Archivo = $SalidaCsv; Muestras = $fila }
    }

    'ping' {
        # ICMP: medido con la clase .NET (existe en PS 5.1 y 7.x, sin depender de aliases de Test-Connection).
        # OJO: Azure no responde a ICMP desde Internet hacia la VM: para medir tu enlace real usa
        # el objetivo 'tcp:<host>:<puerto>' (latencia de handshake) o el medidor del cliente Moonlight.
        $res = New-Object System.Collections.Generic.List[object]
        foreach ($o in $Objetivos) {
            if ([string]::IsNullOrWhiteSpace($o)) { continue }
            if ($o -like 'tcp:*') {
                $partes = $o.Substring(4) -split ':'
                $h = $partes[0]; $p = [int]$partes[1]
                $muestras = @()
                for ($i = 0; $i -lt $Paquetes; $i++) {
                    $ini = Get-Date
                    $c = New-Object System.Net.Sockets.TcpClient
                    try { $t = $c.ConnectAsync($h, $p); if ($t.Wait(2000)) { $muestras += [math]::Round(((Get-Date) - $ini).TotalMilliseconds, 1) } }
                    catch { } finally { $c.Close() }
                }
            } else {
                $muestras = @()
                $ping = New-Object System.Net.NetworkInformation.Ping
                for ($i = 0; $i -lt $Paquetes; $i++) {
                    try {
                        $r = $ping.Send($o, 2000)
                        if ($r.Status -eq 'Success' -and $r.RoundtripTime -ge 0) { $muestras += [double]$r.RoundtripTime }
                    } catch { }
                    Start-Sleep -Milliseconds 120
                }
                $ping.Dispose()
            }
            if ($muestras.Count -eq 0) {
                $res.Add([pscustomobject]@{ Objetivo = $o; Enviados = $Paquetes; Recibidos = 0; Perdida = 100; Media = 'n/d'; P95 = 'n/d'; Min = 'n/d'; Max = 'n/d'; Metodo = $(if ($o -like 'tcp:*') { 'tcp-connect' } else { 'icmp' }) })
                continue
            }
            $ordenados = @($muestras | Sort-Object)
            $idx = [math]::Min($ordenados.Count - 1, [math]::Floor($ordenados.Count * 0.95))
            $res.Add([pscustomobject]@{
                Objetivo  = $o
                Enviados  = $Paquetes
                Recibidos = $muestras.Count
                Perdida   = [math]::Round((($Paquetes - $muestras.Count) / $Paquetes) * 100, 1)
                Media     = [math]::Round(($muestras | Measure-Object -Average).Average, 1)
                P95       = $ordenados[$idx]
                Min       = $ordenados[0]
                Max       = $ordenados[-1]
                Metodo    = $(if ($o -like 'tcp:*') { 'tcp-connect' } else { 'icmp' })
            })
        }
        $res
    }

    'sesion' {
        $out = New-Object System.Collections.Generic.List[object]
        try { $res = @(query.exe session 2>&1 | Out-String) -split "`r?`n" } catch { $res = @() }
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 22, 24, 25 } -MaxEvents 12 -ErrorAction SilentlyContinue)
        foreach ($e in $ev) { $out.Add([pscustomobject]@{ Tipo = 'evento'; Hora = $e.TimeCreated.ToString('s'); Detalle = ($e.Message -replace "`r?`n", ' ') }) }
        foreach ($l in $res) { if ($l -match '\S') { $out.Add([pscustomobject]@{ Tipo = 'query-session'; Hora = ''; Detalle = $l.Trim() }) } }
        $out
    }
}
