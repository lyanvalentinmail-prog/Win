<#
  .SYNOPSIS
    Prepara el PC Windows desde el que te conectas (no la VM): gateway, experiencia y calidad.
  .DESCRIPTION
    Se ejecuta en TU ORDENADOR LOCAL, no dentro de la VM. Ajusta lo que Windows App /
    Remote Desktop puede negociar por politica de cliente y lo que el SO local puede
    tocar para que el canal se sienta mas firme:

      · experiencia de red y de rendimiento (elijo rendimiento en lugar de Automatico);
      · codificacion de hardware en el cliente (si la GPU local la soporta);
      · animaciones y efectos del propio escritorio local que anaden latencia percibida;
      · desactivacion del ahorro de energia del adaptador de red local;
      · creacion de un .rdp con los valores que usa el proyecto (documentado en docs/05).

    NO hace: magia de mando (Windows App no redirige mandos), overlays tactiles (no
    existen en Windows App), ni cambia nada dentro de la VM.
  .PARAMETER Hostname          IP o FQDN de la VM (o la del tunel).
  .PARAMETER Puente           Ancho de banda declarado en kbps para la politica de experiencia.
  .PARAMETER CrearRdp          Escribe un .rdp en la carpeta de documentos con la config base.
  .PARAMETER SinEfectos        No toca animaciones/efectos visuales locales.
  .EXAMPLE
    .\Configurar-ClienteWindowsApp.ps1 -Hostname 20.30.40.50 -CrearRdp
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$Hostname,
    [ValidateRange(1000, 1000000)][int]$Puente = 45000,
    [switch]$CrearRdp,
    [switch]$SinEfectos
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Solo lectura/escritura en HKCU y en Documentos: no se requieren derechos elevados y no
# hay ninguna clave HKLM de politica que pueda bloquear el propio equipo.
Write-Host ''
Write-Host '  Win Gaming VM — preparacion del cliente Windows' -ForegroundColor Cyan
Write-Host "  equipo: $Hostname · puente declarado: $Puente kbps"

if ($PSCmdlet.ShouldProcess('HKCU:\Software\Microsoft\Terminal Server Client', 'configurar experiencia de red')) {
    $ts = 'HKCU:\Software\Microsoft\Terminal Server Client'
    if (-not (Test-Path $ts)) { New-Item -Path $ts -Force | Out-Null }
    # AuthenticationLevel no se toca: el NLA lo decide el servidor.
    New-ItemProperty -Path $ts -Name 'RDGClientTransport' -PropertyType DWord -Value 1 -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess('HKCU:\Software\Microsoft\Terminal Server Client', 'activar codificacion por hardware')) {
    # El cliente codifica/presenta con GPU si la tiene; si no, ignora la clave.
    $avc = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -and $_.Name -notmatch 'Basic|Microsoft' }
    if ($avc) {
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name 'bEnableGfxAVC444' -PropertyType DWord -Value 2 -Force | Out-Null
        Write-Host ("  GPU local detectada: {0} (AVC444 habilitado en el cliente)" -f $avc[0].Name)
    } else {
        Write-Host '  sin GPU local util: no se activa GFX/AVC444 en el cliente' -ForegroundColor Yellow
    }
}

if (-not $SinEfectos) {
    if ($PSCmdlet.ShouldProcess('HKCU:\Control Panel\Desktop', 'reducir animaciones locales')) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'UserPreferencesMask' -Type Binary -Value ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) -Force
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Type DWord -Value 3 -Force -ErrorAction SilentlyContinue
        Write-Host '  animaciones locales reducidas (afecta a este equipo, no a la VM)'
    }
}

# Ahorro de energia del adaptador: una WiFi que entra en ahorro es latencia periodica.
foreach ($nic in (Get-NetAdapter | Where-Object Status -eq 'Up')) {
    try {
        Set-NetAdapterPowerManagement -Name $nic.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        Write-Host ("  adaptador {0}: ahorro de energia desactivado" -f $nic.Name)
    } catch {
        Write-Host ("  adaptador {0}: no se pudo cambiar el ahorro de energia ({1})" -f $nic.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
}

if ($CrearRdp) {
    $destino = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "WinGamingVM-$Hostname.rdp"
    $lineas = @(
        'screen mode id:i:2',
        'desktopwidth:i:1920',
        'desktopheight:i:1080',
        'session bpp:i:32',
        'winposstr:s:0,3,0,0,1920,1080',
        'full address:s:' + $Hostname,
        'authentication level:i:2',
        'enablecredsspsupport:i:1',
        'networktype:i:3',
        'bandwidthautodetect:i:1',
        'videoplaybackmode:i:1',
        'compression:i:1',
        'keyboardhook:i:2',
        'audiomode:i:0',
        'audiocapturemode:i:0',
        'redirectclipboard:i:1',
        'deviceredirection:i:0',
        'prompt for credentials:i:1'
    )
    Set-Content -LiteralPath $destino -Value ($lineas -join "`r`n") -Encoding ASCII
    Write-Host ''
    Write-Host "  .rdp escrito en $destino" -ForegroundColor Green
    Write-Host '  Abre el fichero con "Editar" en Conexión a Escritorio remoto; Windows App'
    Write-Host '  NO importa ficheros .rdp: en la app se configura el equipo en "Sus equipos".'
    Write-Host '  Estos valores son el punto de partida del cliente: la VM fija politicas de'
    Write-Host '  servidor (profundidad de color, redirecciones, UDP, AVC) y, cuando el servidor'
    Write-Host '  restringe algo, el cliente no puede saltarselo.'
}

Write-Host ''
Write-Host '  Recordatorios de limites (documentados en docs/06-limitaciones-windows-app.md):' -ForegroundColor Yellow
Write-Host '   · Windows App en Android: tactil como puntero/gestos, teclado y raton fisicos por'
Write-Host '     Bluetooth/USB. NO redirige mandos ni crea mandos tactiles en pantalla.'
Write-Host '   · Para mando virtual y overlays hace falta el canal Moonlight/Sunshine y una GPU.'
Write-Host ''
