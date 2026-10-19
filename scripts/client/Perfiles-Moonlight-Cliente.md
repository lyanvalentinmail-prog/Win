# Perfiles de cliente Moonlight (Android/iOS/PC)

Documentacion de pasos, no un script: Moonlight guarda su configuracion en el dispositivo
y no hay API de importacion desde el host. Lo que sigue es lo que hay que tocar, con los
nombres de menu de Moonlight para Android.

## Antes de tocar nada

- La fase `gaming` debe estar en `completada` y el canal accesible
  (`Get-Process`/`netstat` o `scripts/client/Test-ConexionRemota.ps1 -Canal moonlight`).
- Si la VM no tiene GPU verificada, Moonlight va a ir lento pase lo que pase aqui:
  no hay ajustes que compensen la ausencia de codificador por hardware.

## Config global recomendada segun el preset

| Preset (config/gaming-presets.json) | Resolucion | FPS | Bitrate | Codec |
| --- | --- | --- | --- | --- |
| `movil-4g-estable` | 1280x720 | 60 | 12-20 Mbps | HEVC |
| `movil-5g-o-wifi6` | 1920x1080 | 60-90 | 25-40 Mbps | HEVC o AV1 |
| `escritorio-gpu` | 1920x1080 / 2560x1440 | 90-120 | 40-80 Mbps | AV1 si la GPU lo codifica |

En Moonlight: `Ajustes > Video > Resolucion / FPS / Bitrate / Codec`. Si el host no anuncia
AV1, la opcion aparece pero no se usara: `Install-GpuDriver.ps1` y el log de Sunshine dicen
que codificadores hay realmente.

## Input

- `Ajustes > Controles > Tipo de mando`: Xbox (el mas compatible con Windows).
- `Presiona para abrir el menu de guia` / `Hold start to open on-screen keyboard`:
  util para escribir sin teclado fisico.
- `Ajustes > Avanzado > Swap axes` (trackpad) y sensibilidad: si el puntero va "al reves"
  en modo touch, es este ajuste y no el del juego.
- Teclado fisicos/Bluetooth: Moonlight los pasa como eventos HID; Windows App tiene su
  propio teclado en pantalla con modo "Mouse pointer" y "Direct touch".

## Overlay tactil por juego

1. `Ajustes > Controles en pantalla > Mostrar controles en pantalla: Siempre`.
2. Editar layout: engranaje del juego > `Custom controls` > anadir stick, D-pad, boton,
   gatillo, zona de toque. Mover/ajustar tamano con los modos "Move/Resize".
3. Opacidad global en `Ajustes > Controles en pantalla > Transparencia`.
4. Copia los elementos desde la ficha generada por `Set-TouchControls.ps1`
   (`D:\WinGamingVM\controles\<perfil>.moonlight.md`), que trae posiciones normalizadas.

## Teclas rapidas y menus

- `Start + Back` = menu de Moonlight; `Start + L3` (o el boton que definas) = teclado en pantalla.
- `Ajustes > Special keys`: anade combinaciones (Alt+Tab, Ctrl+Alt+Del no es posible:
  el equivalente remoto es `Ctrl+Alt+End`, que la VM si recibe).
- `Win + G` (Game Bar) dentro de la VM: no esta soportado en Server; el proyecto usa la
  superposicion de Moonlight y `Get-SystemMetrics.ps1` en su lugar.

## Que no vas a conseguir con estos ajustes

| Esperanza | Realidad |
| --- | --- |
| "El overlay funcionara en cualquier juego" | Solo cubre teclas/raton. Los juegos que exigen XInput **de verdad** (o antitrampas) no se arreglan con overlays |
| "Windows App va a pasar mi mando" | No redirige mandos: usa Moonlight o un mando soportado por el propio cliente |
| "Mas bitrate = menos input lag" | Sube calidad; el input lag depende de RTT, codificacion y del pipeline del juego |
| "Con AV1 se acabaron los problemas" | Requiere GPU + driver + cliente con soporte; en GPU virtual A10 el HEVC es lo verificado |
