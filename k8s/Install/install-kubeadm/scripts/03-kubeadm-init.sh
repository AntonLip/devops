#!/usr/bin/env bash
# =============================================================================
# 03-kubeadm-init.sh — инициализация Control Plane (только k8s-cp-01)
# =============================================================================
# Запуск: sudo ./03-kubeadm-init.sh
#
# Создаёт: сертификаты, static pods (etcd, API, scheduler, CM), bootstrap token
# После:   ./05-install-calico.sh  →  join workers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

echo "=== [03] kubeadm init ==="
echo "  CP_IP=${CP_IP} (${CP_HOSTNAME})"
echo "  POD_CIDR=${POD_CIDR}  (должен совпадать с Calico)"
echo "  K8S_VERSION=${K8S_VERSION}"

# Preflight: swap, containerd, kubelet healthz
verify_kubeadm_prereqs || exit 1

# Не переинициализировать поверх живого кластера
if [[ -d /etc/kubernetes/manifests ]] && ls /etc/kubernetes/manifests/*.yaml &>/dev/null 2>&1; then
  echo "[ERROR] /etc/kubernetes/manifests не пуст — уже был init?"
  echo "  Сброс: sudo ./cleanup.sh"
  exit 1
fi

# kubeadm init — bootstrap control plane
# --pod-network-cidr  — Calico по умолчанию использует 10.244.0.0/16
# --apiserver-advertise-address — IP для сертификата API и связи kubelet→API
# --control-plane-endpoint — стабильный адрес API (на HA = LB DNS)
# --kubernetes-version — pin minor/patch
# --cri-socket — явно containerd (избегаем autodetect docker.sock)
kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --apiserver-advertise-address="$CP_IP" \
  --control-plane-endpoint="$CP_IP" \
  --kubernetes-version="$K8S_VERSION" \
  --cri-socket="$CRI_SOCKET"

# admin.conf — kubeconfig cluster-admin; копируем пользователю, запустившему sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube/config"
  echo "[OK] kubeconfig → $USER_HOME/.kube/config"
  echo "     ⚠️ Отдельно от Talos! Не перезаписывайте homelab kubeconfig на хосте."
fi

echo ""
echo "=== Следующие шаги ==="
echo "  1. kubectl get nodes     # NotReady до CNI — нормально"
echo "  2. ./05-install-calico.sh"
echo "  3. join workers (команда ниже)"
echo ""
# Токен для подключения worker — сохраните вывод
kubeadm token create --print-join-command 2>/dev/null || true
