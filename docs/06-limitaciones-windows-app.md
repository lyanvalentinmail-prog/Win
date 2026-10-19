# 06 · Límites de Windows App por función

Documento de referencia: **qué funciona, qué no y por qué**, función por función, en
Windows App (cliente oficial de Microsoft) desde Android. Si una función no está aquí, no se
promete: se investiga y se documenta.

Fuente de los límites: la documentación de entrada de Windows App (Learn,
*Input: keyboard, mouse, touch, pen*), las capacidades del protocolo RDP y el
comportamiento observado en las versiones actuales del cliente.

## Tabla maestra

| Función | Windows App (Android) | Cómo se logra realmente | Limites |
| --- | --- | --- | --- |
| Escritorio completo (Inicio, barra de tareas, Explorador, Edge, Bloc de notas, Calculadora, Administrador de tareas, Compresión de ZIP, Reproductor, Recortes, Configuración) | **sí** | es la sesión RDP de la VM | la app que dependa de la Store no existe en Server |
| Instalar más apps dentro de la VM | **sí** | winget / instalador / Store según edición | en Server sin Store, lo de la Store queda manual |
| Teclado físico Bluetooth/USB | **sí** | el SO del dispositivo lo pasa al cliente | el layout se negocia; usa "scancode" si un juego no tecla bien |
| Ratón físico Bluetooth/USB | **sí** | igual | rueda y botones laterales funcionan; la *precisión* depende del modo puntero |
| Teclado en pantalla | **sí** (barra de Windows App) | — | no es un mapa de teclas por juego |
| Toque como puntero / gestos | **sí** (Direct touch / Mouse pointer) | — | sin latencia cero: cada toque viaja |
| **Overlay de botones táctiles en pantalla** | **NO existe** | Moonlight (Android) con controles en pantalla | requiere GPU + Sunshine; se configura en el dispositivo |
| **Mando virtual en pantalla** | **NO existe** | Moonlight (su "on-screen controls" de 5.x) | lo mismo; el layout es del cliente |
| **Mando físico Bluetooth/USB** | **NO se redirige** | Moonlight sí lo pasa como mando virtual/XInput; Steam Link también | en Windows App no hay forma de que la VM vea el mando |
| Vibración del mando | no | Moonlight, si el mando y el SO del móvil la soportan | — |
| Multitáctil como gestos de ratón | **sí** | Windows App | no es "dos dedos = joystick" |
| Audio en el dispositivo | **sí** si la VM lo permite | RDP redirección de reproducción | Server necesita Desktop Experience y la política activa |
| Micrófono | no por defecto | `audiocapturemode` en el cliente + política del servidor | decisión de privacidad conscientemente en off |
| Portapapeles | **sí** | `redirectclipboard` / política de servidor | ficheros grandes, mejor por unidad redirecionada (activa `driveRedirection` si lo necesitas) |
| Redirección de unidades locales | **sí** (activable) | `driveRedirection` | por defecto **off** en este proyecto |
| Impresoras del cliente | **sí** (activable) | `printerRedirection` | por defecto **off** |
| Copiar archivo de 5 GB | lento, y no es el caso de uso | disco de datos persistente + subida por Azure Files/S3 | RDP no es un canal de almacenamiento |
| Sesión persistente al reconectar | **sí** | RDP mantiene la sesión | si la VM se reinicia, la sesión se pierde |
| GPU "de verdad" para el juego | depende del SKU | serie NV con driver GRID; KVM con passthrough | sin driver correcto → Code 43 y sin codificador |
| Game Bar / Xbox Game Pass | **no** en Server | — | `windows-editions.json` marca `GameDVR: false` |
| Antitrampas de kernel | **no** en ninguna VM | — | ver `gaming/antitrampas.md`; no hay truco |
| UWP/apps de la Store | no en Server | solo Win11 (con condiciones) | el catálogo marca `requiereStore` |

## Lo que la gente espera y no existe (declaración explícita)

1. **"Windows App tiene controles táctiles de juego"**. No. Tiene *gestos de puntero* y
   teclado en pantalla. Un overlay con joystick y botones para un juego concreto es una
   función del **cliente de streaming**, no del cliente de escritorio remoto.
2. **"Conecto el mando al móvil y la VM lo ve"**. No: Windows App en Android no redirige
   mandos. Con Moonlight, el mando físico del Android sí llega como mando virtual. Con
   Windows App, la alternativa es un mando conectado a la **red** (no existe) o conectar el
   mando al PC que uses como puente (fuera del alcance de este proyecto).
3. **"El táctil funciona en cualquier juego"**. No: el táctil del cliente genera teclas y
   clics; un juego que no permite reasignar teclado (o que pide entrada de mando real) no
   quedará jugable con un overlay. Por eso los perfiles declaran `modo: mando-virtual` o
   `modo: teclado` y `gaming/touch/README.md` dice en qué juegos lo has probado.
4. **"Con más resolución va mejor"**. Al contrario en remoto: el presupuesto es el ancho de
   banda y el tiempo de codificación. Presets en `config/gaming-presets.json`.
5. **"La latencia se puede bajar con un ajuste"**. La RTT es física. Lo que se puede hacer es
   acercarse (región), reducir saltos (túnel), evitar Wi-Fi compartido y elegir el canal con
   menos pipeline (Moonlight suele ganar a RDP en respuesta de ratón, con GPU).

## Windows App en escritorio (Windows/macOS)

El cliente de Windows/macOS añade cosas que Android no tiene, y conviene saberlas:

- Redirección **RAS/USB** limitada y **policías** del servidor: el proyecto no habilita USB.
- En Windows, el cliente puede redirigir **mandos** si se usa el complemento
  *RdpGamepad* (host Windows + cliente Windows). **No está disponible en Android**, y por eso
  este proyecto no lo cuenta como "acceso táctil desde el móvil".
- Los ficheros `.rdp` se pueden editar en Windows (el script `Configurar-ClienteWindowsApp.ps1`
  genera uno con los valores del proyecto); **en Android no se importan `.rdp`**: la máquina se
  define en la propia app.

## Checklist antes de decir "no va"

- [ ] ¿El informe de preparación (`preparacion-*.md`) está en verde para la función que pides?
- [ ] ¿El canal es el correcto? (mando/overlay → Moonlight; escritorio → Windows App)
- [ ] ¿La VM tiene GPU verificada? (`Get-GvmGpuInfo` / el informe; sin GPU el canal de juego está desactivado)
- [ ] ¿El preset de red se corresponde con tu enlace real? (`Test-ConexionRemota.ps1`)
- [ ] ¿La edición de Windows admite la app que esperas? (`config/windows-editions.json`)
- [ ] ¿El juego soporta VM? (`gaming/antitrampas.md`)
