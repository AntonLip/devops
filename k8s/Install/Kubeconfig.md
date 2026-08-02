# 15.5.7 — Kubeconfig

**Среда:** Ubuntu 24.04 LTS · **K8s 1.32.x** · kubeadm · VM `cp-1`

---

## Цель

Разобрать структуру **kubeconfig** (clusters, contexts, users); понять назначение `admin.conf`, `controller-manager.conf`, `scheduler.conf`, `kubelet.conf`; освоить аутентификацию через **X.509 client certificates** vs **tokens**; на практике переключаться между kubeconfig через `KUBECONFIG` и `--kubeconfig`.

---

## Теория

### Что такое kubeconfig

Kubeconfig — YAML-файл с параметрами подключения клиента к API Server. Используется `kubectl`, `kubelet`, `kube-scheduler`, `kube-controller-manager`, некоторые operators.

```
~/.kube/config  ← обычно копия admin.conf для human admin
/etc/kubernetes/admin.conf
/etc/kubernetes/scheduler.conf
/etc/kubernetes/controller-manager.conf
/etc/kubernetes/kubelet.conf
```

**Структура (три столпа + context):**

```yaml
apiVersion: v1
kind: Config
clusters:          # КУДА подключаться (URL + CA)
- cluster:
    certificate-authority-data: <base64 ca.crt>
    server: https://192.168.1.50:6443
  name: kubernetes
contexts:          # СВЯЗКА cluster + user + default namespace
- context:
    cluster: kubernetes
    user: kubernetes-admin
    namespace: default
  name: kubernetes-admin@kubernetes
current-context: kubernetes-admin@kubernetes
users:             # КТО подключается (credentials)
- name: kubernetes-admin
  user:
    client-certificate-data: <base64>
    client-key-data: <base64>
```

```
┌─────────────┐     current-context      ┌─────────────┐
│  contexts   │ ───────────────────────► │   cluster   │
│             │         +                │  server URL │
│             │ ───────────────────────► │  CA cert    │
└─────────────┘         user             └─────────────┘
                              │
                              ▼
                       ┌─────────────┐
                       │    users    │
                       │ client cert │
                       │ or token    │
                       └─────────────┘
```

### Четыре kubeconfig после kubeadm init

| Файл | Пользователь (CN / username) | Группы | Назначение |
|------|------------------------------|--------|------------|
| `admin.conf` | `kubernetes-admin` | `system:masters` | Полный доступ для администратора |
| `controller-manager.conf` | `system:kube-controller-manager` | — | Controller Manager → API |
| `scheduler.conf` | `system:kube-scheduler` | — | Scheduler → API |
| `kubelet.conf` | `system:node:<hostname>` (после bootstrap) | `system:nodes` | Kubelet → API |

**admin.conf** — копируется в `~/.kube/config` после init:

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

Группа **`system:masters`** обходит RBAC (legacy superuser). В production: отдельные RBAC-роли, не раздавать admin.conf.

### Сертификаты vs tokens

| Механизм | Где используется | Плюсы | Минусы |
|----------|------------------|-------|--------|
| **X.509 client cert** | admin.conf, component kubeconfigs, kubelet после bootstrap | Strong auth, встроен в TLS | Нужно продлевать; хранить key |
| **ServiceAccount token** | Pod'ы в кластере | Автоматом mount в Pod | Bound tokens предпочтительнее legacy |
| **Bootstrap token** | Временно при join | Простой join flow | Короткий TTL, ограниченные права |
| **OIDC / webhook** | Enterprise SSO | Централизованный IAM | Отдельная настройка API Server |

**Client certificate flow:**

```
kubectl
  │ TLS handshake + client cert (kubernetes-admin)
  ▼
kube-apiserver
  │ проверка: подписан ca.crt? CN/O/SAN OK?
  │ Authentication → user: kubernetes-admin, groups: [system:masters]
  ▼
Authorization (RBAC) → для masters часто skip
  ▼
request allowed
```

**Token flow (ServiceAccount):**

```
Pod → /var/run/secrets/kubernetes.io/serviceaccount/token
  │ Authorization: Bearer <JWT>
  ▼
API Server → TokenReview / подпись SA key
```

### Как kubeadm создаёт kubeconfig

При `kubeadm init`:

1. Генерирует client cert для каждого компонента в `pki/`.
2. Встраивает base64 cert/key и `ca.crt` в YAML.
3. Записывает файлы в `/etc/kubernetes/`.
4. Static Pod манифесты ссылаются на `--kubeconfig=/etc/kubernetes/scheduler.conf`.

```
kubeadm init
    │
    ├─► pki/apiserver.crt, ca.crt, ...
    ├─► pki/apiserver-etcd-client.crt
    │
    ├─► kubeconfig: admin, scheduler, controller-manager, kubelet (bootstrap)
    │
    ▼
компоненты читают свой kubeconfig при старте
```

### kubelet.conf и TLS Bootstrap

До join worker `kubelet.conf` на CP содержит **bootstrap credentials** — token + CA. После успешного bootstrap kubelet получает **node client certificate** и kubelet перезаписывает конфиг (или обновляет credentials).


### KUBECONFIG: несколько файлов

Переменная `KUBECONFIG` — список путей через `:` (Linux):

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf:/path/to/other.conf
```

`kubectl` **мержит** конфиги. Контексты из обоих файлов доступны в `kubectl config get-contexts`.

**Приоритет:** `KUBECONFIG` > default `~/.kube/config` > in-cluster config (для Pod).

### Безопасность (production)

- `admin.conf` = root кластера — chmod 600, не в git.
- Ротация: `kubeadm certs renew admin.conf` (и остальные).
- Отдельные kubeconfig для CI/CD с RoleBinding least privilege.
- Не использовать `system:masters` для приложений.

---

## Практика

**Цель:** сравнить четыре kubeconfig, переключить контекст, проверить identity через API.
**Предусловия:** `kubeadm init` на `cp-1` выполнен 


### Шаг 1. Инвентаризация файлов

```bash
sudo ls -la /etc/kubernetes/*.conf
```

Ожидаемо: `admin.conf`, `controller-manager.conf`, `kubelet.conf`, `scheduler.conf`, `super-admin.conf` (в 1.32+ может быть отдельный super-admin).

### Шаг 2. Разбор admin.conf

```bash
# Только структура (без base64 dump)
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf config view --minify

# Текущий context
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf config current-context

# Cluster URL
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf config view -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

### Шаг 3. Кто я? (identity)

```bash
# K8s 1.32+
kubectl --kubeconfig=/etc/kubernetes/admin.conf auth whoami

# Классика
kubectl --kubeconfig=/etc/kubernetes/admin.conf auth can-i '*' '*'
```

Ожидаемо для admin: `yes` на всё (system:masters).

### Шаг 4. Сравнение scheduler vs admin

```bash
# Scheduler — ограниченные права
sudo kubectl --kubeconfig=/etc/kubernetes/scheduler.conf auth can-i list pods --all-namespaces
sudo kubectl --kubeconfig=/etc/kubernetes/scheduler.conf auth can-i create pods --all-namespaces

# Admin
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf auth can-i create pods --all-namespaces
```

Scheduler может `list/get/watch` Pod'ов, `patch` binding — но **не** создавать произвольные Pod'ы как admin.

### Шаг 5. KUBECONFIG merge

```bash
# Создайте второй минимальный config (lab)
sudo cp /etc/kubernetes/admin.conf /tmp/admin-copy.conf

export KUBECONFIG=/etc/kubernetes/admin.conf:/tmp/admin-copy.conf
kubectl config get-contexts

# Переименуйте context для демонстрации
kubectl config rename-context kubernetes-admin@kubernetes lab-admin@kubernetes
kubectl config use-context lab-admin@kubernetes
kubectl auth whoami
```

**Откат:**

```bash
unset KUBECONFIG
# или
export KUBECONFIG=/etc/kubernetes/admin.conf
```

### Шаг 6. Извлечение CA и проверка TLS

```bash
# Сохранить CA из kubeconfig
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/cluster-ca.crt

# Сравнить с pki
diff /tmp/cluster-ca.crt <(sudo cat /etc/kubernetes/pki/ca.crt) && echo "CA match OK"
```

### Шаг 7. kubelet.conf

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/kubelet.conf config view --minify
sudo grep 'client-certificate\|token' /etc/kubernetes/kubelet.conf | head -5
```

На CP после init: user `system:node:cp-1` или bootstrap token (зависит от фазы).

### Шаг 8. Практика для студента — скрипт


```bash
#!/usr/bin/env bash
set -euo pipefail
for f in admin controller-manager scheduler kubelet; do
  echo "=== $f.conf ==="
  kubectl --kubeconfig="/etc/kubernetes/${f}.conf" config view --minify 2>/dev/null || true
  kubectl --kubeconfig="/etc/kubernetes/${f}.conf" auth whoami 2>/dev/null || echo "(whoami N/A)"
done
```

### Что произошло внутри Kubernetes

```
kubeadm init
    │
    ├─► kubeadm создаёт client certs:
    │     kubernetes-admin, system:kube-scheduler,
    │     system:kube-controller-manager, system:node:bootstrap
    │
    ├─► встраивает в kubeconfig (base64 fields)
    │
    ▼
kubectl --kubeconfig admin.conf
    │
    ├─► TLS: предъявляет client cert
    ├─► API Server: Authenticate → kubernetes-admin
    ├─► Authorize: system:masters → allow
    │
    ▼
ответ API

scheduler.conf при старте static Pod:
    │
    ├─► kube-scheduler читает файл
    ├─► подключается к https://cp-1:6443 с system:kube-scheduler cert
    ├─► leader-elect lease в kube-system
    └─► watch unscheduled pods
```

