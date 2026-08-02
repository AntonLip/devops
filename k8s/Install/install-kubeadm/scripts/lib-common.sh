#!/usr/bin/env bash
# lib-common.sh — общие функции для kubeadm lab (15.5)
# Подключение: source "$(dirname "$0")/lib-common.sh"
#
# Реальный кейс homelab: после reboot swap снова включался → kubelet unhealthy → kubeadm init fail

# Отключить swap сейчас и после каждой перезагрузки.
# kubelet по умолчанию отказывается работать при включённом swap (fail-swap-on).
disable_swap_persistent() {
  echo "[swap] Отключение swap (обязательно для kubelet)..."

  # swapoff -a — выключить все активные swap-разделы/файлы прямо сейчас
  swapoff -a 2>/dev/null || true

  # Бэкап fstab — на случай отката
  cp -a /etc/fstab /etc/fstab.bak.k8s-lab 2>/dev/null || true

  # Закомментировать ЛЮБЫЕ строки swap в /etc/fstab
  # (Ubuntu 24.04 часто: /swap.img none swap sw 0 0)
  sed -i '/[[:space:]]swap[[:space:]]/s/^/#k8s-swap-disabled /' /etc/fstab
  sed -i '\|/swap\.img|s/^/#k8s-swap-disabled /' /etc/fstab

  # Остановить и замаскировать systemd swap units (иначе swap поднимется после reboot)
  systemctl stop swap.target 2>/dev/null || true
  systemctl mask swap.target 2>/dev/null || true
  while read -r unit _; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
  done < <(systemctl list-units --type=swap --all --no-legend 2>/dev/null || true)

  # Скрипт, который гарантированно выключает swap при каждой загрузке (ДО kubelet)
  cat >/usr/local/sbin/k8s-swapoff.sh <<'SWAPOFF'
#!/bin/bash
# Вызывается systemd unit k8s-disable-swap.service при загрузке
swapoff -a 2>/dev/null || true
SWAPOFF
  chmod +x /usr/local/sbin/k8s-swapoff.sh

  cat >/etc/systemd/system/k8s-disable-swap.service <<'UNIT'
[Unit]
Description=Disable swap for Kubernetes kubeadm lab
DefaultDependencies=no
# Должен выполниться раньше kubelet, иначе kubelet стартует при включённом swap
Before=kubelet.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/k8s-swapoff.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable k8s-disable-swap.service
  systemctl start k8s-disable-swap.service

  verify_no_swap || return 1
  echo "[swap] OK: swap выключен, автозапуск swap заблокирован"
}

# Проверка: если swap включён — exit 1 с понятным сообщением
verify_no_swap() {
  # swapon --show — единственный надёжный индикатор активного swap
  if swapon --show 2>/dev/null | grep -q .; then
    echo "[ERROR] Swap ВСЁ ЕЩЁ включён!" >&2
    swapon --show >&2
    echo "  Причина на homelab: после reboot Ubuntu поднял /swap.img" >&2
    echo "  Решение: sudo ./00-prep-node.sh && reboot  или  sudo ./fix-kubelet.sh" >&2
    return 1
  fi
  return 0
}

# Preflight перед kubeadm init/join
verify_kubeadm_prereqs() {
  echo "[preflight] Проверка перед kubeadm..."

  verify_no_swap || {
    echo "  → Запустите: sudo ./00-prep-node.sh <hostname>  или  sudo ./fix-kubelet.sh"
    return 1
  }

  # containerd должен быть active — без CRI kubelet не поднимет static pods
  if ! systemctl is-active --quiet containerd; then
    echo "[ERROR] containerd не запущен. Запустите: sudo ./01-install-containerd.sh" >&2
    return 1
  fi

  # SystemdCgroup=true — иначе kubelet unhealthy (cgroup driver mismatch)
  if [[ -f /etc/containerd/config.toml ]] && ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    echo "[ERROR] containerd: SystemdCgroup не true. Запустите: sudo ./01-install-containerd.sh" >&2
    return 1
  fi

  # healthz kubelet — kubeadm init ждёт ответ ok на :10248
  if ! curl -sf --max-time 5 http://127.0.0.1:10248/healthz | grep -q ok; then
    echo "[WARN] kubelet :10248/healthz не ok — попробуйте: sudo ./fix-kubelet.sh"
  fi

  echo "[preflight] OK"
  return 0
}

# Очистка после kubeadm reset (то, что reset не делает сам)
cleanup_k8s_networking() {
  echo "[cleanup] CNI, iptables, kubeconfig..."

  # kubeadm reset не удаляет CNI config
  rm -rf /etc/cni/net.d

  # Остатки данных кластера
  rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/*

  # Правила NAT/filter от kube-proxy (reset их не чистит)
  iptables -F 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  ipvsadm --clear 2>/dev/null || true

  # kubeconfig пользователя (reset предупреждает, но не удаляет)
  if [[ -n "${SUDO_USER:-}" ]]; then
    rm -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.kube/config" 2>/dev/null || true
  fi
}
