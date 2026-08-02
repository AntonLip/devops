#!/usr/bin/env bash
# =============================================================================
# access-dashboard.sh — открыть Kubernetes Dashboard с хоста (Manjaro)
# =============================================================================
# Dashboard Pod'ы Running на кластере — но Service ClusterIP, с браузера напрямую не открыть.
# Нужны: kubeconfig kubeadm lab + port-forward + Token login.
#
# Запуск на ХОСТЕ (не на VM):
#   ./access-dashboard.sh
#   ./access-dashboard.sh --fetch-kubeconfig   # скопировать config с CP
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

KUBECONFIG_LAB="${KUBECONFIG_LAB:-${HOME}/.kube/kubeadm-lab-config}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
VM_USER="${VM_USER:-k8s}"

fetch_kubeconfig() {
  echo "[dashboard] Копируем kubeconfig с ${CP_HOSTNAME} (${CP_IP})..."
  mkdir -p "$(dirname "$KUBECONFIG_LAB")"
  scp -o StrictHostKeyChecking=accept-new \
    "${VM_USER}@${CP_IP}:/home/${VM_USER}/.kube/config" \
    "$KUBECONFIG_LAB"
  echo "[dashboard] KUBECONFIG → ${KUBECONFIG_LAB}"
}

check_dashboard() {
  export KUBECONFIG="$KUBECONFIG_LAB"
  if ! kubectl cluster-info &>/dev/null; then
    echo "[ERROR] kubectl не подключается к ${CP_IP}:6443" >&2
    echo "  Запустите: $0 --fetch-kubeconfig" >&2
    exit 1
  fi
  echo "[dashboard] Pods:"
  kubectl get pods -n kubernetes-dashboard -o wide
  local ready
  ready=$(kubectl get deploy kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [[ "$ready" != "1" ]]; then
    echo "[ERROR] kubernetes-dashboard deployment не Ready. На CP: ./06-install-dashboard.sh" >&2
    exit 1
  fi
}

print_token_hint() {
  export KUBECONFIG="$KUBECONFIG_LAB"
  echo ""
  echo "=== Token для входа (скопируйте в браузер) ==="
  echo "Выполните в другом терминале:"
  echo "  KUBECONFIG=${KUBECONFIG_LAB} kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h"
  echo ""
  echo "Или на CP:"
  echo "  ssh ${VM_USER}@${CP_IP} 'kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h'"
  echo ""
}

[[ "${1:-}" == "--fetch-kubeconfig" ]] && fetch_kubeconfig

if [[ ! -f "$KUBECONFIG_LAB" ]]; then
  echo "[WARN] Нет ${KUBECONFIG_LAB}"
  fetch_kubeconfig
fi

check_dashboard
print_token_hint

echo "=== Port-forward (оставьте этот терминал открытым) ==="
echo "  Браузер: https://localhost:${LOCAL_PORT}"
echo "  Login:   Token (НЕ username/password!)"
echo "  Cert:    Accept / Advanced → Proceed (self-signed)"
echo ""
export KUBECONFIG="$KUBECONFIG_LAB"
exec kubectl -n kubernetes-dashboard port-forward "svc/kubernetes-dashboard" "${LOCAL_PORT}:443"
