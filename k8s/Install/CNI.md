# CNI

**Среда:** Ubuntu 24.04 LTS · **K8s 1.32.x** · kubeadm · **Calico** CNI

---

## Цель

Понять, почему Pod'ы без CNI застревают в **ContainerCreating**; разобрать модель **CNI** (Container Network Interface); сравнить **Calico, Cilium, Flannel, Weave**; установить Calico скриптом `05-install-calico.sh` и довести ноды и тестовый Pod до рабочей сети.

---

## Теория

### Почему Kubernetes «не приносит сеть» из коробки

Kubernetes задаёт **модель** сети (каждый Pod - уникальный IP, flat network, NAT для egress), но **не реализует** её. За data plane отвечает плагин **CNI**.

```
kubectl run nginx
    │
    ▼
API Server → kubelet: создай Pod
    │
    ▼
kubelet → containerd: создай sandbox (pause)
    │
    ▼
kubelet → CNI plugin: "ADD pod network"
    │
    ├─► успех → Pod IP, маршруты, policy
    └─► нет плагина → зависание ContainerCreating
```

**Без CNI:**

- Sandbox container создан, но **нет IP**.
- `kubectl get pods` → `ContainerCreating` бесконечно.
- `kubectl describe pod` → `FailedCreatePodSandBox` / `network plugin not ready`.
- Node `Ready=False`, condition `NetworkUnavailable`.

```
Node worker-1
┌─────────────────────────────────────┐
│ kubelet: "нужен CNI для sandbox"    │
│         ↓                           │
│    /opt/cni/bin/ - пусто или нет    │
│    /etc/cni/net.d/ - нет conf       │
│         ↓                           │
│    ❌ Pod не Ready                  │
└─────────────────────────────────────┘
```

### CNI specification (кратко)

CNI - спецификация и набор бинарников. Kubelet вызывает:

```
/opt/cni/bin/<plugin> ADD <container-id> <netns> <config>
```

| Этап | Действие |
|------|----------|
| **ADD** | Назначить IP, настроить veth, маршруты |
| **DEL** | Убрать интерфейс при удалении Pod |
| **CHECK** | Проверить состояние (опционально) |

Конфиг: `/etc/cni/net.d/10-*.conf` или `.conflist` - chain из плагинов (например `loopback` + `calico`).

```
Pod network namespace
┌──────────────────┐
│ eth0 10.244.1.5  │◄── veth pair ──► host (caliXXXX)
└──────────────────┘
         │
         ▼
   CNI plugin (Calico)
         │
         ▼
   BGP / vxlan / routing на Node
```

### Pod Network CIDR

При `kubeadm init`:

```bash
kubeadm init --pod-network-cidr=192.168.0.0/16
```

CNI должен использовать **совместимый** диапазон. Calico по умолчанию часто `192.168.0.0/16` - совпадает с нашим lab.
Service CIDR отдельно: `--service-cidr=10.96.0.0/12` - не путать с Pod CIDR.

### Сравнение CNI (lab + production)

| Критерий | **Calico** | **Cilium** | **Flannel** | **Weave** |
|----------|------------|------------|-------------|-----------|
| **Data plane** | iptables/nft + eBPF (опция) | eBPF | vxlan/host-gw | userspace/kernel |
| **NetworkPolicy** | Да (Calico policy) | Да (eBPF) | Нет (базовый) | Да |
| **Производительность** | Высокая | Очень высокая | Средняя | Средняя |
| **Сложность** | Средняя | Выше | Низкая | Средняя |
| **BGP** | Нативно | Да | Нет | Нет |
| **Observability** | Hubble нет | Hubble встроен | Минимум | weave scope |
| **kubeadm совместимость** | Отличная | Отличная | Отличная | Хорошая |
| **Наш lab** | **Выбор курса** | Talos homelab | - | - |

**Почему Calico на курсе:** industry standard, NetworkPolicy, хорошая документация для CKA, предсказуемо на Ubuntu 24.04 + kubeadm 1.32.

**Когда Cilium:** eBPF, замена kube-proxy, advanced policy.
**Когда Flannel:** быстрый старт homelab, policy не нужна.

### Calico architecture (упрощённо)

```
┌─────────────────────────────────────────────────────────┐
│ kube-system                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐ │
│  │ calico-node │  │ calico-node  │  │ calico-kube-    │ │
│  │ DaemonSet   │  │ (worker-1)   │  │ controllers     │ │
│  └──────┬──────┘  └──────┬───────┘  └────────┬────────┘ │
└─────────┼────────────────┼───────────────────┼───────────┘
          │                │                   │
          ▼                ▼                   ▼
    install CNI      routing/BPF         IPAM / IP pools
    on each node     on each node        CRD / config
```

- **calico-node** - DaemonSet: Felix (policy), BIRD (BGP опционально), CNI binary install.
- **calico-kube-controllers** - синхронизация policy и endpoints.

### Жизненный цикл сети Pod

```
1. Scheduler назначает Pod на worker-1
2. kubelet создаёт pause sandbox
3. kubelet вызывает CNI ADD
4. Calico: IPAM выдаёт IP из 192.168.0.0/16
5. Создаётся veth, маршрут на host
6. kubelet запускает рабочие контейнеры в netns
7. Pod status → Running
8. Node condition NetworkUnavailable → False
9. Node Ready → True
```

---

## Практика

**Цель:** установить Calico, перевести ноды в Ready, проверить сеть между Pod'ами.

**Предусловия:** CP + worker joined; `kubeadm init` с `--pod-network-cidr=192.168.0.0/16`.

### Шаг 1. Симптом «до CNI»

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl run test-before-cni --image=nginx:1.27 --restart=Never
kubectl get pods test-before-cni -w
kubectl describe pod test-before-cni | tail -20
```

Если CNI ещё не ставили - `ContainerCreating`, events про sandbox/network.

### Шаг 2. Установка Calico - скрипт lab

[./install-kubeadm/scripts/05-install-calico.sh](./install-kubeadm/scripts/05-install-calico.sh):

```bash
#!/usr/bin/env bash
# ./install-kubeadm/scripts/05-install-calico.sh
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

echo "[*] Applying Calico ${CALICO_VERSION}"
kubectl apply -f "$MANIFEST_URL"

echo "[*] Waiting for calico-node DaemonSet"
kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s

echo "[*] Waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
kubectl get nodes
```

Запуск на `cp-1`:

```bash
chmod +x ./install-kubeadm/scripts/05-install-calico.sh
./install-kubeadm/scripts/05-install-calico.sh
```

> Версию Calico сверяйте с [документацией Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart) для K8s 1.32.

### Шаг 3. Проверка CNI на ноде

```bash
# На worker-1
ls -la /etc/cni/net.d/
ls -la /opt/cni/bin/ | head

ip link show | grep -E 'cali|vxlan|tunl'
```

### Шаг 4. Тестовый Pod с IP

```bash
kubectl delete pod test-before-cni --ignore-not-found
kubectl run test-after-cni --image=nginx:1.27 --restart=Never
kubectl get pod test-after-cni -o wide

# IP должен быть из 192.168.0.0/16
kubectl get pod test-after-cni -o jsonpath='{.status.podIP}{"\n"}'
```

### Шаг 5. Связность pod-to-pod

```bash
# Второй Pod на другой ноде (если 2 workers) или на том же
kubectl run test-curl --image=curlimages/curl:8.11.1 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-curl --timeout=120s

POD_IP=$(kubectl get pod test-after-cni -o jsonpath='{.status.podIP}')
kubectl exec test-curl -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${POD_IP}"
```

Ожидаемо: `200`.

### Шаг 6. Проверка NetworkPolicy CRD (Calico)

```bash
kubectl get crd | grep calico
kubectl api-resources | grep -i networkpolicy
```

### Откат

```bash
kubectl delete -f "https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml"
# На каждой ноде может потребоваться перезапуск kubelet
sudo systemctl restart kubelet
```

---

### Что произошло внутри Kubernetes

```
kubectl apply calico.yaml
    │
    ├─► ServiceAccount, RBAC, ConfigMap calico-config
    ├─► DaemonSet calico-node → pod на cp-1 и worker-1
    ├─► Deployment calico-kube-controllers
    │
    ▼
calico-node стартует на worker-1
    │
    ├─► копирует бинарники в /opt/cni/bin
    ├─► пишет /etc/cni/net.d/10-calico.conflist
    ├─► Felix: policy + routes
    │
    ▼
kubelet: CNI plugin ready
    │
    ├─► Node condition NetworkUnavailable cleared
    ├─► Node Ready=True
    │
    ▼
pending Pod'ы: повтор sandbox create
    │
    ├─► CNI ADD → IP 192.168.x.x
    └─► Pod → Running
```

---

## Troubleshooting

| Симптом | Причина | Диагностика | Исправление |
|---------|---------|-------------|-------------|
| Pod `ContainerCreating` | Нет CNI / CNI crash | `journalctl -u kubelet`, `kubectl -n kube-system get pods` | Установить/переустановить Calico |
| `pod cidr not configured` | Неверный pod-network-cidr при init | `kubectl cluster-info dump \| grep cluster-cidr` | Re-init с правильным CIDR (или patch) |
| Calico `CrashLoopBackOff` | Несовместимость версий; нет IP forward | `kubectl logs -n kube-system -l k8s-app=calico-node` | `sysctl net.ipv4.ip_forward=1`; версия manifest |
| Node NotReady | CNI не на ноде | `kubectl describe node` | `kubectl get pods -n kube-system -o wide` calico-node |
| IP pool exhausted | Малый CIDR | Calico IPAM status | Расширить pool / перепланировать CIDR |
| MTU issues | vxlan overlay | ping с большим payload | Настроить `veth_mtu` / `ipip` в Calico |

**Диагностика kubelet CNI:**

```bash
sudo journalctl -u kubelet | grep -i cni
ls /etc/cni/net.d/
cat /etc/cni/net.d/*.conflist | head -50
```
