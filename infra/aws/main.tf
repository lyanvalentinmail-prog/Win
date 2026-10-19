# -----------------------------------------------------------------------------
# Win Gaming VM — AWS
#
# Realidad del proveedor (leer antes de aplicar):
#  * g4dn/g5/g6 = GPU NVIDIA T4/A10G/L4 para calculo general. No son una estación de juego:
#    NVIDIA exige licencia GRID/vWS en muchos escenarios y los juegos antitrampas no
#    estan soportados. Este modulo NO finge lo contrario.
#  * g4dn.g2xlarge? no existe; los tamanos validos estan en config/provider-limits.json.
#  * Windows Server esta licenciado por hora dentro del precio de la AMI.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["801119661308", "125523088429"] # Amazon / Microsoft (aliases publicos de imagenes de Windows)

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "win" {
  name        = "${var.name}-sg"
  description = "Win Gaming VM: acceso remoto solo desde CIDR declaradas"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# Sin CIDR declaradas no se crea ninguna regla de entrada: el acceso ira por tunel
# (Session Manager / bastion / Tailscale), que es el modo recomendado.
resource "aws_vpc_security_group_ingress_rule" "rdp" {
  count = length(var.rdp_allowed_cidrs) > 0 ? 1 : 0

  security_group_id = aws_security_group.win.id
  description       = "RDP (Windows App) desde las IP del usuario"
  from_port         = var.rdp_port
  to_port           = var.rdp_port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.rdp_allowed_cidrs[0]
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.win.id
  description       = "Salida para winget, actualizaciones y telemetria del SO"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "win" {
  ami                         = data.aws_ami.windows.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.win.id]
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip
  # user_data se limita a ARRANCAR el bootstrap; la configuracion va en el disco,
  # no en user_data (64 KB y visible en la consola "DescribeInstanceUserData").
  user_data_replace_on_change = true
  disable_api_termination     = true
  ebs_optimized               = var.ebs_optimized

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2: sin esto, cualquier proceso local puede leer el rol
  }

  root_block_device {
    volume_type = var.root_volume_type
    volume_size = var.os_disk_gb
    encrypted   = true
    tags        = merge(var.tags, { Nombre = "${var.name}-root" })
  }

  dynamic "ebs_block_device" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      device_name = "/dev/xvdf"
      volume_type = var.data_volume_type
      volume_size = var.data_disk_gb
      encrypted   = true
      tags        = merge(var.tags, { Nombre = "${var.name}-datos" })
    }
  }

  tags = merge(var.tags, { Name = var.name, Proyecto = "win-gaming-vm" })

  lifecycle {
    precondition {
      condition     = var.instance_type != "g4ad.4xlarge" || !var.enable_game_stream
      error_message = "g4ad (AMD) + streaming de juego: no lo dejes por defecto. El driver y el codificador AMF hay que verificarlos dentro de la VM (Install-GpuDriver.ps1) y muchos titulos antitrampas no soportan VM."
    }
    precondition {
      condition     = length(var.rdp_allowed_cidrs) == 0 || alltrue([for c in var.rdp_allowed_cidrs : can(cidrhost(c, 0))])
      error_message = "Cada entrada de rdp_allowed_cidrs debe ser un CIDR valido (p. ej. 203.0.113.10/32); '0.0.0.0/0' esta prohibido por politica de seguridad."
    }
    precondition {
      condition     = var.data_disk_gb == 0 || var.data_disk_gb >= 128
      error_message = "EBS gp3 empieza a rendir bien desde 128 GiB (por debajo, los 3000 IOPS base se quedan cortos para una libreria de juegos)."
    }
  }
}
