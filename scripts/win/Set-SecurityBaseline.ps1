<#
.SYNOPSIS
  Linea base de seguridad del host de escritorio remoto.
.DESCRIPTION
  Principios que este script respeta SIEMPRE (y que no se pueden desactivar por config):
   - No apaga Microsoft Defender, su actualizacion de firmas, el firewall ni Windows Update.
   - No guarda, genera ni imprime credenciales.
   - No abre puertos a 0.0.0.0/0.
   - Cualquier desviacion del "recomendado" se registra como AVISO visible en el informe.

  Aplica: actualizaciones, NLA/TLS, refuerzo de LSA, NetBIOS/LLMNR desactivados, auditoria
  de sesiones RDP, bloqueo de pantalla opcional, cifrado del disco de datos (solo si se pide
  explicitamente y se entrega donde guardar la clave de recuperacion) y comprobacion de que
  WinRM/RDP no estan expuestos mas de lo previsto.
.OUTPUTS
  PSCustomObject: Aplicados, Advertencias, Hallazgos
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [string]$ClaveBitlockerSalida,
    [switch]$SinReinicio
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\GamingVM\GamingVM.psd1') -Force

# Cada fase puede ejecutarse suelta (o como proceso hijo del bootstrap): inicializa su
# propio log/estado. Si quien llama es el bootstrap, el fichero de log sera el de esta fase,
# que es lo util cuando hay que relanzar solo una.
[void](Initialize-GvmRuntime -Nombre ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)))

$cfg = Resolve-GvmConfig -Entrada $Config
$Fase = 'seguridad'
$aplicados = 0; $avisos = 0
$detallado = New-Object System.Collections.Generic.List[object]
function Add-Item { param([string]$i, [string]$e, [string]$d)
    $null = $detallado.Add([pscustomobject]@{ item = $i; estado = $e; detalle = $d })
    if ($e -eq 'aplicado') { $script:aplicados++ } elseif ($e -eq 'aviso') { $script:avisos++ }
}

# --- 1. Estado de Defender (solo lectura + refuerzo, nunca apagado) ----------
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.AntivirusEnabled) { Add-Item 'Defender' 'aplicado' "en tiempo real=$($mp.RealTimeProtectionEnabled), firmas $($mp.AntivirusSignatureVersion) ($($mp.AntivirusSignatureLastUpdated))" }
    else { Add-Item 'Defender' 'aviso' 'el antivirus no esta habilitado: revisa si la imagen del proveedor lo quito (este proyecto no lo desactiva y no lo reactiva por la fuerza si una GPO lo impide)' }
    if ($PSCmdlet.ShouldProcess('Defender', 'Update-MpSignature')) { Update-MpSignature -ErrorAction SilentlyContinue }
} catch { Add-Item 'Defender' 'aviso' "Get-MpComputerStatus no disponible: $($_.Exception.Message)" }

# --- 2. Windows Update --------------------------------------------------------
$au = Get-GvmConfigValor -Config $cfg -Ruta 'security.autoUpdates' -PorDefecto 'install'
$auMapa = @{ notify = 2; install = 4; 'install-and-restart-off' = 3 }
$auPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-GvmRegistryValue -Path $auPol -Name 'NoAutoUpdate' -Value 0 -Type DWord -Comentario 'las actualizaciones automaticas se dejan activas' | Out-Null
Set-GvmRegistryValue -Path $auPol -Name 'AUOptions' -Value $auMapa[$au] -Type DWord | Out-Null
Set-GvmRegistryValue -Path $auPol -Name 'ScheduledInstallDay' -Value 0 -Type DWord | Out-Null
Set-GvmRegistryValue -Path $auPol -Name 'ScheduledInstallTime' -Value 4 -Type DWord -Comentario 'madrugada: fuera de tus partidas' | Out-Null
Add-Item 'Windows Update' 'aplicado' "$au (AUOptions=$($auMapa[$au]), instalacion programada 04:00)"
if ($au -ne 'install') { Add-Item 'Windows Update' 'aviso' "has elegido '$au': una VM expuesta a Internet sin parches es un riesgo real" }
if (Get-GvmConfigValor -Config $cfg -Ruta 'windows.disableAutoUpdates' -PorDefecto $false) {
    Add-Item 'Windows Update' 'aviso' 'windows.disableAutoUpdates=true en el config: NO se desactiva el servicio, pero queda anotado como desviacion'
}

# --- 3. Red de autenticacion y sesiones --------------------------------------
Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'everyoneincludesanonymous' -Value 0 -Type DWord | Out-Null
Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RestrictAnonymous' -Value 1 -Type DWord | Out-Null
Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Value 3 -Type DWord -Comentario 'NTLMv2 + session security: mantiene RDP/NLA funcionando' | Out-Null
Set-GvmRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'limitblankpassworduse' -Value 1 -Type DWord | Out-Null
Add-Item 'LSA' 'aplicado' 'anonymous y NTLM restringidos; sesiones de invitado locales no aplican'

# TLS fuerte para .NET (el host de RDP ya negocia TLS1.2+)
foreach ($hive in 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319') {
    Set-GvmRegistryValue -Path $hive -Name 'SchUseStrongCrypto' -Value 1 -Type DWord | Out-Null
    Set-GvmRegistryValue -Path $hive -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord | Out-Null
}
Add-Item 'TLS' 'aplicado' 'TLS 1.2 forzado en .NET para las utilidades del host'

# --- 4. Ruido de red local ----------------------------------------------------
Set-GvmRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -Value 0 -Type DWord -Comentario 'LLMNR desactivado (mitiga NetBIOS/LLMNR poisoning desde la red de la VM)' | Out-Null
try {
    foreach ($nc in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop)) {
        if ($nc.TcpipNetBIOSDisabled -ne $true) { $nc.SetTcpipNetbios(2) | Out-Null }
    }
    Add-Item 'NetBIOS' 'aplicado' 'desactivado en los adaptadores IP-enabled'
} catch { Add-Item 'NetBIOS' 'aviso' "no se pudo configurar por WMI: $($_.Exception.Message)" }

# --- 5. Auditoria de sesiones remotas ----------------------------------------
if (Get-GvmConfigValor -Config $cfg -Ruta 'security.auditLogging' -PorDefecto $true) {
    foreach ($sub in 'Logon/Logoff', 'Object Access', 'Policy Change', 'Account Management') {
        auditpol.exe /set /subcategory:"$sub" /success:enable /failure:enable 2>&1 | Out-Null
    }
    Add-Item 'Auditoria' 'aplicado' 'eventos de sesion/entrada/salida en el Event Log (TerminalServices-LocalSessionManager)'
}

# --- 6. Bloqueo de pantalla ---------------------------------------------------
$bloqueo = [int](Get-GvmConfigValor -Config $cfg -Ruta 'security.screenLockMinutes' -PorDefecto 0)
if ($bloqueo -gt 0) {
    Set-GvmRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'inactivityhp' -Value ($bloqueo * 60) -Type DWord -Comentario '"Interactive logon: Machine inactivity limit"' | Out-Null
    Add-Item 'bloqueo por inactividad' 'aplicado' "$bloqueo min"
} else {
    Add-Item 'bloqueo por inactividad' 'aviso' '0 minutos (sin bloqueo): normal en una VM de juego personal, pero si compartes el equipo considera 15'
}

# --- 7. Comprobacion de exposicion -------------------------------------------
foreach ($par in @(@{ p = 5985; n = 'WinRM HTTP' }, @{ p = 5986; n = 'WinRM HTTPS' }, @{ p = 22; n = 'SSH' }, @{ p = 5900; n = 'VNC' })) {
    $escuchando = @(Get-NetTCPConnection -State Listen -LocalPort $par.p -ErrorAction SilentlyContinue)
    $regla = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -contains "$($par.p)" -and $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
    if ($escuchando.Count -gt 0 -and $regla.Count -gt 0) { Add-Item "exposicion $($par.n)" 'aviso' "puerto $($par.p) abierto en el firewall y a la escucha: verificale en el NSG/Security Group del proveedor" }
    else { Add-Item "exposicion $($par.n)" 'aplicado' "sin acceso entrante libre por $($par.p)" }
}
$winrm = Get-Service -Name WinRM -ErrorAction SilentlyContinue
if ($winrm -and $winrm.Status -eq 'Running' -and (Get-GvmConfigValor -Config $cfg -Ruta 'remote.type') -ne 'none') {
    Add-Item 'WinRM' 'aviso' 'el servicio esta corriendo (lo usa el agente del proveedor): asegurate de que el NSG no expone 5985/5986'
}

# --- 8. Cifrado del disco de datos (solo a peticion explicita) ---------------
if (Get-GvmConfigValor -Config $cfg -Ruta 'security.bitlockerDataDisk' -PorDefecto $false) {
    if (-not $ClaveBitlockerSalida) {
        Add-Item 'BitLocker D:' 'aviso' 'se pidio bitlockerDataDisk=true pero no se indico -ClaveBitlockerSalida: NO se cifra nada (la clave de recuperacion debe guardarse FUERA de la VM)'
    } elseif (Test-Path -LiteralPath 'D:\') {
        if ($PSCmdlet.ShouldProcess('D:', 'Enable-BitLocker')) {
            try {
                $prot = Enable-BitLocker -MountPoint 'D:' -EncryptionMethod XtsAes256 -UsedVolumeOnly $true -RecoveryPasswordProtector -ErrorAction Stop
                (Get-BitLockerVolume -MountPoint 'D:').KeyProtector | ForEach-Object { $_.RecoveryPassword } | Set-Content -LiteralPath $ClaveBitlockerSalida -Encoding UTF8
                Add-Item 'BitLocker D:' 'aplicado' "cifrado solo de espacio usado; clave escrita en $ClaveBitlockerSalida (BORRA este fichero en cuanto lo hayas guardado fuera)"
            } catch { Add-Item 'BitLocker D:' 'aviso' "no se pudo cifrar: $($_.Exception.Message)" }
        }
    } else { Add-Item 'BitLocker D:' 'aviso' 'no existe la unidad D:' }
}

# --- 9. Perfil de energia del adaptador de red (no ahorrar bateria en la VM) --
foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
    try {
        if (Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue) {
            Disable-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            Add-Item "energia NIC $($a.Name)" 'aplicado' 'ahorro de energia del adaptador desactivado (recorte de latencia)'
        }
    } catch { Add-Item "energia NIC $($a.Name)" 'aviso' "el driver no expone el control: $($_.Exception.Message)" }
}

$hallazgos = @(
    New-GvmHallazgo -Item 'Linea base' -Nivel OK -Detalle "$aplicados medidas aplicadas"
    if ($avisos -gt 0) { New-GvmHallazgo -Item 'Desviaciones' -Nivel WARN -Detalle "$avisos avisos (ver detalle en el informe)" }
    New-GvmHallazgo -Item 'No cubierto por este proyecto' -Nivel INFO -Detalle 'la red del proveedor (NSG/Security Group, diagnosticos, backups del disco) y las credenciales siguen siendo responsabilidad tuya: ver infra/ y docs/04-seguridad.md'
)
New-GvmInforme -Nombre 'seguridad' -Datos ([pscustomobject]@{ items = $detallado; autoUpdates = $au; bloqueoMin = $bloqueo }) -Hallazgos $hallazgos | Out-Null

Write-GvmLog -Nivel OK -Fase $Fase -Mensaje "linea base de seguridad: $aplicados aplicados, $avisos avisos"
[pscustomobject]@{ Aplicados = $aplicados; Advertencias = $avisos; Detallado = $detallado }
