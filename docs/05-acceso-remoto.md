# 05 · Acceso remoto (Windows App, sesión y calidad)

## Qué se está usando, con nombre y apellido

| Pieza | Rol | Soporte |
| --- | --- | --- |
| **Servicio de Escritorio remoto (RDP)** | el canal: pantalla, teclado, ratón, portapapeles, audio | soportado por Microsoft en Windows; `TermService` |
| **Windows App** (Android/iOS/Windows/macOS) | el cliente que tú usas | sustituyó a la app de Escritorio remoto (27/05/2025); en Android requiere 11 o superior |
| **NLA + CredSSP + TLS** | autenticación y cifrado | `SecurityLayer=1`, `fDenyTSConnections=0` con NLA obligatoria |
| **UDP (puerto 3389)** | flujo y menor latencia percibida | lo negocia el cliente; hay que habilitar la regla de firewall |
| **AVC/H.264 y HEVC (4:4:4 opcional)** | codificación de pantalla | en el cliente con GPU; en la VM depende del driver de pantalla |
| **Sunshine + Moonlight** | canal *alternativo* para jugar con overlay táctil | requiere GPU con codificador por hardware |

Windows App **no** es un cliente de videojuegos: es un cliente de escritorio. Todo lo que
sigue está escrito para que no se confundan las dos cosas.

## Cómo se configura desde el repo

`config/vm.json` → `remote.*` (estructura en `config/vm.schema.json`), y las políticas base
en `config/remote-session.json`. `Set-RemoteDesktop.ps1` traduce esos valores a registro:

| Valor del config | Clave real que escribe `Set-RemoteDesktop.ps1` | Efecto |
| --- | --- | --- |
| `session.quality: low-latency\|balanced\|fidelity` | preset de `config/remote-session.json` (`politicas` del preset) | compresión/color/AVC en bloque, con nombres ya revisados |
| `session.colorDepth: 16\|24\|32` | `ColorDepth` (16→2, 24→3, 32→4) | menos bits = menos bytes por frame |
| `session.udp: true\|false` | habilita o deshabilita la regla integrada `Remote Desktop - User Mode (UDP-In)` | fluidez mejorada si la red lo permite; **no** hay clave de registro inventada |
| `session.avc444` | `AVC444ModePreferred` (1/0) | 4:4:4 **solo** si `Get-GvmGpuInfo` ve GPU; si no, se escribe 0 |
| `session.hardwareEncoding` | `AVCHardwareEncodePreferred`, `bEnumerateHWBeforeSW`, `fEnableWddmDriver` | idem: sin GPU se escriben 0 explícitos |
| `session.idleDisconnectMinutes` | `MaxIdleTime` (ms) | desconexión por inactividad |
| `session.reconnectRetries` | `MaxReconnectionTime` (ms, mínimo 60 000) | ventana de reconexión |
| `session.clipboard` | `fDisableClip` (0 permitido / 1 bloqueado) | portapapeles |
| `session.driveRedirection` | `fDisableCdm` | unidades del cliente (por defecto **bloqueadas**) |
| `session.printerRedirection` | `fDisablePrint` | impresoras (por defecto **bloqueadas**) |
| `session.audio: play\|no-play` | `fDisableCam` (0 permite la redirección de reproducción / 1 la bloquea) | audio en el dispositivo cliente |
| — (fijo) | `fDisableAudioCapture = 1` | el **micro** del cliente no entra en la VM: decisión de privacidad, cambiable |
| `remote.requireNla` | `UserAuthentication`, `SecurityLayer=1`, `MinEncryptionLevel=3` | NLA y cifrado alto |
| `remote.port` | `PortNumber` en `RDP-Tcp` (si es ≠ 3389) | puerto alternativo |
| `remote.allowedCidrs` | alcance de las reglas TCP-In/UDP-In integradas | quién puede llamar |
| `remote.tunnel != none` | las reglas se limitan a `LocalSubnet` y el schema exige `allowedCidrs: []` | nada expuesto al público |

Nota importante: **estas son las claves reales** de
`HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` (donde viven las
políticas de GPO) y `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server` +
`...\WinStations\RDP-Tcp` (donde viven los valores del listener, como `PortNumber`). No se
inventan nombres: si una política no existe en tu build, `Set-GvmRegistryValue` lo registra
en el log y el informe lo muestra como omisión, no lo escribe "a ver si cuela".

## Los tres modos de llegar a la VM

### 1. Túnel (recomendado)

Sin puertos abiertos. `remote.tunnel: tailscale` (o bastion/SSH) y `allowedCidrs: []`.

```powershell
# En tu estacion, si el salto puede ver la VM por la red interna:
.\scripts\client\Montar-TunelSSH.ps1 -Salto 'admin@tu-host-publico' -DestinoVM '10.20.1.4:3389'
# Windows App -> nueva maquina: 127.0.0.1:13389 (el tunel hace el resto)
```

En Android, con Tailscale: instalas la app, inicias sesión en el mismo tailnet y apuntas
Windows App a la IP del tailnet. Es la vía con menos superficie y sin abrir 3389 nunca.

### 2. IP pública con lista de control de acceso

`remote.tunnel: none` + `remote.allowedCidrs: ["tu.ip.publica/32"]`. El NSG de Terraform y el
firewall de Windows reciben la **misma** lista; cualquier origen distinto se descarta. Pon tu
IP real: `curl ifconfig.me`. Si tu operador cambia la IP dinámicamente, el modo túnel es
mejor opción que abrir /0.

### 3. Solo para diagnóstico: sesión por consola

`Unlock-ConsoleSession.ps1` devuelve la sesión a la consola con `tscon` (útil para Sunshine,
que necesita la sesión de consola). **Corta tu conexión RDP actual**: el script avisa antes.

## Con Windows App en Android (lo que puedes tocar)

En `Ajustes del equipo` (por máquina) o `Ajustes` (globales):

| Ajuste | Que hace | Nota |
| --- | --- | --- |
| Resolución / "Ajustar a la pantalla" | el cliente pide el tamaño; la VM aplica `windows.display` | en móvil, 1280×720 con escalado sube los FPS reales |
| Calidad de sesión | auto / calidad / rapidez | con el preset `low-latency` el servidor negocia compresión |
| Teclado en pantalla | abre el teclado de Windows App desde la barra | incluye modo puntero y teclas de Windows/Alt/Ctrl |
| "Ratón" / gestures | *Direct touch* (toque = clic) o *Mouse pointer* (toque = puntero, arrastre = movimiento) | la elección cambia mucho la sensación de precisión |
| Enviar secuencias de escaneado | teclado físico envía scancodes | algunos juegos/trucos lo necesitan; en Android está expuesto como toggle |
| Pantalla completa + barra lateral | gestos de ratón, SSH, portapapeles | la barra es donde está el teclado en pantalla |

**Lo que no está en Windows App, por mucho que se busque**: redirección de mando, overlay de
botones táctiles, vibración, giroscopio como stick analógico, y "modo juego". Si necesitas
eso, el canal es Moonlight (documentado en `docs/06` y `gaming/touch/README.md`).

## Audio

- RDP redirige la **reproducción** al cliente cuando la política lo permite. En Windows Server
  hace falta el componente "Audio and video playback" (viene en las ediciones Desktop
  Experience); el bootstrap lo habilita si está presente y **lo declara** si no.
- La **captura** del micrófono está **desactivada por defecto** (`audiocapturemode:i:0`): si
  quieres chat de voz, actívalo en el cliente y añade la política correspondiente. Es
  deliberado: un micro redirigido en una VM multiuso es un micrófono siempre encendido.
- En el canal de juego, Sunshine captura y codifica el audio; la latencia y la sincronía
  dependen del codificador y de tu red, no de un ajuste mágico.

## Calidad vs ancho de banda: números, no adjetivos

`config/gaming-presets.json` trae presets y la fórmula de consumo:

```text
GB/h ≈ Mbps × 3600 / 8 / 1000          25 Mbps ≈ 11,25 GiB/h · 60 Mbps ≈ 27 GiB/h
```

Eso se multiplica por el precio del egreso de tu proveedor. En Azure el egreso a Internet
suele facturarse por GB (con los primeros 100 GB/mes gratis); en AWS por GB; en KVM, en tu
propia línea. **Un día de juego en 4K/120 puede ser decenas de gigas**: si tu plan de datos
del móvil es limitado, el límite lo pone tu operadora, no el bitrate.

Para el escritorio normal, RDP con compresión y 16-24 bpp consume notablemente menos porque
solo envía lo que cambia; el canal de juego envía un flujo de vídeo constante.

## Reconexión y estabilidad

- `MaxReconnectionTime`: la VM mantiene la sesión durante la ventana configurada; si
  reapareces dentro de ese tiempo, Windows App reconecta sin pedir credenciales (la sesión
  sigue viva en el servidor).
- Con `idleDisconnectMinutes`, si dejas la sesión inactiva se desconecta **y se queda
  bloqueada** (bloqueo por inactividad de `security.screenLockMinutes`). Para sesiones de
  juego largas, configura tiempos coherentes: no tiene sentido un idle de 3 minutos.
- Si la VM se reinicia, la sesión no "sobrevive": hay que volver a conectar y reabrir el
  juego. Sunshine vuelve solo (servicio o tarea de inicio); RDP también, pero el acceso a la
  consola tras un reinicio requiere sesión iniciada (ver `remote.autoLogon`, que el proyecto
  deja **apagado** por defecto por seguridad).

## Prueba mínima de que el acceso funciona

```powershell
# desde tu estacion
.\scripts\client\Test-ConexionRemota.ps1 -Hostname <ip-o-fqdn> -Puertos 3389
```

Y dentro de la VM:

```powershell
.\scripts\win\Get-SystemMetrics.ps1 -Modo sesion    # tipo de sesion, politica de cifrado, escucha
.\scripts\win\Test-GamingReadiness.ps1              # el informe completo
```

El checklist completo de aceptación (incluida la prueba desde el Android) está en
`docs/11-prueba-de-aceptacion.md`.
