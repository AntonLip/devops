#!/usr/bin/env bash
# =============================================================================
# 07-install-metrics-server.sh — Metrics API для kubectl top / HPA
# =============================================================================
# Запуск на CP: ./07-install-metrics-server.sh
# kubelet-insecure-tls в manifest — для self-signed kubelet certs на kubeadm
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== [07] Metrics Server ==="

kubectl apply -f "${SCRIPT_DIR}/../manifests/03-metrics-server.yaml"

# APIService регистрирует metrics.k8s.io в API aggregation layer
sleep 15
kubectl get apiservice v1beta1.metrics.k8s.io -o wide 2>/dev/null || true

echo ""
echo "Через ~60 сек:"
echo "  kubectl top nodes"
echo "  kubectl top pods -A"
