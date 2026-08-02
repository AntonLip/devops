#!/usr/bin/env bash
# stop-vbox-vms.sh — остановить все kubeadm lab VM
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

for name in "${CP_HOSTNAME}" "${WORKER1_HOSTNAME}" "${WORKER2_HOSTNAME}"; do
  if VBoxManage list runningvms | grep -q "\"${name}\""; then
    echo "[stop] ${name}..."
    VBoxManage controlvm "$name" acpipowerbutton 2>/dev/null || \
      VBoxManage controlvm "$name" poweroff
  else
    echo "[stop] ${name} — не запущена"
  fi
done
