variable "name" {
  type        = string
  description = "Prefijo de nombres y computer name (maximo 15 caracteres para Windows)."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,14}$", var.name))
    error_message = "3-15 caracteres: minusculas, digitos y guiones; debe empezar por letra o digito."
  }
}

variable "location" {
  type        = string
  description = "Region de Azure. Comprueba antes que alli hay capacidad para el SKU NV elegido (az vm list-skus -r Microsoft.Compute -l <region> --size Standard_NV)."
}

variable "resource_group_name" {
  type        = string
  default     = null
  description = "Grupo de recursos existente (si es null se crea rg-<name>)."
}

variable "vm_size" {
  type        = string
  default     = "Standard_NV6ads_A10_v5"
  description = "Tamanos con GPU en Azure: Standard_NV{6,12,18,36}ads_A10_v5. Ver config/provider-limits.json."
  validation {
    condition     = can(regex("^Standard_(NV|D|B)[A-Za-z0-9]+$", var.vm_size))
    error_message = "Debe ser un tamanho de la serie NV (GPU), D o B. Sin prefijo Standard_ Azure lo rechaza."
  }
}

variable "windows_edition" {
  type        = string
  default     = "windows-server-2025-desktop"
  description = "Clave que mapea a publicador/oferta/SQL en infra/azure/vm.tf. Debe coincidir con config/vm.json."
  validation {
    condition     = contains(["windows-server-2025-desktop", "windows-server-2022-desktop", "windows-11-pro", "windows-11-enterprise"], var.windows_edition)
    error_message = "Ediciones soportadas: windows-server-2025-desktop, windows-server-2022-desktop, windows-11-pro, windows-11-enterprise."
  }
}

variable "image_version" {
  type        = string
  default     = "latest"
  description = "Version de la imagen del marketplace. Fijala (no 'latest') si quieres reproducibilidad real: az vm image list --publisher ... para ver las disponibles."
}

variable "vm_admin_user" {
  type        = string
  default     = "gamingadmin"
  description = "Usuario administrador local. Azure reserva ciertos nombres (admin, administrator, ...)."
  validation {
    condition     = can(regex("^(?!.(?:admin|administrator|azureuser|test|user)$)[A-Za-z][A-Za-z0-9_]{2,19}$", var.vm_admin_user))
    error_message = "3-20 caracteres, letra inicial, sin espacios ni caracteres reservados por Azure/Windows."
  }
}

variable "vm_admin_password" {
  type        = string
  description = "Contrasena del administrador local. SIN valor por defecto a proposito: pasala por TF_VAR_vm_admin_password o un -var-file fuera del repositorio. Terraform la guarda en el state: protege el state (blob con versionado + RBAC) o usa un Key Vault."
  sensitive   = true
}

variable "os_disk_sku" {
  type        = string
  default     = "StandardSSD_LRS"
  description = "StandardSSD_LRS (equilibrado), PremiumV2_LRS/Premium_LRS (mejores IOPS para juegos), Standard_LRS (desaconsejado para juegos)."
  validation {
    condition     = contains(["Premium_LRS", "PremiumV2_LRS", "Premium_LRS", "StandardSSD_LRS", "StandardSSD_ZRS", "Standard_LRS"], var.os_disk_sku)
    error_message = "Valores: Premium_LRS, PremiumV2_LRS, StandardSSD_LRS, StandardSSD_ZRS, Standard_LRS."
  }
}

variable "os_disk_gb" {
  type        = number
  default     = 128
  description = "Disco del SO. Minimo 64 GiB; 128 GiB deja margen para actualizaciones y apps."
}

variable "data_disk_gb" {
  type        = number
  default     = 512
  description = "Disco de datos PERSISTENTE (juegos y perfiles). 0 = no crear (y entonces nada es persistente tras un deallocate)."
}

variable "data_disk_sku" {
  type        = string
  default     = "Premium_LRS"
  description = "Para librerias de juegos grandes, Premium o PremiumV2 reduce los tiempos de carga frente a StandardSSD."
}

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "rdp_port" {
  type        = number
  default     = 3389
  description = "Puerto RDP expuesto. Cambiarlo no sustituye a la lista de control de acceso; es solo ruido para los escaneos masivos."
}

variable "rdp_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Tu IP publica en CIDR (p. ej. 203.0.113.10/32). VACIO = sin regla de red: accede por tunel (Tailscale/Bastion/SSH) — modo recomendado."
}

variable "enable_rdp_udp" {
  type        = bool
  default     = false
  description = "Regla UDP para RDP (flujo mas suave, pero el UDP remoto depende de tu red intermedia)."
}

variable "enable_game_stream" {
  type        = bool
  default     = false
  description = "Abre en el NSG los puertos TCP de Sunshine para el canal Moonlight. Requiere rdp_allowed_cidrs no vacio y un SKU NV."
}

variable "accelerated_networking" {
  type        = bool
  default     = true
  description = "SR-IOV. Soportado en las series NV/D v5; baja la latencia de red, que es lo que se nota en el input."
}

variable "spot_priority" {
  type        = bool
  default     = false
  description = "VM spot: mas barata y con desalojos. Usala solo para validar el despliegue, no para jugar."
}

variable "automatic_updates" {
  type        = bool
  default     = false
  description = "Actualizaciones automaticas de Windows. Con 'false' el patch mode es Manual y decide quien mantiene la VM; los scripts de seguridad siguen aplicando Defender y auditado."
}

variable "timezone" {
  type        = string
  default     = "UTC"
  description = "Zona horaria de la VM (afecta a programadores y a los registros de auditoria)."
}

variable "boot_diagnostics" {
  type        = bool
  default     = true
  description = "Habilita el almacen de diagnostico de arranque: si la VM no arranca, tienes pantallazo en vez de adivinanzas."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Etiquetas (cost center, entorno, ...). Util para entender la factura de esta VM."
}

variable "dns_prefix" {
  type        = string
  default     = null
  description = "Etiqueta DNS publica (se convierte en <prefix>.<region>.cloudapp.azure.com). Con viñeta DNS puedes fijar un nombre para el certificado y el cliente."
}

variable "skip_provider_registration" {
  type        = bool
  default     = false
  description = "true solo si la suscripcion ya tiene los providers registrados y el plan tardaria demasiado en registrarlos."
}
