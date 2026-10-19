#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KVM: crea la VM de Windows con virt-install (via recomendada en este proyecto).
#
# Por que virt-install y no Terraform: el dominio necesita UEFI con Secure Boot,
# vTPM, bridge, cdroms de instalacion y (opcional) passthrough; con virt-install
# el XML resultante se puede inspeccionar y repetir, y no depende de que la
# sintaxis del proveedor de Terraform cambie entre versiones.
#
# Uso (en el host, como root):
#   sudo WIN_ISO=/vm/iso/SW_DVD9_Win_Server_2025...iso \
#        VIRTIO_ISO=/vm/iso/virtio-win-0.1.285.iso \
#        GPU_BDF=0000:01:00.0 GPU_AUDIO_BDF=0000:01:00.1 \
#        ./scripts/linux/kvm-deploy.sh wingamingvm01
#
# Variables: RAM_MB (16384), VCPUS (8), OS_GB (128), DATA_GB (512),
#            BRIDGE (br0), POOL (default), GPU_BDF (vacio = sin GPU),
#            EFI (yes/no), TPM (yes/no), AUTOSTART (yes/no).
# -----------------------------------------------------------------------------
set -euo pipefail

NOMBRE="${1:-wingamingvm01}"
RAM_MB="${RAM_MB:-16384}"
VCPUS="${VCPUS:-8}"
OS_GB="${OS_GB:-128}"
DATA_GB="${DATA_GB:-512}"
POOL="${POOL:-default}"
BRIDGE="${BRIDGE:-br0}"
WIN_ISO="${WIN_ISO:-}"
VIRTIO_ISO="${VIRTIO_ISO:-}"
GPU_BDF="${GPU_BDF:-}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-}"
EFI="${EFI:-yes}"
TPM="${TPM:-yes}"
AUTOSTART="${AUTOSTART:-no}"
DATOS_RUTA="${DATOS_RUTA:-/var/lib/libvirt/images/${NOMBRE}-datos.qcow2}"
OS_RUTA="${OS_RUTA:-/var/lib/libvirt/images/${NOMBRE}-os.qcow2}"

fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 2; }
info() { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
aviso() { printf '\033[33m[aviso]\033[0m %s\n' "$*"; }

command -v virt-install >/dev/null 2>&1 || fail "virt-install no esta instalado (paquete virt-install)."
command -v virsh >/dev/null 2>&1 || fail "virsh no esta instalado (libvirt-client + libvirtd activo)."
[[ $EUID -eq 0 ]] || fail "ejecutalo como root o con sudo (escribe en el pool de libvirt)."

if [[ -z "$WIN_ISO" ]]; then
  aviso "sin WIN_ISO: la VM se crea con disco vacio y habra que montar la ISO a mano."
  aviso "consigue la ISO de Microsoft (Evaluation Center o VLSC) - no se distribuye desde este repo."
elif [[ ! -r "$WIN_ISO" ]]; then
  fail "WIN_ISO no legible: $WIN_ISO"
fi
if [[ -z "$VIRTIO_ISO" || ! -r "$VIRTIO_ISO" ]]; then
  fail "necesitas VIRTIO_ISO legible (virtio-win.iso) o el disco qcow2 no se vera durante la instalacion"
fi

virsh net-info default >/dev/null 2>&1 || aviso "la red 'default' de libvirt no existe; con BRIDGE=$BRIDGE hace falta un bridge real (virsh net-list, ip -d link show)"

# Discos
if [[ ! -f "$OS_RUTA" ]]; then
  qemu-img create -f qcow2 "$OS_RUTA" "${OS_GB}G" >/dev/null
  info "disco del SO creado: $OS_RUTA (${OS_GB} GiB, qcow2)"
else
  info "disco del SO existente: $OS_RUTA (se reutiliza)"
fi
if [[ "$DATA_GB" != "0" && ! -f "$DATOS_RUTA" ]]; then
  qemu-img create -f qcow2 "$DATOS_RUTA" "${DATA_GB}G" >/dev/null
  info "disco de datos persistente: $DATOS_RUTA (${DATA_GB} GiB)"
fi

ARGS=(
  --name "$NOMBRE"
  --memory "$RAM_MB"
  --vcpus "$VCPUS"
  --cpu host
  --osinfo win11
  --network "bridge=$BRIDGE,model=virtio,driver_name=qemu,driver_type=virtio"
  --disk "path=$OS_RUTA,format=qcow2,bus=virtio,cache=writeback"
  --disk "path=$VIRTIO_ISO,device=cdrom"
  --graphics spice,listen=0.0.0.0
  --video virtio
  --sound ich9
  --input-type tablet
  --watchdog ib700
  --boot hd,cdrom
  --autostart="$AUTOSTART"
)
if [[ -n "$WIN_ISO" && -r "$WIN_ISO" ]]; then
  ARGS+=(--disk "path=$WIN_ISO,device=cdrom,readonly=on")
fi
if [[ "$DATA_GB" != "0" ]]; then
  ARGS+=(--disk "path=$DATOS_RUTA,format=qcow2,bus=virtio,cache=native,discard=unmap")
fi
[[ "$EFI" == "yes" ]] && ARGS+=(--boot uefi)
[[ "$TPM" == "yes" ]] && ARGS+=(--tpm emulate,model=tpm-crb,version=2.0)

if [[ -n "$GPU_BDF" ]]; then
  ARGS+=(--hostdev "$GPU_BDF")
  [[ -n "$GPU_AUDIO_BDF" ]] && ARGS+=(--hostdev "$GPU_AUDIO_BDF")
  info "passthrough: $GPU_BDF${GPU_AUDIO_BDF:+ + $GPU_AUDIO_BDF}"
  if [[ "$EFI" != "yes" ]]; then
    aviso "GPU moderna con OVMF/UEFI: sin --boot uefi el Option ROM puede no inicializar (y Windows no vera la GPU)."
  fi
else
  aviso "sin GPU_BDF: la VM se crea SIN GPU. El proyecto lo reportara como limitacion (no se finge un adapter)."
  aviso "para solo escritorio remoto por RDP/Windows App esto es suficiente; para gaming no."
fi

printf '\n\033[1m== comando ==\033[0m\nvirt-install %q ' "${ARGS[@]}"; echo
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  info "DRY_RUN=1: no se ejecuto nada."
  exit 0
fi

virt-install "${ARGS[@]}"

info "dominio creado. Instalacion: virt-viewer -c qemu:///system $NOMBRE  (o virsh console $NOMBRE para ver el arranque)"
echo
echo "Siguientes pasos:"
echo "  1. Termina la instalacion de Windows (elige el disco VirtIO; carga el driver desde la ISO de virtio)."
echo "  2. Crea el usuario y habilita Escritorio remoto."
echo "  3. Prepara la VM desde dentro o via virsh/virt-exec (sin tuneles aun):"
echo "       powershell -File C:\\ProgramData\\WinGamingVM\\scripts\\win\\Bootstrap-GamingVM.ps1"
echo "  4. Accede con Windows App a la IP de la VM (debe estar en tu LAN por el bridge)."
echo
echo "Si la VM queda sin IP en la LAN: ip -br addr en el host y 'virsh domifaddr $NOMBRE'."
