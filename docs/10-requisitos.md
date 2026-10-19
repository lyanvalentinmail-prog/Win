# 10 · Requisitos (checklist antes de empezar)

## Lo que tienes que tener antes de ejecutar nada

| Requisito | Detalle | Como comprobarlo |
| --- | --- | --- |
| Cuenta con **método de pago** en el proveedor | Azure con suscripción Pay-as-you-go, AWS con pago por uso, o un host KVM propio | no hay ruta "gratis": `cost.acknowledgePaidResources` existe para que nadie se sorprenda |
| Cuota para el SKU | los SKU NV/ serie G tienen cuota por región | `az vm list-skus` / `aws service-quotas` / capacidad local |
| Windows **con licencia** | en Azure/AWS la licencia va en el precio de la imagen; en KVM necesitas tu licencia válida para la edición elegida | `config/vm.json -> windows.edition` y los EULA del proveedor |
| 2 vCPU y 4 GiB **mínimo** | real: 6 vCPU y 16 GiB para jugar decentemente en la nube | `config/provider-limits.json` |
| 64 GiB de disco del SO | el schema lo exige (`osDiskGiB >= 64`) | `validate.py` te lo dice |
| Disco persistente si quieres conservar algo | Azure: disco gestionado (Terraform lo crea); AWS: EBS; KVM: qcow2 en pool | 128 GiB si solo escribes, 512 GiB+ si hay juegos |
| GPU para el canal de juego | A10 vGPU (Azure NV), T4/A10G/L4 (AWS G), o passthrough (KVM) | `Install-GpuDriver.ps1` y `Test-GamingReadiness.ps1` lo verifican **en la máquina** |
| Cliente Windows App o Moonlight | Windows App: Android 11+, iOS, Windows, macOS; Moonlight: Android/iOS/PC | instalarlo y probarlo antes de configurar nada en la VM |
| Red | 15-25 Mbps estables y < 60 ms de RTT es el mínimo razonable; el egreso se factura | `scripts/client/Test-ConexionRemota.ps1` |
| PowerShell | **5.1** (el que trae Windows) o 7.x; los scripts se prueban en ambos (CI) | `$PSVersionTable` |
| Python 3.9+ para el validador | solo en tu estación, no en la VM | `python scripts/validate/validate.py` |
| Terraform ≥ 1.6 y la CLI del proveedor | solo para crear la infraestructura | `terraform version` |

## Requisitos de software dentro de la VM

| Componente | Que hace | Si falta |
| --- | --- | --- |
| winget (App Installer) | instalar las apps del catálogo | Server 2022/2019: hay que bootstrapear (`aka.ms/getwinget` + VCLibs) o la fase `apps` reporta `sin-dependencia` |
| .NET Framework 4.8 / Visual C++ Redistributables | Steam, Epic y varios juegos | el bootstrap instala los del catálogo que están en winget (`Microsoft.VCRedist.*`) |
| Driver NVIDIA GRID (Azure NV) | que el adaptador aparezca sin Code 43 y haya NVENC | sin él: `driver-pendiente` y gaming desactivado |
| Windows Audio + "Audio and Video Playback Redirection" | sonido en el cliente | en Server hay que habilitar el servicio de audio; la fase `remoto` lo intenta y lo informa |
| Servicio de escritorio remoto | el acceso en sí | `Set-RemoteDesktop.ps1` habilita RDP; el rol RDS **no** hace falta |
| Defender y actualizaciones | nada que negociar | `Set-SecurityBaseline.ps1` los deja activos |
| PowerToys Keyboard Manager (opcional) | remapeos de teclas declarados en los perfiles | se queda en `pendientes` con la instrucción manual |

## Requisitos por perfil de juego

Cada `gaming/profiles/*.json` declara `requisitos` con su `fuente` (página oficial, no un
foro) y `compatibilidadVm`. El bootstrap respeta esas condiciones: un juego que pide 8 GiB
de VRAM y una GPU que no está no se instala "a ver si va".

## Tamaño de VM recomendado (y su coste relativo)

| Objetivo | SKU orientativo | Nota |
| --- | --- | --- |
| Escritorio + utilidades, sin juegos | `Standard_D4ads_v5` (sin GPU) | 4 vCPU/16 GiB; gaming desactivado y reportado |
| eSports a 1080p60, indie, emulation | `Standard_NV6ads_A10_v5` (6 vCPU/55 GiB/A10 4 GiB) | la vía "por defecto" del repo |
| AAA a 1080p con ajustes medios | `Standard_NV12ads_A10_v5` (12 vCPU/110 GiB/8 GiB) | más CPU y más VRAM, mismo límite de "GPU virtual" |
| Pruebas de despliegue, no de juego | cualquier `Standard_NV*ads` en **spot** | `infra/azure/variables.tf -> spot_priority` + `config/vm.json -> vm.spot` |

**Ninguna de estas filas es una oferta**: el precio del día está en la página de precios de
Azure/AWS de tu región y lo paga tu cuenta. La fórmula de consumo de tráfico está en
`config/gaming-presets.json` y el detalle en `gaming/gastos.md`.

## Lo que **no** necesitas (y a veces te van a intentar vender)

- Un "servicio de cloud gaming" de terceros, ni sus apps.
- Un cliente RDP "premium" con supuestos gamepad: Windows App es el cliente.
- Un programa de optimización de RAM/CPU de pago: `Set-GamingOptimizations.ps1` hace lo que
  se puede hacer con documentación, y nada más.
- Drivers "gaming" descargados de un mirror: `gpu.instaladorUrl` apunta **solo** al origen
  oficial y se valida la firma Authenticode antes de ejecutarlo.
- Una cuenta Microsoft compartida: la VM se usa con tus credenciales, dentro de tu sesión.
