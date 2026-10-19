# -----------------------------------------------------------------------------
# Win Gaming VM — KVM/libvirt (autohospedado)
#
# Es la unica via con GPU FISICA posible (VFIO / PCI passthrough) y la que mas
# preparacion exige en el host:
#   1) IOMMU activo en BIOS/UEFI y en el kernel (intel_iommu=on | amd_iommu=on,
#      iommu=pt), grupos de PCI aislados (acs override solo si no hay alternativa).
#   2) La GPU (y su dispositivo de audio HDMI) desvinculada del driver del host.
#   3) Windows 11 necesita UEFI + Secure Boot + vTPM: sin eso, la edicion no arranca
#      con las condiciones soportadas por Microsoft.
#
# Este modulo NO finge el passthrough: si no declaras var.gpu_hostdev_ids, la VM se
# crea SIN GPU y el informe de preparacion lo refleja (nunca se inventa un adapter).
#
# SINTAXIS: escrita contra dmacvicar/libvirt 0.9.x, que movio el dominio de bloques
# HCL ("disk { ... }") a ATRIBUTOS ANIDADOS ("devices = { disks = [ ... ] }"). Con un
# provider 0.7/0.8 este fichero NO valida: los nombres de argumento cambiaron todos.
# Si tu objetivo es jugar y no gestionas libvirt con Terraform, usa la via comprobable:
# scripts/linux/kvm-deploy.sh (virt-install) genera el mismo dominio con las mismas
# opciones de disco, red, UEFI y passthrough.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# ---------------------------------------------------------------------------
# Volumenes. El qcow2 se crea vacio: Windows se instala desde la ISO (ver el
# output montar_medios_de_instalacion), no existe una "imagen base" oficial.
# ---------------------------------------------------------------------------

resource "libvirt_volume" "disco_os" {
  name     = "${var.name}-os.qcow2"
  pool     = var.storage_pool
  capacity = var.os_disk_gb * 1073741824

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "disco_datos" {
  count = var.data_disk_gb > 0 ? 1 : 0

  name     = "${var.name}-datos.qcow2"
  pool     = var.storage_pool
  capacity = var.data_disk_gb * 1073741824

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# Cloudbase-init lee este ISO para crear el usuario, habilitar RDP/WinRM y fijar el
# hostname. La contrasena NO va aqui: si necesitas un cloud-config completo, cambia
# user_data por file("./cloudinit/user-data.yaml") (deja ese fichero fuera del repo:
# *.tfvars, cloud-init y demas payloads ya estan en .gitignore) y genera la clave con
# 'openssl rand -base64 24' en el host.
resource "libvirt_cloudinit_disk" "preseed" {
  name = "${var.name}-cloudinit.iso"

  user_data = <<-EOD
    #cloud-config
    disable_root: true
    rdp_enabled: true
    hostname: ${var.name}
    EOD

  meta_data = "instance-id: ${var.name}\nlocal-hostname: ${var.name}\n"
}

locals {
  # Pila de discos con una forma uniforme: el provider acepta todos los atributos como
  # opcionales, y mantener la misma "columna" en cada elemento evita que Terraform tenga
  # que unificar objetos de formas distintas (eso si falla en el plan).
  discos = concat(
    [
      {
        tipo    = "disk"
        dev     = "vda"
        bus     = "virtio"
        pool    = var.storage_pool
        nombre  = libvirt_volume.disco_os.name
        ruta    = null
        formato = "qcow2"
        cdrom   = false
      },
      {
        tipo    = "cdrom"
        dev     = "sda"
        bus     = "sata"
        pool    = null
        nombre  = null
        ruta    = libvirt_cloudinit_disk.preseed.path
        formato = "raw"
        cdrom   = true
      },
    ],
    var.data_disk_gb > 0 ? [
      {
        tipo    = "disk"
        dev     = "vdb"
        bus     = "virtio"
        pool    = var.storage_pool
        nombre  = libvirt_volume.disco_datos[0].name
        ruta    = null
        formato = "qcow2"
        cdrom   = false
      },
    ] : [],
  )

  # "0000:01:00.0" -> numeros sueltos, que es lo que pide la schema 0.9 (Number).
  # Grupos con nombre: sin "?P<...>" Terraform devuelve una lista con el match completo
  # en [0] y el indexado por numero cambia de una expresion a otra.
  gpu = [
    for id in var.gpu_hostdev_ids : {
      managed = true
      subsys_pci = {
        source = {
          address = {
            domain   = tonumber(regex("^(?P<dom>[0-9a-f]{4})", lower(id)).dom)
            bus      = tonumber(regex(":(?P<bus>[0-9a-f]{2}):", lower(id)).bus)
            slot     = tonumber(regex(":(?P<slot>[0-9a-f]{2})[.:]", lower(id)).slot)
            function = tonumber(regex("[.](?P<func>[0-9])$", lower(id)).func)
          }
        }
      }
    }
  ]
}

resource "libvirt_domain" "win" {
  name        = var.name
  type        = "kvm"
  memory      = var.ram_mb
  memory_unit = "MiB"
  vcpu        = var.vcpus
  autostart   = var.autostart

  # Que hace la VM al apagarse o petar: 'restart' mantiene la sesion de juego viva ante
  # un cuelgue del guest; 'destroy' es el comportamento por defecto de libvirt.
  on_reboot   = "restart"
  on_poweroff = "destroy"
  on_crash    = "restart"

  os = merge(
    {
      type         = "hvm"
      type_arch    = "x86_64"
      type_machine = var.uefi ? "q35" : "pc"
    },
    # Windows 11 solo se soporta en UEFI + Secure Boot + vTPM. El loader "secboot" ya
    # trae el verificador; loader_secure se deja fuera porque su valor depende de la
    # builds de OVMF del host (algunas lo ignoran y otras lo exigen).
    var.uefi ? {
      firmware        = "efi"
      loader          = var.uefi_code_fd
      loader_readonly = "yes"
      nv_ram = {
        nv_ram   = "/var/lib/libvirt/qemu/nvram/${var.name}-VARS.fd"
        template = var.uefi_vars_fd
      }
    } : {},
  )

  # host-passthrough es lo que rinde en gaming (instrucciones del CPU real, sin
  # emular); 'host-model' es el portable si movemos la VM a otro host.
  cpu = {
    mode  = var.cpu_mode
    match = "exact"
  }

  clock = {
    offset = "utc"
  }

  devices = {
    # VirtIO en disco y red: sin los drivers de virtio-win.iso el guest no ve nada.
    disks = [
      for d in local.discos : {
        device = d.tipo
        source = merge(
          d.nombre != null ? { volume = { pool = d.pool, volume = d.nombre } } : {},
          d.ruta != null ? { file = { file = d.ruta } } : {},
        )
        target = {
          dev = d.dev
          bus = d.bus
        }
        driver = {
          name  = "qemu"
          type  = d.formato
          cache = d.cdrom ? "none" : var.disk_cache
          io    = d.cdrom ? null : "native"
        }
        read_only = d.cdrom ? true : null
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = merge(
          var.network_bridge != null ? { bridge = { name = var.network_bridge } } : {},
          var.network_bridge == null ? { network = { name = var.network_name } } : {},
        )
        mac = var.mac_address != null ? { address = var.mac_address } : null
        driver = {
          queues = var.virtio_queues
        }
      },
    ]

    # SPICE queda en localhost: es la consola de instalacion y de rescate, no un canal
    # de acceso remoto. Para verlo desde otra maquina, tunel SSH al host (ver
    # scripts/client/Montar-TunelSSH.ps1) en lugar de abrir el puerto.
    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      },
    ]

    # VGA basica para poder instalar sin drivers; con la GPU atada la salida real es la
    # de la GPU y este adapter queda de respaldo.
    videos = [
      {
        model = {
          type  = "vga"
          heads = 1
        }
      },
    ]

    consoles = [
      {
        source = {
          pty = {}
        }
        target = {
          type = "isa-serial"
          port = 0
        }
      },
    ]

    tpms = var.vtpm ? [
      {
        model = "tpm-crb"
        backend = {
          emulator = {
            version = "2.0"
          }
        }
      },
    ] : []

    hostdevs = local.gpu
  }

  lifecycle {
    precondition {
      condition     = !var.gpu_passthrough || length(var.gpu_hostdev_ids) > 0
      error_message = "gpu_passthrough=true con gpu_hostdev_ids=[]: no hay ninguna PCI atada a vfio-pci, asi que la VM seguiria sin GPU. Declara las direcciones (lspci -nn) o deja el flag en false; el modulo no simula un adapter que no existe."
    }
    precondition {
      condition     = !var.uefi || (var.uefi_code_fd != null && var.uefi_vars_fd != null)
      error_message = "uefi=true necesita uefi_code_fd y uefi_vars_fd: las rutas de OVMF cambian por distribucion (Debian /usr/share/OVMF/..., Fedora/Arch /usr/share/edk2/...)."
    }
    precondition {
      condition     = !var.uefi || var.vtpm
      error_message = "Windows 11 en UEFI sin vTPM: la instalacion no pasa los requisitos de Microsoft. O activas vtpm=true o usas una edicion/SKU que no los pida (Server), pero no lo dejes a medias."
    }
  }
}
