# scripts/

```text
win/       lo que corre DENTRO de la VM (Windows PowerShell 5.1 o 7)
deploy/    lo que corre en TU ESTACION para Orquestar el proveedor (az, aws, terraform)
client/    lo que corre en TU EQUIPO cliente (preparar Windows App, tuneles, medir el canal)
linux/     lo que corre en el HOST KVM (diagnostico VFIO + creacion con virt-install)
validate/  el validador del repositorio (Python), sin ejecucion en la VM
```

## scripts/win

| Script | Rol |
| --- | --- |
| `Bootstrap-GamingVM.ps1` | orquesta las 8 fases, con checkpoints, `-Reanudar`, `-Forzar`, `-Simulacion`, `-Fases` |
| `Install-GpuDriver.ps1` | driver GRID/passthrough o verificacion; detecta Code 43; nunca inventa una GPU |
| `Set-GamingOptimizations.ps1` | plan de energia, GameDVR, HAGS, efectos, fondo/resolucion, limpieza de procesos/servicios con listas de exclusion |
| `Set-RemoteDesktop.ps1` | RDP + politicas de sesion + firewall + guia `acceso-windows-app.md` |
| `Install-Apps.ps1` | catalogo + selecciones + `apps.custom`, con verificacion de firma y CSV de resultados |
| `Set-Sunshine.ps1` | canal de juego (config, codificador real, puertos con alcance, tarea de consola) |
| `Set-TouchControls.ps1` | sensibilidad de raton, remapeos (PowerToys), fichas de layout para el cliente |
| `Set-SecurityBaseline.ps1` | Defender, actualizaciones, LSA/TLS, auditoria, bloqueo, energia del adaptador, expocion de puertos |
| `Test-GamingReadiness.ps1` | informe final de preparacion (exit 2 si hay bloqueos) |
| `Get-SystemMetrics.ps1` | medicion: punto / rendimiento / ping / sesion, con CSV |
| `Unlock-ConsoleSession.ps1` | devuelve la sesion a la consola (`tscon`) para Sunshine; corta tu RDP |
| `Remove-GamingVM.ps1` | revierte registro/reglas/tareas/PowerToys y ofrece desinstalar las apps |
| `Modules/GamingVM/` | logging, checkpoints, config, registro con respaldo, firma, winget, GPU, informes |

Convenciones de todos los scripts: `Set-StrictMode -Version 1.0` (leer propiedades opcionales
de un JSON con `Latest` lanzaria), `$ErrorActionPreference='Stop'`, `SupportsShouldProcess`
en lo que escribe, documentacion `Comment-based` (`Get-Help`), salidas por `Write-GvmLog`
(consola + `logs/*.log`) y **ningun secreto** en pantalla ni en ficheros.

## scripts/deploy y scripts/client

`azure-deploy.ps1` y `aws-ssm.ps1` usan el canal de administracion del proveedor
(Run Command / SSM): no abren puertos ni piden la contrasena por linea de comandos.
`backup-disk.ps1` documenta instantanea de disco por proveedor.
En `client/`, `Configurar-ClienteWindowsApp.ps1` toca solo HKCU, `Montar-TunelSSH.ps1` solo
levanta el tunel, `Test-ConexionRemota.ps1` mide, y `Preparar-MandoAndroide.ps1` **no cambia
nada**: comprueba y explica.

## scripts/linux

`kvm-gpu-check.sh` (IOMMU, grupos, drivers ocupados) antes de tocar nada;
`kvm-deploy.sh` crea el dominio con `virt-install` (UEFI, vTPM, bridge, VirtIO, passthrough
opcional). `DRY_RUN=1` imprime el comando. Ambos son de host Linux: no se ejecutan en la VM.

## scripts/validate

`validate.py` es el unico ejecutable: `--solo config|apps|gaming|powershell|estructura|secretos`,
`--online` (contrasta ids de winget con GitHub), `--verbose`. Ademas: `check_links.py`
(enlaces internos de los .md) y `release_notes.py` (notas del tag desde `CHANGELOG.md`).
