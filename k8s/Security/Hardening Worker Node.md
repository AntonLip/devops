# Hardening Worker Node

## Цель

Понять, как **kubelet + containerd 2.1.5** на Talos workers (`worker-1/2/3`) запускают контейнеры; настроить **capabilities**, **seccomp** и разобрать **ограничения AppArmor** на immutable OS; захардить `web-dep` / `api-dep` в `devops-lab` без privileged CNI pods.

---

## Теория

### Зачем hardening worker node

### Цепочка: API → container

```
Deployment spec
      │
      ▼
Scheduler → выбирает worker (например worker-2)
      │
      ▼
Kubelet (на worker-2)
      │
      ├─► PodSecurity / PSA (если namespace labeled)
      ├─► SecurityContext merge (pod + container)
      ├─► seccomp profile
      ├─► capabilities (add/drop)
      └─► CRI вызов containerd
              │
              ▼
         runc / container runtime
              │
              ▼
         namespaces + cgroups + seccomp
```

**Kubelet** - агент на каждой node. **containerd** - daemon, который создаёт container через **runc**. Kubernetes **не** запускает Docker на Talos - только containerd через CRI socket.

### containerd 2.1.5 на Talos

| Аспект | На homelab |
|--------|------------|
| Управление | Talos machine config - **не** правка `/etc/containerd/config.toml` вручную |
| Socket | `/run/containerd/containerd.sock` (kubelet → CRI) |
| Namespace | `k8s.io` для Pod containers |
| Образы | Pull через kubelet; `hashicorp/http-echo:1.0` уже на workers |
| Sandbox | pause container (`registry.k8s.io/pause:3.x`) на каждый Pod |

**Проверка снаружи node** (без SSH на Talos):

```bash
kubectl get nodes -o wide
kubectl describe node worker-1 | grep -A5 "Container Runtime"
kubectl get pods -n devops-lab -o wide
```

Ожидаемо: `Container Runtime Version: containerd://2.1.5`.

**Что containerd применяет из Pod spec:**

- `securityContext.runAsUser` → UID в user namespace
- `capabilities.drop/add` → bounding set процесса
- `seccompProfile` → syscall filter
- `readOnlyRootFilesystem` → overlay mount read-only
- `privileged: true` → **отключает** seccomp и даёт все capabilities

### Linux Capabilities

Вместо полного root процесс получает **набор capabilities** (POSIX). Kubernetes маппит их через `securityContext.capabilities`.

| Capability | Риск | Кто на стенде |
|------------|------|---------------|
| `CAP_NET_RAW` | Raw sockets, ARP spoof | Cilium agent - **нужен** для CNI |
| `CAP_SYS_ADMIN` | mount, namespace tricks | privileged pods |
| `CAP_NET_BIND_SERVICE` | bind port < 1024 | nginx без root если drop ALL + add NET_BIND |
| `CAP_CHOWN` | chown файлов | часто в default set |

**PSA restricted** требует `capabilities.drop: ["ALL"]` и запрещает `NET_RAW` (кроме исключений). На стенде PSA audit уже **заблокировал** `NET_RAW` в `cilium-test-ccnp2` - событие в Events.

**Default capabilities** (если не drop ALL): `CHOWN`, `DAC_OVERRIDE`, `FSETID`, `FOWNER`, `MKNOD`, `NET_RAW`, `SETGID`, `SETUID`, `SETFCAP`, `SETPCAP`, `NET_BIND_SERVICE`, `SYS_CHROOT`, `KILL`, `AUDIT_WRITE`.

### Seccomp (Secure Computing Mode)

**Seccomp** - фильтр **syscall**: разрешённые и запрещённые системные вызовы.

| Профиль | Источник | На Talos |
|---------|----------|----------|
| `RuntimeDefault` | container runtime (OCI default) | **Рекомендуется** для PSA restricted |
| `Localhost` | ConfigMap с custom profile | Редко на homelab |
| `Unconfined` | Без фильтра | privileged, legacy |

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault   # Pod level
```

**containerd 2.1.5** применяет OCI seccomp default при `RuntimeDefault`. Это блокирует опасные syscall (например `reboot`, `kexec_load`) без custom policy.

**Проверка в running Pod:**

```bash
POD=$(kubectl get pod -n devops-lab -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$POD" -- cat /proc/1/status | grep -i seccomp
# Seccomp: 2  → filter mode active
```

До hardening на `web-dep` seccomp может быть `0` (disabled) - если профиль не задан.

### AppArmor на Talos - ограничения

**AppArmor** - Mandatory Access Control (MAC) на уровне ОС: профили `docker-default`, `cri-containerd.apparmor.d` и т.д.

| Платформа | AppArmor |
|-----------|----------|
| Ubuntu/Debian K8s | Часто включён, профили в `/etc/apparmor.d` |
| **Talos Linux** | **Минимальная поддержка** - immutable, нет классического apparmor parser для custom profiles |
| Альтернатива | **SELinux** тоже не в типичном Talos flow |

```yaml
# На Talos - не рассчитывайте на это в production checklist
securityContext:
  appArmorProfile:
    type: RuntimeDefault
```

Для interview: «На Talos worker hardening = SecurityContext + PSA + NetworkPolicy + immutable OS, AppArmor - secondary».

### Что должно быть privileged (и почему)

| Pod | privileged | Почему допустимо |
|-----|------------|------------------|
| Cilium agent | да | eBPF, hostNetwork, hostPath |
| Falco (после install) | частично | kernel events |
| `web-dep` / `api-dep` | **нет** | stateless echo - restricted достаточно |

**Правило:** privileged только для **инфраструктурных** DaemonSet с documented exception.

### Hardening checklist (worker scope)

| Контроль | Уровень | PSA restricted |
|----------|---------|----------------|
| `runAsNonRoot: true` | Pod | обязательно |
| `allowPrivilegeEscalation: false` | container | обязательно |
| `readOnlyRootFilesystem: true` | container | обязательно (+ emptyDir для tmp) |
| `capabilities.drop: [ALL]` | container | обязательно |
| `seccompProfile: RuntimeDefault` | Pod | обязательно |
| `hostPID/hostNetwork: false` | Pod | по умолчанию |
| Resource limits | container | best practice |

## Практика

### Цель

Захардить `web-dep` и `api-dep` в `devops-lab`; сравнить capabilities до/после; проверить seccomp; убедиться, что `demo.home` работает.

### Шаг 1 - Baseline (до hardening)

```bash
# Текущий securityContext
kubectl get deploy web-dep api-dep -n devops-lab \
  -o jsonpath='{range .items[*]}{.metadata.name}{": podSC="}{.spec.template.spec.securityContext}{" containerSC="}{.spec.template.spec.containers[0].securityContext}{"\n"}{end}'

# Capabilities running process (если есть capsh)
POD=$(kubectl get pod -n devops-lab -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$POD" -- cat /proc/1/status | grep -E '^(Cap|Seccomp|NoNewPrivs)'

# UID
kubectl exec -n devops-lab "$POD" -- id
```

**Ожидаемо до patch:** `securityContext: {}`, root UID, Seccomp: 0.

### Шаг 2 - Patch web-dep (frontend)

```bash
kubectl patch deployment web-dep -n devops-lab --type=strategic -p '
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
'
```

> **Примечание:** `hashicorp/http-echo` слушает 8080 - non-root OK. Для writable `/tmp` при необходимости добавьте `emptyDir` volume.

### Шаг 3 - Patch api-dep (backend)

```bash
kubectl patch deployment api-dep -n devops-lab --type=strategic -p '
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: api
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
'
```

```bash
kubectl rollout status deployment/web-dep deployment/api-dep -n devops-lab
```

### Шаг 4 - Проверка после hardening

```bash
POD=$(kubectl get pod -n devops-lab -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-lab "$POD" -- id
# uid=65534(nobody)

kubectl exec -n devops-lab "$POD" -- cat /proc/1/status | grep -E '^(Cap|Seccomp|NoNewPrivs)'
# CapEff: 0000000000000000  (после drop ALL)
# Seccomp: 2
# NoNewPrivs: 1

# Функциональность
curl -s -H "Host: demo.home" http://192.168.1.201/ | head -3
curl -s -H "Host: demo.home" http://192.168.1.201/api | head -3
```

### Шаг 5 - PSA dry-run на devops-lab

```bash
# Если добавить enforce=restricted на devops-lab:
kubectl label namespace devops-lab \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

kubectl label namespace devops-lab \
  pod-security.kubernetes.io/enforce- \
  --overwrite   # откат enforce если нужно сохранить учебный режим
```

После patch deployment должен проходить PSA restricted.

### Шаг 6 - containerd на worker (read-only)

```bash
kubectl get --raw /api/v1/nodes/worker-1/proxy/stats/summary 2>/dev/null | head -5 || \
  kubectl describe node worker-1 | grep -E 'Container Runtime|Operating System|Kernel'
```

### Ожидаемый результат

| Проверка | До | После |
|----------|-----|-------|
| runAsUser | 0 (root) | 65534 |
| CapEff | non-zero | 0000000000000000 |
| Seccomp | 0 | 2 |
| demo.home | OK | OK |
| PSA restricted | FAIL | PASS |

### Откат

```bash
kubectl patch deployment web-dep -n devops-lab --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/securityContext"}]'
kubectl patch deployment api-dep -n devops-lab --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/securityContext"}]'
kubectl rollout restart deployment/web-dep deployment/api-dep -n devops-lab
```

---

## Что произошло внутри Kubernetes

### Patch Deployment

```
kubectl patch → API Server
    → Authentication (admin X509)
    → Authorization (RBAC allow)
    → Admission (resource validation)
    → etcd: Deployment spec updated, resourceVersion++
    → Deployment controller: new ReplicaSet
    → Scheduler: new Pods → workers
    → Kubelet: PullImage (IfNotPresent) → CreateContainer
    → containerd: OCI spec с seccomp.json + capability bounding set
    → runc: clone namespaces, apply cgroup, start process UID 65534
```

### containerd CreateContainer

1. **Pause container** - network namespace holder.
2. **App container** - получает merged SecurityContext.
3. **Seccomp** - загружается profile `RuntimeDefault` из OCI bundle.
4. **Capabilities** - `drop ALL` → пустой effective set.
5. **Read-only root** - overlayfs lower read-only, upper empty (или tmpfs).

**Старые Pod'ы** терминируются по rolling update strategy - kubelet отправляет SIGTERM, grace period, затем SIGKILL.

---

## Типичные ошибки

| Ошибка | Симптом | Диагностика | Исправление |
|--------|---------|-------------|-------------|
| `runAsNonRoot` без `runAsUser` | CrashLoop если image USER root | `kubectl logs`, `describe pod` | Явный `runAsUser: 65534` |
| `readOnlyRootFilesystem` без volume | Permission denied на write | logs, `exec touch /tmp/x` | `emptyDir` для `/tmp` |
| Drop ALL + порт 80 | bind: permission denied | logs | Порт 8080 или add `NET_BIND_SERVICE` |
| AppArmor profile на Talos | Pod Pending / warning | events | Убрать appArmorProfile, seccomp only |
| Hardening без NetworkPolicy | Lateral movement остаётся | Hubble flows | [15.3.4](15.3.4%20Kubernetes%20-%20NetworkPolicy%20(Cilium).md) |
| Privileged для «простоты» | PSA deny, огромный blast radius | `kubectl describe pod` | restricted + capabilities drop |

---
