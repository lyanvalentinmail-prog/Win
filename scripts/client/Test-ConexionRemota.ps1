<#
  .SYNOPSIS
    Diagnostico del canal desde el cliente: TCP/UDP, latencia, MTU y negociacion.
  .DESCRIPTION
    Se ejecuta en TU PC (Windows o donde tengas PowerShell 7). Comprueba lo que se puede
    comprobar desde fuera, sin tocar la VM:

      · 3389/tcp abierto y tiempo de handshake (si el tunel esta caido, esto lo dice);
      · latencia ICMP (si la ruta la permite; los bloquean a menudo, no es un fallo);
      · perdida y variacion (jitter) en 20 sondas: lo que se nota como "tirones";
      · MTU de la ruta (un MTU recortado fragmenta y sube la latencia);
      · si el certificado TLS presentado es verificable (NLA/CredSSP dependen de eso).

    Interpreta, no promete: un ping bonito no garantiza 60 fps, y un ping feo no invalida
    el acceso de escritorio. Los numeros de dentro de la VM (y la latencia de entrada real)
    se miden con Get-SystemMetrics.ps1 en la VM.
  .PARAMETER Hostname
  .PARAMETER Puertos
  .PARAMETER Sondas
  .PARAMETER FormatoJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Hostname,
    [int[]]$Puertos = 3389,
    [int]$Sondas = 20,
    [switch]$FormatoJson,
    [string]$TunelHost = '',
    [int]$TunelPuerto = 0
)

Set-StrictMode -Version 1.0   # 1.0: se leen propiedades opcionales de JSON
# 'Continue' a proposito: son scripts de medicion/diagnostico y deben informar de todo,
# no abortar en la primera comprobacion que falle (un puerto cerrado no es un error).
$ErrorActionPreference = 'Continue'
$resultado = [ordered]@{
    destino  = $Hostname
    fecha    = (Get-Date).ToString('o')
    tcp      = @()
    icmp     = $null
    mtu      = $null
    tls      = $null
    tunel    = $null
    lecturas = @()
}

foreach ($p in $Puertos) {
    $ini = Get-Date
    $cliente = New-Object Net.Sockets.TcpClient
    try {
        $tarea = $cliente.ConnectAsync($Hostname, $p)
        $ok = $tarea.Wait(5000)
        $ms = [math]::Round(((Get-Date) - $ini).TotalMilliseconds, 1)
        if ($ok -and $cliente.Connected) {
            $resultado.tcp += [ordered]@{ puerto = $p; abierto = $true; handshakeMs = $ms }
        } else {
            $resultado.tcp += [ordered]@{ puerto = $p; abierto = $false; error = 'timeout de 5 s en el handshake' }
        }
    } catch {
        $resultado.tcp += [ordered]@{ puerto = $p; abierto = $false; error = $_.Exception.Message }
    } finally { $cliente.Dispose() }
}

# ICMP: informativo. Muchos proveedores lo filtran; la ausencia no es un problema en si.
try {
    $ping = New-Object Net.NetworkInformation.Ping
    $valores = @()
    for ($i = 0; $i -lt $Sondas; $i++) {
        $r = $ping.Send($Hostname, 1000)
        if ($r.Status -eq 'Success') { $valores += $r.RoundtripTime }
        Start-Sleep -Milliseconds 250
    }
    if ($valores.Count -ge 3) {
        $media = ($valores | Measure-Object -Average).Average
        $perdida = [math]::Round((($Sondas - $valores.Count) / $Sondas) * 100, 1)
        $jitter = if ($valores.Count -ge 4) { ($valores | ForEach-Object { [math]::Abs($_ - $media) } | Measure-Object -Average).Average } else { 0 }
        $resultado.icmp = [ordered]@{
            sondas            = $Sondas
            respuestas        = $valores.Count
            perdidaPorciento  = $perdida
            mediaMs           = [math]::Round($media, 1)
            minMs             = ($valores | Measure-Object -Minimum).Minimum
            maxMs             = ($valores | Measure-Object -Maximum).Maximum
            desviacionMediaMs = [math]::Round($jitter, 1)
        }
    } else {
        $resultado.icmp = [ordered]@{ respuestas = $valores.Count; nota = 'ICMP filtrado o ausente: no concluyente, usa el handshake TCP como referencia' }
    }
} catch {
    $resultado.icmp = [ordered]@{ error = $_.Exception.Message }
}

# MTU de ruta: 1472 = 1500 - cabeceras. Bajos = PPPoE/tunel; la fragmentacion duele al UDP.
try {
    $bytes = New-Object byte[] 1464
    $ping2 = New-Object Net.NetworkInformation.Ping
    $r = $ping2.Send($Hostname, 1500, $bytes)
    $resultado.mtu = [ordered]@{ payloadOk = 1464; estado = $r.Status.ToString() }
} catch {
    $resultado.mtu = [ordered]@{ nota = 'no se pudo probar el tamano de paquete: ' + $_.Exception.Message }
}

# TLS del endpoint de gestion (443) o del port RDP si el servidor presenta STARTTLS.
try {
    $tcp = New-Object Net.Sockets.TcpClient($Hostname, 443)
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { param($s, $cert, $chain, $errors) $true })
    $ssl.AuthenticateAsClient($Hostname)
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    $resultado.tls = [ordered]@{
        sujeto        = $cert.Subject
        emisor        = $cert.Issuer
        caducidad     = $cert.NotAfter.ToString('yyyy-MM-dd')
        autosellicdo  = $cert.Issuer -eq $cert.Subject
        nota          = 'autofirmado es normal en el certificado RDP; con IP dinamica, usa el nombre del tunel o un certificado interno'
    }
    $ssl.Dispose(); $tcp.Dispose()
} catch {
    $resultado.tls = [ordered]@{ nota = 'sin TLS en 443 (normal si solo expones 3389): ' + $_.Exception.Message }
}

if ($TunelHost -and $TunelPuerto) {
    $ini = Get-Date
    $c = New-Object Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($TunelHost, $TunelPuerto); $ok = $t.Wait(3000)
        $resultado.tunel = [ordered]@{ host = $TunelHost; puerto = $TunelPuerto; activo = [bool]$ok; ms = [math]::Round(((Get-Date) - $ini).TotalMilliseconds, 1) }
    } catch { $resultado.tunel = [ordered]@{ host = $TunelHost; puerto = $TunelPuerto; error = $_.Exception.Message } } finally { $c.Dispose() }
}

# Interpretacion
if (-not $FormatoJson) {
    Write-Host ''
    Write-Host "  Win Gaming VM — canal desde el cliente hacia $Hostname" -ForegroundColor Cyan
    foreach ($t in $resultado.tcp) {
        if ($t.abierto) { Write-Host ("  [OK]   {0}/tcp abierto (handshake {1} ms)" -f $t.puerto, $t.handshakeMs) }
        else { Write-Host ("  [ERROR] {0}/tcp: {1}" -f $t.puerto, $t.error) -ForegroundColor Red }
    }
    if ($resultado.icmp -and $resultado.icmp.mediaMs) {
        $i = $resultado.icmp
        $veredicto = if ($i.mediaMs -lt 40 -and $i.perdidaPorciento -lt 1) { 'bueno para escritorio y stream' }
                    elseif ($i.mediaMs -lt 90) { 'usable; el input lag sube con la RTT' }
                    else { 'la experiencia va a notar la red, no la VM' }
        Write-Host ("  [INFO] RTT media {0} ms (min {1} / max {2}), variacion {3} ms, perdida {4}%" -f $i.mediaMs, $i.minMs, $i.maxMs, $i.desviacionMediaMs, $i.perdidaPorciento)
        Write-Host "         lectura: $veredicto"
    } elseif ($resultado.icmp) {
        Write-Host ("  [AVISO] ICMP: " + $resultado.icmp.nota) -ForegroundColor Yellow
    }
    if ($resultado.mtu) { Write-Host ("  [INFO] MTU de ruta: " + ($resultado.mtu | ConvertTo-Json -Compress)) }
    if ($resultado.tls -and $resultado.tls.sujeto) {
        Write-Host ("  [INFO] TLS: {0} · caduca {1} · autosellado={2}" -f $resultado.tls.sujeto, $resultado.tls.caducidad, $resultado.tls.autosellicdo)
    }
    if ($resultado.tunel) { Write-Host ("  [INFO] tunel: " + ($resultado.tunel | ConvertTo-Json -Compress)) }
    Write-Host ''
    Write-Host '  Limites de esta medicion: mide la red y el puerto, no el pipeline de codificacion.' -ForegroundColor DarkGray
    Write-Host '  La latencia real de entrada se mide en la VM (Get-SystemMetrics.ps1) y en el overlay de Moonlight.'
    Write-Host ''
}
$resultado | ConvertTo-Json -Depth 6
