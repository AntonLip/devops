# Control Plane и Static Pods

**Среда:** Ubuntu 24.04 LTS · **K8s 1.32.x** · kubeadm · containerd · VM `cp-1` (Control Plane)

---

## Цель

Понять, почему компоненты Control Plane в kubeadm-кластере запускаются как **static Pods**; изучить содержимое `/etc/kubernetes/manifests/` и `/etc/kubernetes/pki/` **файл за файлом**; научиться связывать манифесты на диске с Pod'ами в `kube-system` и диагностировать проблемы запуска API Server, etcd, Scheduler и Controller Manager.

---

## Теория

### Control Plane: четыре столпа кластера

Control Plane - «мозг» Kubernetes. В kubeadm на single-node CP все четыре ключевых компонента работают на одной VM (`cp-1`):

| Компонент | Роль | Порт (типично) |
|-----------|------|----------------|
| **kube-apiserver** | Единая точка входа REST API; auth, authz, admission; запись в etcd | 6443 |
| **kube-scheduler** | Выбирает Node для Pod без `spec.nodeName` | - |
| **kube-controller-manager** | Запускает controllers (ReplicaSet, Node, SA token, …) | - |
| **etcd** | Source of truth - все объекты K8s | 2379 (client), 2380 (peer) |

```
                    kubectl / kubelet / controllers
                              │
                              ▼
                    ┌─────────────────┐
                    │ kube-apiserver  │◄──── watch/list/get
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        kube-scheduler   kube-ctrl-mgr      etcd
              │              │              │
              └──────────────┴──────────────┘
                    все ходят в API Server
                    (etcd - только с API Server)
```

**Почему не systemd-сервисы?** Исторически и архитектурно: kubelet уже умеет запускать Pod'ы через CRI. Static Pod - минимальная абстракция: «файл в `/etc/kubernetes/manifests/` → kubelet создаёт Pod без участия API Server на старте». Это решает проблему «курицы и яйца»: API Server нужен для обычных Pod'ов, но сам API Server тоже Pod - его поднимает kubelet напрямую.

### Static Pods: жизненный цикл

```
kubeadm init
    │
    ▼
запись YAML в /etc/kubernetes/manifests/
    │
    ▼
kubelet (file watcher) видит новый/изменённый файл
    │
    ▼
kubelet → containerd → sandbox + контейнер
    │
    ▼
Pod mirror в API Server (имя: <pod-name>-<node-name>)
    │
    ▼
kubectl get pods -n kube-system  ← видим static Pods
```

**Ключевые свойства static Pods:**

- Управляются **только kubelet** на конкретной ноде, не Deployment/ReplicaSet.
- Изменение файла в `manifests/` → kubelet пересоздаёт Pod.
- Удаление файла → kubelet останавливает Pod.
- В API Server отображаются с суффиксом ноды: `kube-apiserver-cp-1`, `etcd-cp-1`.
- Нельзя `kubectl delete` static Pod навсегда - kubelet пересоздаст его из файла.

### /etc/kubernetes/manifests/ - четыре манифеста

После `kubeadm init` на `cp-1` появляются четыре файла:

| Файл | Образ (1.32.x) | Назначение |
|------|----------------|------------|
| `kube-apiserver.yaml` | `registry.k8s.io/kube-apiserver:v1.32.x` | REST API, TLS, admission |
| `kube-controller-manager.yaml` | `registry.k8s.io/kube-controller-manager:v1.32.x` | Controllers |
| `kube-scheduler.yaml` | `registry.k8s.io/kube-scheduler:v1.32.x` | Scheduling |
| `etcd.yaml` | `registry.k8s.io/etcd:3.5.x` | Хранилище состояния |

**kube-apiserver.yaml** - самый «тяжёлый» манифест:

- `--etcd-servers=https://127.0.0.1:2379` - локальный etcd (stacked topology).
- `--tls-cert-file`, `--tls-private-key-file` - серверный сертификат API.
- `--client-ca-file` - CA для проверки клиентских сертификатов.
- `--service-cluster-ip-range=10.96.0.0/12` - диапазон ClusterIP (задаётся при init).
- `--advertise-address` - IP, который ноды используют для доступа к API.
- `--authorization-mode=Node,RBAC` - Node authorizer для kubelet + RBAC.
- `--enable-admission-plugins=NodeRestriction,...` - ограничения для kubelet.

**etcd.yaml**:

- `--data-dir=/var/lib/etcd` - персистентные данные (критично для backup!).
- `--cert-file`, `--key-file` - TLS для client API.
- `--peer-cert-file`, `--peer-key-file` - TLS между членами etcd (на single-node peer = self).
- `--initial-cluster-state=new` при первом init.

**kube-scheduler.yaml** и **kube-controller-manager.yaml**:

- `--kubeconfig=/etc/kubernetes/scheduler.conf` (или `controller-manager.conf`).
- `--leader-elect=true` - при HA только один активный экземпляр.
- `--bind-address=127.0.0.1` - metrics/health только localhost (security best practice).

### /etc/kubernetes/pki/ - сертификаты файл за файлом

kubeadm генерирует PKI при init. Понимание каждого файла - must-have для CKA и production troubleshooting.

```
/etc/kubernetes/pki/
├── ca.crt              ← Cluster CA (публичный)
├── ca.key              ← Cluster CA (приватный) ⚠ секрет
├── apiserver.crt       ← Сертификат API Server
├── apiserver.key
├── apiserver-kubelet-client.crt  ← API → kubelet (logs, exec)
├── apiserver-kubelet-client.key
├── front-proxy-ca.crt  ← CA для aggregation layer (metrics-server)
├── front-proxy-client.crt
├── front-proxy-client.key
├── sa.key / sa.pub     ← Подпись ServiceAccount tokens (legacy)
├── etcd/
│   ├── ca.crt
│   ├── ca.key
│   ├── server.crt      ← etcd server cert
│   ├── server.key
│   ├── peer.crt        ← etcd peer cert
│   ├── peer.key
│   ├── healthcheck-client.crt
│   └── healthcheck-client.key
└── (после join workers - доп. client certs)
```

| Файл | Кто использует | Зачем |
|------|----------------|-------|
| `ca.crt` / `ca.key` | Весь кластер | Корень доверия; подписывает сертификаты компонентов и kubelet после bootstrap |
| `apiserver.crt` | kube-apiserver | TLS при подключении `kubectl`, kubelet, controllers |
| `apiserver-kubelet-client.crt` | kube-apiserver | Клиентский cert при вызовах kubelet API (exec, logs, port-forward) |
| `front-proxy-ca.crt` | API aggregation | Проверка extension API servers (metrics-server) |
| `sa.key` | Controller Manager | Подпись JWT ServiceAccount (до bound tokens) |
| `etcd/ca.crt` | etcd, apiserver | Отдельная CA для etcd (можно external etcd с другой CA) |
| `etcd/server.crt` | etcd | TLS для клиентов (apiserver) и healthcheck |

**Срок действия:** kubeadm по умолчанию - 1 год. Проверка: `kubeadm certs check-expiration`. Продление: `kubeadm certs renew all` + перезапуск static Pods.

### Stacked etcd vs external (контекст)

На lab-стенде (single CP) - **stacked etcd**: etcd как static Pod на той же ноде, что и API Server.

```
┌────────────────────────────────────────────── cp-1 ──┐
│  kubelet                                              │
│    ├── static: kube-apiserver ──► etcd (127.0.0.1)   │
│    ├── static: kube-scheduler                         │
│    ├── static: kube-controller-manager                │
│    └── static: etcd                                   │
│         data: /var/lib/etcd                           │
└──────────────────────────────────────────────────────┘
```


### Production best practices

- **Не редактировать** `manifests/` вручную без понимания - используйте `kubeadm upgrade` и шаблоны.
- **Backup** `pki/` и `etcd` snapshot - без них кластер не восстановить.
- **Права:** `ca.key`, `*.key` - только root; `chmod 600`.
- **Мониторинг:** static Pod в `CrashLoopBackOff` = кластер мёртв или деградировал.
- **Логи:** `crictl logs` / `journalctl -u kubelet` - не только `kubectl logs` (static Pod может не отвечать).

---

## Практика

**Цель lab:** после `kubeadm init` исследовать файловую систему Control Plane и сопоставить её с Pod'ами.

**Предусловия:** `cp-1` - init выполнен; `kubectl` работает от root с `admin.conf`.

### Шаг 1. Pod'ы Control Plane в kube-system

```bash
# На cp-1
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl get pods -n kube-system -o wide
```

**Ожидаемый результат** (имена с суффиксом hostname):

```
NAME                                READY   STATUS    RESTARTS   AGE
etcd-cp-1                           1/1     Running   0          10m
kube-apiserver-cp-1                 1/1     Running   0          10m
kube-controller-manager-cp-1        1/1     Running   0          10m
kube-scheduler-cp-1                 1/1     Running   0          10m
```

> CoreDNS, kube-proxy появятся после CNI и join - в этой главе их может не быть или они Pending.

```bash
# Подробности одного static Pod
kubectl describe pod -n kube-system kube-apiserver-cp-1
```

Обратите внимание на:

- `Controlled By: Node/cp-1` - не ReplicaSet!
- `Tolerations: :NoExecute op=Exists` - static Pod'ы терпимы к taint'ам CP.
- `Priority Class: system-node-critical`.

### Шаг 2. Манифесты на диске

```bash
sudo ls -la /etc/kubernetes/manifests/

# API Server - ключевые аргументы
sudo grep -E '^\s*-\s*--' /etc/kubernetes/manifests/kube-apiserver.yaml | head -30

# etcd - data-dir и certs
sudo grep -E 'data-dir|cert-file|key-file' /etc/kubernetes/manifests/etcd.yaml
```

**Сравните** аргументы в файле с `kubectl get pod kube-apiserver-cp-1 -n kube-system -o yaml` → секция `spec.containers[0].command`.

### Шаг 3. PKI - инвентаризация

```bash
sudo find /etc/kubernetes/pki -type f | sort

# Срок действия сертификатов
sudo kubeadm certs check-expiration

# Детали apiserver cert
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates
```

Запишите в блокнот: issuer CN, SAN (Subject Alternative Names) - там должен быть IP `cp-1` и Service `kubernetes.default.svc`.

### Шаг 4. Процессы на ноде (containerd)

```bash
# Через crictl (предпочтительно на Ubuntu 24.04)
sudo crictl ps --name kube-apiserver -o wide
sudo crictl ps --name etcd -o wide

# Логи API Server (если kubectl logs недоступен)
APISERVER_ID=$(sudo crictl ps --name kube-apiserver -q)
sudo crictl logs "$APISERVER_ID" 2>&1 | tail -20
```

### Шаг 5. Проверка API и etcd health

```bash
kubectl cluster-info
kubectl get --raw /healthz?verbose
kubectl get --raw /readyz?verbose

# etcd health через pod (если Running)
kubectl exec -n kube-system etcd-cp-1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

### Шаг 6. Эксперимент: связь manifest ↔ Pod (осторожно!)

> **Только на lab!** Не на production.

```bash
# Сделайте backup
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml.bak

# Добавьте label через аннотацию в файле - НЕ рекомендуется в prod;
# вместо этого просто проверьте: изменение файла вызывает перезапуск
sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml

# Наблюдайте
watch -n1 'kubectl get pods -n kube-system | grep scheduler'
```

Kubelet перезапустит scheduler Pod при изменении timestamp файла.

**Откат:**

```bash
sudo cp /root/kube-scheduler.yaml.bak /etc/kubernetes/manifests/kube-scheduler.yaml
```

### Что произошло внутри Kubernetes

```
kubeadm init (15.5.5)
    │
    ├─► генерация /etc/kubernetes/pki/* (ca, apiserver, etcd, front-proxy, sa)
    │
    ├─► запись admin.conf, controller-manager.conf, scheduler.conf, kubelet.conf
    │
    ├─► запись 4 YAML в /etc/kubernetes/manifests/
    │
    ▼
kubelet стартует (systemd) с config /var/lib/kubelet/config.yaml
    │
    ├─► staticPodPath: /etc/kubernetes/manifests
    │
    ▼
Порядок подъёма (типичный):
    1. etcd        ──► слушает 127.0.0.1:2379
    2. kube-apiserver ──► подключается к etcd, :6443
    3. scheduler + controller-manager ──► --kubeconfig → API Server
    │
    ▼
kubelet регистрирует mirror Pod'ы в API (если API уже доступен)
    │
    ▼
kubeadm ждёт /healthz → "Your Kubernetes control-plane has initialized"
```

**Почему порядок важен:** без etcd API Server не стартует; без API Server scheduler/CM не могут leader-elect. Kubelet не зависит от API для **запуска** static Pods - только для **отображения** их в API.

---

## Troubleshooting

| Симптом | Вероятная причина | Диагностика | Исправление |
|---------|-------------------|-------------|-------------|
| `kube-apiserver-cp-1` CrashLoopBackOff | Просрочен cert; etcd down; неверный `--advertise-address` | `crictl logs`, `journalctl -u kubelet`, `kubeadm certs check-expiration` | `kubeadm certs renew all`; проверить etcd; исправить IP |
| `etcd-cp-1` не стартует | Нет места на диске; corrupt data; права на `/var/lib/etcd` | `df -h`, `ls -la /var/lib/etcd`, etcd logs | Освободить диск; restore из snapshot ([15.5.17](15.5.17%20Kubernetes%20-%20Backup%20и%20Restore%20etcd.md)) |
| Static Pod есть, в API нет | API Server ещё не поднялся | `crictl ps` vs `kubectl get pods` | Подождать; чинить apiserver |
| `kubectl` timeout | API не слушает 6443; firewall | `ss -tlnp \| grep 6443`, `curl -k https://localhost:6443/healthz` | `ufw`/iptables; перезапуск kubelet |
| После ручного edit manifest - cluster broken | Синтаксическая ошибка YAML | `journalctl -u kubelet -f` | Восстановить backup YAML |
| `x509: certificate signed by unknown authority` | Несовпадение CA в kubeconfig и кластере | Сравнить `ca.crt` в kubeconfig и `/etc/kubernetes/pki/ca.crt` | Пересоздать kubeconfig или скопировать правильный ca |

**Чеклист диагностики static Pod:**

```
1. systemctl status kubelet          → active?
2. ls /etc/kubernetes/manifests/     → 4 файла?
3. crictl ps | grep kube-             → контейнеры Running?
4. crictl logs <id>                   → ошибки TLS/etcd?
5. kubeadm certs check-expiration    → даты OK?
6. kubectl get pods -n kube-system   → mirror Pods?
```

---
