# Steam Input, mandos virtuales y remapeo en el host

Tres problemas distintos, tres soluciones distintas. Mezclarlos es la fuente de
todos los tutoriales falsos de "juega desde el móvil con controles táctiles".

## A) El juego ya soporta mando → no hay que remapear nada

Moonlight/Sunshine presentan un **mando XInput** en la VM (el cliente emula un
Xbox 360 controller, o entregas un mando Bluetooth real al PC local del cliente
cuando el protocolo lo permite). Steam lo ve como cualquier mando y **Steam Input**
traduce a las teclas/botones que el juego entienda.

Ventaja: no dependes de software de terceros ni de drivers. Es la vía por defecto
de este proyecto (`gaming/touch/layouts/accion-2sticks.json`).

## B) El juego solo acepta teclado/ratón → mapear el mando a teclas

Opciones reales:

| Herramienta | Automatable | Nota |
|---|---|---|
| **Steam Input** (para juegos dentro de Steam, o añadidos como "no-Steam") | Parcial: el perfil se guarda en la cuenta y en `...\userdata\<id>\config\controllerpaks`; no hay API oficial para escribirlo en caliente. | Recomendado: se documenta abajo. |
| **AntiMicroX** (GPL, en `apps/catalog.json`) | Sí *en el PC donde corre*: perfiles XML en `%APPDATA%\antimicrox\profiles\*.xml` | **No lo automatiza este proyecto.** `Set-TouchControls.ps1` deja la entrada como `pendiente` con los pasos: AntiMicroX tiene que ejecutarse en la máquina que recibe el mando (en tu caso, la VM) y su XML no es un formato que el proyecto escriba a ciegas. |
| **PowerToys Keyboard Manager** | Sí: `remapkeys.json`/`remapshortcuts.json` por aplicación | Vale para teclado→tecla y atajos; **no** convierte mandos. |
| **AutoHotkey** | Sí | Potente, pero requiere confianza en el origen del script y añadirlo al catálogo (no incluido por defecto). |

## C) Un juego de Steam "no-Steam" o fuera de Steam

1. Steam → *Juegos* → *Añadir un juego no-Steam* → selecciona el ejecutable.
2. Botón derecho en la entrada → *Administrar* → *Mando Steam* → elegir plantilla
   `Gamepad` y editar el mapeo.
3. La plantilla queda en `.../config/config.vdf` y en `controller_config/user/<AppId>`:
   **Steam no garantiza un formato estable entre versiones**, por eso
   `Set-TouchControls.ps1` no escribe esos ficheros: documenta el paso y lo deja en
   `pasosManuales`.

## Qué automatiza `Set-TouchControls.ps1` hoy (parametros reales)

```powershell
.\Set-TouchControls.ps1 -Config C:\ProgramData\WinGamingVM\configm.json
.\Set-TouchControls.ps1 -Config ... -Perfil fortnite -AplicarEnPowerToys
.\Set-TouchControls.ps1 -Config ... -RestaurarSensibilidad
```

| Que hace | Donde queda |
| --- | --- |
| Sensibilidad del puntero de la VM a partir de `controles.sensibilidad.mouseSensitivity` del perfil (`MouseSensitivity` 1-20, `MouseSpeed`, `MouseThreshold1/2`, `SmoothMouseXCursor`) | `HKCU:\Control Panel\Mouse` (+ respaldo en el checkpoint de la fase) |
| `Remap keys` / `Remap shortcuts` declarados en el perfil, en el formato JSON de PowerToys Keyboard Manager | se preparan en `<BaseDir>\controles-powertoys\` y **solo** se copian a `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\` con `-AplicarEnPowerToys`, tras copiar el fichero previo como `*.backup-<marca>` |
| Ficha por perfil con la geometria del layout tactil (elementos, tamano, opacidad, funcion asignada) | `<disco de datos>\WinGamingVM\controles\<perfil>.moonlight.md` y `\<perfil>.layout.json` |
| Fuentes de entrada que no se pueden mapear a teclado (mando) | quedan en `pendientes` del informe, con el paso manual (Steam Input o AntiMicroX) |

**Que no hace, y no va a hacer**: escribir el layout tactil del cliente (Moonlight lo guarda
en el dispositivo), generar perfiles de Steam Input o de AntiMicroX en formatos sin contrato
estable, ni "inyectar" un mando que el protocolo no redirige. Cada una de esas cosas aparece
en el informe como `pendiente-manual` con sus pasos, no como `aplicado`.
