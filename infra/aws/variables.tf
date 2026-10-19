variable "region" {
  type        = string
  description = "Region de AWS. Elige la mas cercana a ti: la latencia del canal remoto es lo primero que se nota."
}

variable "name" {
  type        = string
  description = "Prefijo de nombres / clave del host."
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{2,20}$", var.name))
    error_message = "3-21 caracteres alfanumericos o guion."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC existente (este modulo no crea una VPC para no multiplicar recursos facturables)."
}

variable "subnet_id" {
  type        = string
  description = "Subred donde levantar la instancia."
}

variable "instance_type" {
  type        = string
  default     = "g4dn.xlarge"
  description = "Con GPU: g4dn.xlarge/2xlarge (T4), g5.xlarge/2xlarge/4xlarge (A10G), g6.xlarge (L4). Sin GPU para solo escritorio: m7i.large/xlarge. Ver config/provider-limits.json."
}

variable "ami_name_pattern" {
  type        = string
  default     = "Windows_Server-2022-English-Full-Base-*"
  description = "Patrón de la AMI. Para Server 2025 usa Windows_Server-2025-English-Full-Base-* si existe en tu region; comprobalo en la consola antes de aplicar."
}

variable "key_name" {
  type        = string
  description = "Par de claves EC2 EXISTENTE (la clave privada no va al repositorio). Necesario para descifrar la contrasena inicial de la instancia."
}

variable "rdp_port" {
  type        = number
  default     = 3389
}

variable "rdp_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDR permitidas para RDP. Vacias = sin apertura; usa Session Manager o tunel."
}

variable "associate_public_ip" {
  type        = bool
  default     = false
  description = "IP publica directa. Solo con rdp_allowed_cidrs llenas y conciencia del riesgo."
}

variable "os_disk_gb" {
  type        = number
  default     = 128
}

variable "data_disk_gb" {
  type        = number
  default     = 512
  description = "Volumen EBS persistente para juegos y perfiles. 0 = sin disco de datos (nada persiste tras borrar la instancia)."
}

variable "root_volume_type" {
  type        = string
  default     = "gp3"
  validation {
    condition     = contains(["gp3", "gp2", "io2"], var.root_volume_type)
    error_message = "gp3 (recomendado), gp2 o io2. magnetic/standard no: el arranque y las cargas serian inusables."
  }
}

variable "data_volume_type" {
  type        = string
  default     = "gp3"
}

variable "ebs_optimized" {
  type        = bool
  default     = true
  description = "En algunos tamanos es un extra facturable; sin ella el rendimiento del disco cae. Verifica en la pagina de precios."
}

variable "enable_game_stream" {
  type        = bool
  default     = false
  description = "Reservado para el canal Moonlight: requiere GPU verificada dentro de la VM y CIDR propias. Los puertos se documentan en Install-GpuDriver/Set-Sunshine."
}

variable "tags" {
  type        = map(string)
  default     = {}
}
