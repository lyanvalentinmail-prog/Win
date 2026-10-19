# 11 · Prueba de aceptación

Si esto está en verde, el despliegue funciona. Si algo está en rojo, el proyecto **no**
dice "listo". No borres filas porque "en mi caso funciona": añade la evidencia.

## 0 · Preparación

- [ ] `python scripts/validate/validate.py --verbose` → 0 errores.
- [ ] `python -m pytest -q` → todo en verde.
- [ ] `config/vm.json` es **tu** copia (el repo solo trae `vm.example.json`), con tu IP/túnel,
      tus conjuntos de apps y `cost.acknowledgePaidResources: true`.

## 1 · La VM existe y es una VM real de Windows

- [ ] `terraform output` / `az vm list -d` / `virsh list` muestra la VM en ejecución con el SKU pedido.
- [ ] Dentro: `systeminfo | Select-String "OS Name","Version"` → la edición pedida.
- [ ] `Get-ComputerInfo | Select-Object OsName, OsVersion, CsTotalPhysicalMemory, CsNumberOfProcessors`
      coincide con `config/vm.json` (RAM/vCPU), y `Get-GvmCpuResumen` lo informa.
- [ ] Disco de datos presente y montado: `Get-Disk`, `D:\` existe y es persistente
      (la fila "Persistencia D:" del informe lo comprueba; `-IncluirDiscos` no existe, se
      consulta `Get-Volume` dentro de la VM).

## 2 · El bootstrap pasó

- [ ] `C:\ProgramData\WinGamingVM\state\fases.json` → 8 fases en `completada` (o `fallida` con motivo escrito).
- [ ] `C:\ProgramData\WinGamingVM\logs\bootstrap-*.log` sin `ERROR` sin resolver.
- [ ] `informes\preparacion-*.md` abre y su veredicto es el esperado para **tu** HW:
      con GPU → "preparada para escritorio y juego"; sin GPU → "preparada para escritorio;
      juego no recomendado", con el motivo.
- [ ] Repetir el bootstrap es idempotente: `-Forzar -Fases escritorio,remoto` no duplica
      reglas ni claves, y el log lo muestra.

## 3 · Windows App conecta (el requisito principal)

- [ ] Desde Android (u otro dispositivo), Windows App ve el equipo y **abre sesión**.
- [ ] Menú Inicio visible, barra de tareas funcional, Explorador abre `D:\`.
- [ ] Apps por defecto presentes: Edge, Bloc de notas, Calculadora, Administrador de tareas,
      Configuración, Visor de eventos, Reproducción de vídeo con VLC, compresión ZIP con 7-Zip.
- [ ] Puedes **instalar otra app** dentro de la VM (p. ej. `winget install Notepad++` o desde
      el catálogo con `-Conjuntos`) y aparece en Inicio.
- [ ] Portapapeles bidireccional (si `clipboard: true`), y **bloqueado** si lo pusiste en false.
- [ ] Audio audible en el dispositivo (o el informe declara por qué no).
- [ ] Al desconectar y reconectar en < `MaxReconnectionTime`, la **misma** sesión sigue viva
      (ventanas abiertas donde las dejaste).
- [ ] Tras reiniciar la VM, reconectas y los datos de D: siguen ahí.

## 4 · Apps del catálogo

- [ ] `informes\apps-instalacion.csv`: ninguna fila en `fallida` sin motivo escrito.
- [ ] Las filas `pendiente-manual` tienen sus `pasosManuales` ejecutados o asumidos como límite.
- [ ] `instalada` = el ejecutable existe y la **firma** coincide con `firmanteEsperado`
      (ver el log de `Test-GvmFirma`); nada "instalado" solo porque winget devolviese 0.

## 5 · Optimización y GPU

- [ ] `powercfg /getactivescheme` = el plan elegido en `power.plan`.
- [ ] `Get-GvmGpuInfo` / `nvidia-smi` informan la GPU (o el informe dice "sin GPU" sin rodeos).
- [ ] `Test-GamingReadiness.ps1 -Exportar` → fila "DirectX/3D" en OK si hay GPU; en WARN si no.
- [ ] Ningún servicio de seguridad en la lista de prohibidos ha sido tocado:
      `Get-Service WinDefend,mpssvc,Sense,BFE | Select Name,Status,StartType`.
- [ ] Los procesos que se cerraron están listados en `informes\optimizacion-*.md` (con
      `Run` quitado para que no vuelvan solos).

## 6 · Gaming (si el canal lo permite)

- [ ] Sunshine: `https://<ip>:47990` accesible **desde la red permitida** (y no accesible desde fuera).
- [ ] Moonlight enlaza con el PIN, y el log de Sunshine muestra el **codificador real** en uso
      (nvenc/hevc/av1); si sale `x264` en una VM con GPU, revisa el driver.
- [ ] Un juego sin antichat arranca y se ve en el overlay de estadísticas (fps/frame time).
- [ ] Un perfil con `antitrampas.vm: restringida` aparece como **no instalado** y el informe
      lo marca ERROR.
- [ ] Los layouts táctiles: reproducidos en el cliente Moonlight siguiendo
      `controles\<perfil>.moonlight.md`, y probados **en el juego concreto** (aquí no hay
      automatismo posible: es un trabajo del dispositivo).
- [ ] Mando físico: si va por Moonlight, funciona; si esperabas que Windows App lo redirija,
      vuelve a `docs/06` (no existe).

## 7 · Seguridad

- [ ] `netstat -ano | Select-String '0.0.0.0:(3389|47984|47990|48010)'` = solo lo que declaraste.
- [ ] Con `remote.tunnel != none`: el NSG **no** tiene regla de entrada 3389 (compruébalo en el proveedor).
- [ ] `Get-MpComputerStatus | Select AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated` → `True/True` y fecha reciente.
- [ ] NLA activa (`UserAuthentication=1`) y `SecurityLayer=1`.
- [ ] Bloqueo por inactividad efectivo: deja la sesión X min y reconecta → pide credenciales.
- [ ] El repo **no** contiene secretos: `python scripts/validate/validate.py --solo secretos` y
      `git log --stat` de tu fork (si subiste un `.tfvars`, rota la contraseña).

## 8 · Reproducibilidad (el criterio final)

- [ ] Destruye la VM (conservando el disco de datos o sin conservarlo), vuelve desde
      `terraform apply` + `azure-deploy.ps1` y la VM queda **igual de preparada** sin
      intervención manual, salvo los pasos `manual` documentados.
- [ ] Otra persona, siguiendo `README.md` + `docs/`, puede llegar al mismo estado con su
      propia cuenta, sin preguntas y sin que tú le pases un fichero con credenciales.

## Formato del informe

Copia este checklist, márcalo y pégalo en un issue/discusión cuando algo falle. Los items
sin marcar con su comando de verificación valen más que cualquier descripción.
