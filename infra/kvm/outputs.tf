output "dominio" {
  description = "Nombre del dominio libvirt de la VM: lo que esperan virsh, virt-viewer y los scripts del host."
  value       = libvirt_domain.win.name
}

output "gpu_asignada" {
  description = "Número de hostdev PCI atados. 0 = la VM no tiene GPU y el gaming nativo no es viable."
  value       = length(var.gpu_hostdev_ids)
}

output "montar_medios_de_instalacion" {
  description = "Los cdroms no son un recurso de este modulo: se montan con virsh (y se desmontan al terminar la instalacion)."
  value = var.instalar_desde_iso ? [
    "virsh attach-disk ${libvirt_domain.win.name} ${var.windows_iso_path} hdc --type cdrom --mode readonly",
    "virsh attach-disk ${libvirt_domain.win.name} ${var.virtio_iso_path} hdd --type cdrom --mode readonly",
    "virt-viewer -c ${var.libvirt_uri} ${libvirt_domain.win.name}",
    "cuando acabe: virsh detach-disk ${libvirt_domain.win.name} hdc && virsh detach-disk ${libvirt_domain.win.name} hdd",
    ] : [
    "la VM ya arranca del disco: no hay cdroms que montar (var.instalar_desde_iso = false)",
  ]
}

output "comandos_utiles" {
  description = "Comandos de libvirt para averiguar la IP, abrir la consola de instalacion, tomar instantanea y ver el disco."
  value = [
    "virsh domifaddr ${libvirt_domain.win.name} # IP de la VM",
    "virt-viewer -c qemu:///system ${libvirt_domain.win.name} # consola grafica para la instalacion",
    "virsh snapshot-create-as --domain ${libvirt_domain.win.name} --name pre-juegos --disk-only --atomic",
    "qemu-img info /var/lib/libvirt/images/${libvirt_domain.win.name}-datos.qcow2",
  ]
}

output "recordatorios" {
  description = "Limitaciones propias de KVM (memoria del host, red, licencias de GeForce, instantaneas en caliente)."
  value = [
    "Deja memoria y CPU para el host: una VM que se come el host degrada la propia experiencia remota.",
    "Con network_name (NAT) la latencia anadida es pequena, pero el cliente debe apuntar al host; con bridge la VM tiene su propia IP en la LAN.",
    "VFIO con NVIDIA consumidora: revisa la politica de licencias del driver de GeForce (no permite virtualizacion de consumidores en host no soportado). El proyecto no elude licencias.",
    "Instantaneas: usa disk-only para no corromper el qcow2 con escrituras en curso (suspende el juego antes).",
  ]
}
