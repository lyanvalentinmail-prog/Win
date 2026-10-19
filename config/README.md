# config/ — configuración validada

| Fichero | Que define | Leido por |
| --- | --- | --- |
| `vm.schema.json` | contrato de `vm.json` (draft 2020-12, `additionalProperties: false` en todos los objetos) | `validate.py`, `Get-GvmConfig` |
| `vm.example.json` | un despliegue realista de ejemplo (azure, NV6ads, Server 2025, RDP + tailscale, `apps.selections: [utilities, gaming]`) | copiarlo a `vm.json` |
| `vm.json` | **tu** configuración — ignorado por git | todas las fases del bootstrap |
| `provider-limits.json` | vCPU/RAM/discos/ofertas **reales** por SKU, con `gotchas` | `validate.py`, `Test-GvmRequisito` en la VM |
| `windows-editions.json` | qué admite cada edición (winget, Store, shell, personalización, GameDVR, DX12U, multi-sesión) | `Install-Apps.ps1`, `Set-GamingOptimizations.ps1`, el informe |
| `remote-session.json` | políticas base de sesión, claves reales de `Terminal Services`, presets `low-latency`/`balanced`/`fidelity` | `Set-RemoteDesktop.ps1` |
| `gaming-presets.json` | 4 presets (resolución/fps/bitrate/codec), guía geográfica, fórmula de tráfico y reglas de validación | `Set-Sunshine.ps1`, `gaming/gastos.md` |
| `resolutions.json` | resoluciones válidas y escalado recomendado | `Set-GamingOptimizations.ps1`, `validate.py` |

## Reglas del esquema (y por qué duelen)

- **Nada de campos sobrantes**: un `ramGB` en lugar de `ramGiB` se rechaza en vez de
  ignorarse en silencio.
- **`osDiskGiB >= 64`** y `dataDiskGiB` en `0` o `128…32767`: son los pasos reales de los
  discos gestionados.
- **`gpu.mode`** es `none | paravirtual | passthrough`: no existe "gpu: true".
- Si un instalador de driver se declara con `instaladorUrl`, **debe** ser `https://` y traer
  `instaladorSha256` de 64 hex.
- **`remote.tunnel != none` obliga a `allowedCidrs: []`**: si hay túnel, no se abre el puerto.
- Las claves de objeto están restringidas a `^[0-9a-z]+$` con valores `^//`… : imposible
  inyectar rutas o comandos por una clave de JSON.
- `apps.custom` no puede contener `Microsoft.Windows.Defender` (el proyecto no gestiona la
  eliminación del antivirus).
- `power.disableUnusedServices` tiene una **lista negra** dentro del esquema: servicios de
  seguridad, red de sesión o arranque no se pueden nombrar ni para desactivarlos.
- `cost.acknowledgePaidResources` debe ser `true`: recuerda que esto **se factura**.

## Validar sin tocar ninguna VM

```bash
python scripts/validate/validate.py --solo config --verbose
python scripts/validate/validate.py --online      # contrasta los ids de winget con el repo oficial
```

Dentro de la VM, la fase `preflight` relanza las mismas comprobaciones estructurales antes de
tocar nada.
