# Подключение Worker Node

**Среда:** Ubuntu 24.04 LTS · **K8s 1.32.x** · kubeadm · `cp-1` + `worker-1`

---

## Цель

Понять полный цикл **kubeadm join**: bootstrap token, discovery, TLS bootstrap, CSR, регистрация Node; разобрать команду join **по полям**; на практике подключить `worker-1` скриптом `04-kubeadm-join.sh` и довести ноду до статуса **Ready**.

---

## Теория

### Зачем отдельный процесс join

Control Plane после `kubeadm init` готов принимать workload, но **одна нода** - не production topology. Worker расширяет data plane: kubelet + kube-proxy + container runtime.

Проблема безопасности: как новая машина получает **доверенный** client certificate для kubelet **без** ручной раздачи `admin.conf`?

Ответ Kubernetes: **TLS Bootstrap** + ограниченный **bootstrap token**.

```
worker-1 (чистая ОС)
    │
    │  kubeadm join <API>:6443 --token ... --discovery-token-ca-cert-hash ...
    ▼
preflight checks (swap, ports, containerd, …)
    │
    ▼
kubelet стартует с bootstrap kubeconfig
    │
    ▼
CSR: system:node:worker-1 → API Server
    │
    ▼
controller-manager auto-approves (если bootstrap ok)
    │
    ▼
kubelet получает node cert → записывает kubelet.conf
    │
    ▼
Node object в API; kube-proxy DaemonSet; готов к Pod'ам (после CNI)
```

### Bootstrap Token

При `kubeadm init` создаётся Secret в `kube-system`:

```bash
kubeadm token list
# или
kubectl get secrets -n kube-system | grep bootstrap-token
```

| Свойство | Значение |
|----------|----------|
| Формат | `<6 chars>.<16 chars>` например `abcdef.0123456789abcdef` |
| TTL | По умолчанию 24 часа (`--ttl`) |
| Права | Только bootstrap: создать CSR для kubelet |
| Где хранится | Secret `bootstrap-token-<id>` в kube-system |

**Создание нового token** (если истёк):

```bash
kubeadm token create --print-join-command
```

### Cluster Discovery

Worker должен **доверять** тому API Server, к которому подключается (защита от MITM).

Два механизма (часто оба в join command):

| Параметр | Назначение |
|----------|------------|
| `--discovery-token-ca-cert-hash sha256:<hash>` | Hash CA из `ca.crt` - worker сверяет при TLS |
| `--certificate-key` (при upload-certs) | Расшифровка сертификатов CP при multi-control-plane |
| `--tls-bootstrap` | Включён по умолчанию в kubeadm join |

```
worker                           cp-1 API
  │                                 │
  │──── TLS connect ───────────────►│
  │◄─── server cert ────────────────│
  │     verify hash(ca) == discovery-token-ca-cert-hash
  │                                 │
  │──── CSR (bootstrap auth) ──────►│
```

### TLS Bootstrap и CSR

1. Kubelet генерирует private key локально.
2. Создаёт CertificateSigningRequest с:
   - `spec.signerName: kubernetes.io/kube-apiserver-client-kubelet`
   - `spec.usages: client auth`
   - `spec.username` (в CSR) → `system:node:worker-1`
3. Аутентификация CSR - bootstrap token (user `system:bootstrap:<token-id>`).
4. **Node CSR approving controller** в controller-manager проверяет:
   - kubelet identity соответствует Node object / hostname;
   - bootstrap credentials валидны.
5. Подписанный cert возвращается kubelet → сохраняется в `/var/lib/kubelet/pki/`.

```
┌──────────────┐    CSR     ┌─────────────┐   approve   ┌──────────────────┐
│ kubelet      │ ─────────► │ API Server  │ ──────────► │ controller-mgr   │
│ worker-1     │            │  CSR object │             │ node-csr-approver│
└──────────────┘            └─────────────┘             └──────────────────┘
       ▲                                                        │
       └──────────── signed cert ◄──────────────────────────────┘
```

### Node Registration

После получения cert kubelet:

- Создаёт/обновляет **Node** object (`metadata.name = hostname`).
- Репортит capacity, allocatable, conditions.
- Устанавливает **taints** (worker без taint `NoSchedule` на CP - только `control-plane` taint на masters).
- Запускает **static pods** нет (на worker); ждёт DaemonSet'ы (kube-proxy, CNI).

**Conditions:**

| Condition | Ready=true когда |
|-----------|------------------|
| `Ready` | CNI настроен, runtime OK, нет pressure |
| `NetworkUnavailable` | CNI ещё не ready (исчезает после CNI) |

> **Важно:** сразу после join Node часто **NotReady** - нет CNI ([15.5.9](15.5.9%20Kubernetes%20-%20CNI.md)).

### kubeadm join - разбор команды

Типичный вывод `kubeadm token create --print-join-command`:

```bash
kubeadm join 192.168.1.50:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:7a5b8c9d...
```

| Часть | Значение |
|-------|----------|
| `192.168.1.50:6443` | `control-plane-endpoint` - API Server (IP или LB VIP) |
| `--token` | Bootstrap token из Secret |
| `--discovery-token-ca-cert-hash` | `sha256` от DER `ca.crt` (первые 256 бит) |

**Дополнительные флаги:**

```bash
# Worker (наш lab)
kubeadm join ... 

# Второй Control Plane (HA, не в базовом lab)
kubeadm join ... --control-plane --certificate-key <key>

# Указать имя ноды явно (если hostname не подходит)
kubeadm join ... --node-name worker-1

# CRI socket (если нестандартный)
kubeadm join ... --cri-socket unix:///run/containerd/containerd.sock
```

**Что kubeadm делает на worker:**

1. Preflight.
2. Скачивает `kubelet` config, `kubeadm-flags.env`.
3. Записывает bootstrap `kubelet.conf`.
4. `systemctl enable --now kubelet`.
5. Kubelet выполняет TLS bootstrap → join завершён с точки зрения kubeadm.
6. Устанавливает **kube-proxy** и **CoreDNS** addon'ы если ещё не стоят (на CP при init).

### Что появляется на worker-1

```
/etc/kubernetes/
├── kubelet.conf          ← после bootstrap: node client cert
├── kubeadm-config        ← ConfigMap snapshot (optional)
└── pki/
    └── ca.crt            ← cluster CA (для доверия)

/var/lib/kubelet/
├── config.yaml
├── kubeadm-flags.env
└── pki/
    ├── kubelet-client-current.pem
    └── kubelet.crt

/etc/systemd/system/kubelet.service.d/
└── 10-kubeadm.conf
```

---

## Практика

**Цель:** подключить `worker-1` к кластеру на `cp-1`.

**Предусловия:**

-  worker подготовлен (swap off, containerd, kubeadm packages).
- CP инициализирован.

### Шаг 1. Получить join command на cp-1

```bash
# На cp-1
export KUBECONFIG=/etc/kubernetes/admin.conf

kubeadm token create --print-join-command --ttl 2h
```

Сохраните вывод - он понадобится на worker.

### Шаг 2. Скрипт join (lab)

На `worker-1` используйте [./install-kubeadm/scripts/04-kubeadm-join.sh](./install-kubeadm/scripts/04-kubeadm-join.sh):

```bash
#!/usr/bin/env bash
# ./install-kubeadm/scripts/04-kubeadm-join.sh
set -euo pipefail

JOIN_CMD="${1:-}"
if [[ -z "$JOIN_CMD" ]]; then
  echo "Usage: $0 '<kubeadm join ...>'"
  echo "Get command on cp-1: kubeadm token create --print-join-command"
  exit 1
fi

echo "[*] Preflight: containerd + kubelet"
systemctl is-active containerd
systemctl enable kubelet

echo "[*] Running: $JOIN_CMD"
eval "sudo $JOIN_CMD"

echo "[*] Join finished. Check node from cp-1:"
echo "    kubectl get nodes"
```

Запуск:

```bash
# На worker-1 - вставьте реальную команду с cp-1
chmod +x 04-kubeadm-join.sh
./04-kubeadm-join.sh 'kubeadm join 192.168.1.50:6443 --token ... --discovery-token-ca-cert-hash sha256:...'
```

### Шаг 3. Наблюдение CSR (на cp-1)

```bash
# Во время join
kubectl get csr -w
```

Ожидаемо: CSR `Pending` → `Approved,Issued` за секунды.

```bash
kubectl describe csr | grep -A5 "Name:\|Approved"
```

### Шаг 4. Проверка Node

```bash
kubectl get nodes -o wide
kubectl describe node worker-1
```

Сразу после join:

```
NAME       STATUS     ROLES    AGE   VERSION
cp-1       Ready      control-plane   ...
worker-1   NotReady   <none>   1m    v1.32.x
```

Причина NotReady: `KubeletNotReady` / `container runtime network not ready` - **нет CNI** 

```bash
kubectl get node worker-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq .
```

### Шаг 5. kubelet на worker

```bash
# На worker-1
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager

# CSR файлы
sudo ls -la /var/lib/kubelet/pki/
```

### Шаг 6. kube-proxy

```bash
kubectl get pods -n kube-system -o wide | grep kube-proxy
```

На worker должен появиться Pod `kube-proxy-xxxxx` (может Pending до CNI).

### Откат (удаление worker из кластера)

```bash
# На cp-1
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-1

# На worker-1
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd
sudo systemctl restart containerd
```

---

### Что произошло внутри Kubernetes

```
kubeadm join (worker-1)
    │
    ├─► preflight OK
    ├─► запись /etc/kubernetes/kubelet.conf (bootstrap token user)
    ├─► systemctl start kubelet
    │
    ▼
kubelet → API: "я worker-1, вот мой CSR"
    │
    ├─► Authentication: bootstrap token
    ├─► CSR created in API
    │
    ▼
kube-controller-manager (csrapproving controller)
    │
    ├─► validates Node identity
    ├─► signs cert with cluster CA
    │
    ▼
kubelet saves cert → обновляет credentials
    │
    ├─► creates Node API object
    ├─► lease: kube-node-lease/worker-1
    ├─► status: NotReady (no CNI)
    │
    ▼
DaemonSet kube-proxy: pod scheduled to worker-1
addon CoreDNS: может reschedule на worker
```

---

## Troubleshooting

| Симптом | Причина | Диагностика | Исправление |
|---------|---------|-------------|-------------|
| `token expired` | TTL bootstrap token | `kubeadm token list` | `kubeadm token create --print-join-command` |
| `unable to fetch discovery token` | Неверный token / нет доступа к API | curl API с worker | Новый token; firewall 6443 |
| `x509: certificate signed by unknown authority` | Неверный `discovery-token-ca-cert-hash` | Пересчитать hash от `ca.crt` | Взять hash из `kubeadm init` output |
| CSR `Pending` forever | controller-manager down; CSR approver disabled | `kubectl get csr`; logs CM | Починить CP; проверить CM static pod |
| `Node worker-1 already exists` | Повторный join без reset | `kubectl get node` | `kubeadm reset` на worker; delete Node |
| Join OK, NotReady | Нет CNI | `kubectl describe node` | [15.5.9 CNI](15.5.9%20Kubernetes%20-%20CNI.md) |
| `ERROR FileAvailable--etc-kubernetes-kubelet.conf` | Остатки прошлого join | `ls /etc/kubernetes` | `kubeadm reset` |

**Пересчёт discovery hash:**

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

---
