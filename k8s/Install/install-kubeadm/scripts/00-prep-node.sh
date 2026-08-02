#!/usr/bin/env bash
# =============================================================================
# 00-prep-node.sh — подготовка Ubuntu 24.04 к Kubernetes (kubeadm)
# =============================================================================
# Запуск:  sudo ./00-prep-node.sh [hostname]
# Пример:  sudo ./00-prep-node.sh k8s-cp-01
#
# На каждой ноде (CP и workers) ОДИН раз, затем reboot.
#
# Реальный баг на homelab: после reboot swap снова включался → kubelet unhealthy.
# Этот скрипт отключает swap навсегда (fstab + systemd mask + unit при загрузке).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"

echo "=== [00] Подготовка node к Kubernetes ==="
echo "    Сеть: ${NODE_NETWORK}"
echo "    CP: ${CP_IP} (${CP_HOSTNAME})"
echo "    Workers: ${WORKER1_IP} (${WORKER1_HOSTNAME}), ${WORKER2_IP} (${WORKER2_HOSTNAME})"

# -----------------------------------------------------------------------------
# Hostname — имя Node object в Kubernetes и в TLS-сертификатах kubelet
# -----------------------------------------------------------------------------
HOSTNAME_ARG="${1:-}"
if [[ -n "$HOSTNAME_ARG" ]]; then
  # hostnamectl — постоянное имя хоста (не только текущая сессия)
  hostnamectl set-hostname "$HOSTNAME_ARG"
  echo "[hostname] $HOSTNAME_ARG"
fi

# -----------------------------------------------------------------------------
# SWAP — kubelet требует swap OFF (главная причина вашей ошибки init)
# -----------------------------------------------------------------------------
disable_swap_persistent

# -----------------------------------------------------------------------------
# Kernel modules — нужны для overlayFS (containerd) и bridge networking (CNI)
# -----------------------------------------------------------------------------
# overlay — слои файловой системы контейнера
# br_netfilter — iptables видит трафик между Pod'ами через linux bridge
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay    # загрузить модуль сейчас (без reboot)
modprobe br_netfilter
echo "[modules] overlay, br_netfilter"

# -----------------------------------------------------------------------------
# Sysctl — маршрутизация и фильтрация bridge-трафика для Kubernetes/CNI
# -----------------------------------------------------------------------------
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
# Pod-to-Pod через bridge должен проходить iptables (kube-proxy, Calico)
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
# Маршрутизация между Pod CIDR и внешним миром
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null   # применить все sysctl.d
echo "[sysctl] bridge-nf, ip_forward"

# -----------------------------------------------------------------------------
# NTP — расхождение времени ломает TLS-сертификаты API Server и etcd
# -----------------------------------------------------------------------------
timedatectl set-ntp true 2>/dev/null || true
echo "[ntp] enabled"

# -----------------------------------------------------------------------------
# Firewall (если ufw активен) — порты control plane и Calico
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 6443/tcp comment 'k8s API' 2>/dev/null || true          # kube-apiserver
  ufw allow 2379:2380/tcp comment 'etcd' 2>/dev/null || true        # etcd client/peer
  ufw allow 10250/tcp comment 'kubelet' 2>/dev/null || true           # kubelet API
  ufw allow 10259/tcp comment 'kube-scheduler' 2>/dev/null || true
  ufw allow 10257/tcp comment 'kube-controller-manager' 2>/dev/null || true
  ufw allow 30000:32767/tcp comment 'NodePort' 2>/dev/null || true  # Service NodePort
  ufw allow 179/tcp comment 'Calico BGP' 2>/dev/null || true
  ufw allow 4789/udp comment 'Calico VXLAN' 2>/dev/null || true
  ufw allow from "${WORKER1_IP}" to any port 6443 2>/dev/null || true
  ufw allow from "${WORKER2_IP}" to any port 6443 2>/dev/null || true
  echo "[ufw] rules added"
else
  echo "[ufw] skip (не активен)"
fi

# -----------------------------------------------------------------------------
# /etc/hosts — резолв имён нод для join и etcd (если нет DNS в lab)
# -----------------------------------------------------------------------------
MARKER="# kubeadm lab 15.5 (Anton 192.168.1.0/24)"
if ! grep -q 'kubeadm lab 15.5' /etc/hosts 2>/dev/null; then
  cat >>/etc/hosts <<EOF

${MARKER}
${CP_IP}  ${CP_HOSTNAME}
${WORKER1_IP}  ${WORKER1_HOSTNAME}
${WORKER2_IP}  ${WORKER2_HOSTNAME}
${TALOS_CP_IP}  maste1-talos
EOF
  echo "[hosts] записи kubeadm + Talos"
fi

echo ""
echo "=== [00] Готово. ОБЯЗАТЕЛЬНО перезагрузитесь: sudo reboot ==="
echo ""
echo "После reboot проверьте на этой VM:"
echo "  swapon --show          # пусто!"
echo "  free -h                # Swap: 0"
echo "  sysctl net.ipv4.ip_forward   # = 1"
echo ""
echo "Затем: sudo ./01-install-containerd.sh"
