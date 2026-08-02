#!/usr/bin/env bash
# =============================================================================
# 05-install-calico.sh — CNI (Container Network Interface)
# =============================================================================
# Запуск на CP после kubeadm init: ./05-install-calico.sh
#
# Без CNI: Node NotReady, Pod'ы ContainerCreating forever.
# Calico DaemonSet на каждой ноде настраивает Pod network 10.244.0.0/16.
# =============================================================================
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../manifests/01-calico.yaml"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "=== [05] Установка Calico ${CALICO_VERSION} ==="

# kubectl должен видеть API (admin.conf настроен после init)
if ! kubectl cluster-info &>/dev/null; then
  echo "[ERROR] kubectl не подключён. Настройте ~/.kube/config" >&2
  exit 1
fi

# Локальный yaml только если есть apiVersion (не README-заглушка)
if [[ -f "$MANIFEST" ]] && grep -q '^apiVersion:' "$MANIFEST" 2>/dev/null; then
  echo "[apply] локальный manifest"
  kubectl apply -f "$MANIFEST"
else
  echo "[apply] upstream: ${CALICO_URL}"
  kubectl apply -f "$CALICO_URL"
fi

# Ждём calico-node — после этого Node станет Ready
echo "Ожидание calico-node..."
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s 2>/dev/null || true

kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl get nodes

echo ""
echo "[OK] Node должен быть Ready. Далее: join workers или addons (06, 07)."
