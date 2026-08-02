#!/usr/bin/env bash
# =============================================================================
# 02-install-k8s-packages.sh — kubeadm, kubelet, kubectl
# =============================================================================
# Запуск: sudo ./02-install-k8s-packages.sh [VERSION]
# Пример: sudo ./02-install-k8s-packages.sh 1.32.4
#
# kubelet — агент на каждой ноде, запускает Pod'ы через containerd
# kubeadm — bootstrap кластера (init/join), не нужен после установки
# kubectl — CLI к API (на CP; на workers опционально)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

K8S_VERSION="${1:-1.32.4}"
K8S_MINOR="${K8S_VERSION%.*}"

echo "=== [02] Установка Kubernetes ${K8S_VERSION} ==="

verify_no_swap || exit 1

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg

# Официальный репозиторий Kubernetes (pkgs.k8s.io) — версия привязана к minor
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update

# Пины версий — kubeadm требует kubelet той же minor
apt-get install -y kubelet="${K8S_VERSION}-1.1" kubeadm="${K8S_VERSION}-1.1" kubectl="${K8S_VERSION}-1.1"

# apt-mark hold — случайный apt upgrade не сломает совместимость кластера
apt-mark hold kubelet kubeadm kubectl

# cri-tools — пакет crictl для диагностики
if ! command -v crictl >/dev/null; then
  apt-get install -y cri-tools 2>/dev/null || true
fi

# enable kubelet — будет активен после kubeadm init/join
systemctl enable kubelet

echo "[OK] kubeadm $(kubeadm version -o short)"
echo "[OK] kubelet $(kubelet --version | awk '{print $2}')"

echo ""
echo "kubelet в состоянии activating до init/join — это нормально."
echo "CP:     sudo ./03-kubeadm-init.sh"
echo "Worker: sudo ./04-kubeadm-join.sh '<join-command>'"
