# 04 · Aplicaciones (opcionalidad y verificación)

## Principio

Un catálogo **no** es una lista de instalación. Lo que se instala lo deciden tres ficheros:

```text
apps/catalog.json          30 aplicaciones candidatas, con su verificación completa
apps/selections/*.json     conjuntos: minimal / utilities / gaming / full
config/vm.json -> apps     que conjuntos, que extras y que custom (este fichero NO va al repo)
```

Si una app está en el catálogo pero no en ninguna selección elegida, **no se descarga**. No
hay "instalación recomendada por defecto" que se te cuele.

```powershell
# Ver que se instalaria, sin tocar nada
.\Install-Apps.ps1 -Config ..\..\config\vm.json -SoloVerificar
# Solo los utilitarios (sin gaming), reintentando lo que fallo
.\Install-Apps.ps1 -Config ..\..\config\vm.json -Conjuntos utilities -ReintentarFallidas
```

`-Config` acepta la ruta del JSON o el objeto ya resuelto (lo normaliza `Resolve-GvmConfig`).
`-RepoDir` apunta al arbol que contiene `apps/catalog.json`: si no se pasa, se busca en
`$env:GVM_REPO_DIR`, en `C:\ProgramData\WinGamingVM\repo` y en el propio repositorio.

## Anatomía de una entrada del catálogo

```json
{
  "id": "7zip.7zip",
  "categoria": "utilidad",
  "conjuntos": ["minimal", "utilities", "gaming", "full"],
  "fuente": {
    "oficial": "https://www.7-zip.org/",
    "descargaDirecta": "https://www.7-zip.org/a/7z2604.exe",
    "licencia": "GNU LGPL 2.1"
  },
  "instalacion": { "metodo": "winget", "version": "26.04", "scope": "machine", "silentFlags": "/S" },
  "verificacion": {
    "firmanteEsperado": ["Igor Pavlov"],
    "installerSha256": "…",
    "comprobarFirmaPostInstalacion": true
  },
  "compatibilidad": { "ediciones": ["*"], "requiereGpu": false, "requiereStore": false, "bloqueadoEnVm": false },
  "postInstalacion": ["crear-carpeta-juegos"],
  "riesgos": ["el instalador ofrece navegador/search si no se usan silentFlags"]
}
```

Contratos (JSON Schemas con `additionalProperties: false`): `apps/catalog.schema.json` y
`apps/selections/selections.schema.json`. Un campo inventado o mal escrito **falla en CI**.

## Las cuatro comprobaciones antes de tocar el sistema

1. **Compatibilidad con la edición.** `compatibilidad.ediciones` vs `windows.edition` de tu
   config. Un ejemplo real: `Mojang.Minecraft` (Java Edition) funciona en Server; las
   ediciones que piden Microsoft Store no. Con `apps.skipUnsupported: true` la app queda
   `omitida` en lugar de fallar.
2. **GPU y Store reales.** `requiereGpu` y `requiereStore` se consultan contra lo que
   `Get-GvmGpuInfo` y la imagen informan **en esta máquina**, no contra un supuesto.
3. **Antichat.** `bloqueadoEnVm: true` (o un perfil con `antitrampas.vm: restringida`) ⇒ la
   app **no** se instala y `Test-GamingReadiness.ps1` lo marca como ERROR. No es
   capricho: es que no se puede jugar así y el proyecto no lo disimula.
4. **Origen.** La URL de descarga debe vivir en un host de `apps/sources.json` y el método
   debe ser `winget`. Un método `store`/`manual` se reporta como `pendiente-manual` con los
   pasos, **sin fingir** que se ha instalado.

## Verificación de firma y hash

- **Antes de instalar**: winget valida `InstallerSha256` cuando el manifiesto lo declara.
  El catálogo fija el hash para `7zip`, `Valve.Steam` y `Mojang.Minecraft` y anota en cada
  entrada cuándo se tomó el snapshot (`snapshotVerificadoEl: 2026-10-18`).
- **Después de instalar**: `Test-GvmFirma` comprueba `Get-AuthenticodeSignature` del
  ejecutable declarado en `verificacion.ejecutableRuta` contra `firmanteEsperado`. Si el
  firmante no coincide ⇒ `advertencia-firmante` (o fallo si la app lo exige). Las apps GPL
  sin firmar en su `unins000.exe` no hacen fallar el bootstrap: se registra el motivo.

## Añadir una app (procedimiento honesto)

```bash
# 1) Existe el id exacto en winget? (no vale "cualquiera se le parece")
gh api repos/microsoft/winget-pkgs/git/trees/master:manifests/<primera-letra>/<Publicador>/<Paquete>
# 2) Coges el manifiesto del instalador y su SHA-256 reales
gh api repos/microsoft/winget-pkgs/contents/manifests/<l>/<Pub>/<Pkg>/<version>/<id>.installer.yaml
# 3) Verificas que la URL del instalador es el host del fabricante (no un mirror)
# 4) Anades el host a apps/sources.json con el producto y la prueba de que es oficial
```

Después: `python scripts/validate/validate.py` comprueba que el id existe en la forma, que el
hash tiene 64 hex, que el host está en la allow-list y que `postInstalacion` solo usa hooks
**implementados** (7). Si un hook no existe, la CI te lo dice antes de que tengas una VM
"configurada" que no lo está.

## Estado de cada app en el informe

| `Estado` | Significado | ¿Se puede arreglar? |
| --- | --- | --- |
| `instalada` | winget salió 0, la lista la ve y la firma coincidió | — |
| `omitida` | no aplica a esta edición/GPU/Store y `skipUnsupported` | cambiando la edición o el SKU |
| `pendiente-manual` | el método no está automatizado (Store, licencia) | siguiendo `pasosManuales` |
| `bloqueada-en-vm` | incompatible con VM (antichat) | no, y no se debe intentar |
| `rechazada-fuente` | host no permitido | corrigiendo el catálogo con la fuente oficial |
| `no-en-catalogo` | el id de la selección no existe en `catalog.json` | añadiéndolo con verificación |
| `sin-dependencia` | falta winget en la imagen | bootstrap de App Installer |
| `fallida` | el instalador devolvió error | ver `Detalle` y el log |

## Juegos

Steam, Epic y Minecraft son apps normales del catálogo. Lo que **no** es automático: iniciar
sesión en tu cuenta, comprar juegos, ni que el juego arranque en la VM (depende del
antichat y de la GPU). `gaming/profiles/*.json` declara `requisitos` reales y
`compatibilidadVm`, y `gaming/antitrampas.md` documenta el estado por título con su fuente.

## Qué se ha decidido no automatizar y por qué

| Solicitud típica | Respuesta del proyecto |
| --- | --- |
| "Instala la última build de CapFrameX/ReShade" | no están en winget: se documenta la fuente y se deja `manual`, sin descargar de un tercero |
| "Instala Discord/Netflix/Spotify" | sí están en el catálogo si el id es oficial; si no, entran como `manual` |
| "Instala el Game Pass/Xbox app" | no en Server: el catálogo lo marca con `requiereStore` y la fase lo omite |
| "Pon antivirus ligero" | no se desactiva Defender; no se sustituye por otro sin que tú lo pidas en `apps.custom` |
| "Optimizador de RAM" | no existe tal cosa que no sea cerrar procesos: `power.processCleanup` lo hace con lista de protegidos |
