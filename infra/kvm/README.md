# infra/kvm

Modulo Terraform para la VM Windows real en **kvm**. Los supuestos duros (SKU, AMI/imagen,
tamanos de disco, apertura de red) son variables: comprueba precios y disponibilidad en tu
cuenta antes de aplicar, porque **ningun valor por defecto de este repo es una oferta**.

## Uso

```bash
export TF_VAR_...            # ver variables.tf; las contrasenas van por entorno
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tf.plan
terraform apply tf.plan
```

## Despues del apply

La VM esta **creada, no preparada**. Entrega `scripts/win/Bootstrap-GamingVM.ps1` con el
mecanismo propio del proveedor (SSM en AWS, `virsh`/console en KVM) y ejecuta las 8 fases.
Sin esa preparacion no hay apps, ni politicas de sesion, ni linea de acceso, ni informe.

## Limites que este modulo no puede saltarse

- La **licencia de la GPU**: en AWS los drivers GRID para T4/A10G/L4 se contratan aparte de
  la instancia; la GPU es para computacion/streaming general, no una estacion de juego
  soportada. Los juegos con antitrampas a nivel kernel no estan soportados.
- **Sin disco cifrado + TPM**: la vTPM es del hypervisor; si cambias de host, los protectores
  de BitLocker con TPM pueden requerir la clave de recuperacion. Guarda la clave fuera de la VM.
- Windows App necesita un endpoint accesible. Con tunel (Session Manager/Tailscale/SSH) no
  abras 3389; con IP publica, la regla existe solo si pusiste tus CIDR.

## Que hace (y que no hace) `terraform apply` aqui

El modulo crea volumenes qcow2 y el dominio, **no instala Windows**. El orden real:

```bash
sudo scripts/linux/kvm-gpu-check.sh                 # IOMMU, grupos ACS, GPU libre
terraform -chdir=infra/kvm apply                      # discos + dominio (UEFI, vTPM, VirtIO)
virsh attach-disk <dominio> /ruta/Windows.iso hdc --type cdrom --mode readonly
virsh attach-disk <dominio> /ruta/virtio-win.iso hdd --type cdrom --mode readonly
virt-viewer -c qemu:///system <dominio>               # instalar Windows y pinchar los drivers VirtIO
virsh detach-disk <dominio> hdc && virsh detach-disk <dominio> hdd
```

Hasta que no hayas montado las ISO el dominio arranca contra un disco vacio y se queda en
"no bootable device": es el estado esperado, no un fallo del modulo. Los medios se montan
con `virsh` a proposito: cambiar de "arrancar de la ISO" a "arrancar del disco" es un paso
manual en cualquier via de KVM, y meterlo en el estado de Terraform hacia que un
`terraform apply` posterior se lo cargara.

## SINTAXIS del provider (importante)

`infra/kvm/main.tf` esta escrito contra **dmacvicar/libvirt 0.9.x**, que paso el dominio de
bloques HCL (`disk { ... }`, `network_interface { ... }`) a **atributos anidados**
(`devices = { disks = [ ... ], interfaces = [ ... ] }`). Con un provider 0.7/0.8 este
fichero no valida: los argumentos `hostdev`, `clock_offset` y el bloque `disk` con `file`
no existen ahi. Si prefieres no depender de Terraform, `scripts/linux/kvm-deploy.sh`
(virt-install) genera el mismo dominio: mismo q35+UEFI, misma vTPM, mismo VirtIO, mismo
passthrough.

Variables que no estan en el resto de proveedores y que cambian el resultado:

| Variable | Para que |
| --- | --- |
| `cpu_mode` | `host-passthrough` (rendimiento) o `host-model` (portable). |
| `disk_cache` | `writeback` rinde mas; `none` si el disco del host no tiene SAPI/SBWA. |
| `virtio_queues` | colas multihard de virtio-net (0 = valor por defecto del host). |
| `uefi_code_fd` / `uefi_vars_fd` | rutas de OVMF, que cambian por distribucion. |
| `gpu_hostdev_ids` | direcciones PCI `0000:01:00.0` ya atadas a vfio-pci. **No se simulan.** |

## Audio y GPU

El audio del guest viaja por el canal de sesion (RDP/Sunshine), no por una tarjeta virtual:
por eso el dominio no declara `soundhw`. Y si el host no tiene una GPU pasada, el informe de
preparacion (`Test-GamingReadiness.ps1`) lo reporta como limitacion; el modulo no inventa un
adapter.
