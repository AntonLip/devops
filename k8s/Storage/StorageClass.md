# StorageClass

## Цель

- Понять роль **StorageClass** как шаблона dynamic provisioning
- Разобрать поля: `provisioner`, `parameters`, `reclaimPolicy`, `allowVolumeExpansion`, `volumeBindingMode`
- Сравнить **Immediate** и **WaitForFirstConsumer**
- На **Talos homelab** (сейчас **нет** SC/CSI) установить **local-path-provisioner** и применить lab StorageClass

---

## Теория

### Зачем появился StorageClass

До dynamic provisioning администратор вручную создавал **PV** под каждый запрос. Это не масштабируется: сотни PVC → сотни ручных PV.

**StorageClass (SC)** — cluster-scoped объект, который описывает:

- **кто** создаёт том (`provisioner`)
- **с какими параметрами** (`parameters`)
- **когда** привязывать том к Pod (`volumeBindingMode`)
- **что делать** при удалении PVC (`reclaimPolicy`)
- **можно ли** увеличивать размер (`allowVolumeExpansion`)

```
Разработчик                    Администратор (один раз)
     │                                │
     ▼                                ▼
   PVC                          StorageClass
     │                                │
     │         provisioner            │
     └──────────────► CSI / external provisioner
                           │
                           ▼
                    PV + backend disk
```

### StorageClass vs PV vs PVC

| Объект | Scope | Кто создаёт | Роль |
|--------|-------|-------------|------|
| **StorageClass** | Cluster | Admin | Шаблон / политика |
| **PV** | Cluster | Provisioner или Admin | Реальный том |
| **PVC** | Namespace | Developer | Заявка приложения |

**Static:** Admin создаёт PV → PVC привязывается к существующему PV.
**Dynamic:** PVC ссылается на SC → provisioner **создаёт** PV автоматически.

### Поле provisioner

`provisioner` — имя драйвера, который обрабатывает PVC с этим `storageClassName`.

```
StorageClass.spec.provisioner
         │
         ├─► ebs.csi.aws.com          (AWS EBS CSI)
         ├─► nfs.csi.k8s.io           (NFS CSI)
         ├─► rancher.io/local-path    (local-path external provisioner)
         └─► kubernetes.io/no-provisioner  (только static PV)
```

**Важно:** значение `provisioner` должно совпадать с тем, что слушает драйвер:
- для **CSI** — имя из объекта `CSIDriver`
- для **local-path** — `rancher.io/local-path` (это **не** CSI, а legacy external provisioner)

```bash
kubectl get storageclass   # No resources found
kubectl get csidrivers     # No resources found
```

### Поле parameters

`parameters` — key/value для backend. Интерпретация зависит от provisioner.

| Provisioner | Пример parameters | Смысл |
|-------------|-------------------|-------|
| `ebs.csi.aws.com` | `type: gp3`, `iops: "3000"` | Тип диска AWS |
| `nfs.csi.k8s.io` | `server: nfs.example.com` | NFS server |
| `rancher.io/local-path` | *(обычно пусто)* | Путь задаётся в ConfigMap provisioner |

```yaml
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
```

Provisioner читает parameters при `CreateVolume` и передаёт в cloud API или локальный скрипт.

### reclaimPolicy

Определяет судьбу **динамически созданного** PV после удаления PVC.

| Policy | Поведение | Когда использовать |
|--------|-----------|-------------------|
| **Delete** | PV удаляется, backend том уничтожается | Dev, lab, ephemeral data |
| **Retain** | PV → `Released`, данные на диске остаются | Production, compliance |

```
PVC удалён
    │
    ▼
reclaimPolicy?
    │
    ├─ Delete ──► PV deleted ──► backend disk deleted
    │
    └─ Retain ──► PV status=Released ──► admin cleanup вручную
```

**Static PV** имеет собственное поле `persistentVolumeReclaimPolicy` на объекте PV — оно **перекрывает** SC для static сценария.
**На собеседовании:** «PVC удалили, данные остались» → `Retain` или failed delete в cloud.

### allowVolumeExpansion

```yaml
allowVolumeExpansion: true
```

Разрешает увеличение `spec.resources.requests.storage` в PVC (только **увеличение**, не уменьшение).
Требует поддержки:

1. StorageClass: `allowVolumeExpansion: true`
2. Provisioner / CSI: `ControllerExpandVolume` + `NodeExpandVolume`
3. Файловая система: resize2fs, xfs_growfs

```
kubectl patch pvc ... storage: 2Gi
         │
         ▼
external-resizer / expander controller
         │
         ▼
Backend volume grow
         │
         ▼
Node: filesystem resize
```

local-path v0.0.30 поддерживает expansion на homelab — пригодится в следующих главах.

### volumeBindingMode: Immediate vs WaitForFirstConsumer

Критично для **зональных** дисков (EBS, Azure Disk, GCE PD).

#### Immediate

```
t=0  User создаёт PVC
         │
         ▼
t=1  Provisioner сразу создаёт PV + disk
         │
         ▼
t=2  PVC = Bound (Pod ещё нет!)
         │
         ▼
t=3  Pod scheduled на node в zone-B
         │
         ▼
     DISK в zone-A ──► Multi-Attach / zone mismatch ──► Pod Pending
```

Диск создаётся **до** schedule Pod. На multi-AZ кластере диск может оказаться не в той зоне.

#### WaitForFirstConsumer (WFFC)

```
t=0  User создаёт PVC
         │
         ▼
t=1  PVC = Pending (volume binding delayed)
         │
         ▼
t=2  Pod создан, scheduler выбирает node (zone-A)
         │
         ▼
t=3  Volume Binding Controller + provisioner
         │
         ▼
t=4  Disk создаётся в zone-A (topology-aware)
         │
         ▼
t=5  PVC = Bound, Pod = Running
```

**WFFC** откладывает provisioning до момента, когда известен **целевой node** (и его topology labels).

#### Сравнение

| | Immediate | WaitForFirstConsumer |
|---|-----------|---------------------|
| Когда создаётся PV | Сразу при PVC | После schedule Pod |
| PVC до Pod | Bound | Pending (нормально!) |
| Topology | Риск mismatch | Диск в нужной zone |
| Homelab без AZ | Оба работают | WFFC всё равно полезен на multi-node |

### Default StorageClass

```yaml
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

PVC **без** `storageClassName` получает default SC.

```bash
kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

**Best practice:** один default SC на кластер; для production БД — явный `storageClassName: gp3-retain`.

### Полная ASCII-архитектура StorageClass

```
┌─────────────────────────────────────────────────────────────┐
│                     StorageClass (cluster)                   │
│  provisioner: rancher.io/local-path                         │
│  reclaimPolicy: Delete                                      │
│  volumeBindingMode: WaitForFirstConsumer                    │
│  allowVolumeExpansion: true                                   │
│  parameters: { ... }                                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
         PVC.spec.storageClassName = "local-path"
                           │
                           ▼
              ┌────────────────────────┐
              │  external-provisioner  │  (local-path Deployment)
              │  или CSI sidecar       │
              └───────────┬────────────┘
                          │
                          ▼
              ┌────────────────────────┐
              │  CreateVolume / PV   │
              └───────────┬────────────┘
                          │
                          ▼
              ┌────────────────────────┐
              │  PV (cluster)          │
              │  status: Bound         │
              └────────────────────────┘
```

### Ограничения и best practices

| Практика | Почему |
|----------|--------|
| WFFC для зональных дисков | Избегает zone mismatch |
| Retain для prod databases | Защита от случайного delete |
| Явный storageClassName | Не полагаться на default в prod |
| Не менять provisioner на живом SC | Создайте новый SC, мигрируйте workload |
| Документировать parameters | `gp3` vs `gp2`, encryption, IOPS |

### Типичные ошибки

- PVC `Pending` + SC не существует → provisioner не найден
- `storageClassName: ""` + нет default SC → PVC зависнет
- Immediate + EBS + multi-AZ → Pod не стартует
- Ожидание RWX от local-path / EBS → только RWO

---

## Практика

### Цель

Установить **local-path-provisioner** на homelab и применить учебный StorageClass из lab.


### Предусловия

```bash
kubectl get nodes
kubectl get sc,pv,pvc -A          # должно быть пусто
kubectl get pods -A | grep -i local-path   # ничего
```

### Шаг 1. Namespace storage-lab

```bash
cd "storage-homelab"
kubectl apply -f 00-namespace.yaml
kubectl get ns storage-lab
```

### Шаг 2. Установка local-path-provisioner

Официальный манифест v0.0.30 (включает namespace, RBAC, Deployment, **встроенный** SC `local-path`):

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

Проверка:

```bash
kubectl get pods -n local-path-storage
kubectl get storageclass
kubectl describe sc local-path
```

Ожидаемо:

```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
local-path             rancher.io/local-path   Delete          WaitForFirstConsumer   <unset>
```

```
local-path-storage   local-path-provisioner-xxxxx   1/1   Running
```

### Шаг 3. Учебный StorageClass из lab

Манифест upstream создаёт SC `local-path`. Lab-файл демонстрирует **явную** конфигурацию и `allowVolumeExpansion: true`:

```bash
kubectl apply -f 01-storageclass-local-path.yaml
kubectl get sc local-path -o yaml
```

Содержимое lab-файла:

```yaml
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

> **Примечание:** повторное применение обновит существующий SC. Поле `is-default-class: "false"` — default не включаем намеренно (явный выбор SC в lab).

### Шаг 4. Аудит после установки

```bash
kubectl get sc -o wide
kubectl get pods -n local-path-storage -o wide
kubectl get configmap -n local-path-storage local-path-config -o yaml
kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=50
```

В ConfigMap `local-path-config` путь по умолчанию: `/opt/local-path-provisioner` на node.

### Шаг 5. Сравнение Immediate vs WFFC (теория на живом SC)

```bash
# Текущий режим
kubectl get sc local-path -o jsonpath='{.volumeBindingMode}{"\n"}'
# WaitForFirstConsumer

# Immediate создал бы PV до Pod — на homelab с 4 nodes риск:
# диск на worker-2, Pod на worker-3 → attach fail для block storage
# local-path создаёт hostPath на конкретном node → WFFC обязателен
```

### Ожидаемый результат

| Проверка | Ожидание |
|----------|----------|
| Pod `local-path-provisioner` | Running |
| SC `local-path` | provisioner=`rancher.io/local-path`, WFFC |
| `kubectl get csidrivers` | **пусто** — local-path не CSI |
| Namespace `storage-lab` | Active |

### Откат

```bash
# Удалить только lab SC (upstream SC вернётся при re-apply upstream)
kubectl delete -f 01-storageclass-local-path.yaml

# Полное удаление provisioner (осторожно — удалит dynamic PV с reclaim Delete)
kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

---

## Что произошло внутри Kubernetes

### Установка local-path

```
kubectl apply local-path-storage.yaml
         │
         ▼
API Server: создаёт Namespace, SA, RBAC, Deployment, ConfigMap, StorageClass
         │
         ▼
Deployment controller: Pod local-path-provisioner на одном из nodes
         │
         ▼
local-path-provisioner стартует
         │
         ├─ watch: PVC с provisioner=rancher.io/local-path
         ├─ watch: PV, Node, StorageClass
         └─ config: nodePathMap → /opt/local-path-provisioner
```

### Применение lab StorageClass

```
kubectl apply 01-storageclass-local-path.yaml
         │
         ▼
API Server: update StorageClass "local-path"
         │
         ▼
allowVolumeExpansion: true записан в etcd
         │
         ▼
Следующие PVC с storageClassName: local-path наследуют политику
```

### WFFC при будущем PVC (превью)

```
PVC created (storageClassName: local-path)
         │
         ▼
volumeBindingMode = WaitForFirstConsumer
         │
         ▼
PVC status = Pending (это нормально!)
         │
         ▼
Pod scheduled → известен node
         │
         ▼
provisioner: helper-pod на node → mkdir /opt/local-path-provisioner/pvc-xxx
         │
         ▼
PV created + Bound to PVC
```

---

## Troubleshooting

| Симптом | Причина | Диагностика | Fix |
|---------|---------|-------------|-----|
| `kubectl get sc` пусто | Provisioner не установлен | `kubectl get pods -A \| grep local-path` | `kubectl apply` upstream manifest |
| Pod provisioner `CrashLoopBackOff` | RBAC, config | `kubectl logs -n local-path-storage ...` | Проверить ConfigMap, SA |
| PVC `Pending` + `no StorageClass` | SC не найден | `kubectl describe pvc` Events | Создать/установить SC |
| PVC `Pending` + `waiting for first consumer` | WFFC, нет Pod | `kubectl get pods` | Создать Pod с volumeMount |
| `provisioning failed` | Нет места на node, path | logs provisioner + helper-pod | Освободить disk, проверить path |
| Два default SC | Аннотация на двух SC | `kubectl get sc -o yaml \| grep default` | Снять аннотацию с одного |
| Expansion не работает | `allowVolumeExpansion: false` | `kubectl get sc -o yaml` | Patch SC + driver support |

```bash
# Быстрая диагностика SC
kubectl describe sc local-path
kubectl get events -A --field-selector reason=ProvisioningFailed
kubectl logs -n local-path-storage deployment/local-path-provisioner --tail=100
```
