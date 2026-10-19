# 02 · Proveedores y límites reales

Este documento es la razón de ser del proyecto. Cada fila está escrita **contra la
documentación y el comportamiento del proveedor**, no contra una hipótesis. Si tu caso no
está aquí, se comprueba antes de prometer nada y se añade al documento.

## Matriz de capacidad (lo que cada vía puede dar de verdad)

| | Azure (serie NV) | AWS (g4dn/g5/g6) | KVM/Proxmox autohospedado |
| --- | --- | --- | --- |
| VM de Windows real | sí | sí | sí |
| GPU "visible" dentro de Windows | sí, GPU virtual A10 con driver GRID | sí (T4/A10G/L4), con licencia de driver según caso | sí **solo** con PCI passthrough |
| Codificador de vídeo (NVENC/HEVC/AV1) | sí con el driver GRID correcto | normalmente sí (los datos de media funcionan; verifica en el invitado) | sí, si has pasado la GPU física |
| Windows Store / Xbox app / Game Bar | **no** (Server no la trae; en Win11 la Store existe pero las apps UWP tienen condiciones) | igual que Azure según imagen | depende de la imagen que instales |
| Mandos y controles táctiles vía Windows App | no redirige mandos; táctil solo como puntero/gesto | igual | igual |
| Mando virtual + overlay táctil | vía Moonlight (cliente) | vía Moonlight | vía Moonlight |
| Antitrampas de kernel (EAC/Vanguard/BattlEye/BSP) | **no soportado** | **no soportado** | **no soportado** (no hay truco: ni con passthrough de GPU hay soporte oficial) |
| Persistencia de datos | disco gestionado (StandardSSD o Premium) | EBS gp3 cifrado | qcow2 + instantáneas |
| Precio | por hora del SKU + discos + IP + egreso | por hora + EBS + transferencia | tu hardware y tu luz |
| Cumplimiento de licencia Windows | incluida en el precio del SKU (licensing por hora) | incluida en la AMI | **la licencia es tuya** |

> Regla del proyecto: si una fila dice "no soportado", los scripts **lo reportan como
> límite** en `Test-GamingReadiness.ps1` y no instalan lo que no va a funcionar.

## Azure — lo que hay que saber

**La serie NVadsA10_v5** (`Standard_NV6ads_A10_v5` y hermanos) es la vía con más sentido:

| SKU | vCPU | RAM | Disco temporal | VRAM de la GPU virtual |
| --- | --- | --- | --- | --- |
| `Standard_NV6ads_A10_v5` | 6 | 55 GiB | 180 GiB | 4 GiB |
| `Standard_NV12ads_A10_v5` | 12 | 110 GiB | 360 GiB | 8 GiB |
| `Standard_NV18ads_A10_v5` | 18 | 220 GiB | 720 GiB | 12 GiB |
| `Standard_NV36ads_A10_v5` | 36 | 440 GiB | 720 GiB | 24 GiB (2 GPU) |

Estas cuatro columnas salen de la página oficial de tamaños de Azure (serie NVadsA10_v5),
igual que los 2 500 Mbps de red y los 4 discos de datos del `NV6ads`. Para el resto de
cifras (ancho de banda y número máximo de discos de los SKU más grandes) **no ponemos
números aquí**: compruébalos en esa página o con `az vm list-vm-capabilities -l <region> -s
<SKU>` antes de dimensionar la librería. El módulo de Terraform, por diseño, monta **un**
disco de datos (LUN 0) persistente: si necesitas más volumen, añade otro disco y mueve
`steamapps` a él.

> El ancho de banda del SKU es un máximo de la plataforma: la red real depende de tu ruta,
> del NSG, del túnel y del tráfico del host. Elige la región **más cercana a ti**, no la más
> barata: la RTT es lo que se nota en el input, y 4 000 km de distancia no se arreglan con
> configuración.

CPU: AMD EPYC 74F3v (Milan) a 3.2 GHz base / 4.0 GHz turbo. La licencia del driver GRID
NVIDIA está **incluida en el precio del SKU** en Azure. Esto no es una estación de juego: es
GPU virtual con fracción de memoria y codificadores soportados para remote visualization y
gaming no crítico.

Cosas que se rompen si las ignoras:

- **Driver equivocado = Code 43.** La serie NV necesita el *NVIDIA vGPU/GRID driver*
  (serie 19.6 LTS o 20.x), no el driver GeForce de consumo. `Install-GpuDriver.ps1`
  comprueba el estado PnP del adaptador y lo declara.
- **Win11 pide Trusted Launch** (vTPM + Secure Boot), 4 GiB, 2 vCPU, 64 GB. El módulo de
  Terraform lo pone con `secure_boot_enabled = true` + `vtpm_enabled = true`, que es como se
  escribe en el provider `azurerm` 4.x; el viejo `security_type = "TrustedLaunch"` (3.x) ya no
  existe y `terraform validate` lo rechaza.
- **Capacidad regional limitada**: si `az vm list-skus` no lo lista o el deploy falla con
  `ResourceAllocationFailure`, no es un bug del repo.
- **`NVv4` (GPU de series anteriores) está retirado** (30/09/2026): no lo uses como destino.
- **WDDM y Server 2025**: con `fEnableWddmDriver=1` hay reportes de DWM reiniciándose en
  Server. El proyecto **no** lo fuerza: se configura (`remote.session.hardwareEncoding`) y
  `Test-GamingReadiness.ps1` comprueba el estado real.
- **Soporte**: Microsoft no da soporte a "juegos en VM de Server"; la VM de Server está
  licenciada para escritorio remoto/administración. Tenlo presente antes de montar un
  servicio con terceros.

## AWS — lo que hay que saber

- `g4dn.xlarge` (T4, 16 GB VRAM, 4 vCPU/16 GiB), `g5.xlarge/2xlarge/4xlarge` (A10G),
  `g6.xlarge` (L4). **No hay SKU "de gaming"**: los perfiles de instancia son de compute
  gráfico/visualización.
- El driver **GRID/vWS necesita licencia NVIDIA** aparte en muchos escenarios de consumo;
  los drivers "Game Ready" no son el camino en instancias de centro de datos. Aquí no se elude ninguna
  licencia: si no tienes derechos de uso del driver, esta vía no es para ti.
- **Ningún juego con antichat de kernel está soportado** (EAC, Vanguard, BattlEye,
  FACEIT, Ricochet). En AWS esto es idéntico que en Azure: no hay modo "soportado".
- El acceso sin abrir 3389 se hace por **SSM** (rol con `AmazonSSMManagedInstanceCore`):
  `scripts/deploy/aws-ssm.ps1` lo usa, y por eso la instancia puede vivir en una subred
  privada.
- La contraseña inicial de la instancia se recupera con **tu clave privada**
  (`aws ec2 get-password-data`). Nunca se guarda en el repo ni en outputs de Terraform.
- `DisableApiTermination` en el módulo está a `true` a propósito: perder la instancia con
  la librería de juegos dentro es caro de digerir.

## KVM / autohospedado — lo que hay que saber

- Es la única vía con **GPU física completa** y, por tanto, la que puede acercarse a la
  experiencia local. Exige: IOMMU activo, grupos de PCI limpios, GPU desvinculada del host,
  UEFI + Secure Boot + vTPM si Windows 11, y `vfio-pci` bien atado.
- **La licencia del driver GeForce**: los términos de NVIDIA para consumo no autorizan
  virtualización/compartición en host no soportado. Con una GPU dedicada entera en passthrough
  para tu propio uso personal el escenario es distinto al de un servicio; el proyecto no da
  asesoramiento legal: **revisa los EULA** (ver `docs/12-ideas-evaluadas.md`).
- Sin passthrough, `virtio`/QXL no te da NVENC: la fase de gaming termina en
  `desactivado-sin-gpu` y el informe lo dice.
- `scripts/linux/kvm-gpu-check.sh` diagnostica todo esto **antes** de crear la VM.

## Comprobaciones previas

1. **Región/capacidad**: `az vm list-skus -r Microsoft.Compute -l <region> --size <SKU>`;
   en AWS, `aws ec2 describe-instance-type-offerings`; en KVM, el diagnóstico anterior.
2. **Cuota de vCPU y de discos**: los SKU NV tienen cuota regional propia. Auméntala antes.
3. **Presupuesto**: `gaming/gastos.md` y la fórmula de
   `config/gaming-presets.json` (`GB/h ≈ Mbps·3600/8/1000`) para estimar el egreso.
4. **Cuenta que paga**: `cost.acknowledgePaidResources: true` no es un trámite del schema, es
   que **no hay VM gratis**. Los créditos de prueba se consumen y luego se factura.

## Errores que este proyecto se niega a cometer

| Promesa habitual | Realidad documentada |
| --- | --- |
| "VM de gaming gratis" | Se factura por hora (VM + discos + IP + egreso). deallocate salva la VM, no el disco |
| "Táctil funciona en todos los juegos" | Solo mediante overlay del cliente (Moonlight) y mapeo a teclas/ratón |
| "Windows App conecta mandos" | No los redirige en Android |
| "Cualquier GPU vale para stream" | Sin codificador de hardware la latencia y el bitrate real no aguantan |
| "Juegos online con antichat en VM" | No soportado; `gaming/antitrampas.md` detalla por juego |
| "Rendimiento igual que un PC local" | Hay una capa de virtualización, GPU virtual y red por medio |
