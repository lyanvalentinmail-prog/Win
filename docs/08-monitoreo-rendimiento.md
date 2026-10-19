# 08 · Monitoreo: CPU, RAM, GPU, disco, latencia y estabilidad

## Herramienta principal

`scripts/win/Get-SystemMetrics.ps1` — cuatro modos, todos **sin dependencias** (usa
`Get-Counter`, WMI/CIM y `System.Net.NetworkInformation.Ping`):

```powershell
.\Get-SystemMetrics.ps1 -Modo punto                       # una muestra, para logs
.\Get-SystemMetrics.ps1 -Modo rendimiento -IntervaloSegundos 2 -Muestras 300
.\Get-SystemMetrics.ps1 -Modo rendimiento -HastaQueCorte -SalidaCsv D:\WinGamingVM\sesion.csv
.\Get-SystemMetrics.ps1 -Modo ping -Objetivos 1.1.1.1,8.8.8.8 -Paquetes 20
.\Get-SystemMetrics.ps1 -Modo sesion                      # tipo de sesion, listener, WDDM/AVC
```

`-Modo rendimiento` escribe CSV por sí solo en
`C:\ProgramData\WinGamingVM\informes\rendimiento-<marca>.csv` (o en la ruta que des con
`-SalidaCsv`), para que puedas abrirlo en una hoja de cálculo después de la sesión.
`-HastaQueCorte` graba hasta que el proceso se cae o tú lo cortas: es el modo útil para
responder a "fue en un momento concreto, no siempre".

## Qué mide cada cosa y cómo leerlo

| Métrica | Fuente | Lectura sana en una VM de juego | Si sale mal |
| --- | --- | --- | --- |
| CPU total | `\Processor(_Total)\% Processor Time` | < 85 % sostenido | el cuello es la CPU virtual: baja settings o sube SKU |
| RAM libre | `\Memory\Available MBytes` | > 2 000 MiB con el juego abierto | con 4-8 GiB y un navegador dentro, el juego sufre |
| Uso de GPU | `\GPU Engine(*engtype_3D)\Utilization Percentage` | 60-99 % con el juego en primer plano (alto **no** es fallo) | si el juego está al 5 %, el límite es CPU/resolución o el vsync |
| VRAM | WMI `Win32_VideoController.AdapterRAM` + `nvidia-smi` si existe | < 90 % de la VRAM asignada (4 GiB en NV6ads) | texturas en ultra no caben: es el límite duro de la GPU virtual |
| Disco | `\PhysicalDisk(*)\Avg. Disk Queue Length`, `\% Idle Time` | cola < 2, idle > 20 % | si D: está al 100 %, la librería en un Premium SSD no ayuda: revisa qué está copiando |
| Latencia del canal | ping al gateway/cliente + overlay de Moonlight | < 40 ms de red + render | con > 70 ms de RTT no hay settings que lo arreglen |
| FPS / frame time | superposición de Sunshine/Moonlight, o `Steam > Renderir > FPS` | estable, con picos cortos | picos periódicos = paginación, disco o Driver timeout |

## Honestidad de los contadores

- Si un contador no existe en esa edición/imágen, el script escribe **`no-disponible`**, no
  un `0`. Un `0` en una GPU sin driver no significa "GPU al 0 %": significa que no hay a
  quién preguntar. Lo mismo para `\GPU Engine` en Server sin WDDM.
- `Get-Counter` necesita los nombres **localizados**; el script pide por id de contador y
  captura el fallo, en lugar de asumir el nombre en inglés.
- La latencia medida **desde la VM hacia Internet** no es la latencia de tu sesión: el
  pipeline real es `dispositivo → red → VM → codificador → red → pantalla`. Para eso está
  el overlay del cliente y `-Modo ping` desde tu estación
  (`scripts/client/Test-ConexionRemota.ps1`).

## ICMT: límite de tiempo del driver

Con GPU, el watchdog de TDR puede matar la codificación si un frame dura demasiado. En
autohospedado puedes subir `TdrDelay`/`TdrLevel` (registro `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`)
**bajo tu responsabilidad**: en una VM de nube con GPU virtual normalmente no aplica y no se
toca desde este proyecto. El bootstrap **no** modifica TDR: si algún día lo hace, será con su
clave documentada, su respaldo `.reg` y una línea en el informe.

## Registro de estabilidad

Para una sesión larga, el modo `-HastaQueCorte` graba CSV cada N segundos y detecta:
- caídas del proceso `Sunshine` (servicio reiniciado),
- desconexiones de sesión (el contador de sesiones de Terminal Services),
- picos de cola de disco.

Y para el "se cortó y no sé por qué", mira el registro de eventos dentro de la VM:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddHours(-6)} -MaxEvents 40 |
  Select-Object TimeCreated, Id, ProviderName, Message | Format-List
# 4101 = el driver de pantalla rechazo la peticion (Code 43 habitual); nvlddmkm = driver NVIDIA
```

`Test-GamingReadiness.ps1` ya deja en el informe la parte que se puede leer por WMI
(estado del adaptador, Cod43, servicio de sesión); el resto es consulta directa.

## Plan de energía y su efecto medible

`power.plan: ultimate|high-performance|balanced` cambia `CPMINCORES`, sub-balanceo y estados
de ahorro. Cómo comprobar que hizo algo:

```powershell
powercfg /getactivescheme
Get-CimInstance Win32_Processor | Select-Object CurrentClockSpeed, MaxClockSpeed
.\Get-SystemMetrics.ps1 -Modo punto
```

En Azure NV verás `CurrentClockSpeed` reportando el reloj base (el guest no siempre ve el
turbo real): es una limitación de la virtualización, no un fallo del plan.

## Qué NO hace este proyecto en el monitoreo

- No instala CapFrameX/ReShade/HWiNFO "porque sí": no hay manifiesto de winget para varios
  de ellos (está anotado en el catálogo) y descargar binarios de terceros contradice la
  política de fuentes. Se documenta la fuente oficial y el usuario decide.
- No "limpia la RAM" con trucos: vaciar working sets de otros procesos empeora el juego.
- No promete FPS: no existe forma honesta de prometerlos sin conocer tu juego, tu red y tu SKU.
