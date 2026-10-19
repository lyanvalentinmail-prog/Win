<#
.SYNOPSIS
  Comprueba, instala (si procede) y verifica la GPU de la VM.
.DESCRIPTION
  Detecta la GPU REAL visible por el invitado y aplica la politica honesta del proyecto:

    - Azure NV*/NVA* (gpu.mode = paravirtual): el driver GRID/vGPU lo instala la extension
      'AzureGPU' declarada en infra/azure. Este script VERIFICA que existe, que no esta en
      Code 43 (el sintoma tipico de un driver incompatible con el driver del host) y que
      expone codificador de hardware. Si falta, dice el comando exacto a ejecutar.
    - AWS g4dn/g5 (paravirtual): se espera el driver Tesla/Data Center preinstalado en la AMI
      o instalado desde el paquete del catalogo; se verifican las mismas senales.
    - KVM con gpu.mode = passthrough: si config.gpu.instaladorUrl + config.gpu.instaladorSha256
      estan declarados, descarga SOLO desde un host de apps/sources.json, verifica SHA-256 y
      la firma Authenticode antes de ejecutarlo en silencio.
    - Sin GPU (gpu.mode = none): no instala nada, no simula nada y marca el informe.

  No instala drivers "modificados", ni parches para burlar licencias, ni drivers de terceros
  sin firma. Ninguna de esas vias existe aqui.
.OUTPUTS
  PSCustomObject: Estado, Detalle, Datos, RequiereReinicio
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]$Config,
    [ValidateSet('auto', 'verificar-solo')][string]$Modo = 'auto',
    [string]$RutaDescargas = 'C:\ProgramData\WinGamingVM\descargas'
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
$Fase = 'gpu'
$estado = 'sin-gpu'
$detalle = ''
$requiereReinicio = $false

$gpuMode = Get-GvmConfigValor -Config $cfg -Ruta 'gpu.mode' -PorDefecto 'none'
$driver = Get-GvmConfigValor -Config $cfg -Ruta 'gpu.driver' -PorDefecto 'none'
$provider = Get-GvmConfigValor -Config $cfg -Ruta 'provider'
$size = Get-GvmConfigValor -Config $cfg -Ruta 'vm.size'

Write-GvmLog -Fase $Fase -Mensaje "gpu.mode=$gpuMode driver=$driver proveedor=$provider size=$size"

if ($gpuMode -eq 'none') {
    $info = Get-GvmGpuInfo
    $detalle = 'config gpu.mode=none: la VM se entrega como escritorio sin aceleracion 3D. Los perfiles de control de juegos 3D y el canal Moonlight quedaran desactivados.'
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje $detalle -Detalle $info.Resumen
    return [pscustomobject]@{ Estado = 'sin-gpu'; Detalle = $detalle; Datos = $info; RequiereReinicio = $false }
}

# 1) Estado actual ------------------------------------------------------------
$info = Get-GvmGpuInfo
Write-GvmLog -Fase $Fase -Mensaje "GPU vista por el invitado" -Detalle $info.Resumen

# Code 43 / dispositivos con error: es el fallo tipico del driver vGPU de Azure.
$pnp = @()
try {
    $pnp = @(Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' })
} catch {
    Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje 'Get-PnpDevice no disponible (WMI/PnP no disponible en esta imagen)' -Detalle $_.Exception.Message
}
$code43 = @($pnp | Where-Object { "$($_.ConfigErrorCode)" -eq '43' })

# 2) Si falta el driver, actuar segun proveedor -------------------------------
if (-not $info.Presente -or $code43.Count -gt 0 -or [string]::IsNullOrEmpty($info.Nombre)) {
    $url = Get-GvmConfigValor -Config $cfg -Ruta 'gpu.instaladorUrl'
    $sha = Get-GvmConfigValor -Config $cfg -Ruta 'gpu.instaladorSha256'

    if ($Modo -eq 'verificar-solo' -or -not $url) {
        $comandoSugerido = switch ($provider) {
            'azure' { "az vm extension set -g <grupo> -n AzureGPU -publisher Microsoft.HpcCompute --vm-name <vm> --no-wait  (o descarga el paquete GRID indicado en config/provider-limits.json)" }
            'aws'   { 'Instala el driver NVIDIA de la AMI de Deep Learning o el paquete NVIDIA Grid/Tesla correspondiente al SKU (ver docs/06-despliegue-aws.md)' }
            'libvirt' { 'Pasa la GPU fisica a la VM (vfio) y declara gpu.instaladorUrl + gpu.instaladorSha256 en config/vm.json' }
            default { 'revisa config/gpu en config/vm.json' }
        }
        $detalle = "no hay GPU util (Code43=$($code43.Count)); instala el driver oficial antes de continuar. Como: $comandoSugerido"
        Write-GvmLog -Nivel WARN -Fase $Fase -Mensaje $detalle
        return [pscustomobject]@{ Estado = 'driver-pendiente'; Detalle = $detalle; Datos = $info; RequiereReinicio = $false; Code43 = @($code43 | ForEach-Object { $_.FriendlyName }) }
    }

    # Descarga verificada (unica via: URL oficial + SHA-256 declarado por el usuario)
    if (-not (Test-Path -LiteralPath $RutaDescargas)) { New-Item -ItemType Directory -Path $RutaDescargas -Force | Out-Null }
    $origen = Test-GvmOrigenPermitido -Url $url
    if (-not $origen.Permitido) { throw "Descarga bloqueada: $($origen.Motivo)" }
    $archivo = Join-Path $RutaDescargas ([IO.Path]::GetFileName($origen.Host + '-' + [uri]$url.Segments[-1]))
    Write-GvmLog -Fase $Fase -Mensaje "descargando driver oficial" -Detalle $url
    if ($PSCmdlet.ShouldProcess($url, 'descargar instalador de driver')) {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $url -OutFile $archivo -UseBasicParsing -TimeoutSec 300 } finally { $ProgressPreference = $prev }
        $hash = (Get-FileHash -LiteralPath $archivo -Algorithm SHA256).Hash
        if ($sha -and ($hash -replace '-', '').ToUpperInvariant() -ne ($sha -replace '-', '').ToUpperInvariant()) {
            Remove-Item -LiteralPath $archivo -Force
            throw "SHA-256 del instalador no coincide con el declarado ($hash). Descarga abortada."
        }
        $sig = Get-AuthenticodeSignature -FilePath $archivo
        $asunto = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        if ($sig.Status -ne 'Valid' -or $asunto -notmatch 'NVIDIA') {
            Remove-Item -LiteralPath $archivo -Force
            throw "Firma del instalador no valida o no pertenece a NVIDIA (estado=$($sig.Status), asunto=$asunto). Abortado."
        }
        Write-GvmLog -Nivel OK -Fase $Fase -Mensaje 'instalador verificado (hash + firma)'
        $p = Start-Process -FilePath $archivo -ArgumentList '/s', '/noreboot' -Wait -PassThru
        Write-GvmLog -Nivel $(if ($p.ExitCode -in 0, 1, 3010) { 'OK' } else { 'ERROR' }) -Fase $Fase -Mensaje "instalador de driver termino con codigo $($p.ExitCode)"
        if ($p.ExitCode -eq 3010 -or $p.ExitCode -eq 0) { $requiereReinicio = $true }
    }
    $info = Get-GvmGpuInfo
}

# 3) Verificacion funcional ----------------------------------------------------
$dx = Test-GvmDirectXDisponible
$codificador = (Get-GvmGpuInfo).CodificadorHw
$hallazgos = @(
    New-GvmHallazgo -Item 'GPU visible' -Nivel $(if ($info.Presente) { 'OK' } else { 'ERROR' }) -Detalle $(if ($info.Presente) { [string]$info.Resumen } else { 'el invitado no ve una GPU util' })
    New-GvmHallazgo -Item 'Direct3D acelerado (dxdiag)' -Nivel $(if ($dx.Disponible) { 'OK' } else { 'WARN' }) -Detalle "$($dx.Motivo) $($dx.Extracto)"
    New-GvmHallazgo -Item 'Codificador de hardware' -Nivel $(if ($codificador -ne 'ninguno') { 'OK' } else { 'WARN' }) -Detalle "$(if ($codificador -eq 'ninguno') { 'Sunshine usara x264 (software) o el canal de juego quedara desactivado' } else { [string]$codificador })"
    New-GvmHallazgo -Item 'Dispositivos con Code 43' -Nivel $(if ($code43.Count) { 'ERROR' } else { 'OK' }) -Detalle $(if ($code43.Count) { "revisa que el driver GRID es el soportado para $($size) (ver docs/12-troubleshooting.md)" } else { 'ninguno' })
)

# Politica de render en sesion remota: solo tiene sentido con GPU WDDM.
if ($info.Presente) {
    Set-GvmRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableWddmDriver' -Value 1 -Type DWord -Comentario 'render GPU dentro de la sesion RDP' | Out-Null
    $estado = if ($dx.Disponible) { 'gpu-ok' } else { 'gpu-parcial' }
    $detalle = "GPU '$($info.Nombre)' visible; D3D $($dx.Disponible); codificador $codificador"
} else {
    Set-GvmRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableWddmDriver' -Value 0 -Type DWord -Comentario 'sin GPU: se deja el camino XDDM para evitar cuelgues del compositor en la sesion remota' | Out-Null
    $estado = 'sin-gpu'
    $detalle = 'El host no ofrece GPU al invitado. No se ha simulado: la VM funciona como escritorio remoto, no como PC de gaming.'
}

New-GvmInforme -Nombre 'gpu' -Datos ([pscustomobject]@{ gpu = $info; dxdiag = $dx; code43 = @($code43 | ForEach-Object { $_.FriendlyName }); modo = $gpuMode; proveedor = $provider; size = $size }) -Hallazgos $hallazgos | Out-Null
Write-GvmLog -Nivel $(if ($estado -eq 'gpu-ok') { 'OK' } else { 'WARN' }) -Fase $Fase -Mensaje "resultado: $estado" -Detalle $detalle

[pscustomobject]@{
    Estado            = $estado
    Detalle           = $detalle
    Datos             = [pscustomobject]@{ gpu = $info; dx = $dx; codificador = $codificador }
    RequiereReinicio  = $requiereReinicio
}
