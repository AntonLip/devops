#!/usr/bin/env bash
# =============================================================================
# 01-install-containerd.sh — Container Runtime (CRI) для kubelet
# =============================================================================
# Запуск: sudo ./01-install-containerd.sh
# После:  00-prep-node + reboot
#
# kubelet общается с контейнерами через CRI socket containerd.
# SystemdCgroup=true — ОБЯЗАТЕЛЬНО на Ubuntu 24.04, иначе kubelet unhealthy.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

echo "=== [01] Установка containerd ==="

# Проверка swap — если забыли reboot после 00, поймаем здесь
verify_no_swap || {
  echo "Сначала: sudo ./00-prep-node.sh && sudo reboot" >&2
  exit 1
}

# apt-get update — обновить индекс пакетов
apt-get update

# ca-certificates curl gnupg — HTTPS-репозитории и GPG-ключи
apt-get install -y ca-certificates curl gnupg

# Ключ репозитория Docker (пакет containerd.io поставляется оттуда)
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Подключить apt repo Docker CE для Ubuntu (noble = 24.04)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  >/etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y containerd.io

# containerd config default — шаблон конфига с правильной структурой TOML
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml

# SystemdCgroup=true — kubelet использует cgroup driver systemd;
# без этого containerd использует cgroupfs → mismatch → kubelet crash
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# enable — автозапуск при boot; restart — применить конфиг
systemctl enable containerd
systemctl restart containerd

# kubelet ещё не настроен kubeadm, но cgroup-driver задаём заранее
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/00-cgroup-driver.conf <<'EOF'
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd"
EOF
systemctl daemon-reload

if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  echo "[ERROR] SystemdCgroup не true — kubelet будет unhealthy" >&2
  exit 1
fi

# crictl — CLI для отладки CRI (аналог docker, но для containerd)
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo "[OK] containerd $(containerd --version)"
echo "[OK] systemctl is-active containerd: $(systemctl is-active containerd)"
crictl version 2>/dev/null || echo "[INFO] crictl появится после 02-install-k8s-packages.sh"

echo ""
echo "Проверка: crictl info | head -3"
echo "Далее:    sudo ./02-install-k8s-packages.sh 1.32.4"
