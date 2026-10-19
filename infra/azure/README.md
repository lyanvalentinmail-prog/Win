# infra/azure — VM real de Windows con GPU en Azure

## Antes de nada

1. Ten una **suscripcion que pague** (Azure cobra VM + discos + IP + egreso por hora/GB).
2. Comprueba capacidad del SKU en tu region — los SKU NV tienen capacidad limitada:

```bash
az account set -s "<tu-suscripcion>"
az vm list-skus -r Microsoft.Compute -l westeurope --size Standard_NV6ads_A10_v5 -o table
```

3. Lee [docs/02-proveedores-y-limites.md](../../docs/02-proveedores-y-limites.md): ahi esta
   lo que Azure **no** deja hacer (GPU fisica completa, Store, Game Bar, soporte oficial de gaming).

## Despliegue

```bash
# La contrasena se lee por terminal (sin eco y sin quedar en el historial) y se exporta:
read -rs TF_VAR_vm_admin_password && export TF_VAR_vm_admin_password
cp terraform.tfvars.example terraform.tfvars   # edita
terraform init
terraform plan -out=tf.plan
terraform apply tf.plan
```

`terraform validate` y `tflint` corren en CI (`.github/workflows/tf-lint.yml`).
Este repositorio **no** guarda `terraform.tfvars` ni el state en git.

## Despues del apply: preparar Windows

Terraform solo crea la infraestructura. La preparacion (RDP, apps, optimizacion, seguridad,
canal de juego) la hace el bootstrap en la propia VM, por Run Command:

```powershell
..\..\scripts\deploy\azure-deploy.ps1 -ResourceGroup rg-wingamingvm01 -Name wingamingvm01 -ConfigFile ..\..\config\vm.json
```

Equivalente manual:

```bash
az vm run-command invoke -g rg-wingamingvm01 -n wingamingvm01 \
  --command-id RunPowerShellScript --scripts @../../scripts/win/Bootstrap-GamingVM.ps1
```

## Driver de GPU

`Install-GpuDriver.ps1` (fase `gpu`) decide segun el origen declarado:

| `gpu.instaladorDesde` | Que hace |
| --- | --- |
| `extension-azure` | `az vm extension set --publisher Microsoft.HpcCompute --name NvidiaGpuDriverWindows --slot Default` y **verifica dentro de la VM** |
| `url-oficial` | descarga, exige HTTPS, comprueba SHA-256 y firma Authenticode, instala en silencio |
| `omitir` | nada; `Test-GamingReadiness` marca la limitacion |

Si prefieres fijar la extension desde Terraform, anade `azurerm_virtual_machine_extension`
con `type_handler_version` resuelta por `az vm extension image list` — no dejes un numero
copiado a ciegas, porque una version no soportada deja el adaptador con Code 43.

## Que se ha abierto en la red

- Nada, si `rdp_allowed_cidrs = []`. En ese modo Windows App entra por un tunel
  (Tailscale, Azure Bastion, o un tunel SSH a 127.0.0.1:3389 desde dentro de la red).
- Con CIDR propias: regla TCP `3389` (+UDP si lo pides) **solo** a esas direcciones, y dentro
  de la VM el firewall de Windows limita el perfil Public y restringe RDP a administradores.
- Los puertos de Sunshine se crean **deshabilitados** en el NSG si no hay CIDR declaradas:
  el script te dira como abrirlos, no lo hara a escondidas.

## Destruir

```bash
terraform destroy   # borra la VM y la IP; el disco de datos se elimina con ella
```

Si quieres conservar los juegos, `terraform state rm azurerm_managed_disk.datos[0]` y
desanclalo antes, o haz una instantanea del disco (ver `scripts/deploy/backup-disk.ps1`).
