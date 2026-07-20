
# Kubernetes - Namespaces

## 2. Зачем namespace в одном cluster

Kubernetes cluster - **один** control plane и набор worker nodes. Namespace - **виртуальное разделение** внутри API: разные «папки» для объектов с **одинаковыми типами**, но разными именами и политиками.

Типичные сценарии:

| Сценарий | Пример namespace |
|----------|------------------|
| Окружения в dev cluster | `dev`, `staging` |
| Команды / продукты | `team-payments`, `team-auth` |
| Lab / курс | `lab-space` |
| Системные компоненты | `kube-system`, `ingress-nginx` |

```text
Cluster (один API server)
├── namespace: default
├── namespace: kube-system     ← CoreDNS, kube-proxy, CNI
├── namespace: ingress-nginx   ← Ingress Controller (после addon)
└── namespace: lab-space       ← наши lab workloads
```

**Namespace не заменяет** отдельный cluster для production isolation (compliance, blast radius). Но для dev/staging и организации манифестов - **стандартный** инструмент.

---

## 3. Системные и пользовательские namespace

При старте cluster создаются namespace:

| Namespace | Содержимое |
|-----------|------------|
| **default** | Ресурсы без явного `metadata.namespace` |
| **kube-system** | CoreDNS, kube-proxy, CNI, storage addons |
| **kube-public** | Публичная info (редко трогают) |
| **kube-node-lease** | Heartbeat nodes |

```bash
kubectl get namespaces
```

**Правило:** не деплоить учебные приложения в `kube-system` - там system components; ошибка может сломать cluster.

Custom namespace создаётся объектом `Kind: Namespace`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lab-space
  labels:
    env: lab
```

Поле `metadata.name` - **имя namespace** (DNS-compatible, lowercase). Labels на namespace полезны для **политик** и мониторинга, но не изолируют сами по себе.

---

## 4. metadata.namespace и контекст kubectl

Каждый namespaced object (Pod, Service, Deployment, Ingress, Secret, …) живёт **ровно в одном** namespace. Имя ресурса уникально **внутри** namespace: `nginx-svc` в `default` и `nginx-svc` в `lab-space` - **разные** объекты.

Задать namespace в манифесте:

```yaml
metadata:
  name: web-dep
  namespace: lab-space
```

Или при apply:

```bash
kubectl apply -f deployment.yaml -n lab-space
```

### Default namespace в kubectl

Чтобы не писать `-n` каждый раз:

```bash
kubectl config set-context --current --namespace=lab-space
kubectl config view --minify | grep namespace:
```

Все последующие `kubectl get pods`, `apply` без `-n` идут в **lab-space**. Проверяйте контекст перед destructive командами.

```bash
kubectl config get-contexts
kubectl config use-context minikube
```

**Cluster-wide** ресурсы (Node, PersistentVolume, ClusterRole, CRD) **не** имеют namespace.

---

## 5. ResourceQuota и LimitRange

Без квот один namespace может исчерпать CPU/RAM или «забить» cluster сотнями Pod'ов. В prod multi-tenant cluster **ResourceQuota** и **LimitRange** почти всегда включены. На Minikube в `lab-space` по умолчанию их **нет** - ниже примеры, которые можно применить для эксперимента.

### 5.1. ResourceQuota - бюджет namespace

**ResourceQuota** задаёт **потолок** на суммарное потребление **внутри одного namespace**. Scheduler и API server **отклонят** создание Pod (или другого объекта), если квота исчерпана.

Важно: квота считает не «фактическое» CPU/RAM (как `kubectl top`), а **requests/limits из spec Pod'ов** (включая **ephemeral-storage**), **storage PVC** и **количество объектов**.

Типичная пара в prod: **Quota** = бюджет команды на namespace, **LimitRange** = правила на каждый Pod/container (см. §5.2).

#### Полный пример ResourceQuota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mem-cpu-quota
  namespace: lab-space
  labels:
    team: lab
spec:
  hard:
    # --- CPU и память (сумма по всем Pod'ам в NS) ---
    requests.cpu: "4"            # суммарные CPU requests всех контейнеров
    requests.memory: 8Gi         # суммарные memory requests
    limits.cpu: "8"              # суммарные CPU limits (часто ставят вместе с requests)
    limits.memory: 16Gi          # суммарные memory limits

    # --- Локальный/ephemeral disk (emptyDir, logs, writable layer) ---
    requests.ephemeral-storage: 10Gi
    limits.ephemeral-storage: 20Gi

    # --- Persistent volumes (отдельно от ephemeral) ---
    requests.storage: 50Gi       # суммарный storage всех PVC в NS
    # --- Количество объектов ---
    pods: "20"                   # макс. Pod'ов в namespace
    services: "10"               # макс. Service
    services.loadbalancers: "2"  # макс. Service type=LoadBalancer
    services.nodeports: "5"      # макс. Service type=NodePort
    secrets: "20"
    configmaps: "20"
    resourcequotas: "1"          # сколько ResourceQuota объектов можно иметь
```

Применение:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mem-cpu-quota
  namespace: lab-space
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    requests.ephemeral-storage: 10Gi
    limits.ephemeral-storage: 20Gi
    requests.storage: 50Gi
    persistentvolumeclaims: "4"
    pods: "20"
    services: "10"
EOF
```

#### Таблица полей `spec.hard`

| Поле | За что отвечает |
|------|-----------------|
| `requests.cpu` | Сумма **requests.cpu** всех контейнеров во всех Pod'ах NS. Scheduler резервирует это на node. |
| `requests.memory` | Сумма **requests.memory** - «забронированная» память для namespace. |
| `limits.cpu` | Сумма **limits.cpu** - верхняя граница CPU (throttling при превышении). |
| `limits.memory` | Сумма **limits.memory** - при превышении container может быть **OOMKilled**. |
| `requests.ephemeral-storage` | Сумма **requests.ephemeral-storage** - локальный disk Pod'ов (см. §5.1.1). |
| `limits.ephemeral-storage` | Сумма **limits.ephemeral-storage** - потолок локального disk; при превышении Pod может быть **evicted**. |
| `requests.storage` | Суммарный **storage** всех **PVC** в namespace (EBS, NFS, …) - **не** emptyDir. |
| `pods` | Максимум **Pod** объектов в namespace. |
| `services` | Максимум **Service** (любого типа). |
| `services.loadbalancers` | Только LoadBalancer Services. |
| `services.nodeports` | Только NodePort Services. |
| `persistentvolumeclaims` | Максимум **PVC** (число объектов). |
| `secrets` / `configmaps` | Максимум Secret / ConfigMap. |
| `count/deployments.apps` | (K8s 1.23+) лимит на число Deployment. |
| `count/ingresses.networking.k8s.io` | лимит Ingress и т.д. |

Есть также квоты на **число объектов** вида `count/<resource>.<group>` для конкретных kinds.

#### 5.1.1. ephemeral-storage - что входит

**ephemeral-storage** - это **локальное** хранилище на node, связанное с Pod'ом, **не** переживающее migrate на другой node (в отличие от PVC):

| Источник | Пример |
|----------|--------|
| **emptyDir** volume | cache, scratch space между containers в Pod |
| **Логи container** | stdout/stderr, файлы логов на disk node |
| **Writable layer** container | слой поверх image, если root FS не read-only |
| **configMap/secret** mounts | обычно малы; иногда учитываются |

**Не путать:**

| Квота | Что ограничивает |
|-------|------------------|
| `requests.ephemeral-storage` / `limits.ephemeral-storage` | Локальный disk **Pod'ов** (emptyDir и т.д.) |
| `requests.storage` | Суммарный размер **PersistentVolumeClaim** |
| `persistentvolumeclaims` | **Количество** PVC объектов |

В Pod указывают так же, как CPU/memory:

```yaml
resources:
  requests:
    ephemeral-storage: 1Gi
  limits:
    ephemeral-storage: 2Gi
```

При **emptyDir** с `sizeLimit` kubelet учитывает лимит volume в quota. Если Pod пишет больше **limits.ephemeral-storage**, node может **evict** Pod (при включённом мониторинге local storage на node).

На Minikube enforcement иногда мягче, чем в prod cloud; **quota в API** всё равно считает requests/limits из spec.

#### requests vs limits

| | **requests** | **limits** |
|---|-------------|------------|
| Смысл | «Мне **нужно минимум** столько» | «Мне **нельзя больше** столько» |
| Scheduler | Использует requests для **размещения** на node | Не влияет на выбор node |
| Quota | Увеличивает `Used requests.*` | Увеличивает `Used limits.*` |
| Runtime | Гарантия ресурса (best-effort) | CPU throttle / OOM при превышении memory |
| Disk | `requests.ephemeral-storage` в quota | Eviction при переполнении local disk (limits) |

Quota может ограничивать только requests, только limits, или **оба**. Если в квоте указаны только `requests.*` и `pods`, Pod **без** блока `resources` не увеличит `Used requests.*`, но всё равно считается в `pods: "20"`. Pod с **emptyDir** без `ephemeral-storage` в resources может не учитываться в ephemeral quota - зависит от LimitRange defaults.

---

### 5.2. LimitRange - правила на Pod и Container

**LimitRange** задаёт **default/min/max** на один Container, Pod или PVC в namespace - чтобы Pod'ы не создавались «без limits» и не ломали планирование.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: lab-space-limits
  namespace: lab-space
spec:
  limits:
    # --- Ограничения на один Container ---
    - type: Container
      default:                 # default limits, если в Pod не указаны
        cpu: "500m"
        memory: 512Mi
        ephemeral-storage: 2Gi
      defaultRequest:          # default requests
        cpu: "100m"
        memory: 128Mi
        ephemeral-storage: 1Gi
      min:                     # минимум на container
        cpu: "50m"
        memory: 64Mi
        ephemeral-storage: 500Mi
      max:                     # максимум на container
        cpu: "2"
        memory: 2Gi
        ephemeral-storage: 5Gi
      maxLimitRequestRatio:    # limits не больше requests в N раз
        cpu: "2"
        memory: "2"

    # --- Ограничения на весь Pod (сумма контейнеров) ---
    - type: Pod
      max:
        cpu: "4"
        memory: 4Gi
        ephemeral-storage: 10Gi

    # --- Ограничения на PVC ---
    - type: PersistentVolumeClaim
      min:
        storage: 1Gi
      max:
        storage: 10Gi
```

#### Типы `spec.limits[].type`

| type | За что |
|------|--------|
| `Container` | min/max/default/defaultRequest **на один container** |
| `Pod` | min/max **на сумму** всех containers в Pod |
| `PersistentVolumeClaim` | min/max **storage** на PVC |

---

### 5.3. Pod, который учитывается в квоте

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-quota
  namespace: lab-space
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      resources:
        requests:
          cpu: "100m"       # +100m к Used requests.cpu
          memory: 128Mi     # +128Mi к Used requests.memory
          ephemeral-storage: 1Gi
        limits:
          cpu: "500m"       # +500m к Used limits.cpu
          memory: 512Mi     # +512Mi к Used limits.memory
          ephemeral-storage: 2Gi
  volumes:
    - name: cache
      emptyDir:
        sizeLimit: 1Gi      # учитывается в ephemeral-storage quota
```

---

### 5.4. Превышение квоты

```bash
kubectl run too-big --image=nginx -n lab-space \
  --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx","resources":{"requests":{"cpu":"10","memory":"10Gi"}}}]}}'
```

Типичная ошибка:

```text
Error: exceeded quota: mem-cpu-quota, requested: requests.cpu=10, used: ..., limited: requests.cpu=4
```

Pod **не создастся** - квота проверяется на **admission** (create/update).

**Связка в одном предложении:** ResourceQuota - «бюджет команды на namespace»; LimitRange - «каждый Pod/container в допустимых рамках»; requests/limits в Pod - «сколько workload забирает из бюджета».

---

### 5.5. Проверка квот и потребления

```bash
NS=lab-space

# сам namespace - привязанные quota/limitrange
kubectl get ns $NS
kubectl describe ns $NS

# квота: Used / Hard
kubectl get resourcequota -n $NS
kubectl describe resourcequota mem-cpu-quota -n $NS

# limitrange
kubectl get limitrange -n $NS
kubectl describe limitrange -n $NS

# что съедает квоту
kubectl get pods -n $NS -o custom-columns=\
NAME:.metadata.name,\
CPU_REQ:.spec.containers[*].resources.requests.cpu,\
MEM_REQ:.spec.containers[*].resources.requests.memory

kubectl top pods -n $NS    # фактическое CPU/RAM; нужен metrics-server
```

Пример вывода `describe resourcequota`:

```text
Resource                Used   Hard
--------                ----   ----
limits.cpu              1      8
limits.memory           512Mi  16Gi
limits.ephemeral-storage 2Gi   20Gi
pods                    3      20
requests.cpu            300m   4
requests.memory         384Mi  8Gi
requests.ephemeral-storage 1Gi  10Gi
requests.storage        5Gi    50Gi
```

Если `No resources found` для ResourceQuota - квот **не настроено** (нормально для чистого Minikube lab).

Удалить учебную квоту после эксперимента:

```bash
kubectl delete resourcequota mem-cpu-quota -n lab-space
kubectl delete limitrange lab-space-limits -n lab-space
```
