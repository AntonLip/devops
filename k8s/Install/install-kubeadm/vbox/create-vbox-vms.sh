#!/usr/bin/env bash
# create-vbox-vms.sh — создание 3 VM VirtualBox для kubeadm lab (15.5)
#
# Создаёт: k8s-cp-01 (.20), k8s-w-01 (.21), k8s-w-02 (.22)
# Сеть: bridged → ваша LAN 192.168.1.0/24 (рядом с Talos)
#
# Требования на хосте (Manjaro/Arch):
#   virtualbox  xorriso  curl
#
# Использование:
#   ./create-vbox-vms.sh                          # скачать ISO, создать VM
#   UBUNTU_ISO=~/Downloads/ubuntu.iso ./create-vbox-vms.sh
#   BRIDGE_IFACE=enp3s0 ./create-vbox-vms.sh
#   ./create-vbox-vms.sh --start                  # создать и запустить все VM
#   ./create-vbox-vms.sh --destroy                # удалить VM и диски
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../config.env
source "${LAB_DIR}/config.env"

# --- Параметры VM (можно переопределить через env) ---
VM_USER="${VM_USER:-k8s}"
VM_PASSWORD="${VM_PASSWORD:-k8s}"          # только для lab!
VM_SSH_PUBKEY="${VM_SSH_PUBKEY:-${HOME}/.ssh/id_rsa.pub}"
CP_CPUS="${CP_CPUS:-2}"
CP_RAM_MB="${CP_RAM_MB:-4096}"
CP_DISK_MB="${CP_DISK_MB:-40960}"
WORKER_CPUS="${WORKER_CPUS:-2}"
WORKER_RAM_MB="${WORKER_RAM_MB:-3072}"
WORKER_DISK_MB="${WORKER_DISK_MB:-30720}"
VBoxVM_DIR="${VBoxVM_DIR:-${HOME}/VirtualBox VMs/kubeadm-lab}"
SEED_DIR="${SCRIPT_DIR}/.seed-isos"
UBUNTU_ISO="${UBUNTU_ISO:-/home/anton/PRG/DevOps/iso/ubuntu-24.04.1-live-server-amd64.iso}"
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso}"

BRIDGE_IFACE="${BRIDGE_IFACE:-$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)}"

declare -a VM_NAMES=("${CP_HOSTNAME}" "${WORKER1_HOSTNAME}" "${WORKER2_HOSTNAME}")
declare -a VM_IPS=("${CP_IP}" "${WORKER1_IP}" "${WORKER2_IP}")
declare -a VM_CPUS_ARR=("${CP_CPUS}" "${WORKER_CPUS}" "${WORKER_CPUS}")
declare -a VM_RAM_ARR=("${CP_RAM_MB}" "${WORKER_RAM_MB}" "${WORKER_RAM_MB}")
declare -a VM_DISK_ARR=("${CP_DISK_MB}" "${WORKER_DISK_MB}" "${WORKER_DISK_MB}")

log()  { echo "[vbox] $*"; }
die()  { echo "[vbox] ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Нужна команда '$1'. Установите пакет и повторите."
}

check_prereqs() {
  need_cmd VBoxManage
  need_cmd xorriso
  [[ -n "$BRIDGE_IFACE" ]] || die "Не найден bridge-интерфейс. Задайте: BRIDGE_IFACE=enp3s0 ./create-vbox-vms.sh"
  log "Bridged adapter: ${BRIDGE_IFACE}"
  ip link show "$BRIDGE_IFACE" >/dev/null 2>&1 || die "Интерфейс ${BRIDGE_IFACE} не существует"
}

download_iso() {
  if [[ -f "$UBUNTU_ISO" ]]; then
    log "ISO уже есть: ${UBUNTU_ISO}"
    return
  fi
  mkdir -p "$(dirname "$UBUNTU_ISO")"
  log "Скачивание Ubuntu 24.04 Server (~2.6 GB)..."
  log "URL: ${UBUNTU_ISO_URL}"
  curl -fL --progress-bar -o "${UBUNTU_ISO}.partial" "$UBUNTU_ISO_URL"
  mv "${UBUNTU_ISO}.partial" "$UBUNTU_ISO"
  log "ISO сохранён: ${UBUNTU_ISO}"
}

hash_password() {
  # autoinstall ожидает hashed password
  openssl passwd -6 -salt "$(openssl rand -hex 8)" "$VM_PASSWORD"
}

build_seed_iso() {
  local name="$1" ip="$2" seed_iso="$3"
  local tmp
  tmp="$(mktemp -d)"
  local hashed_pw
  hashed_pw="$(hash_password)"

  local ssh_block=""
  if [[ -f "$VM_SSH_PUBKEY" ]]; then
    ssh_block="  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - $(cat "$VM_SSH_PUBKEY")"
  else
    ssh_block="  ssh:
    install-server: true
    allow-pw: true"
  fi

  cat >"${tmp}/meta-data" <<EOF
instance-id: ${name}
local-hostname: ${name}
EOF

  cat >"${tmp}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${name}
    username: ${VM_USER}
    password: "${hashed_pw}"
${ssh_block}
  network:
    network:
      version: 2
      ethernets:
        enp0s3:
          dhcp4: false
          addresses:
            - ${ip}/24
          routes:
            - to: default
              via: ${GATEWAY}
          nameservers:
            addresses:
              - ${GATEWAY}
              - 8.8.8.8
        enp0s8:
          dhcp4: false
          optional: true
  storage:
    layout:
      name: direct
  packages:
    - openssh-server
    - curl
    - ca-certificates
  late-commands:
    - curtin in-target -- systemctl enable ssh
    - curtin in-target -- sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    - curtin in-target -- bash -c 'echo "${VM_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${VM_USER} && chmod 440 /etc/sudoers.d/90-${VM_USER}'
EOF

  mkdir -p "$SEED_DIR"
  xorriso -as mkisofs -output "$seed_iso" -volid cidata -joliet -rock "$tmp/meta-data" "$tmp/user-data" >/dev/null
  rm -rf "$tmp"
  log "  seed ISO: ${seed_iso}"
}

vm_exists() {
  VBoxManage list vms | grep -q "\"$1\""
}

destroy_vms() {
  log "Удаление VM kubeadm lab..."
  for name in "${VM_NAMES[@]}"; do
    if vm_exists "$name"; then
      VBoxManage controlvm "$name" poweroff 2>/dev/null || true
      sleep 2
      VBoxManage unregistervm "$name" --delete 2>/dev/null || VBoxManage unregistervm "$name"
      log "  удалена: ${name}"
    fi
  done
  rm -rf "$SEED_DIR"
  log "Готово. ISO кэш оставлен: ${UBUNTU_ISO}"
}

create_vm() {
  local name="$1" ip="$2" cpus="$3" ram="$4" disk_mb="$5"
  local vm_dir="${VBoxVM_DIR}/${name}"
  local disk_path="${vm_dir}/${name}.vdi"
  local seed_iso="${SEED_DIR}/${name}-cidata.iso"

  if vm_exists "$name"; then
    log "VM '${name}' уже существует — пропуск (используйте --destroy для пересоздания)"
    return
  fi

  log "Создание VM: ${name} (${ip}, ${cpus} CPU, ${ram} MB RAM, ${disk_mb} MB disk)"
  mkdir -p "$vm_dir"
  build_seed_iso "$name" "$ip" "$seed_iso"

  VBoxManage createvm --name "$name" --register --basefolder "$VBoxVM_DIR" --ostype Ubuntu_64
  VBoxManage modifyvm "$name" \
    --memory "$ram" \
    --cpus "$cpus" \
    --ioapic on \
    --paravirt-provider kvm \
    --vram 16 \
    --graphicscontroller vmsvga \
    --nic1 bridged \
    --bridgeadapter1 "$BRIDGE_IFACE" \
    --nicpromisc1 allow-all \
    --audio none \
    --usb off \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --clipboard disabled \
    --draganddrop disabled

  VBoxManage createmedium disk --filename "$disk_path" --size "$disk_mb" --format VDI
  VBoxManage storagectl "$name" --name SATA --add sata --controller IntelAhci --portcount 4
  VBoxManage storageattach "$name" --storagectl SATA --port 0 --device 0 --type hdd --medium "$disk_path"
  VBoxManage storageattach "$name" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$UBUNTU_ISO"
  VBoxManage storageattach "$name" --storagectl SATA --port 2 --device 0 --type dvddrive --medium "$seed_iso"

  log "  OK: ${name}"
}

start_vms() {
  # По умолчанию — только CP. Три VM одновременно при autoinstall = RCU stall на слабом хосте.
  local target="${START_MODE:-cp}"
  case "$target" in
    all)
      for name in "${VM_NAMES[@]}"; do _start_one "$name"; done
      ;;
    cp)
      _start_one "${CP_HOSTNAME}"
      log "Workers НЕ запущены. После установки CP: START_MODE=all ./start-vbox-vms.sh"
      ;;
    *)
      _start_one "$target"
      ;;
  esac
}

_start_one() {
  local name="$1"
  if vm_exists "$name"; then
    state="$(VBoxManage showvminfo "$name" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
    if [[ "$state" != "running" ]]; then
      log "Запуск ${name}..."
      VBoxManage startvm "$name" --type headless
    else
      log "${name} уже running"
    fi
  fi
}

wait_hint() {
  cat <<EOF

================================================================================
  VM созданы. Автоустановка Ubuntu 24.04 займёт ~10–15 мин на каждую VM.

  Запуск (если ещё не запущены):
    VBoxManage startvm ${CP_HOSTNAME} --type headless
    VBoxManage startvm ${WORKER1_HOSTNAME} --type headless
    VBoxManage startvm ${WORKER2_HOSTNAME} --type headless

  Или GUI: VirtualBox → Start

  После установки (проверка с хоста):
    ssh ${VM_USER}@${CP_IP}       # пароль: ${VM_PASSWORD}
    ssh ${VM_USER}@${WORKER1_IP}
    ping -c2 ${TALOS_CP_IP}      # Talos рядом в LAN

  Скопировать lab на CP:
    scp -r "${LAB_DIR}" ${VM_USER}@${CP_IP}:/tmp/install-kubeadm

  На каждой VM:
    cd /tmp/install-kubeadm/scripts && chmod +x *.sh
    sudo ./00-prep-node.sh <hostname>
    ...

  Удалить VM:
    ${SCRIPT_DIR}/create-vbox-vms.sh --destroy

  Параметры:
    BRIDGE_IFACE=${BRIDGE_IFACE}
    VM_USER=${VM_USER}  VM_PASSWORD=${VM_PASSWORD}
    Диски: ${VBoxVM_DIR}
================================================================================
EOF
}

main() {
  local do_start=false do_destroy=false
  for arg in "$@"; do
    case "$arg" in
      --start)   do_start=true ;;
      --destroy) do_destroy=true ;;
      -h|--help)
        sed -n '2,18p' "$0"
        exit 0
        ;;
      *) die "Неизвестный аргумент: $arg (используйте --help)" ;;
    esac
  done

  if $do_destroy; then
    destroy_vms
    exit 0
  fi

  check_prereqs
  download_iso

  for i in "${!VM_NAMES[@]}"; do
    create_vm "${VM_NAMES[$i]}" "${VM_IPS[$i]}" "${VM_CPUS_ARR[$i]}" "${VM_RAM_ARR[$i]}" "${VM_DISK_ARR[$i]}"
  done

  $do_start && start_vms
  wait_hint
}

main "$@"
