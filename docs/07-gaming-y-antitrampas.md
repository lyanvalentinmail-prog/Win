# 07 · Gaming, GPU y antitrampas

## La pregunta que decide todo: ¿hay GPU con codificador?

Los scripts **consultan** la máquina; no asumen. `Get-GvmGpuInfo` + `Test-GvmDirectXDisponible`
responden, y de ahí sale el estado de la fase:

| Estado | Significado | Que puede esperar el usuario |
| --- | --- | --- |
| `gpu-ok` | adaptador con driver correcto, sin Code 43, DirectX 11 disponible | escritorio remoto + canal de juego con codificador por hardware |
| `gpu-parcial` | GPU vista pero DirectX/codificador dudoso o WDDM desactivado | se puede intentar; mide antes de recomendar |
| `sin-gpu` | sin adaptador de renderizado util | **no se configura el canal de juego**; el informe lo dice con todas las letras |
| `driver-pendiente` | falta el driver GRID / hay que reiniciar | `-Fases gpu -Forzar` tras el reinicio |

Un resumen honesto del límite: con una GPU virtual A10 en Azure puedes jugar a títulos con
requerimientos moderados, con 4-8 GiB de VRAM, y el codificador NVENC está para el
streaming. No es una RTX local, y en un móvil con WiFi compartida la latencia la marca tu red.

## Qué automatiza la fase `gaming`

1. **Sunshine** (`LizardByte.Sunshine` vía winget, con verificación de firmante
   `LizardByte`/`Johannes Kauffmann`), configuración escrita en
   `%ProgramData%\Sunshine\config\sunshine.conf` con los campos del formato actual:
   `[general] port=47984`, `upnp=disabled`, `origin_web_ui_allowed=pc`;
   `[encoder] encoder` según lo que la GPU informe (hevc/av1/nvenc);
   `[video] fps`, `bitrate` (Mbps × 1000).
2. **Puertos de stream** TCP 47984/47989/48010/47990 y UDP 47998-48002/48010, **limitados a
   `gaming.sunshine.allowedCidrs`**; si no hay CIDR y hay túnel, se crean restringidos a
   `LocalSubnet`; si no hay ninguna de las dos cosas, se crean **deshabilitados** con aviso.
3. **Sesión de consola**: Sunshine necesita la sesión de la consola; se crea una tarea que
   llama a `Unlock-ConsoleSession.ps1` y el script advierte de que eso corta tu RDP.
4. **Perfiles de control** (`Set-TouchControls.ps1`): sensibilidad de ratón de la VM
   (`MouseSensitivity` derivada del factor del perfil, 1-20, con restauración de fábrica),
   ficheros de PowerToys Keyboard Manager en `controles-powertoys\` (copiados al perfil de
   usuario solo con `-AplicarEnPowerToys`, con copia previa), fichas por perfil en
   `D:\WinGamingVM\controles\<perfil>.moonlight.md` + `.layout.json`.
5. **Cuándo NO se configura nada de esto**: si `gaming.channel=rdp` o si no hay GPU
   (`desactivado-sin-gpu`). En ambos casos el informe lo declara, no lo oculta.

## Qué es manual, y por qué

| Parte | Por qué no puede ser automática |
| --- | --- |
| Emparejar Moonlight con Sunshine (PIN) | es el mecanismo de seguridad: el PIN se introduce en la web local de Sunshine desde la LAN |
| Dibujar el overlay táctil en el dispositivo | Moonlight guarda su configuración en `SharedPreferences` del Android; no hay API de importación desde el host |
| Perfiles de Steam Input por juego | Steam guarda sus perfiles en su nube/local y no expone un formato soportado para inyectarlos desde fuera |
| Mando en Windows App | el cliente no redirige mandos desde Android |
| Periféricos USB (volantes, mandos específicos) | no hay passthrough USB en este escenario; documentado en `docs/02` |
| Activar/desactivar el juego en Steam/Epic y tu cuenta | eso es tu cuenta y tus compras: el proyecto no toca credenciales |

## Antitrampas: la parte que no se puede negociar

Muchos títulos usan antichat de **kernel** que rechaza máquinas virtuales. No es una cuestión
de "ocultar la VM": hacerlo (spoofing de SMBIOS/DMAR, desactivar hypervisor flags, drivers
sin firmar) viola las condiciones de servicio del juego y del software de seguridad, y puede
acabar en baneo permanente del hardware/cuenta. El proyecto **no lo automatiza ni lo
recomienda**.

Cómo está tratado en los datos:

- Cada perfil tiene `compatibilidadVm.antitrampas`: `sistemas`, `vm`
  (`permitida | restringida | desconocida`), `riesgoBaneo`, `nota` (con fuente y fecha).
- `vm: restringida` ⇒ la app **no se instala** y `Test-GamingReadiness.ps1` emite un **ERROR**
  explícito.
- `vm: desconocida` ⇒ el informe lo marca como WARN con la instrucción de comprobarlo antes.
- `gaming/antitrampas.md` es el documento vivo: título por título, con la fuente consultada
  y la fecha, más la política de "verifícalo el día que juegues, porque esto cambia".

Títulos que **no** van a funcionar en VM (antichat de kernel, sin excepciones conocidas):
cualquiera con Easy Anti Cheat en modo "requiere arranque limpio", BattlEye, Vanguard
(VALORANT/LoL), FACEIT AC, y los shooters con modo ranked + anti-cheat de anillo 0.
Títulos que **suelen** funcionar: juegos single-player sin antichat, juegos con antichat en
modo usuario (algunos), emuladores, juegos de tienda sin servicio online, y la mayoría de
juegos indie/estrategia/simulación — **compruébalo siempre en la ficha del juego**.

## Rendimiento esperado: cómo hablar de esto sin mentir

Fórmula de estimación en `config/gaming-presets.json`, y esta tabla de expectativas:

| Escenario | FPS realistas | Nota |
| --- | --- | --- |
| Server 2025 + A10 4 GiB (NV6ads), 720p60 HEVC 18 Mbps, eSports poco exigentes | jugable | el límite suele ser la CPU virtual y la VRAM, no el codec |
| AAA moderno, 1080p, ajustes altos | **no lo prometas** | 4 GiB de VRAM y una fracción de GPU no es una RTX 4070 |
| Sin GPU (serie D o B) | no aplica | codificación por CPU + x264 = latencia alta y poca estabilidad |
| KVM + GPU física dedicada | lo más cercano a local | exige VFIO bien montado y sigue sin soportar antichat de kernel |
| Windows App + RDP (sin Moonlight) | escritorio | para juegos de ratón lento, no para acción competitiva |

El informe de preparación, `Get-SystemMetrics.ps1 -Modo rendimiento` y el overlay de
Moonlight (estadísticas) son las tres fuentes de medición. Si un número no se puede medir
(no hay contador, no hay GPU), **se marca como `no-disponible`** en lugar de poner un cero.
