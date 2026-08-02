# install-kubeadm - lab для модуля 15.5

Практический стенд на **вашей домашней сети** `192.168.1.0/24` - рядом с Talos homelab, **без конфликта IP**.


### kubeadm lab - ваши новые VM

| VM | Hostname | IP | Роль |
|----|----------|-----|------|
| 1 | `k8s-cp-01` | **192.168.1.20** | Control Plane |
| 2 | `k8s-w-01` | **192.168.1.21** | Worker |
| 3 | `k8s-w-02` | **192.168.1.22** | Worker (опционально) |

**Внутренние сети K8s (не конфликтуют с LAN):**
- Pod CIDR: `10.244.0.0/16` (Calico)
- Service CIDR: `10.96.0.0/12` (default kubeadm)

**Конфиг:** все IP в [`config.env`](config.env)

```
kubeadm lab API:  https://192.168.1.20:6443
Talos homelab:    https://192.168.1.9:6443   ← отдельный kubeconfig!
```

## Подготовка VM (netplan пример)

На **каждой** Ubuntu 24.04 VM задайте статический IP. Пример `/etc/netplan/01-k8s.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens18:   # имя интерфейса - проверьте: ip a
      addresses:
        - 192.168.1.20/24   # .21 на worker-1, .22 на worker-2
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
ip a show ens18
ping -c 2 192.168.1.9    # Talos CP доступен
ping -c 2 192.168.1.21   # между VM после настройки
```

## VirtualBox - автоматическое создание 3 VM

Скрипты в [`vbox/`](vbox/):

```bash
# На хосте (Manjaro): virtualbox xorriso
cd "15. K8s/15.5 Install/./install-kubeadm/vbox"

# Узнать имя сетевого интерфейса для bridge
ip -4 route show default
# Пример: enp3s0, wlan0 - НЕ используйте wlan если не уверены

# Создать 3 VM + скачать Ubuntu 24.04 ISO (~2.6 GB)
BRIDGE_IFACE=enp3s0 ./create-vbox-vms.sh --start

# Запустить все (после установки CP):
START_MODE=all ./start-vbox-vms.sh
./stop-vbox-vms.sh       # остановить
./fix-vbox-resources.sh  # RCU stall: уменьшить CPU/RAM
./ssh-to-vms.sh cp       # SSH на CP (.20)
./ssh-to-vms.sh all      # проверить все VM

# Удалить VM и диски
./create-vbox-vms.sh --destroy
```

| Скрипт | Что делает |
|--------|------------|
| `create-vbox-vms.sh` | 3 VM: CP 4CPU/8GB, workers 2CPU/4GB, bridged LAN, autoinstall |
| `start/stop-vbox-vms.sh` | Запуск/остановка |
| `ssh-to-vms.sh` | Быстрый SSH |

**После autoinstall (~15 мин):**
- Пользователь: `k8s` / пароль: `k8s` (только lab!)
- Статические IP уже в netplan: `.20`, `.21`, `.22`
- Дальше - скрипты `scripts/00-prep-node.sh` и т.д.

**Bridged networking** - VM получают IP в вашей `192.168.1.0/24` напрямую (как физические машины).

### RCU stall / зависание на login

Сообщения `rcu_preempt detected stalls` - **хост не успевает** отдавать CPU всем VM. Часто если запустили **3 autoinstall сразу**.

```bash
./stop-vbox-vms.sh
./fix-vbox-resources.sh          # 2 CPU / 4 GB на CP
VBoxManage startvm k8s-cp-01 --type headless   # только одна VM
# подождать 15 мин → ssh k8s@192.168.1.20
# потом по очереди k8s-w-01, k8s-w-02
```

Установку делайте **по одной VM**, не `--start` на всех сразу.

Если ISO уже скачан:
```bash
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-live-server-amd64.iso BRIDGE_IFACE=enp3s0 ./create-vbox-vms.sh --start
```

## Порядок установки (важно!)

```
CP:     00-prep → reboot → 01 → 02 → 03-init → 05-calico → addons
Worker: 00-prep → reboot → 01 → 02 → 04-join (после Calico на CP)
```

### Swap после reboot - главная причина «kubelet not healthy»

Ubuntu 24.04 поднимает `/swap.img` после перезагрузки. Скрипт `00-prep-node.sh`:
- комментирует swap в `/etc/fstab`
- маскирует `swap.target`
- ставит `k8s-disable-swap.service` (swapoff при каждой загрузке)

**После `00-prep-node.sh` обязателен `sudo reboot`**, затем проверка:

```bash
swapon --show    # пусто
free -h          # Swap used: 0
```

Перед init/join скрипты `01`–`04` проверяют swap автоматически.

## Быстрый старт

**Путь к lab на вашем ПК** (копируйте целиком - в пути есть пробелы):


```bash
# 1. Скопировать lab на CP (логин k8s, не user!)
LAB="$HOME/install-kubeadm"

scp -r "$LAB" k8s@192.168.1.20:/tmp/install-kubeadm

# То же на workers (когда они готовы):
scp -r "$LAB" k8s@192.168.1.21:/tmp/install-kubeadm
scp -r "$LAB" k8s@192.168.1.22:/tmp/install-kubeadm
```

Или из каталога курса:

```bash
scp -r ./install-kubeadm/ k8s@192.168.1.20:/tmp/install-kubeadm
```

```bash
# 2. На VM k8s-cp-01 (ssh k8s@192.168.1.20)
cd /tmp/install-kubeadm/scripts
chmod +x *.sh
sudo ./00-prep-node.sh k8s-cp-01    # k8s-w-01 / k8s-w-02 на workers
sudo reboot

# 3. containerd (все ноды)
sudo ./01-install-containerd.sh

# 4. Пакеты K8s (все ноды)
sudo ./02-install-k8s-packages.sh 1.32.4

# 5. Только CP (192.168.1.20):
sudo ./03-kubeadm-init.sh

# 6. CNI
./05-install-calico.sh

# 7. Workers (192.168.1.21, .22):
sudo ./04-kubeadm-join.sh 'kubeadm join 192.168.1.20:6443 --token ... --discovery-token-ca-cert-hash sha256:...'

# 8. Addons
./06-install-dashboard.sh
./07-install-metrics-server.sh

# 9. Тест
kubectl apply -f ./manifests/00-test-app.yaml
kubectl apply -f ./manifests/07-web-service.yaml
```

## Отдельный kubeconfig (важно!)

Talos и kubeadm lab - **разные кластеры**. Не перезаписывайте `~/.kube/config`:

```bash
# Talos (как сейчас)
export KUBECONFIG=~/.kube/config

# kubeadm lab
export KUBECONFIG=~/.kube/kubeadm-lab-config
# после init: cp /etc/kubernetes/admin.conf ~/.kube/kubeadm-lab-config
```

## Скрипты

| Скрипт | Глава | Описание |
|--------|-------|----------|
| `00-prep-node.sh` | 15.5.2 | swap, sysctl, modules, /etc/hosts |
| `01-install-containerd.sh` | 15.5.3 | containerd + SystemdCgroup |
| `02-install-k8s-packages.sh` | 15.5.4 | kubeadm, kubelet, kubectl |
| `03-kubeadm-init.sh` | 15.5.5 | Control Plane на **192.168.1.20** |
| `04-kubeadm-join.sh` | 15.5.8 | Worker join |
| `05-install-calico.sh` | 15.5.9 | Calico CNI |
| `06-install-dashboard.sh` | 15.5.13 | Dashboard |
| `07-install-metrics-server.sh` | 15.5.14 | Metrics Server |
| `cleanup.sh` | 15.5.18 | kubeadm reset |
| `fix-kubelet.sh` | 15.5.5 | kubelet not healthy / cgroup fix |

## Dashboard через NodePort (без port-forward)

```bash
# На CP после 06-install-dashboard.sh
kubectl apply -f ../manifests/04-dashboard-nodeport.yaml
kubectl get svc kubernetes-dashboard -n kubernetes-dashboard
```

Браузер:

```
https://192.168.1.20:30443
# или https://192.168.1.21:30443 / .22 - любая node
```

- **https** обязательно (Dashboard на TLS)
- Сертификат self-signed → Advanced → Proceed
- Login: **Token** → `kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h`

Откат к ClusterIP:

```bash
kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard \
  -p '{"spec":{"type":"ClusterIP","ports":[{"port":443,"targetPort":8443}]}}'
```

### kubelet is not healthy (init failed)

На **k8s-cp-01** после ошибки `http://127.0.0.1:10248/healthz`:

```bash
cd /tmp/install-kubeadm/scripts
sudo ./fix-kubelet.sh --reset    # сброс + исправление cgroup/containerd
sudo ./03-kubeadm-init.sh        # повтор init
```

Вручную проверить:
```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 40 --no-pager
grep SystemdCgroup /etc/containerd/config.toml   # должно true
free -h   # swap 0
```

## Сброс

```bash
sudo ./cleanup.sh   # на каждой VM lab (.20, .21, .22)
```
