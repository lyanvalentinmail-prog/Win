# infra/ — que crea cada proveedor (y que no)

Terraform es la via reproducible para levantar la **VM real**. Elige una carpeta segun
donde vayas a pagar los recursos:

| Carpeta | Como | GPU | Persistencia | Recomendado para |
| --- | --- | --- | --- | --- |
| [`azure/`](azure/README.md) | az CLI + Terraform | Serie NV (A10 vGPU, GRID incluido) | disco de datos gestionado | **via por defecto**: Windows App + Android |
| [`aws/`](aws/README.md) | aws CLI + Terraform | g4dn/g5/g6 (T4/A10G/L4) | EBS gp3 cifrado | quien ya opera AWS y acepta las licencias |
| [`kvm/`](kvm/README.md) | libvirt (Terraform o `scripts/linux/kvm-deploy.sh`) | PCI passthrough de TU GPU | qcow2 + instantaneas | autohospedado, maximo control |

## Reglas comunes a las tres

1. **Sin credenciales en el repositorio.** Las contrasenas se pasan por variables de
   entorno (`TF_VAR_...`), `-var-file` ignorado por git, o se recuperan con la clave
   privada del proveedor. `terraform.tfvars` y `*.tfstate` estan en `.gitignore`.
2. **Protege el state.** Contiene la contrasena del administrador. Usa un backend remoto
   cifrado (blob de Azure con versionado + RBAC, S3 + KMS) en lugar de `terraform.tfstate`
   local; documentalo en tu wiki antes de compartir el repo.
3. **Nada se abre a 0.0.0.0/0.** Los tres modulos omiten la regla de entrada si no declaras
   tus CIDR, y los scripts de la VM repiten la politica dentro del sistema.
4. **La GPU se verifica dentro del sistema**, no en el HCL: `Install-GpuDriver.ps1` consulta
   PnP y DirectX; si falta el driver o aparece Code 43, la fase `gpu` lo declara.
5. `terraform init` necesita acceso al registry. En CI usamos `terraform fmt -check`,
   `validate` y `tflint` (ver `.github/workflows/tf-lint.yml`).

## Orden correcto de trabajo

```text
terraform apply        ->  la VM existe (todavia sin preparar)
scripts/deploy/*       ->  entrega el bootstrap y ejecuta las 8 fases
scripts/win/Test-GamingReadiness.ps1  ->  informe honesto (exit 2 si hay bloqueos)
config/vm.json         ->  ajusta apps/perfil/tunel segun el informe
```
