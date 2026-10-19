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
# VIDA REAL: `terraform init` necesita descargar dmacvicar/libvirt, y el provider
# cambia la sintaxis de nvram/cpu con bastante frecuencia. Si tu objetivo es jugar,
# usa la via soportada y comprobable: scripts/linux/kvm-deploy.sh (virt-install),
# que genera el mismo dominio con las mismas opciones. Este modulo es para quien ya
# gestiona libvirt con Terraform.
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

resource "libvirt_volume" "disco_os" {
  name    = "${var.name}-os.qcow2"
  pool    = var.storage_pool
  size    = var.os_disk_gb * 1073741824
  # Sin imagen base el volumen queda vacio y Windows se instala desde la ISO.
}

resource "libvirt_volume" "disco_datos" {
  count = var.data_disk_gb > 0 ? 1 : 0

  name = "${var.name}-datos.qcow2"
  pool = var.storage_pool
  size = var.data_disk_gb * 1073741824
}

resource "libvirt_cloudinit_disk" "preseed" {
  name      = "${var.name}-cloudinit.iso"
  pool      = var.storage_pool
  user_data = <<-EOD
    #cloud-config
    # cloudbase-init (imagen "CloudImg" de Windows) usa este disco para crear el
    # usuario, habilitar WinRM/RDP y fijar el hostname. NO pongas aqui la contrasena:
    # genererala en el host (openssl rand) y reemplazala con un fichero que no se
    # versiona, o usa var.cloudbase_init_user_data_file.
    disable_root: true
    rdp_enabled: true
    EOD
  meta_data = "instance-id: ${var.name}\nlocal-hostname: ${var.name}\n"
}

resource "libvirt_domain" "win" {
  name      = var.name
  memory    = var.ram_mb
  vcpu      = var.vcpus
  firmware  = var.uefi ? "efi" : null
  autostart = var.autostart

  cpu {
    mode = "host-passthrough"
  }

  dynamic "tpm" {
    for_each = var.vtpm ? [1] : []
    content {
      model   = "tpm-crb"
      type    = "emulator"
      version = "2.0"
    }
  }

  clock_offset = "utc"

  console {
    type        = "pty"
    target_port = "0"
  }

  graphics {
    type        = var.gpu_passthrough ? "none" : "spice"
    listen_type = "address"
    autoport    = true
  }

  network_interface {
    network_name = var.network_name
    bridge       = var.network_bridge
    mac          = var.mac_address
}

  # VirtIO: disco y red para rendimiento (los drivers van en la ISO de virtio-win).
  disk {
    file   = libvirt_volume.disco_os.id
    format = "qcow2"
  }

  disk {
    file = libvirt_cloudinit_disk.preseed.id
  }

  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      file   = libvirt_volume.disco_datos[0].id
      format = "qcow2"
    }
  }

  dynamic "disk" {
    for_each = var.instalar_desde_iso ? [1] : []
    content {
      file     = var.windows_iso_path
      cdrom    = true
      readonly = true
    }
  }

  dynamic "disk" {
    for_each = var.instalar_desde_iso ? [1] : []
    content {
      file     = var.virtio_iso_path
      cdrom    = true
      readonly = true
    }
  }

  # Passthrough real: cada id es un BDF (0000:01:00.0) ya preparado en el host con
  # nvidia/vfio-bind. Vaciar esta lista = VM sin GPU (y el proyecto lo reporta asi).
  dynamic "hostdev" {
    for_each = var.gpu_hostdev_ids
    content {
      mode = "subsystem"
      type = "pci"
      id   = hostdev.value
    }
  }
}
