# 12 · Ideas evaluadas y por qué no están (o están a medias)

Registrar los callejones sin salida es parte del trabajo: evita que el siguiente los
reintente y deja claro que no se descartó por flojera sino porque **no es posible o no es
honesto**.

## Se intentó y se descartó técnicamente

| Idea | Por qué no |
| --- | --- |
| Generar un `.rdp` e importarlo en Windows App (Android) | Windows App en Android no importa ficheros `.rdp`: las máquinas se definen en la app. El `.rdp` sí sirve en Windows/macOS, por eso `Configurar-ClienteWindowsApp.ps1` lo escribe ahí y lo dice |
| Instalar el perfil de controles táctiles en el cliente Moonlight desde la VM | Moonlight (Android) guarda sus layouts en `SharedPreferences`; no hay API ni fichero importable desde fuera. Se entrega una **ficha con geometría normalizada** para reproducirlo en 2 minutos |
| `InstallFromModel`/`usbdev:…` en el `.rdp` para pasar un mando USB | no existe en el protocolo; la redirección USB/PnP está bloqueada por política (`fDisablePNPRedir=1`) y además no aplica a Android |
| Usar RemoteFX vGPU para tener GPU en cualquier VM | retirado en 2020 por vulnerabilidades; no hay forma soportada de reviveirlo |
| Instalar la serie NVv4 (A602) como opción barata | AMD/`NVv4` quedó retirado el 30/09/2026: documentarlo como opción sería vender algo que ya no se puede crear |
| Automatizar el PIN de emparejamiento de Sunshine | es precisamente el mecanismo de autenticación: automatizarlo desde el host equivaldría a abrir la puerta. Se guía el paso manual en la LAN |
| Escribir `apps.json` de Sunshine con "cualquier formato" | los nombres de campo cambian entre versiones: se escribe solo si el formato es el observado en la versión instalada y con un flag explícito (`-EscribirAppsJson`), y se anota en el informe |
| Ocultar la VM al antichat (spoof de SMBIOS, `hypervisorpresent` off, drivers sin firmar) | viola condiciones de servicio del juego/anticheat, expone a baneo permanente y no es reparable desde el repo. No se hace, y los perfiles lo declaran |
| Forzar `fEnableWddmDriver=1` para "sacar GPU en RDP" | en Server 2025 hay reportes de reinicios de DWM con WDDM; forzarlo rompe el acceso. Se configura y se verifica, no se impone |
| `Set-StrictMode -Version Latest` en los scripts | las propiedades opcionales de un JSON leido con `ConvertFrom-Json` lanzan al leerse si faltan (PS 2.0+). Se usa `1.0` con comentario explicándolo, porque un bootstrap que revienta por un campo opcional es peor que un null |
| Confiar en la tabla de códigos de salida de winget (`0x8A1500xx`) | inestable entre versiones: se clasifica por `exit 0` + subcadenas estables del output y se **verifica la instalación real** (registro/ejecutable/firma) |
| Descargar CapFrameX/ReShade/HWiNFO/RealBench "porque son de gaming" | no están en winget (verificado contra el repo de manifiestos) y bajarlos de un mirror rompe la política de fuentes oficiales: quedan como pasos manuales con la fuente citada |
| Importar layouts de AntiMicroX por XML desde la VM | AntiMicroX es una app de cliente/PC local con su propio directorio de perfiles; no hay canal desde la VM hacia el Android. `Set-TouchControls.ps1` **no** lo automatiza (el README de `gaming/steam/` lo aclara) |
| Un "modo simulación" que enseña lo que haría sin tocar la VM | existe, pero no como bandera inventada en cada script: es `-WhatIf` (`SupportsShouldProcess`) y `-Simulacion` en el bootstrap. Un `-Simular` suelto en cada fase duplica la superficie de errores |

## Se descartó por honestidad

| Idea tentadora | Por qué no está |
| --- | --- |
| "VM gratis" con créditos de prueba | los créditos se acaban y la VM sigue facturando; el schema obliga a `cost.acknowledgePaidResources: true` |
| Instalar todas las apps "para que esté completo" | `No descargues todas las aplicaciones obligatoriamente`: catálogo ≠ lista de instalación |
| Prometer "1080p60 en cualquier juego" | depende del SKU, del driver, del juego y de tu red; el proyecto emite un veredicto medido, no una promesa |
| Poner un fondo de pantalla descargado de un repo ajeno | `windows.wallpaper.source: url` exige HTTPS + host permitido en `apps/sources.json`; se puede poner un color sólido o una ruta local |
| Afirmar que "el táctil funciona en todos los juegos" | solo hay overlay donde el cliente lo implementa y teclas que el juego acepte reasignar; los perfiles declaran el modo |
| Un número de FPS "estimado" | sin medir en TU máquina no hay estimación honesta: `Get-SystemMetrics.ps1` mide, y si el contador no existe sale `no-disponible` |
| "Compatibilidad total con Game Pass" | Cloud Gaming de Microsoft y Game Pass en VM son cosas distintas, y la app de Xbox necesita la Store; se documenta el límite |
| Compartir un `config/vm.json` de ejemplo con una IP y un usuario reales | el ejemplo usa valores claramente falsos y no hay contraseñas en ningún sitio del repo |

## Queda pendiente (no es "no se hará", es "no está hecho")

- Un empaquetado `.msixwizard` o similar para configurar Windows App en Android por MDM:
  fuera de alcance para un proyecto personal, y además la app de Microsoft exige otros
  supuestos (gateway, Workspace).
- Perfiles de Steam Input aplicables desde CLI: no hay interfaz estable documentada; se
  documentan los pasos en la GUI de Steam.
- Un módulo de Terraform que también cree el **Azure Bastion** (para no abrir nunca 3389 y
  sin instalar Tailscale): se puede añadir; hoy se documenta el modo túnel y el NSG cerrado.
- Pruebas de humo automáticas **dentro de una VM real** en CI: requerirían una suscripción
  que pague cada ejecución. El workflow de Windows usa un runner de GitHub (no es una VM de
  gaming) y lo dice en el nombre del job.
- Soporte de audio espacial / 5.1 en la sesión: no probado en Server; el proyecto solo
  redirige reproducción estéreo cuando la política lo permite.
- Un "modo consola" para que Xbox Game Bar funcione en Server: no existe; Game Bar no está
  en Server y no se instala un parche no soportado.

## Notas de licencia (para que no te sorprendas)

- **Windows**: en Azure/AWS la licencia va incluida en el precio de la VM del marketplace,
  con sus condiciones (en Server, el uso es de administración/escritorio remoto con
  licencias adicionales según escenario). En KVM, la licencia es tuya y la responsabilidad
  también. **Este repo no distribuye ISO, ni claves, ni activadores: no los va a contener
  nunca.**
- **Drivers NVIDIA**: los de centro de datos / vGPU (GRID) requieren licencia según escenario; los de
  consumo no autorizan virtualización en host no soportado. El proyecto descarga de la URL
  oficial que **tú** declaras y verifica firma, sin opinar sobre tus derechos de uso.
- **Juegos**: el contenido es de su editor; el proyecto no instala juegos, lanza
  instaladores de aplicaciones (Steam/Epic/Minecraft launcher) que abrirán **tu** cuenta.
- **Software de terceros** (7-Zip, VLC, VS Code, …): cada entrada del catálogo declara su
  licencia; se descargan de la fuente oficial. MIT/BSD/GPL conviven: respeta la de cada una.
