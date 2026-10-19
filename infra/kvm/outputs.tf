output "dominio" {
  value = libvirt_domain.win.name
}

output "gpu_asignada" {
  description = "Número de hostdev PCI atados. 0 = la VM no tiene GPU y el gaming nativo no es viable."
  value       = length(var.gpu_hostdev_ids)
}

output "comandos_utiles" {
  value = [
    "virsh domifaddr ${libvirt_domain.win.name}          # IP de la VM",
    "virt-viewer -c qemu:///system ${libvirt_domain.win.name}   # consola grafica para la instalacion",
    "virsh snapshot-create-as --domain ${libvirt_domain.win.name} --name pre-juegos --disk-only --atomic",
    "qemu-img info /var/lib/libvirt/images/${libvirt_domain.win.name}-datos.qcow2",
  ]
}

output "recordatorios" {
  value = [
    "Deja memoria y CPU para el host: una VM que se come el host degrada la propia experiencia remota.",
    "Con network_name (NAT) la latencia anadida es pequena, pero el cliente debe apuntar al host; con bridge la VM tiene su propia IP en la LAN.",
    "VFIO con NVIDIA consumidora: revisa la politica de licencias del driver de GeForce (no permite virtualizacion de consumidores en host no soportado). El proyecto no elude licencias.",
    "Instantaneas: usa disk-only para no corromper el qcow2 con escrituras en curso (suspende el juego antes).",
  ]
}
