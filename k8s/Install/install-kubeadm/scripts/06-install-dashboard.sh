#!/usr/bin/env bash
# =============================================================================
# 06-install-dashboard.sh — Kubernetes Dashboard (UI)
# =============================================================================
# Запуск на CP: ./06-install-dashboard.sh
# Доступ: kubectl port-forward + token SA dashboard-admin
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

DASHBOARD_VERSION="${DASHBOARD_VERSION:-v2.7.0}"

echo "=== [06] Kubernetes Dashboard ${DASHBOARD_VERSION} ==="

# Официальный manifest Dashboard (Deployment + Service + RBAC)
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

# SA + cluster-admin binding для входа по token (только lab!)
kubectl apply -f "${SCRIPT_DIR}/../manifests/02-dashboard-admin-sa.yaml"

kubectl wait --for=condition=Available deployment/kubernetes-dashboard \
  -n kubernetes-dashboard --timeout=120s 2>/dev/null || true

echo ""
echo "=== Доступ к Dashboard ==="
echo ""
echo "Dashboard — ClusterIP, с браузера НАПРЯМУЮ не открыть."
echo "Нужен port-forward + kubeconfig kubeadm lab (отдельно от Talos!)."
echo ""
echo "На ХОСТЕ (Manjaro):"
echo "  ../vbox/access-dashboard.sh --fetch-kubeconfig"
echo "  # или вручную:"
echo "  scp k8s@${CP_IP}:/home/k8s/.kube/config ~/.kube/kubeadm-lab-config"
echo "  KUBECONFIG=~/.kube/kubeadm-lab-config kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443"
echo ""
echo "Браузер: https://localhost:8443"
echo "Login:   Token (не kubeconfig файл в поле login!)"
echo "Token:"
echo "  kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h"
echo ""
echo "Частые ошибки:"
echo "  - port-forward на CP, браузер на хосте → не работает без SSH -L"
echo "  - http:// вместо https://"
echo "  - нет KUBECONFIG на хосте → kubectl идёт на localhost:8080"
