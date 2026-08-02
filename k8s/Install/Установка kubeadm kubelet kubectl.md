
# Установка kubeadm, kubelet, kubectl

## Цель

Установить **kubeadm**, **kubelet**, **kubectl** версии **1.32.x** из официального репозитория **pkgs.k8s.io**, зафиксировать версии через **apt hold**, понять **матрицу совместимости** и подготовить node к `kubeadm init` / `join`.

---

## Теория

### Роли трёх бинарников

| Бинарник    | Где runs                  | Назначение                                    |
| ----------- | ------------------------- | --------------------------------------------- |
| **kubeadm** | CLI, ad-hoc               | Bootstrap cluster: init, join, upgrade, certs |
| **kubelet** | systemd on **every** node | Node agent, CRI, static pods, sync            |
| **kubectl** | admin workstation / CP    | Client API - **не** required on node          |

```
Admin laptop                    Node (CP or worker)
     │                                │
     │ kubectl apply                  │ kubelet (always)
     │────────────────► API ◄─────────│
     │                                │
     │ kubeadm init/join (once)       │ kubeadm (CLI only when invoked)
     └────────────────────────────────┘
```

**Production:** `kubectl` на CP **не обязателен** - admins use CI/CD или bastion with kubeconfig.

---

### Репозиторий pkgs.k8s.io

С Kubernetes 1.24+ packages moved from `apt.kubernetes.io` to **pkgs.k8s.io** (community-owned).

**Структура (Debian/Ubuntu):**

```
/etc/apt/sources.list.d/kubernetes.list:

deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg]
  https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /
```

| Путь | Значение |
|------|----------|
| `core:/stable:/v1.32/deb/` | **minor 1.32** track |
| patch versions | `1.32.0-1.1`, `1.32.4-1.1`, … |

**Почему pin minor:** `apt upgrade` не должен прыгнуть на **1.33** без `kubeadm upgrade plan`.

---

### Version pinning и apt hold

```bash
apt-get install -y kubelet=1.32.* kubeadm=1.32.* kubectl=1.32.*
apt-mark hold kubelet kubeadm kubectl
```

| Без hold | С hold |
|----------|--------|
| `unattended-upgrades` может обновить kubelet | версия stable до manual unhold |
| skew между nodes | controlled upgrade window |

**Upgrade flow (preview):** unhold → install target patch → `kubeadm upgrade apply` → drain → upgrade kubelet - глава 15.5.16.

---

### Матрица совместимости (1.32.x lab)

| Компонент | Версия lab | Правило |
|-----------|------------|---------|
| **kube-apiserver** | 1.32.x | эталон (control plane) |
| **kubeadm** | 1.32.x | **=** control plane minor |
| **kubelet** (all nodes) | 1.32.x | **≤** apiserver minor; **не новее** apiserver |
| **kubectl** (client) | 1.32.x или 1.33.x | skew ±1 minor от apiserver OK |
| **containerd** | 1.7.x+ | см. [node validation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) |

#### Skew table (официальная политика)

| From | To | Supported skew |
|------|-----|----------------|
| kube-apiserver | kubelet | kubelet **до 2 minor** ниже apiserver |
| kube-apiserver | kubeadm | **same minor** |
| kubectl | kube-apiserver | **±1 minor** |

**Lab rule:** всё **1.32.x** - zero skew confusion.

**Contrast Talos 1.34.1:** homelab **новее** lab - kubectl 1.34 client к lab 1.32 API **OK** (client newer within 1 minor... actually 1.34 to 1.32 is 2 minor - might warn). Для lab используйте **kubectl 1.32** context или `--server` with matching client.

---

### kubelet до kubeadm init

После `apt install kubelet`:

```bash
systemctl status kubelet
# often: activating / crash - NORMAL before kubeadm init
```

**Почему:** нет `/var/lib/kubelet/config.yaml`, нет `/etc/kubernetes/kubelet.conf` - kubelet не может join API.

**kubeadm init** создаёт:

- `/etc/kubernetes/kubelet.conf` (bootstrap credentials)
- `/var/lib/kubelet/config.yaml` (from `kubelet-config` ConfigMap later)
- drop-in `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`

```
Before init:
  kubelet → no API config → exit loop

After init:
  kubelet → kubelet.conf + static manifests path
         → starts API server, etcd, ... as mirror pods
```

---

### kubeadm vs OS packages

| Package | Content |
|---------|---------|
| `kubeadm` | binary + bash completion |
| `kubelet` | binary + systemd unit |
| `kubectl` | binary |
| `kubernetes-cni` | CNI plugins binaries (`/opt/cni/bin`) - **не** Calico manifest |
| `cri-tools` | sometimes bundled / separate (crictl) |

**Calico** - отдельно в 15.5.9; **не** входит в apt kubernetes-cni meta alone.

---

### Production best practices

| Практика | Детали |
|----------|--------|
| Same version all nodes | automation (Ansible) |
| `apt-mark hold` | mandatory |
| Install kubeadm **first** on CP only for init | workers same packages before join |
| Document exact patch | `1.32.4` in runbook |
| Air-gapped | sync pkgs.k8s.io mirror + registry.k8s.io |
| Separate kubectl from prod | contexts (15.5.0) |

**Типичные ошибки:**

- mix 1.31 kubelet + 1.32 kubeadm init;
- forget `kubernetes-cni` → no loopback CNI binary;
- start `kubeadm init` before containerd;
- `kubectl` from snap (wrong version).

---

## Практика

### Цель

На **k8s-cp-01** (и workers **до join**) установить пакеты **1.32.x** скриптом [`02-install-k8s-packages.sh`](./install-kubeadm/scripts/02-install-k8s-packages.sh).

### Зачем

Без aligned versions `kubeadm init` preflight fails with version skew errors.

### Предусловия

- 15.5.2 prep ✓
- 15.5.3 containerd running ✓

### Шаг 1 - run install script

```bash
cd /tmp/install-kubeadm/scripts
chmod +x 02-install-k8s-packages.sh
sudo ./02-install-k8s-packages.sh
```

**Ожидаемые шаги скрипта:**

| # | Action |
|---|--------|
| 1 | install prerequisites: `apt-transport-https`, `ca-certificates`, `curl`, `gpg` |
| 2 | add pkgs.k8s.io GPG key → `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` |
| 3 | add `kubernetes.list` for **v1.32** |
| 4 | `apt-get update` |
| 5 | `apt-get install -y kubelet kubeadm kubectl` (pin 1.32.*) |
| 6 | `apt-mark hold kubelet kubeadm kubectl` |
| 7 | `systemctl enable kubelet` |

### Шаг 2 - verify versions

```bash
kubeadm version -o short
kubelet --version
kubectl version --client -o short
apt-mark showhold | grep -E 'kube'
```

**Ожидаемый результат:**

```
v1.32.x
Kubernetes v1.32.x
v1.32.x
kubelet hold
kubeadm hold
kubectl hold
```

### Шаг 3 - kubelet status (pre-init)

```bash
systemctl status kubelet --no-pager | head -15
journalctl -u kubelet -n 20 --no-pager
```

**Ожидаемый результат:** kubelet may **fail** - нет config until init - **это нормально**.

### Шаг 4 - CNI binaries

```bash
ls /opt/cni/bin/ | head -10
# loopback, bridge, host-local, ...
```

### Шаг 5 - dry-run preflight (optional, on CP only)

```bash
sudo kubeadm init phase preflight 2>&1 | tail -20
# Some checks fail without init flags - OK
```

### Шаг 6 - repeat on workers

```bash
# k8s-w-01, k8s-w-02 - same script BEFORE join
sudo ./02-install-k8s-packages.sh
```

**Workers:** не запускайте `kubeadm init` - только packages + kubelet enable.

### Verify

| Node | kubeadm | kubelet | hold | containerd |
|------|---------|---------|------|------------|
| k8s-cp-01 | 1.32.x | 1.32.x | yes | active |
| k8s-w-01 | 1.32.x | 1.32.x | yes | active |

### Rollback

```bash
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get remove -y kubelet kubeadm kubectl kubernetes-cni
sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/systemd/system/kubelet.service.d
sudo systemctl daemon-reload
# containerd stays - rollback 15.5.3 if full reset needed
```

---

## Что произошло внутри Kubernetes

```
02-install-k8s-packages.sh
         │
         ▼
apt installs binaries to /usr/bin/
         │
         ├── kubeadm → /usr/bin/kubeadm (CLI only)
         ├── kubelet → systemd unit enabled
         └── kubectl → client (optional on node)

systemd start kubelet (enabled)
         │
         ▼
kubelet reads /var/lib/kubelet/config.yaml - NOT FOUND (yet)
         │
         ▼
crash loop / waiting - expected

(Next: kubeadm init creates /etc/kubernetes/* )
         │
         ▼
kubelet gets kubelet.conf + manifests
         │
         ▼
control plane static pods start
```

---

## Troubleshooting

| Симптом | Причина | Решение |
|---------|---------|---------|
| `Package kubelet has no installation candidate` | wrong repo minor | fix kubernetes.list v1.32 |
| Version skew preflight | mixed versions | reinstall same 1.32.x |
| kubelet restart loop pre-init | expected | proceed to kubeadm init |
| `hold` ignored | unhold ran | `apt-mark hold` again |
| GPG error apt update | keyring path | re-add signed-by keyring |
| kubectl talks wrong cluster | KUBECONFIG | separate context |
| CNI binary missing | kubernetes-cni not installed | apt install kubernetes-cni |
