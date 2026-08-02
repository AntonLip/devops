#!/usr/bin/env bash
# fix-vbox-resources.sh — уменьшить ресурсы VM если RCU stall / тормоза
# Запускать на ХОСТЕ когда VM выключены (или после poweroff)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

# Профиль "lite" — достаточно для kubeadm lab на хосте 12 CPU / 16+ GB RAM
CP_CPUS="${CP_CPUS:-2}"
CP_RAM_MB="${CP_RAM_MB:-4096}"
WORKER_CPUS="${WORKER_CPUS:-2}"
WORKER_RAM_MB="${WORKER_RAM_MB:-3072}"

apply() {
  local name="$1" cpus="$2" ram="$3"
  if ! VBoxManage list vms | grep -q "\"${name}\""; then
    echo "[skip] ${name} не найдена"
    return
  fi
  state="$(VBoxManage showvminfo "$name" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
  if [[ "$state" == "running" ]]; then
    echo "[warn] ${name} запущена — сначала: ./stop-vbox-vms.sh"
    return 1
  fi
  echo "[fix] ${name}: ${cpus} CPU, ${ram} MB RAM"
  VBoxManage modifyvm "$name" --cpus "$cpus" --memory "$ram" --ioapic on --paravirt-provider kvm
}

apply "${CP_HOSTNAME}" "$CP_CPUS" "$CP_RAM_MB"
apply "${WORKER1_HOSTNAME}" "$WORKER_CPUS" "$WORKER_RAM_MB"
apply "${WORKER2_HOSTNAME}" "$WORKER_CPUS" "$WORKER_RAM_MB"

echo ""
echo "Готово. Запускайте по одной VM:"
echo "  VBoxManage startvm ${CP_HOSTNAME} --type headless"
echo "  # дождитесь установки + ssh ${VM_USER:-k8s}@${CP_IP}"
echo "  # затем worker-1, потом worker-2"
