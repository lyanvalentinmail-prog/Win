<#
  .SYNOPSIS
    Tuneles SSH a la VM para no abrir el 3389 a Internet (RDP o SSM-style access).
  .DESCRIPTION
    Dos modos:
      · -Modo rdp      -> levanta un tunel local hacia el 3389 de la VM y genera un .rdp
                         que apunta a 127.0.0.1:13389. Necesitas acceso SSH al host que
                         enruta (el propio equipo publico, un bastion o el host KVM).
      · -Modo autossh  -> tunel permanente con reconexion automatica (si tienes autossh).
    La VM puede estar SIN puerto abierto: el tunel sale desde una maquina que si lo ve.
    No guarda contrasenas: usa clave SSH y (si la pides) el agente ssh-agent.
  .PARAMETER Modo
  .PARAMETER Salto        host de salto con SSH (usuario@host).
  .PARAMETER DestinoVM     IP/hostname y puerto de la VM detras del salto.
  .PARAMETER PuertoLocal
  .EXAMPLE
    .\Montar-TunelSSH.ps1 -Modo rdp -Salto 'azureuser@20.30.40.50' -DestinoVM '10.20.1.4:3389'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('rdp', 'autossh')][string]$Modo = 'rdp',
    [Parameter(Mandatory)][string]$Salto,
    [string]$DestinoVM = '127.0.0.1:3389',
    [ValidateRange(1024, 65535)][int]$PuertoLocal = 13389,
    [string]$ClaveSsh = ''
)

Set-StrictMode -Version 1.0   # 1.0: se leen propiedades opcionales de JSON
$ErrorActionPreference = 'Stop'
foreach ($cmd in 'ssh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw 'Falta ssh.exe (viene en Windows 10/11 como caracteristica opcional "OpenSSH Client").' }
}
if ($Modo -eq 'autossh' -and -not (Get-Command autossh -ErrorAction SilentlyContinue)) {
    throw 'autossh no esta instalado; usa -Modo rdp o instala Git for Windows / MSYS2.'
}

$destino = $DestinoVM
if ($destino -notmatch ':\d+$') { $destino = "${destino}:3389" }
$argumentos = @('-N', '-L', "${PuertoLocal}:${destino}", '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=4', '-o', 'ExitOnForwardFailure=yes')
if ($ClaveSsh) { $argumentos = @('-i', $ClaveSsh) + $argumentos }
# ProxyJump es mas corto cuando el salto es el propio bastion:
if ($Salto -match '@' -and $DestinoVM -notmatch '^127\.0\.0\.1') {
    $argumentos = @('-J', $Salto) + $argumentos + @('localhost')
} else {
    $argumentos += $Salto
}

Write-Host ''
Write-Host "  tunel: 127.0.0.1:$PuertoLocal -> $destino (via $Salto)" -ForegroundColor Cyan
Write-Host ("  comando: ssh {0}" -f ($argumentos -join ' '))
if ($Modo -eq 'autossh') { $argumentos = @('-M', '0', '-f') + $argumentos }

if ($PSCmdlet.ShouldProcess('tunel SSH', 'levantar en segundo plano')) {
    if ($Modo -eq 'autossh') {
        Start-Process -FilePath 'autossh' -ArgumentList $argumentos -WindowStyle Hidden
        Write-Host '  autossh en segundo plano (para pararlo: Get-Process autossh | Stop-Process)'
    } else {
        Start-Process -FilePath 'ssh' -ArgumentList $argumentos -WindowStyle Hidden
        Write-Host '  tunel lanzado en una ventana oculta; manten el proceso vivo mientras uses el escritorio.'
    }
}

# Comprobacion del tunel y .rdp local
Start-Sleep -Seconds 3
$abierto = $false
$c = New-Object Net.Sockets.TcpClient
try { $t = $c.ConnectAsync('127.0.0.1', $PuertoLocal); $abierto = [bool]($t.Wait(3000)) } catch { } finally { $c.Dispose() }
if (-not $abierto) {
    Write-Host '  el puerto local NO escucha: revisa las claves, el salto y que la VM tenga 3389 accesible desde el saltador.' -ForegroundColor Red
    exit 2
}
$rdp = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "WinGamingVM-tunel-$PuertoLocal.rdp"
@(
    'full address:s:127.0.0.1:13389',
    'screen mode id:i:2', 'session bpp:i:32', 'authentication level:i:0',
    'enablecredsspsupport:i:1', 'networktype:i:1', 'videoplaybackmode:i:1',
    'bandwidthautodetect:i:1', 'compression:i:1', 'keyboardhook:i:2',
    'audiomode:i:0', 'redirectclipboard:i:1'
) | Set-Content -LiteralPath $rdp -Encoding ASCII
Write-Host ''
Write-Host "  [OK] tunel activo y $rdp escrito (con 'authentication level:i:0' porque el nombre no coincide con el certificado: es una decision consciente y esta documentada en docs/05)." -ForegroundColor Green
Write-Host ''
