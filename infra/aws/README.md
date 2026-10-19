# infra/aws

Modulo Terraform para la VM Windows real en **aws**. Los supuestos duros (SKU, AMI/imagen,
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
