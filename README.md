# Win — VM real de Windows para jugar y trabajar desde Windows App (Android, iOS, PC)

Despliegue **reproducible** de una máquina virtual de Windows de verdad —no una simulación—
en tu propia cuenta de Azure, AWS o en un host KVM, accesible con **Windows App** y con un
instalador **verificado y opcional** de utilidades, herramientas diarias y capacidades de
juego. Todo el código de este repositorio se puede auditar: la VM se crea con Terraform, se
prepara con PowerShell idempotente y termina en un **informe honesto** de qué está aplicado,
qué no, y por qué.

```bash
# Si solo quieres ver si tu configuración es coherente (no toca ninguna VM):
pip install -r scripts/validate/requirements.txt
python scripts/validate/validate.py --verbose
```

## Qué es esto y qué no es

| Es | No es |
| --- | --- |
| Una VM Windows real en infraestructura que tú pagas | Un emulador, un "Windows en el navegador" ni una demo |
| Acceso con el cliente oficial **Windows App** (RDP) y, para jugar, con **Moonlight/Sunshine** | Un servicio de cloud gaming con suscripción ni una alternativa a GeForce NOW/xCloud |
| Un catálogo de aplicaciones **opcional**, verificado contra sus fuentes oficiales | Un instalador silencioso de todo lo que existe |
| Controles táctiles vía **layouts documentados** que reproduces en el cliente | "Táctil automático en cualquier juego" (eso no existe) |
| Optimizaciones medibles + GPU verificada o **limitación declarada** | Una GPU dedicada inventada, fps prometidos o un "modo turbo" |
| Escritorio persistente, apps que eliges, sesiones reconectables | Un entorno multiusuario, un servicio para terceros ni una VM gratis |

**Ninguna licencia se finge**: la licencia de Windows la aporta el proveedor (Azure/AWS) o la
tuya (KVM); los drivers NVIDIA tienen sus propias condiciones; los juegos y sus
antitrampas son decisión de sus editores. **Ninguna credencial se guarda en el repositorio.**

## Lo que tendrás al terminar

1. **Un escritorio de Windows completo** al que entras desde el móvil, tablet o portátil:
   menú Inicio, barra de tareas, Explorador de archivos, Edge, Bloc de notas, Calculadora,
   Administrador de tareas, compresión/extracción ZIP con 7-Zip, reproducción de vídeo con VLC,
   Recortes, Configuración — y puedes instalar más aplicaciones dentro.
2. **Persistencia real**: un disco de datos gestionado (Azure), EBS cifrado (AWS) o qcow2 con
   instantáneas (KVM). Tus juegos, documentos y perfiles sobreviven a reinicios y a
   recrear la máquina.
3. **Personalización** declarada en JSON: fondo (color sólido, archivo local o URL oficial),
   resolución y escala, tema claro/oscuro y color de énfasis.
4. **Apps opcionales, verificadas**: 30 aplicaciones en catálogo (`utilities`, `gaming`,
   `full`, `minimal`), cada una con `id` de winget, URL oficial, SHA-256 cuando el manifiesto
   lo declara y **verificación de firma después de instalar**. Lo que no está en tu selección
   **no se descarga**.
5. **Control de juego**: perfiles por título con sensibilidad de ratón, remapeos, atajos y
   layouts táctiles con geometría documentada; mando virtual y overlay **solo** donde el
   canal lo soporta (Moonlight), y **ninguna** afirmación sobre juegos con antichat de kernel.
6. **Optimización y medición**: plan de energía, GameDVR, HAGS, servicios y procesos
  innecesarios (sin tocar nunca Defender ni los servicios de sesión), y un medidor de
   CPU/RAM/GPU/disco/latencia con exportación a CSV.
7. **Un informe**: `preparacion-*.md` con el veredicto por componente y salida `2` si algo
   está bloqueado. Es el requisito de aceptación: si el informe dice "sin GPU", **no** hay
   canal de juego, y no se disimula.

## Arquitectura

Cuatro capas separadas a propósito (detalle en [`docs/01-arquitectura.md`](docs/01-arquitectura.md)):

```text
Tu estacion                       VM Windows real (la que pagas)              Cliente
----------------------           ------------------------------------        -----------------
infra/azure|aws|kvm   --apply-->  Bootstrap-GamingVM.ps1                      Windows App (RDP)
  red, VM, discos, NSG            |                                           (escritorio, teclado,
  (sin secretos en el repo)       +-- 1 preflight  requisitos y config         raton, portapapeles)
                                  +-- 2 gpu        driver o limitacion explicita        |
scripts/deploy/*    run-command-> +-- 3 escritorio optimizacion, fondo, resolucion      |
(az vm run-command,               +-- 4 remoto   RDP + politicas + firewall             v
  SSM, virt-install)              +-- 5 apps     catalogo + selecciones           Moonlight (juego)
                                  +-- 6 gaming   Sunshine + perfiles + tactil     (overlay y mando virtual)
config/vm.json  --> validado -->  +-- 7 seguridad Defender, auditoria, exposicion
                                  +-- 8 informe  Test-GamingReadiness.ps1
```

- **El acceso por defecto es RDP con NLA**, porque es lo que Windows App habla. El canal de
  juego (Sunshine/Moonlight) es **opcional** y requiere GPU con codificador por hardware.
- **El estado vive en `D:\WinGamingVM`** (logs, checkpoints, respaldos `.reg`, informes,
  fichas de control), no en el disco temporal del SKU.

## Instalación

### 0 · Requisitos (léelos, ahorran horas)

Cuenta con método de pago y cuota en el proveedor, PowerShell 5.1+, Terraform ≥1.6 para crear
la VM, Python 3.9+ para validar, Windows App en tu dispositivo y una red decente.
Checklist completo y números reales por SKU: [`docs/10-requisitos.md`](docs/10-requisitos.md).

### 1 · Configurar

```bash
cp config/vm.example.json config/vm.json      # vm.json esta en .gitignore: es tuyo
$EDITOR config/vm.json                          # proveedor, SKU, RAM, disco, edicion, apps, acceso, gaming
python scripts/validate/validate.py --verbose   # el esquema rechaza campos inventados y limites imposibles
```

En `config/vm.json` eliges: proveedor y región, `vm.size`/`vcpus`/`ramGiB` (deben **coincidir**
con lo que el proveedor ofrece de verdad, ver `config/provider-limits.json`), tamaño de discos,
edición de Windows, `remote.tipo`, `remote.tunnel` y `remote.allowedCidrs`, `gaming.channel`,
`gaming.sunshine.*`, `gaming.touchControls.profiles`, `apps.selections`/`apps.custom` y
`windows.wallpaper`/`display`/`theme`. El esquema [`config/vm.schema.json`](config/vm.schema.json)
tiene `additionalProperties: false`: si un campo no existe, **falla** en vez de ignorarse.

### 2 · Crear la VM

```bash
cd infra/azure
read -rs TF_VAR_vm_admin_password && export TF_VAR_vm_admin_password   # nunca en un fichero versionado
cp terraform.tfvars.example terraform.tfvars    # edita region/SKU/discos/CIDR
terraform init && terraform plan -out=tf.plan && terraform apply tf.plan
```

AWS: [`infra/aws/`](infra/aws/README.md) (par de claves EC2, SSM para no abrir 3389).
KVM: `sudo bash scripts/linux/kvm-gpu-check.sh --gpu 01:00` y luego
`sudo WIN_ISO=... VIRTIO_ISO=... scripts/linux/kvm-deploy.sh wingamingvm01`
([`infra/kvm/README.md`](infra/kvm/README.md)).

### 3 · Preparar Windows (las 8 fases)

```bash
# Azure (Run Command, sin abrir puertos):
az vm run-command invoke -g rg-<nombre> -n <nombre> \
  --command-id RunPowerShellScript --scripts @scripts/win/Bootstrap-GamingVM.ps1
# o desde Windows, dentro de la VM:
#   Set-Location C:\ProgramData\WinGamingVM\scripts\win
#   .\Bootstrap-GamingVM.ps1 -Fases preflight        # primero: qué se puede comprobar antes de tocar nada
#   .\Bootstrap-GamingVM.ps1                          # despues: todo, con reanudacion automatica
```

`scripts/deploy/azure-deploy.ps1` hace el ciclo completo (apply → entrega → fases → informes);
en AWS es `scripts/deploy/aws-ssm.ps1`. Cada fase es idempotente, guarda checkpoint, respalda
en `.reg` lo que toca y acepta `-WhatIf`. Detalle: [`docs/03-preparacion-vm.md`](docs/03-preparacion-vm.md).

### 4 · Conectar con Windows App

```powershell
.\scripts\client\Test-ConexionRemota.ps1 -Hostname <ip-o-dns-del-tunel>   # TCP 3389, RTT, MTU, TLS
.\scripts\client\Montar-TunelSSH.ps1 -Salto 'admin@<host>' -DestinoVM '<ip-vm>:3389'   # si no abres el puerto
```

En el dispositivo: Windows App → *Agregar equipo* → esa IP/puerto → usuario y contraseña de la
VM. La VM escribió una guía en `D:\WinGamingVM\acceso-windows-app.md`. Si `remote.tunnel` es
distinto de `none`, **no hay 3389 abierto en la nube**: se entra por el túnel, y así está
diseñado.

### 5 · Jugar (canal de juego)

Con `gaming.channel: "moonlight"` o `"both"` y un SKU con GPU:

1. La fase `gaming` instala y configura Sunshine (winget, firma verificada), limita los
   puertos a tus `allowedCidrs` y deja la Web UI local (`https://<ip>:47990`).
2. Empareja Moonlight con el PIN (ese paso es manual **porque es seguridad**).
3. Reproduce el layout táctil en el cliente siguiendo la ficha generada por la fase
   (`controles\<perfil>.moonlight.md`) y los pasos de
   [`gaming/touch/README.md`](gaming/touch/README.md).
4. Comprueba el estado: `scripts/win/Test-GamingReadiness.ps1` y `Get-SystemMetrics.ps1`.

Sin GPU declarada o verificada, la fase termina en `desactivado-sin-gpu` y el informe lo
explica: **no hay forma honesta** de hacer streaming de juego con calidad aceptable sin
codificador por hardware.

## Estructura del repositorio

```text
README.md                 esta guia
VERSION, CHANGELOG.md     versionado y notas (semver; release.yml exige que el tag = VERSION)
Makefile                  atajos: make valid / test / enlaces / tf-lint / release-check
LICENSE                   MIT (no redistuye ISO, drivers ni instaladores)
.gitignore / .gitattributes / .tflint.hcl / .markdownlint.yml
config/                   vm.schema.json, vm.example.json, provider-limits.json,
                          windows-editions.json, remote-session.json, gaming-presets.json,
                          resolutions.json      (vm.json es tuyo y esta ignorado)
apps/                     catalog.schema.json + catalog.json (30 apps verificadas),
                          sources.json (hosts permitidos), selections/{minimal,utilities,gaming,full}.json
gaming/                   README.md, antitrampas.md, steam/, ajustes/, touch/ (5 layouts),
                          profiles/ (7 perfiles), schemas/
scripts/win/              Bootstrap + 8 fases + Get-SystemMetrics + Test-GamingReadiness +
                          Unlock-ConsoleSession + Remove-GamingVM + Modules/GamingVM
scripts/deploy/           azure-deploy.ps1, aws-ssm.ps1, backup-disk.ps1
scripts/client/           Configurar-ClienteWindowsApp, Test-ConexionRemota, Montar-TunelSSH,
                          Preparar-MandoAndroide, Perfiles-Moonlight-Cliente.md
scripts/linux/            kvm-gpu-check.sh, kvm-deploy.sh (virt-install)
scripts/validate/         validate.py, check_links.py, release_notes.py, requirements.txt,
                          PSScriptAnalyzerSettings.psd1
infra/{azure,aws,kvm}/    main.tf, variables.tf, outputs.tf, README.md (+ terraform.tfvars.example)
docs/                     12 documentos en español (indice en docs/README.md)
tests/                    pruebas del validador y de los datos (pytest, sin red y sin VM)
.github/workflows/        validate.yml, windows-scripts.yml, tf-lint.yml, release.yml
.github/                  SECURITY.md, CODE_OF_CONDUCT.md, SUPPORT.md, plantillas, dependabot
```

## Aplicaciones (opcionales, verificadas)

`apps/catalog.json` describe **candidatos**, no obligaciones. Cada entrada lleva: `id` de
winget verificado contra `microsoft/winget-pkgs`, `fuente.oficial` y `descargaDirecta`
(host que debe estar en `apps/sources.json`), `instalacion.metodo`, `verificacion.firmanteEsperado`
y `installerSha256` (cuando el manifiesto lo declara), `compatibilidad` (ediciones, GPU, Store,
`bloqueadoEnVm`), `postInstalacion` (solo hooks implementados) y `riesgos`.

Cubierta la necesidad diaria: **7-Zip**, **VLC**, **VS Code**, navegador actualizado (**Google
Chrome** o **Mozilla Firefox**), diagnóstico del sistema (**HWMonitor**, **CPU-Z**,
**CrystalDiskInfo**, **HWiNFO** vía su fuente o `manual` cuando winget no lo tiene), además de
**ShareX**, **Notepad++**, **PowerToys**, **Tailscale**, **Steam**, **Epic Games Launcher**,
**Minecraft Launcher (Java Edition)**, **Sunshine**, **AntiMicroX**, **Discord**, **OBS Studio**,
**HandBrake**, **GIMP**, **LibreOffice**, redistributibles VC++/.NET y más.

```powershell
.\scripts\win\Install-Apps.ps1 -Config C:\ProgramData\WinGamingVM\config\vm.json -SoloVerificar   # que se instalaría
.\scripts\win\Install-Apps.ps1 -Config ... -Conjuntos utilities                                     # solo utilidades
```

Detalle y procedimiento para añadir apps: [`apps/README.md`](apps/README.md) y
[`docs/04-aplicaciones.md`](docs/04-aplicaciones.md).

## Controles, táctil y mandos

| Necesidad | Vía real | Automático? |
| --- | --- | --- |
| Teclado y ratón físicos (Bluetooth/USB) en Android | Windows App los usa el SO del dispositivo y el cliente los envía | n/a (es del cliente) |
| Puntero táctil / gestos | Windows App: *Direct touch* o *Mouse pointer* | no requiere nada |
| **Mando virtual en pantalla + overlay táctil** | **Moonlight** (Android/iOS) con controles en pantalla | se documenta la geometría; dibujarlo es del dispositivo |
| **Mando físico Bluetooth** | **Moonlight** lo presenta como mando XInput; **Windows App NO redirige mandos** | — |
| Remapear teclas dentro de la VM | `Set-TouchControls.ps1` prepara PowerToys Keyboard Manager; se aplica con `-AplicarEnPowerToys` | sí (con backup previo) |
| Sensibilidad del puntero por juego | `HKCU:\Control Panel\Mouse` desde el perfil (`1`–`20`) | sí (y `-RestaurarSensibilidad`) |
| Atajos de pausa/salida/menú | Steam Input / Special Keys de Moonlight / remapeo de teclas | pasos documentados |
| Indicador de conexión y latencia | overlay de Moonlight + `Get-SystemMetrics.ps1 -Modo ping` | sí |
| Perfiles por juego | `gaming/profiles/*.json` (esquema validado en CI) | sí, en lo que el SO permite |

Los 7 perfiles incluyen requisitos reales del juego, política de antichat y `pasosManuales`
de lo que solo se hace en el cliente. La frase operativa del proyecto: **el táctil funciona
donde el cliente implementa un overlay y donde el juego acepta entradas de teclado/ratón; en
el resto, no**. Nada más.

Documentos: [`gaming/README.md`](gaming/README.md),
[`gaming/touch/README.md`](gaming/touch/README.md),
[`gaming/ajustes/README.md`](gaming/ajustes/README.md),
[`docs/06-limitaciones-windows-app.md`](docs/06-limitaciones-windows-app.md),
[`docs/07-gaming-y-antitrampas.md`](docs/07-gaming-y-antitrampas.md).

## Optimización del sistema (y su límite)

`Set-GamingOptimizations.ps1` aplica plan de energía (Ultimate/Alto rendimiento/Balanceado con
`CPMINCORES`), desactiva suspensión e hibernación en la sesión de juego, apaga GameDVR si no
lo quieres, activa HAGS **solo** si hay GPU, configura el fondo/resolución/tema/escala,
desactiva indexado de archivos si molesta, y puede cerrar procesos y servicios no necesarios
**con dos listas duras**: nunca se detienen `WinDefend`, `mpssvc`, `BFE`, `Sense`, `wuauserv`,
`TermService`, `LSA`, `Schedule`, etc.; nunca se rematan `csrss`, `lsass`, `dwm`, `svchost`,
`Memory Compression`, `SearchIndexer` ni `Sunshine`.

Si el SKU no tiene GPU, o el driver está ausente (Code 43), **se reporta la limitación** en
el informe y la fase de gaming no se configura: no se simula una GPU dedicada, no se escribe
`AVC444ModePreferred=1` como si el hardware existiera, no se promete codificación por
hardware. Es el punto donde otros proyectos mienten; aquí es donde más se cuida.

## Acceso remoto y seguridad

- **NLA + CredSSP + TLS**, `SecurityLayer=1`, `MinEncryptionLevel=3`
  (`Set-RemoteDesktop.ps1`), NLA no negociable en este proyecto.
- **Cero exposición por defecto**: sin `remote.allowedCidrs` y sin `remote.tunnel`, las reglas
  de firewall se dejan **deshabilitadas** y el script te dice qué tocar. `0.0.0.0/0` es un
  **error de validación**.
- **Túnel primero**: Tailscale, Azure Bastion o SSH a `127.0.0.1` (`Montar-TunelSSH.ps1`);
  AWS puede no abrir ningún puerto (SSM por 443).
- **Defender siempre activo**; actualizaciones de firmas sí, desactivaciones no; exclusiones
  solo si las pides explícitamente.
- **Auditoría** de inicios de sesión y privilegios, bloqueo por inactividad, restricción de
  RDP a administradores, revisión de puertos en escucha, BitLocker del disco de datos
  opcional (con clave exportada **a un fichero fuera del repo**).
- **Sin credenciales en git**: `.gitignore` cubre `config/vm.json`, `*.tfvars`, `*.tfstate*`,
  `*.rdp`, `*.key`, `*.pfx`; Terraform usa variables `sensitive` sin default; el validador
  busca contraseñas, claves privadas, tokens de GitHub/Slack y firmas SAS.

[`docs/09-seguridad.md`](docs/09-seguridad.md) · [`docs/05-acceso-remoto.md`](docs/05-acceso-remoto.md)
· [`.github/SECURITY.md`](.github/SECURITY.md)

## Limitaciones (declaradas, no escondidas)

| Límite | Consecuencia práctica |
| --- | --- |
| Windows Server no tiene Microsoft Store ni Game Bar | apps UWP y todo lo que dependa de la Store queda fuera; `windows-editions.json` lo marca |
| GPU virtual (A10, T4, A10G, L4) ≠ GPU de consumo | VRAM de 4-24 GiB compartida; no esperes AAA en ultra; el driver correcto es el GRID/vGPU |
| Sin GPU = sin codificador por hardware | Moonlight no tiene sentido; `desactivado-sin-gpu` y el escritorio sigue funcionando |
| Windows App en Android no redirige mandos ni crea overlays | el mando/overlay se consigue con Moonlight, no con el cliente de Microsoft |
| Antichats de kernel (EAC, Vanguard, BattlEye, FACEIT) | no soportados en ninguna VM; no hay "modo stealth" en este proyecto |
| Facturación por hora | VM + discos + IP + egreso; los créditos de prueba se agotan; **no hay VM gratis** |
| Latencia de red y física | la RTT manda; 700 km o una WiFi compartida se notan, con cualquier configuración |
| Licencia del driver NVIDIA en consumidora/virtual | es tuya verificarla; este repo no distribuye drivers ni elude condiciones |
| Soporte Microsoft | gaming en VM de Server no es un escenario soportado oficialmente: úsalo con conciencia |

Detalle por proveedor: [`docs/02-proveedores-y-limites.md`](docs/02-proveedores-y-limites.md).
Detalle por función: [`docs/06-limitaciones-windows-app.md`](docs/06-limitaciones-windows-app.md).

## Verificar que funciona (prueba de aceptación)

```bash
python scripts/validate/validate.py --verbose    # config, apps, gaming, PowerShell, estructura, secretos
python -m pytest -q                              # pruebas del validador y de los datos
make enlaces                                     # enlaces internos de la documentacion
```

```powershell
# dentro de la VM
.\Test-GamingReadiness.ps1 -Exportar      # veredicto por componente (exit 2 si hay bloqueos)
.\Get-SystemMetrics.ps1 -Modo sesion      # sesion, listener, politicas WDDM/AVC
.\Bootstrap-GamingVM.ps1 -Fases preflight # requisitos: admin, winget, disco, edicion, GPU
```

Lista completa de comprobaciones (VM creada → bootstrap → Windows App conecta → apps →
optimización → juego → seguridad → **reproducibilidad**):
[`docs/11-prueba-de-aceptacion.md`](docs/11-prueba-de-aceptacion.md).

## Solución de problemas rápidos

| Síntoma | Qué consultar |
| --- | --- |
| El bootstrap aborta | `logs\bootstrap-*.log` + `state\fases.json`; vuelve con `-Reanudar` |
| El adaptador de pantalla sale con Code 43 | `docs/02` (driver GRID) y `-Forzar -Fases gpu` |
| No hay sonido en el cliente | `docs/05` (audio remoto, servicio de audio en Server) |
| "No veo la VM" desde el móvil | `Test-ConexionRemota.ps1`, luego el NSG/túnel (`docs/05`) |
| Va lento | `docs/08`: MTU, RTT, preset del config, `-Modo rendimiento` |
| El juego no arranca | `gaming/antitrampas.md` (VM restringida) y el perfil correspondiente |
| El táctil no hace lo que quiero | `docs/06`: Windows App no tiene overlay; hay que usar Moonlight |
| Falta una app o la firma no coincide | `apps/README.md` (cómo verificar una app nueva) |
| Quiero volver atrás | `scripts\win\Remove-GamingVM.ps1 -SoloInventario` y luego sin el flag |

## Contribuir y licencia

Lee [`docs/12-ideas-evaluadas.md`](docs/12-ideas-evaluadas.md) antes de proponer una
funcionalidad "obvia": probablemente ya se intentó y hay un motivo escrito. Las PRs usan la
plantilla del repo; hay que marcar qué se probó **de verdad** (un "no verificado" vale más que
una promesa). Licencia **MIT**; los instaladores, ISO e imágenes de Windows **no** se
redistribuyen aquí, y las apps se descargan de sus fuentes oficiales en tiempo de instalación.
Reportes de seguridad: [`.github/SECURITY.md`](.github/SECURITY.md) (canal privado, no issues).
