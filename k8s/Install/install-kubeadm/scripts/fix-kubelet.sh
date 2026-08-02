#!/usr/bin/env bash
# =============================================================================
# fix-kubelet.sh — диагностика и исправление «kubelet is not healthy»
# =============================================================================
# Запуск: sudo ./fix-kubelet.sh
# После failed init: sudo ./fix-kubelet.sh --reset
#
# Типичные причины на homelab (проверено):
#   1. Swap включился после reboot  ← главная
#   2. SystemdCgroup=false в containerd
#   3. cgroup-driver kubelet ≠ systemd
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

DO_RESET=false
[[ "${1:-}" == "--reset" ]] && DO_RESET=true

log() { echo "[fix-kubelet] $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Запускайте: sudo $0 [--reset]" >&2
  exit 1
fi

log "=== Диагностика kubelet ==="

# --- 1. SWAP (главная причина вашей ошибки) ---
log "--- swap ---"
if swapon --show 2>/dev/null | grep -q .; then
  log "FIX: swap включён — отключаем навсегда"
  disable_swap_persistent
else
  log "swap выключен сейчас; проверяем fstab и boot unit..."
  disable_swap_persistent
fi

# --- 2. Kernel modules + sysctl ---
log "--- modules/sysctl ---"
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- 3. containerd SystemdCgroup ---
log "--- containerd ---"
if [[ ! -f /etc/containerd/config.toml ]]; then
  log "FIX: нет config — запустите 01-install-containerd.sh"
else
  if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    log "FIX: SystemdCgroup = true"
  fi
  systemctl restart containerd
fi
log "containerd: $(systemctl is-active containerd)"

# --- 4. kubelet cgroup-driver ---
log "--- kubelet ---"
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/00-cgroup-driver.conf <<'EOF'
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd"
EOF
systemctl daemon-reload
systemctl enable kubelet
systemctl restart kubelet
sleep 3

# --- 5. Health check ---
log "--- healthz :10248 ---"
if curl -sf --max-time 5 http://127.0.0.1:10248/healthz | grep -q ok; then
  log "OK: kubelet healthy"
else
  log "FAIL: смотрите journalctl -u kubelet -n 40"
  journalctl -u kubelet -n 40 --no-pager
fi

if $DO_RESET; then
  log "--- kubeadm reset ---"
  kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock 2>/dev/null || kubeadm reset -f
  cleanup_k8s_networking
  systemctl restart kubelet containerd
  log "Сброс готов → sudo ./03-kubeadm-init.sh"
fi

echo ""
log "Дальше:"
echo "  curl -s http://127.0.0.1:10248/healthz   # ok"
echo "  sudo ./03-kubeadm-init.sh"
