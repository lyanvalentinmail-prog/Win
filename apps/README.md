# apps/ — catálogo de aplicaciones

Todo lo que se puede instalar en la VM está aquí, **descrito, no embebido**: en este
directorio no hay un solo instalador. Hay datos que los scripts de Windows consumen y
esquemas que los mantienen honestos.

```text
catalog.schema.json      contrato de cada app (additionalProperties: false)
catalog.json             30 aplicaciones verificadas (snapshot 2026-10-18)
sources.json             hosts de descarga permitidos (allow-list vinculante)
selections/minimal.json     lo mínimo útil (navegador, 7-Zip, VLC)
selections/utilities.json   + VS Code, diagnostico, captura, PowerToys...
selections/gaming.json      + Steam, Epic, Minecraft, Sunshine, monitorizacion
selections/full.json        todo el catalogo candidato
selections.schema.json   contrato de una seleccion
```

## Como se decide que se instala

```text
config/vm.json -> apps.selections = ["utilities", "gaming"]   (que ficheros de selections se leen)
config/vm.json -> apps.custom     = [{ "wingetId": "ShareX.ShareX", "reason": "..." }]
                                                            (anadidos a mano, id por id y con motivo)
config/vm.json -> apps.skipUnsupported = true                (incompatible => omitida, no error)
        |
        v
  union de ids (selecciones + custom)  ->  cada id se busca en catalog.json
        |
        v  (si no esta: 'no-en-catalogo' y NO se instala a ciegas)
  comprobaciones: edicion compatible -> GPU -> Store -> bloqueadoEnVm -> metodo soportado
        -> host de la URL en sources.json -> firma post-instalacion
```

Nada de eso "se baja todo por si acaso": `Install-Apps.ps1` solo descarga lo que salió de la
unión de selecciones y pasó los filtros. `-SoloVerificar` imprime la lista sin tocar nada.

## Cómo se verifica una app antes de entrar en el catálogo

1. El **id de winget existe** en `microsoft/winget-pkgs` (se comprueba contra el árbol de
   `manifests/`, no contra un buscador que muestra "paquetes sugeridos").
2. La **URL del instalador** es el host del fabricante y está en `sources.json`.
3. El **SHA-256** del manifiesto de winget se copia tal cual (cuando el manifiesto lo
   declara) y `snapshotVerificadoEl` registra cuándo se miró.
4. El **firmante** esperado se anota (lo que devuelve `Get-AuthenticodeSignature` tras
   instalar). Apps sin firma en el uninstaller se documentan en `riesgos`.
5. La **licencia** se declara (`fuente.licencia`) y no se re-distribuye nada.

El validador (`scripts/validate/validate.py`) comprueba hosts contra `sources.json`, hashes
de 64 hex, métodos soportados, hooks de `postInstalacion` existentes y que cada `id` sea
`Publicador.Paquete`. Un catálogo que no valida no se fusiona.

## Estacionalidad de los datos

Los números de versión y los hashes **caducan** (por eso el campo `snapshotVerificadoEl`).
Si ves una app que falla por versión:

```bash
gh api repos/microsoft/winget-pkgs/contents/manifests/<letra>/<Publicador>/<Paquete>
```
y actualiza la entrada. `Notepad++` y `Zoom` están marcadas con `versionObservada` porque
sus instaladores cambian con frecuencia y el firmante ha dado sorpresas.

## Anadir una app propia (sin tocar el catalogo)

`config/vm.json -> apps.custom` admite cualquier id **que esté en el catálogo**. Si no está,
primero se añade al catálogo con su verificación (paso anterior). No hay "URL libre" en la
config a propósito: una URL arbitraria ejecutada como administrador en una VM con tu sesión
de juego es una puerta trasera con nombre propio.
