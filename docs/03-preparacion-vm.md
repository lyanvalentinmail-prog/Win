# 03 · Preparación de la VM (bootstrap fase a fase)

`scripts/win/Bootstrap-GamingVM.ps1` es el punto de entrada dentro de Windows. Ocho fases
idempotentes, con registro en fichero, punto de control por fase y un informe final.

## Ejecución

```powershell
# Como Administrador, dentro de la VM, con el repo copiado en C:\ProgramData\WinGamingVM
Set-Location C:\ProgramData\WinGamingVM\scripts\win
.\Bootstrap-GamingVM.ps1                      # todas las fases
.\Bootstrap-GamingVM.ps1 -Fases preflight      # solo comprobaciones
.\Bootstrap-GamingVM.ps1 -Reanudar             # retoma donde se cortó
.\Bootstrap-GamingVM.ps1 -Forzar -Fases apps   # repite una fase
.\Bootstrap-GamingVM.ps1 -WhatIf               # qué haría, sin tocar nada
```

Desde tu estación, sin RDP: `scripts/deploy/azure-deploy.ps1` (Azure, por Run Command) o
`scripts/deploy/aws-ssm.ps1` (AWS, por SSM). En KVM, copia el repo con `virt-copy-in` o
monta una ISO y ejecuta dentro de la sesión.

## Las ocho fases

| # | Fase | Script | Qué hace | Si falta algo |
| --- | --- | --- | --- | --- |
| 1 | `preflight` | el propio bootstrap | admin, edición y build de SO, disco libre, winget, GPU, configuración validada, checkpoint de registro | aborta con lista de requisitos y salida `2` |
| 2 | `gpu` | `Install-GpuDriver.ps1` | instala o **verifica** el driver según `gpu.instaladorDesde`; detecta Code 43; deja `fEnableWddmDriver` según lo que la máquina informe | `sin-gpu` → el resto de fases se ajustan y el informe lo declara |
| 3 | `escritorio` | `Set-GamingOptimizations.ps1` | plan de energía, GameDVR, HAGS (solo con GPU), último acceso, efectos visuales, tema/fondo/resolución, limpieza de procesos y servicios con listas de exclusión | `aviso` por cada cosa que la edición no permita |
| 4 | `remoto` | `Set-RemoteDesktop.ps1` | habilita RDP, aplica `config/remote-session.json` (profundidad de color, redirecciones, UDP, AVC, tiempos de inactividad/reconexión), firewall solo hacia `allowedCidrs`, escribe `acceso-windows-app.md` | sin túnel y sin CIDR → deja las reglas **deshabilitadas** y explica cómo proceder |
| 5 | `apps` | `Install-Apps.ps1` | catálogo + selecciones + `apps.custom`: compatibilidad de edición, GPU, Store, `bloqueadoEnVm`, método soportado, host de descarga en la allow-list, verificación de firma post-instalación, CSV de resultados | `pendiente-manual`, `omitida`, `rechazada-fuente` — nunca "instalada" a medias |
| 6 | `gaming` | `Set-Sunshine.ps1` + `Set-TouchControls.ps1` | Sunshine (config, codificador real, puertos con alcance, tarea de consola), perfiles de control, sensibilidad de ratón, ficheros de PowerToys, fichas de layout | sin GPU → `desactivado-sin-gpu`; `gaming.channel=rdp` → `desactivado` |
| 7 | `seguridad` | `Set-SecurityBaseline.ps1` | Defender (solo lectura + actualización de firmas), actualizaciones, endurecimiento LSA/SChannel/LLMNR, auditoría, bloqueo por inactividad, revisión de puertos expuestos, energía del adaptador | cada desviación queda como `aviso` con el motivo |
| 8 | `informe` | `Test-GamingReadiness.ps1` | 15+ comprobaciones y veredicto en `informes\preparacion-*.md` | salida `2` si hay bloqueos de nivel ERROR |

## Estado, reanudación y reinicios

`state\fases.json` guarda por fase: `estado` (`pendiente|en-curso|completada|fallida`),
`últimoError`, `iniciadaEl`, `completadaEl`, `requiereReinicio`. Cuando una fase marca
`requiereReinicio` y el bootstrap se lanzó con `GVM_AUTO_REBOOT=1`, crea la tarea
`WinGamingVM-Reanudar` (`schtasks /SC ONSTART /RU SYSTEM`) y reinicia: tras el arranque, la
tarea retoma la fase siguiente y se autoelimina. En manual: reinicia tú y ejecuta
`.\Bootstrap-GamingVM.ps1 -Reanudar`.

Si una fase quedó en `en-curso` (corte de luz, timeout del Run Command), el bootstrap
**no** la repite a ciegas: avisa y espera `-Forzar`.

## Registro y ficheros generados

```text
C:\ProgramData\WinGamingVM\
  logs\bootstrap-AAAAMMDD-HHMMSS.log      todo, con marca de tiempo y fase
  state\fases.json                        checkpoints
  backup\reg-backup-*.reg                 respaldo previo a cada clave tocada
  informes\preparacion-*.md|.json         informe de la fase 8
  informes\apps-instalacion.csv           resultado de cada app
  controles\<perfil>.moonlight.md         ficha de layout táctil por perfil
  controles\<perfil>.layout.json          geometría normalizada
  acceso-windows-app.md                   cómo conectar (IP, puerto, usuario, túnel)
```

El log **nunca** incluye contraseñas ni tokens: los scripts no los piden (la autenticación
es la de tu sesión de Windows o la del proveedor).

## Errores típicos y qué significan

| Mensaje | Causa | Acción |
| --- | --- | --- |
| `Ejecuta este script en una consola elevada` | sin privilegios de administrador | PowerShell (Administrador) |
| `config/vm.json no valida el esquema` | campo mal escrito o no permitido | `python scripts/validate/validate.py` en tu estación |
| `winget no disponible en esta imagen` | Server 2022 sin bootstrap de App Installer | la fase `apps` marca `sin-dependencia`; instala el paquete de Microsoft o usa `metodo: manual` |
| `Code 43 en el adaptador` | driver GRID incorrecto o ausente | `gpu.instaladorDesde: extension-azure` y repite `-Forzar -Fases gpu,escritorio` |
| `rechazada-fuente` | el host de descarga no está en `apps/sources.json` | añade el host **verificando que es el oficial** o corrige el catálogo |
| `desactivado-sin-gpu` | sin codificador de hardware | acepta el límite o cambia de SKU; no hay ajuste mágico |
| `pendiente-manual` | el proyecto no automatiza ese método (Store, licencias, OEM) | sigue los `pasosManuales` del catálogo/perfil |

## Qué NO hace el bootstrap

- No abre puertos a Internet sin que tú los declares.
- No desactiva Defender ni Windows Update; puede **excluir** carpetas solo si lo pides
  explícitamente (`security.defender` con `enable-with-exclusions`).
- No instala nada desde un mirror ni desde un `.exe` suelto que no esté en el catálogo.
- No crea ni destruye la VM: eso es Terraform/CLI del proveedor.
- No genera licencias ni activa Windows: la licencia la aporta el proveedor (Azure/AWS) o
  la tuya (KVM).
