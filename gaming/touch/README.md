# Controles táctiles en pantalla

**Leer primero:** Windows App (el cliente RDP de Microsoft en Android/iOS) **no** ofrece
capas de control con joystick y botones. No existe un ajuste en la VM que active
"controles táctiles" sobre RDP: sería una función que no existe. Este directorio
documenta la vía **compatible y verificable** y deja constancia de lo que no lo es.

## 1. Qué mecanismo real hay disponible

| Mecanismo | Cómo llega la entrada al juego | ¿Joystick/botones en pantalla? | ¿Configurable por juego? | ¿Automatizable desde la VM? |
|---|---|---|---|---|
| **Moonlight (Android/iOS) + Sunshine (host)** | El cliente emula un **mando XInput (Xbox 360)** o envía teclado/ratón | Sí: botón digital, stick analógico, D-pad, gatillos, trackpad/zona de ratón | Sí, con ajustes por app del cliente | No: el layout vive en los ajustes de la app cliente |
| **Windows App (RDP) + dedo** | Toque → clic de ratón absoluto; teclado en pantalla de Android | No (solo gestos de ratón y teclado del SO) | No | No |
| **Windows App + teclado/ratón Bluetooth o USB** | Teclado y ratón físicos del dispositivo Android | N/A (mando no) | N/A | No |
| **Steam Link en modo "Steam touch"** | Steam Input traduce zona táctil → mando/teclado | Sí | Sí (por juego) | Parcial (perfiles de Steam Input) |
| **Mando físico Bluetooth (Xbox/PS/8BitDo) + Moonlight** | XInput en el host | No es táctil, pero es la mejor opción para jugar | Perfiles del juego | No |

**Conclusión práctica del proyecto:** para jugar desde el móvil se usa el canal
`gaming.channel = moonlight` (o `both`). Para el escritorio, administración,
instalar juegos y usar apps, se usa Windows App por RDP.

## 2. Configuración en el cliente (Moonlight Android)

Ruta documentada por el propio proyecto (moonlight-android, clase `VirtualController`):

1. Ajustes → **Show on-screen controls** (activar).
2. Durante la partida: tocar el **icono de engranaje** en la esquina superior para entrar
   en el editor → modos **Move buttons** / **Resize buttons**, y control de **opacidad**.
3. Para cada app de la lista de Sunshine: *menú de la tarjeta → Use custom settings*
   (resolución, fps, bitrate y controles por juego).

Los elementos que soporta el cliente son: botones digitales (A/B/X/Y, LB/RB, Start,
Back, Guide), sticks analógicos (con "clic" de stick = L3/R3), D-pad y gatillos
izquierdo/derecho; además el modo **trackpad** (arrastrar = mover puntero) y el
**teclado especial** para combinaciones tipo `Ctrl+Alt+Supr`.

Los ficheros de `gaming/touch/layouts/` son la **especificación** de un layout
(posiciones y tamaños normalizados 0-1, opacidad 0-100) para reproducirlo igual en
cada móvil. `scripts/win/Set-TouchControls.ps1` genera además una ficha legible en la
VM (`D:\WinGamingVM\controles\<juego>.moonlight.md`) con esos valores y los pasos.

> No se puede importar el layout a Moonlight desde el host: la app lo guarda en su
> `SharedPreferences` y no expone importación (salvo root/backup de Android).
> Quien afirme lo contrario está prometiendo algo que no implementa.

## 3. Qué se ajusta **sí** desde la VM

- Sensibilidad del ratón del escritorio remoto (registro `HKCU\Control Panel\Mouse`:
  `MouseSensitivity`, `MouseSpeed`, `MouseThreshold1/2`, `SmoothMouseX`) → `scripts/win/Set-TouchControls.ps1`.
- Aceleración del puntero ("Mejorar precisión del puntero") on/off, por perfil de juego.
- Teclas de atajo de pausa/salir/menú mediante **PowerToys Keyboard Manager**
  (remapeo global o por aplicación), cuando `PowerToys` está instalado.
- Mando virtual → teclado/ratón para juegos sin soporte de mando, con **AntiMicroX**
  o con **Steam Input** (ver `gaming/steam/README.md`).

## 4. Indicadores de conexión y latencia

| Dato | Fuente | Cómo activarlo |
|---|---|---|
| Latencia de red, fps del stream, paquetes perdidos, bitrate | Cliente Moonlight | Quick menu → *Show performance overlay* |
| Latencia media del enlace hacia la VM | `scripts/win/Get-SystemMetrics.ps1 -Modo ping` | En la VM, o `ping` desde el móvil |
| GPU/CPU/RAM/uso de disco, cola de disco | `Administrador de tareas` → Rendimiento, o `Get-SystemMetrics.ps1 -Modo rendimiento` | En la VM; se puede dejar registrado a CSV |
| Cola y tiempos del codificador (NVENC) | Log de Sunshine | `C:\ProgramData\Sunshine\logs\sunshine.log` |

Windows App no muestra medidor de latencia en Android; la alternativa es el
`Get-SystemMetrics.ps1` del host midiendo RTT y pérdida, y la propia sensación de
retraso del ratón (medible con un cronómetro y grabando la pantalla: ver
`docs/11-monitoreo-y-diagnostico.md`).
