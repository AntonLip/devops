
# SecurityContext

---

## Цель

Понять **SecurityContext** на уровне Pod и Container; применить hardening к реальному `web-dep` в `devops-lab`; увидеть разницу между «Pod запустился» и «Pod безопасен» на примере намеренно небезопасного Pod в `lab-space`.

---

## Теория

### Зачем SecurityContext

RBAC отвечает «**кто** может создать Pod». **SecurityContext** отвечает «**как** Pod работает внутри node» — UID, capabilities, filesystem, seccomp, AppArmor.

На вашем стенде (аудит 2026-07-08):

```bash
kubectl get deploy -n devops-lab -o jsonpath='{range .items[*]}{.metadata.name}{": podSC="}{.spec.template.spec.securityContext}{" containerSC="}{.spec.template.spec.containers[0].securityContext}{"\n"}{end}'
```

Ожидаемо: `web-dep` и `api-dep` — **пустой** `securityContext: {}`. Контейнер `hashicorp/http-echo:1.0` стартует **от root (UID 0)** с полным набором Linux capabilities — типичная «работает, но уязвимо» конфигурация.

### Два уровня: Pod vs Container

```
┌─────────────────────────────────────────────────────────────┐
│  Pod.spec.securityContext          (общие настройки)        │
│    runAsUser, runAsGroup, fsGroup, seccompProfile, ...      │
├─────────────────────────────────────────────────────────────┤
│  Container[n].securityContext      (пер-контейнер)          │
│    allowPrivilegeEscalation, capabilities, readOnlyRootFS   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    Kubelet → containerd → OCI runtime
                              │
                              ▼
              Linux: UID/GID, caps, seccomp, namespaces
```

**Правило:** container-level **перекрывает** pod-level для того же поля. Если задан только pod-level `runAsUser: 65534`, все контейнеры наследуют его, если не переопределено.

### Ключевые поля (must know)

| Поле | Уровень | Эффект | Production |
|------|---------|--------|------------|
| **runAsNonRoot** | Pod/Container | Запрет UID 0 | `true` почти всегда для apps |
| **runAsUser** / **runAsGroup** | Pod/Container | Явный UID/GID | Используйте non-zero из Dockerfile `USER` |
| **readOnlyRootFilesystem** | Container | `/` только read-only | + `emptyDir`/`volume` для `/tmp` |
| **allowPrivilegeEscalation** | Container | Запрет setuid битов в caps | `false` вместе с drop ALL |
| **capabilities** | Container | drop/add Linux caps | `drop: ["ALL"]`, add минимум |
| **fsGroup** | Pod | GID для volumes | Важно для RWX PVC |
| **seccompProfile** | Pod/Container | Фильтр syscalls | `RuntimeDefault` (PSA restricted) |
| **privileged** | Container | Полный доступ к host | Только CNI/monitoring — см. Cilium pods |
| **appArmorProfile** | Pod/Container | MAC-профиль (если AA включён) | `runtime/default` |

### Capabilities — что реально опасно

По умолчанию Docker/containerd даёт контейнеру **урезанный** набор, но не нулевой:

```
CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_FOWNER, CAP_FSETID, CAP_KILL,
CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_SETGID, CAP_SETUID, ...
```

**NET_RAW** — причина, по которой PSA **baseline** блокирует его без явного add. На стенде в событиях `cilium-test-ccnp2` уже был deny `NET_RAW`.

```
Атакующий в Pod с NET_RAW
        │
        ▼
  ARP spoof / raw sockets / некоторые scan-техники
```

**Hardening-паттерн:**

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
  allowPrivilegeEscalation: false
```

### readOnlyRootFilesystem

```
┌──────────────────┐     write attempt      ┌─────────────────┐
│  Container /     │ ─────────────────────► │  EACCES (deny)  │
│  (read-only)     │                        └─────────────────┘
└────────┬─────────┘
         │ writes to /tmp
         ▼
┌──────────────────┐
│  emptyDir mount  │  ← явно разрешённый writable path
└──────────────────┘
```

`hashicorp/http-echo` не пишет на диск — для lab **readOnlyRootFilesystem: true** обычно работает без extra volumes.

### fsGroup

При монтировании volume Kubernetes **chown/chmod** файлов на volume под `fsGroup` Pod'а — чтобы процесс non-root мог читать/писать shared storage.

На вашем кластере **CSI/StorageClass нет** — fsGroup актуален теоретически; в production с RWX NFS/EFS это обязательный параметр.

### Seccomp

**Seccomp** (secure computing mode) — фильтр **system calls**:

```
Application syscall
        │
        ▼
┌─────────────────┐
│ seccomp profile │  allow / deny / kill
└─────────────────┘
        │
   RuntimeDefault  ← профиль container runtime (рекомендуется PSA restricted)
   Localhost       ← custom profile из файла на node
   Unconfined      ← без фильтра (опасно)
```

Talos + containerd: `RuntimeDefault` мапится на профиль OCI runtime. **Не путать** с AppArmor.

### AppArmor

**AppArmor** — MAC на уровне path/capability (Ubuntu/SUSE tradition). На **Talos** AppArmor может быть **не активен** — поле `appArmorProfile` игнорируется, если LSM не загружен.

Проверка на worker (read-only, через debug):

```bash
# На node через talosctl или privileged debug — вне scope lab
cat /sys/kernel/security/lsm   # ожидаемо: ...apparmor... или нет
```

**На собеседовании:** «Seccomp ограничивает syscalls, AppArmor — path/network profile. На Talos чаще опираемся на seccomp + PSA, AppArmor — на Ubuntu nodes».

### Сравнение с Cilium (privileged CNI)

| Компонент | privileged | hostNetwork | Зачем |
|-----------|------------|-------------|-------|
| **cilium-agent** | yes | yes | eBPF, map host netns |
| **web-dep** | no | no | HTTP echo — не нужно |

Вопрос с аудита: «Почему Cilium **должен** быть privileged, а web-dep — нет?» — CNI управляет сетевым стеком хоста; приложение должно быть максимально изолировано.

### Defense in Depth

```
RBAC ──► кто создаёт Pod
PSA  ──► минимальный baseline на namespace (след. глава)
SC   ──► как работает процесс внутри Pod
NetPol ──► с кем общается Pod
```

SecurityContext **не заменяет** NetworkPolicy и **не** скрывает Secret от RBAC.

### Что спрашивают на собеседованиях

1. Разница `runAsNonRoot: true` и `runAsUser: 65534`?
2. Зачем `allowPrivilegeEscalation: false` если уже `drop: ALL`?
3. Что сломается при `readOnlyRootFilesystem: true` у nginx без volume?
4. Чем seccomp отличается от capabilities?
5. Можно ли в одном Pod иметь secure и insecure контейнер? (да, разные container SC)

### Production-пример

Банковский microservice:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

---

## Практика

### Цель

1. Запустить **небезопасный** Pod в `lab-space` (PSA `privileged` — admission **пропустит**).
2. Захарднить **реальный** `web-dep` в `devops-lab` по образцу `05-secure-deployment.yaml`.
3. Сравнить UID/capabilities до и после.

### Предусловия

```bash
kubectl get ns lab-space devops-lab sec-lab
kubectl get deploy web-dep api-dep -n devops-lab
```

### Шаг 1 — Baseline: текущее состояние web-dep

```bash
# SecurityContext deployment
kubectl get deploy web-dep -n devops-lab -o yaml | grep -A20 'securityContext'

# Фактический процесс в Pod
WEB_POD=$(kubectl get pod -n devops-lab -l app=web,tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$WEB_POD" -- id
kubectl exec -n devops-lab "$WEB_POD" -- cat /proc/1/status | grep -E '^(Uid|CapEff):'
```

**Ожидаемо:** `uid=0(root)`, CapEff — ненулевой набор capabilities.

### Шаг 2 — Небезопасный Pod в lab-space

Создайте файл `lab/security-homelab/manifests/04-insecure-pod-lab-space.yaml` (адаптация `04-insecure-pod.yaml`):

```yaml
# Намеренно небезопасный Pod — в lab-space PSA enforce=privileged ПРОПУСТИТ
apiVersion: v1
kind: Pod
metadata:
  name: sec-insecure-root
  namespace: lab-space
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      securityContext:
        privileged: true
        runAsUser: 0
```

```bash
kubectl apply -f lab/security-homelab/manifests/04-insecure-pod-lab-space.yaml
kubectl get pod sec-insecure-root -n lab-space
kubectl exec -n lab-space sec-insecure-root -- id
```

**Ожидаемо:** Pod **Running** — PSA `privileged` не блокирует. Это демонстрирует, что **namespace label** определяет допустимость, а не «Kubernetes сам защищает».

> Тот же манифест в `sec-psa-restricted` (см. [15.3.5](15.3.5%20Kubernetes%20—%20Pod%20Security%20Admission.md)) будет **отклонён**.

### Шаг 3 — Secure patch для web-dep

Адаптация `05-secure-deployment.yaml` под существующий `web-dep`:

```bash
kubectl patch deployment web-dep -n devops-lab --type=strategic -p '
{
  "spec": {
    "template": {
      "spec": {
        "securityContext": {
          "runAsNonRoot": true,
          "runAsUser": 65534,
          "seccompProfile": { "type": "RuntimeDefault" }
        },
        "containers": [{
          "name": "http-echo",
          "securityContext": {
            "allowPrivilegeEscalation": false,
            "readOnlyRootFilesystem": true,
            "capabilities": { "drop": ["ALL"] }
          }
        }]
      }
    }
  }
}'
```

Имя контейнера проверьте:

```bash
kubectl get deploy web-dep -n devops-lab -o jsonpath='{.spec.template.spec.containers[*].name}'
```

Если контейнер называется иначе (например `echo`), замените в patch.

```bash
kubectl rollout status deployment/web-dep -n devops-lab
WEB_POD=$(kubectl get pod -n devops-lab -l app=web,tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$WEB_POD" -- id
kubectl exec -n devops-lab "$WEB_POD" -- cat /proc/1/status | grep CapEff
```

**Ожидаемо:** `uid=65534(nobody)`, CapEff `0` или минимальный.

### Шаг 4 — Проверка приложения через Ingress

```bash
curl -s -H "Host: demo.home" http://192.168.1.201/ | head -5
```

**Ожидаемо:** HTTP 200, echo-ответ — hardening **не** ломает frontend.

### Шаг 5 — Демонстрация readOnlyRootFilesystem

```bash
kubectl exec -n devops-lab "$WEB_POD" -- sh -c 'touch /test 2>&1'
```

**Ожидаемо:** `Read-only file system`.

### Откат

```bash
# Удалить lab Pod
kubectl delete pod sec-insecure-root -n lab-space --ignore-not-found

# Откат web-dep (убрать securityContext)
kubectl patch deployment web-dep -n devops-lab --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/securityContext"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/securityContext"}
]'
kubectl rollout status deployment/web-dep -n devops-lab
```

Либо через Git/Argo CD, если `web-dep` управляется GitOps.

---

## Что произошло внутри Kubernetes

```
kubectl patch deployment web-dep
        │
        ▼
┌───────────────────┐
│ API Server        │  Auth: admin (X509) → RBAC allow
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Admission         │  PSA на devops-lab: enforce не задан → warn/audit only
│ (no Kyverno)      │  Patch принят
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ etcd              │  новый ReplicaSet template с securityContext
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Deployment ctrl   │  rolling update → новый Pod
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Scheduler         │  worker-1/2/3
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Kubelet           │  передаёт SC в CRI spec
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ containerd        │  OCI: User 65534, noNewPrivileges, ro rootfs, seccomp
└─────────┬─────────┘
          │
          ▼
   http-echo @ UID 65534
```

Для **privileged Pod** в `lab-space` цепочка та же, но admission PSA **не** генерирует deny — уровень `privileged` разрешает `privileged: true` и `runAsUser: 0`.

---

## Типичные ошибки

| Ошибка | Симптом | Диагностика | Исправление |
|--------|---------|-------------|-------------|
| `runAsNonRoot` без `runAsUser`, образ от root | `CreateContainerConfigError` | `kubectl describe pod` → must runAsNonRoot | Задать `runAsUser: 65534` или USER в Dockerfile |
| `readOnlyRootFilesystem` без `/tmp` | Crash nginx/php | logs: permission denied | `emptyDir` для `/tmp`, `/var/cache` |
| Неверное имя контейнера в patch | SC не применился | `kubectl get pod -o yaml` | Patch правильный container name |
| Drop ALL + нужен 443 | bind: permission denied | `cap_net_bind_service` | `capabilities.add: [NET_BIND_SERVICE]` или port >1024 |
| seccomp Localhost без файла на node | FailedCreatePodSandBox | events на Pod | `RuntimeDefault` или установить profile |
| Думать, что SC = PSA | Pod deny при create | `Forbidden: violates PodSecurity` | Namespace PSA + SC согласованы — см. 15.3.5 |

