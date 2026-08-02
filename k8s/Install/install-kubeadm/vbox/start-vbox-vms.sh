#!/usr/bin/env bash
# start-vbox-vms.sh — запустить kubeadm lab VM (headless)
# По умолчанию только CP. Все три: START_MODE=all ./start-vbox-vms.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

START_MODE="${START_MODE:-cp}"

start_one() {
  local name="$1"
  if VBoxManage list vms | grep -q "\"${name}\""; then
    state="$(VBoxManage showvminfo "$name" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
    if [[ "$state" == "running" ]]; then
      echo "[start] ${name} — уже running"
    else
      echo "[start] ${name}..."
      VBoxManage startvm "$name" --type headless
    fi
  else
    echo "[start] ${name} — не найдена. Сначала: ./create-vbox-vms.sh" >&2
  fi
}

case "$START_MODE" in
  all)
    for name in "${CP_HOSTNAME}" "${WORKER1_HOSTNAME}" "${WORKER2_HOSTNAME}"; do
      start_one "$name"
    done
    ;;
  cp)
    start_one "${CP_HOSTNAME}"
    echo "[start] Workers не запущены (избегаем RCU stall при autoinstall)"
    ;;
  *)
    start_one "$START_MODE"
    ;;
esac

echo ""
VBoxManage list runningvms | grep -E 'k8s-' || echo "(нет запущенных k8s-* VM)"
