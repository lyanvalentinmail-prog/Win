# Ajustes de Windows aplicados (y por qué)

Todo lo que el bootstrap toca está aquí. Si un ajuste no aparece, **no se aplica**.

## Energía y CPU

| Ajuste | Clave / comando | Efecto | Riesgo |
|---|---|---|---|
| Plan **Ultimate Performance** | `powercfg /setactive e9a42b02-d5df-448d-aa66-ad2b75f7b8bb` (o duplicado de High Performance) | Quita el aparcamiento agresivo de núcleos | En VM, parte del control lo tiene el host: no esperes milagros |
| Aparcamiento de núcleos **desactivado** | `powercfg -setacvalueindex <plan> SUB_PROCESSOR CPMINCORES 100` | Menos migración de hilos entre núcleos | Sube el consumo; inútil si el hipervisor reparte vCPU |
| Sleep/Hibernate | `powercfg /h off`, subgrupos Sleep → 0 | Evita que la VM "duerma" en sesión | Ninguno en nube |
| Modo juego | `HKCU\Software\Microsoft\GameBar` `AutoGameModeEnabled=1` | Prioridad al juego, silencia notificaciones | En Server no existe la app: el script lo detecta y lo omite |
| Game DVR / Capturas | `HKCU\...\GameDVR` `AppCaptureEnabled=0`, `BackgroundCaptureEnabled=0`, `GameDVR_Enabled=0` | Quita el overhead de grabación en segundo plano | Pierdes la grabación de Xbox Game Bar (usa OBS o el cliente) |
| HAGS (programación de GPU acelerada por hardware) | `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` `HwSchMode=2` | Menos latencia CPU↔GPU con drivers WDDM | Requiere WDDM + driver compatible; **en vGPU puede no estar expuesto**: el script solo lo activa si `Test-GamingReadiness` ve GPU válida |
| Hardware Scheduling en Steam | Steam → Ajustes → Juegos → *Programación de hardware* | Coherencia con HAGS | — |
| Indexado, SysMain, Superfetch en D: | `DisableLastAccessUpdate`, excluir `D:\Juegos` de Windows Search | Menos IOPS de fondo | Ninguno |

## Red y latencia

| Ajuste | Clave |
|---|---|
| Autotuning de recibe | `netsh int tcp set global autotuninglevel=normal` |
| ECN | `netsh int tcp set global ecncapability=enabled` (si el camino lo soporta) |
| RSC/RSS en la NIC | `Get-NetAdapterRss` / `Set-NetAdapterRsc -Disable 1` solo si el driver lo expone y hay < 8 colas |
| DNS | Fijar el resolver de la VPC/región para bajar la latencia de las primeras peticiones |
| QoS de "juegos" del SO | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile` `NetworkThrottlingIndex=0xffffffff` |

## Sesión remota (lo que realmente cambia la experiencia)

Ver `config/remote-session.json`. En resumen: `fEnableWddmDriver=1` (render WDDM en
RDP), `AVC444ModePreferred=1`, `AVCHardwareEncodePreferred=1`, `bEnumerateHWBeforeSW=1`,
profundidad 32 y UDP. **Si no hay GPU, nada de esto simula aceleración**: el auditor
informa `avc444: no aplicable (sin GPU)` en lugar de fingir que está activo.

## GPU y VRAM

- `Get-GpuInfo` (módulo `GamingVM`) lee `Win32_VideoController` +
  `nvidia-smi` si existe, y devuelve `gpuPresente`, `vramGiB`, `codificadorHw`
  (`nvenc|amf|qsv|ninguno`), `modoRender` (`wddm|xddm|software`) y
  `licenciaGrid` (solo informativo).
- Con `gpu.mode=none`, `Set-GamingOptimizations.ps1` **no** toca HAGS, no fija AVC
  4:4:4 "por si acaso" y no instala perfiles de control táctil para juegos 3D: informa.

## Lo que este proyecto NO hace

- No desactiva Windows Defender, Firewall, UAC ni actualizaciones de seguridad.
- No escribe claves de licencia, ni activadores, ni "evaluation reset".
- No instala drivers genéricos "game ready" en Server si el SKU del proveedor exige
  un driver vGPU específico (Azure: se usa la extensión `AzureGPU` o el paquete oficial
  indicado en `config/provider-limits.json`).
- No promete 120/240 Hz en RDP ni "consola nativa en la nube".
