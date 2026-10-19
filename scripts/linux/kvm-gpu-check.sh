#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KVM: diagnosticos ANTES de prometer una GPU a la VM.
#
# Ejecutar en el HOST. Salida: un informe por consola con lo que hace falta para
# VFIO (IOMMU activo, grupos limpios, dispositivos ocupados por el host) y que
# se puede pasar por alto. No configura nada: si falta un paso, te lo dice.
#
# Uso: sudo bash scripts/linux/kvm-gpu-check.sh [--gpu 01:00]
# -----------------------------------------------------------------------------
set -euo pipefail

GPU_FILTER="${2:-}"
if [[ "${1:-}" == "--gpu" ]]; then GPU_FILTER="${2:-}"; fi

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
amar()  { printf '\033[33m%s\033[0m\n' "$*"; }
cabe()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

problemas=0

cabe "1) Virtualizacion en la CPU"
if grep -qw -e vmx -e svm /proc/cpuinfo; then
  verde "   VMX/SVM presente"
else
  rojo "   sin flags vmx/svm: la virtualizacion por hardware esta apagada en la BIOS"; problemas=$((problemas+1))
fi

cabe "2) IOMMU (necesario para pasar la GPU)"
dmesg_iommu=""
if command -v dmesg >/dev/null 2>&1; then
  dmesg_iommu="$(dmesg 2>/dev/null | grep -E -i 'DMAR: IOMMU enabled|AMD-Vi: Interrupt remapping|iommu' | head -3 || true)"
fi
if [[ -n "$dmesg_iommu" ]]; then
  verde "   senales de IOMMU en el kernel:"; printf '     %s\n' "$dmesg_iommu"
else
  amar "   no hay evidencia de IOMMU activo. Anade al GRUB (Intel): intel_iommu=on iommu=pt"
  amar "     (AMD): amd_iommu=on iommu=pt  y despues: update-grub && reboot"
  problemas=$((problemas+1))
fi
if [[ -d /sys/kernel/iommu_groups ]]; then
  n=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | wc -l)
  if [[ "$n" -gt 0 ]]; then verde "   grupos de IOMMU visibles: $n"; else rojo "   0 grupos de IOMMU"; problemas=$((problemas+1)); fi
else
  rojo "   /sys/kernel/iommu_groups no existe"
  problemas=$((problemas+1))
fi

cabe "3) GPU y dispositivos de audio detectados"
if command -v lspci >/dev/null 2>&1; then
  lspci -nnD | grep -E -i 'VGA compatible controller|3D controller|Audio device' | sed 's/^/   /'
else
  rojo "   falta lspci (pciutils)"
fi

if [[ -n "$GPU_FILTER" ]]; then
  cabe "4) Grupo(s) de IOMMU para el filtro $GPU_FILTER"
  encontradas=0
  for dev in $(find /sys/kernel/iommu_groups -mindepth 3 -maxdepth 3 -name '0000'"$GPU_FILTER"* 2>/dev/null); do
    bdf=$(basename "$dev")
    grupo=$(basename "$(dirname "$(dirname "$(dirname "$dev")")")")
    encontradas=$((encontradas+1))
    echo "   $bdf -> grupo $grupo"
    echo "   compañeros del grupo (todos tienen que pasar a la VM o usar ACS override):"
    for par in /sys/kernel/iommu_groups/"$grupo"/devices/*; do echo "     · $(basename "$par")"; done
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/"$bdf"/driver)" 2>/dev/null || echo '(sin driver)')
    echo "   driver actual: $drv"
    case "$drv" in
      vfio-pci) verde "   ya esta atada a vfio-pci: se puede pasar" ;;
      nvidia|nouveau|radeon|amdgpu|igb|snd*) amarillo "   el host la tiene ocupada: hace falta desvincularla (driverctl/vfio bind + blacklist en initramfs)"; problemas=$((problemas+1)) ;;
      *) amar "   revisar el driver actual" ;;
    esac
  done
  if [[ "$encontradas" -eq 0 ]]; then rojo "   ningun dispositivo coincide con $GPU_FILTER"; problemas=$((problemas+1)); fi
fi

cabe "5) Huecos de HPA / memoria para ballooning"
if [[ -r /proc/meminfo ]]; then
  total=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
  libre=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)
  echo "   host: ${total} MiB totales, ${libre} MiB disponibles"
  echo "   regla: deja >= 4 GiB para el host; si no, el hypervisor empieza a paginar y la VM lo nota"
fi

cabe "6) Huella de red"
if command -v ip >/dev/null 2>&1; then
  ip -br addr | sed 's/^/   /'
  echo "   para latencia baja: bridge (br0/virbr0 con macvtap) en vez de NAT; virsh net-list para ver redes"
fi

cabe "Resultado"
if [[ "$problemas" -eq 0 ]]; then
  verde "   sin bloqueos detectados. Crea la VM con scripts/linux/kvm-deploy.sh y declara los BDF en infra/kvm (gpu_hostdev_ids)."
  echo "   Despues, dentro de la VM, Install-GpuDriver.ps1 y Test-GamingReadiness.ps1 confirman que la GPU es visible y usable."
else
  rojo "   $problemas punto(s) pendientes antes de asignar una GPU: no los saltes 'a ver si va'."
  echo "   Alternativa honesta: VM sin GPU (escritorio remoto y juegos ligeros por software) y la realidad en el informe."
fi
