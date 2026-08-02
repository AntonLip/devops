#!/usr/bin/env bash
# ssh-to-vms.sh — быстрый SSH на kubeadm lab VM
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

VM_USER="${VM_USER:-k8s}"

usage() {
  echo "Usage: $0 [cp|w1|w2|all]"
  echo "  cp  → ${VM_USER}@${CP_IP} (${CP_HOSTNAME})"
  echo "  w1  → ${VM_USER}@${WORKER1_IP} (${WORKER1_HOSTNAME})"
  echo "  w2  → ${VM_USER}@${WORKER2_IP} (${WORKER2_HOSTNAME})"
  echo "  all → проверить ping + ssh на всех"
}

case "${1:-cp}" in
  cp)  exec ssh -o StrictHostKeyChecking=accept-new "${VM_USER}@${CP_IP}" ;;
  w1)  exec ssh -o StrictHostKeyChecking=accept-new "${VM_USER}@${WORKER1_IP}" ;;
  w2)  exec ssh -o StrictHostKeyChecking=accept-new "${VM_USER}@${WORKER2_IP}" ;;
  all)
    for ip in "${CP_IP}" "${WORKER1_IP}" "${WORKER2_IP}"; do
      echo "=== ${ip} ==="
      ping -c1 -W2 "$ip" && ssh -o BatchMode=yes -o ConnectTimeout=5 "${VM_USER}@${ip}" hostname || echo "FAIL"
    done
    ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
