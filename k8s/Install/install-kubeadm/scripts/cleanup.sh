#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — полный сброс kubeadm на этой ноде
# =============================================================================
# Запуск: sudo ./cleanup.sh
#
# kubeadm reset НЕ чистит: /etc/cni/net.d, iptables, ~/.kube/config
# Этот скрипт делает полную очистку для повторного init/join.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"

echo "=== Cleanup kubeadm node ==="
read -p "Сбросить кластер на этой ноде? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# kubeadm reset — остановить static pods, удалить /etc/kubernetes/manifests
kubeadm reset -f --cri-socket="$CRI_SOCKET" 2>/dev/null || kubeadm reset -f

# Всё, что reset оставляет (см. предупреждения kubeadm)
cleanup_k8s_networking

# Перезапуск агентов
systemctl restart containerd kubelet

# Swap не трогаем — k8s-disable-swap.service должен остаться enabled
verify_no_swap && echo "[OK] swap по-прежнему выключен"

echo ""
echo "[OK] Нода очищена."
echo "  CP:     00 → reboot → 01 → 02 → 03 → 05"
echo "  Worker: 00 → reboot → 01 → 02 → 04"
