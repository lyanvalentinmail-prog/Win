variable "libvirt_uri" {
  type        = string
  default     = "qemu:///system"
  description = "URI de libvirt. Para host remoto: qemu+ssh://usuario@host/system (usa clave SSH, nunca contrasena)."
}

variable "name" {
  type        = string
  description = "Nombre del dominio y hostname."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,20}$", var.name))
    error_message = "Minusculas, digitos y guiones, 3-21 caracteres."
  }
}

variable "storage_pool" {
  type        = string
  default     = "default"
  description = "Pool de libvirt donde se crean los volumenes (virsh pool-list)."
}

variable "vcpus" {
  type        = number
  default     = 8
  description = "vCPU. Regla practica: no asignes mas de la mitad de los hilos fisicos del host o el host y la VM se canibalizan."
  validation {
    condition     = var.vcpus >= 2 && var.vcpus <= 128
    error_message = "2-128 vCPU."
  }
}

variable "ram_mb" {
  type        = number
  default     = 16384
  description = "Memoria de la VM en MiB. Deja SIEMPRE margen para el host: con 32 GiB fisicas no asignes mas de 16-20 GiB."
  validation {
    condition     = var.ram_mb >= 4096
    error_message = "Minimo 4096 MiB; con menos, Windows + un juego moderno no son utilizables."
  }
}

variable "os_disk_gb" {
  description = "Tamano maximo en GiB del qcow2 del disco del SO. Crece bajo demanda: 64 es el minimo de Windows y 128 lo comodo."
  type        = number
  default     = 128
}

variable "data_disk_gb" {
  type        = number
  default     = 512
  description = "Volumen qcow2 aparte para juegos y perfiles (facilita instantaneas y respaldos)."
}

variable "uefi" {
  type        = bool
  default     = true
  description = "Firmware EFI. Obligatorio para Windows 11; con Windows Server puedes usar bios (false)."
}

variable "vtpm" {
  type        = bool
  default     = true
  description = "vTPM 2.0 (swtpm). Windows 11 lo pide; ademas habilita BitLocker con protector TPM."
}

variable "autostart" {
  description = "Si libvirt debe encender la VM al arrancar el host. Con un equipo compartido interesa dejarlo en false."
  type        = bool
  default     = false
}

variable "network_name" {
  type        = string
  default     = "default"
  description = "Red virtual de libvirt (virsh net-list). Usarla implica NAT: Windows App tendra que conectar contra el host fisicamente."
}

variable "network_bridge" {
  type        = string
  default     = null
  description = "Bridge del host (p. ej. br0). Preferido para gaming: la VM obtiene IP en tu LAN y el cliente conecta directo."
}

variable "mac_address" {
  type        = string
  default     = null
  description = "MAC fija si necesitas reserva DHCP."
}

variable "instalar_desde_iso" {
  type        = bool
  default     = true
  description = "Monta las ISO como cdroms. Ponlo en false tras completar la instalacion de Windows para no arrancar de nuevo desde el medio."
}

variable "windows_iso_path" {
  type        = string
  default     = null
  description = "Ruta en el HOST a la ISO de Windows (descargada de Microsoft, no de este repo)."
}

variable "virtio_iso_path" {
  type        = string
  default     = null
  description = "Ruta a virtio-win.iso (drivers de disco/red para KVM; sin ellos no veras el disco qcow2)."
}

variable "gpu_passthrough" {
  type        = bool
  default     = false
  description = "true SOLO si has preparado el host (IOMMU + vfio). No cambia nada por si solo: lo que decide son gpu_hostdev_ids."
}

variable "gpu_hostdev_ids" {
  type        = list(string)
  default     = []
  description = "Direcciones PCI (0000:01:00.0) de la GPU y su audio, ya atadas a vfio-pci. [] = sin GPU: el proyecto lo informa, no lo simula."
}
