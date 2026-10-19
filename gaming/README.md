# gaming/ — perfiles de control y ajustes

Contenido:

| Ruta | Qué es |
|---|---|
| `profiles/*.json` | Un perfil por juego: requisitos, estado del anticheat en VM, preset de rendimiento, canales recomendados (RDP vs Moonlight), mapeos, atajos e indicadores. |
| `touch/layouts/*.json` | Especificaciones de layouts táctiles (posición/tamaño/opacidad normalizadas) para reproducir en el cliente Moonlight. Ver `touch/README.md`. |
| `schemas/gaming-profile.schema.json` | JSON Schema de los perfiles; lo validan `scripts/validate/validate_gaming_profiles.py` y CI. |
| `steam/README.md` | Steam Input / mando virtual → teclado y ratón: qué se puede automatizar y qué no. |
| `ajustes/` | Los ajustes de Windows que el proyecto aplica o recomienda, y por qué. |

## Reglas de este directorio

1. **Un perfil describe la realidad, no la promoción.** El campo
   `compatibilidadVm.antitrampas.vm` puede ser `permitida | restringida | desconocida`
   y `vmReportada` indica la fuente. Si es `desconocida`, el auditor lo repite al usuario.
2. **Nada se "promete" sin canal.** `canales.rdp.recomendado` / `canales.moonlight.recomendado`
   dicen por dónde tiene sentido jugar ese título. Un shooter en RDP se marca como no
   recomendado, aunque el juego "arranque".
3. `aplicacion.host` / `aplicacion.cliente` separan lo que un script deja listo en la VM
   de lo que exige tocar el móvil. Cualquier cosa del segundo grupo aparece en
   `aplicacion.pasosManuales` y se imprime en la ficha que se genera en la VM.
4. Los requisitos mínimos se citan con `requisitos.fuente` (URL oficial del fabricante o
   tienda). `scripts/validate/validate_gaming_profiles.py` comprueba que el host de esa URL
   es la ficha del producto, no un blog.

## Cómo crear un perfil para tu juego

```bash
cp gaming/profiles/steam-input-generico.json gaming/profiles/mi-juego.json
# editar id, nombre, procesos, requisitos, anticheat y controles
python3 scripts/validate/validate_gaming_profiles.py gaming/profiles/mi-juego.json
```

Luego añade el `id` a `gaming.touchControls.profiles` en `config/vm.json`; el bootstrap
lo copiará a la VM y `Set-TouchControls.ps1` generará la ficha del cliente.
