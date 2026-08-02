#!/usr/bin/env bash
# =============================================================================
# 04-kubeadm-join.sh — подключение Worker Node к кластеру
# =============================================================================
# Запуск на worker (после 00→01→02 на этой VM):
#   sudo ./04-kubeadm-join.sh 'kubeadm join 192.168.1.20:6443 --token ... --hash ...'
#
# Процесс: bootstrap token → TLS bootstrap → CSR → kubelet cert → Node Ready
# Calico на worker ставить НЕ нужно — DaemonSet calico-node развернётся сам.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"

echo "=== [04] kubeadm join (worker) ==="

verify_kubeadm_prereqs || exit 1

if [[ $# -ge 1 ]]; then
  JOIN_CMD="$*"
else
  echo "Вставьте join command с CP (kubeadm token create --print-join-command):"
  read -r JOIN_CMD
fi

# Убрать дублирующий префикс если вставили полную строку
JOIN_CMD="${JOIN_CMD#kubeadm join }"
JOIN_CMD="${JOIN_CMD#kubeadm join}"

# --cri-socket — явно containerd (как при init)
if [[ "$JOIN_CMD" != *"cri-socket"* ]]; then
  JOIN_CMD="$JOIN_CMD --cri-socket=$CRI_SOCKET"
fi

# kubeadm join — регистрация ноды в API, настройка kubelet, установка kube-proxy
kubeadm join $JOIN_CMD

echo ""
echo "[OK] Worker joined."
echo "На CP (${CP_IP}): kubectl get nodes"
echo "Calico pod появится на worker автоматически."
