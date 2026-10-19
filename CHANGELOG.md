# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/es/1.1.0/), versionado
[semántico](https://semver.org/lang/es/). Este proyecto versiona **configuración, guiones y
documentación**: no empaqueta instaladores ni imágenes, así que una nueva versión de una app
del catálogo no obliga a subir la versión del repo (se actualiza el snapshot del catálogo y
se anota `snapshotVerificadoEl`).

## [0.1.0] - 2026-10-18

Primera versión pública: despliegue completo y reproducible de una VM **real** de Windows
accesible con Windows App, con catálogo opcional de aplicaciones, canal de juego opcional y
documentación de límites por proveedor y por función.

### Añadido

- **Configuración validada** (`config/`): `vm.schema.json` (draft 2020-12,
  `additionalProperties: false`, límites de disco, modo de GPU explícito, `tunnel != none ⇒
  allowedCidrs: []`, lista negra de servicios para `power.disableUnusedServices`,
  `cost.acknowledgePaidResources` obligatorio), `vm.example.json`, `provider-limits.json`
  con vCPU/RAM/discos **reales** por SKU, `windows-editions.json`, `remote-session.json`
  (claves documentadas de `Terminal Services`), `gaming-presets.json` (4 presets + fórmula
  de tráfico) y `resolutions.json`.
- **Catálogo de aplicaciones** (`apps/`): 30 aplicaciones con `id` de winget verificado,
  URL oficial, SHA-256 cuando el manifiesto lo declara, firmante esperado y compatibilidad por
  edición/GPU/Store; `sources.json` como lista blanca de hosts vinculante; cuatro selecciones
  (`minimal`, `utilities`, `gaming`, `full`) para que **nada se instale por defecto**.
- **Scripts de la VM** (`scripts/win/`): `Bootstrap-GamingVM.ps1` con 8 fases idempotentes,
  puntos de control por fase, `-Reanudar`, `-Forzar`, `-Simulacion`, `-Fases` y reinicio con
  reanudación programada; `Install-GpuDriver.ps1` (instalación/verificación del driver GRID,
  detección de Code 43 y estados `gpu-ok|gpu-parcial|sin-gpu|driver-pendiente`);
  `Set-GamingOptimizations.ps1` (plan de energía, GameDVR, HAGS solo con GPU, fondo y
  resolución, limpieza de procesos y servicios con listas de protegidos/prohibidos);
  `Set-RemoteDesktop.ps1` (RDP + políticas de sesión + firewall con alcance + guía de
  acceso); `Install-Apps.ps1` (catálogo + selecciones + firma post-instalación + CSV);
  `Set-Sunshine.ps1` (canal de juego, codificador real, puertos restringidos, tarea de
  consola); `Set-TouchControls.ps1` (sensibilidad, PowerToys con copia previa, fichas de
  layout); `Set-SecurityBaseline.ps1`; `Test-GamingReadiness.ps1` (informe con veredicto y
  `exit 2` ante bloqueos); `Get-SystemMetrics.ps1` (punto/rendimiento/ping/sesión con CSV);
  `Unlock-ConsoleSession.ps1`; `Remove-GamingVM.ps1` (revertido desde los respaldos).
- **Módulo compartido** `scripts/win/Modules/GamingVM`: registro con niveles, checkpoints,
  resolución de configuración, respaldo `.reg` antes de tocar el registro, lista blanca de
  hosts, verificación de firma Authenticode, información de GPU y DirectX, generación de
  informes `.md`/`.json` (con copia `-latest`) y validación de requisitos.
- **Control táctil y perfiles de juego** (`gaming/`): esquema de perfil con requisitos,
  rendimiento y **antitrampas** (`vm: permitida | restringida | desconocida` + riesgo de
  baneo + fuente), esquema de layout táctil con geometría normalizada y límites por tipo de
  elemento, 7 perfiles, 5 layouts y la documentación de cómo reproducirlos en el cliente
  (Moonlight), de lo que Windows App **no** hace y de `gaming/antitrampas.md`.
- **Infraestructura** (`infra/`): Azure (RG, VNet, NSG con reglas solo para CIDR declaradas,
  IP, VM Trusted Launch, disco de datos persistente, spot opcional y precondiciones que
  cortan un gaming sin GPU antes de facturar), AWS (SG sin entrada por defecto, IMDSv2,
  EBS cifrado, user_data mínimo) y KVM (módulo Terraform honesto con `gpu_hostdev_ids` vacío
  por defecto) más `scripts/linux/kvm-deploy.sh` y `kvm-gpu-check.sh` por `virt-install`.
- **Despliegue desde la estación** (`scripts/deploy/`): `azure-deploy.ps1` (apply + entrega
  por Run Command + fases + recuperación de informes), `aws-ssm.ps1` (todo por SSM, sin
  abrir 3389) y `backup-disk.ps1` (instantánea por proveedor).
- **Cliente** (`scripts/client/`): `Configurar-ClienteWindowsApp.ps1` (solo HKCU + `.rdp`
  opcional), `Test-ConexionRemota.ps1` (TCP/RTT/jitter/MTU/TLS), `Montar-TunelSSH.ps1`,
  `Preparar-MandoAndroide.ps1` (verificación y pasos reales en el dispositivo) y
  `Perfiles-Moonlight-Cliente.md`.
- **Validación** (`scripts/validate/`): `validate.py` con seis áreas (config, apps, gaming,
  PowerShell, estructura, secretos), `check_links.py`, `release_notes.py`, requirements y
  configuración de PSScriptAnalyzer.
- **CI/CD** (`.github/workflows/`): `validate.yml` (validador + pytest + análisis de
  PowerShell + parseo con PowerShell 7), `windows-scripts.yml` (prueba de humo en un runner
  Windows real), `tf-lint.yml` (fmt/init/validate/tflint por módulo) y `release.yml` (tag =
  VERSION, sin binarios, artefactos con SHA-256).
- **Documentación en español** (`README.md` + `docs/01…12`): arquitectura, proveedores y
  límites, preparación fase a fase, aplicaciones, acceso remoto, límites de Windows App por
  función, gaming y antitrampas, medición, seguridad, requisitos, prueba de aceptación e
  ideas evaluadas con su motivo de descarte.

### Conocido

- Los números de versión y hashes del catálogo son un **snapshot de 2026-10-18**: caducan.
- La validación de `.tf` en local es de sintaxis (HCL parseado); `terraform validate` se
  ejecuta en CI, donde hay red hacia el registry.
- Ningún script toca la sesión de consola sin avisar de que corta tu conexión RDP.
- La instalación de apps que requieren la Microsoft Store, drivers con licencia propia o
  lanzadores con cuenta se reporta como `pendiente-manual`: es deliberado.
- `infra/kvm` requiere que el host tenga IOMMU/VFIO preparado; el módulo no lo configura y
  lo dice en su propio README.

[0.1.0]: https://github.com/lyanvalentinmail-prog/Win/releases/tag/v0.1.0
