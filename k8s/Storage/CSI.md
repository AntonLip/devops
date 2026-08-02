# CSI (Container Storage Interface)

## Цель

- Понять **историю**: in-tree drivers → CSI
- Разобрать **полную архитектуру CSI**: Identity, Controller, Node plugins
- Изучить **все sidecars** и их роль в lifecycle тома
- Проследить **жизненный цикл** тома от PVC до mount в контейнер

---

## Теория

### Зачем появился CSI

**Проблема in-tree (до K8s 1.13):**

Драйверы хранилища были **вшиты в код** Kubernetes (`kubernetes/kubernetes`):

```
kubernetes/kubernetes/pkg/volume/
  ├── aws_ebs/
  ├── gce_pd/
  ├── azure_disk/
  ├── nfs/
  └── ...
```

| Проблема in-tree | Последствие |
|------------------|-------------|
| Релиз драйвера = релиз K8s | Ждать 3–4 месяца между версиями |
| Vendor не контролирует код | Багфикс AWS зависит от SIG-Storage |
| Разные API на каждый backend | Сложно унифицировать |
| Безопасность | Компромисс драйвера = компромисс control plane |

**CSI (Container Storage Interface)** - открытый стандарт gRPC API между **оркестратором** (Kubernetes) и **storage vendor**.

```
До CSI:
  K8s release ──► in-tree driver code ──► Cloud API

После CSI:
  K8s release ──► sidecars (generic) ──► CSI plugin (vendor image) ──► Cloud API
```

In-tree драйверы **deprecated** с 1.21, **removed** в 1.31+. Production = только CSI (или legacy provisioners вроде local-path для lab).

### Три CSI сервиса (gRPC)

Каждый CSI driver реализует до трёх gRPC-сервисов:

```
┌─────────────────────────────────────────────────────────────┐
│                    CSI Plugin (один бинарь)                  │
├─────────────────────────────────────────────────────────────┤
│  Identity Server     │  Controller Server  │  Node Server   │
│  ─────────────────   │  ─────────────────  │  ────────────  │
│  GetPluginInfo       │  CreateVolume       │  NodeStage     │
│  GetPluginCapabilities│ DeleteVolume       │  NodeUnstage   │
│  Probe               │  ControllerPublish  │  NodePublish   │
│                      │  ControllerUnpublish│  NodeUnpublish │
│                      │  ValidateVolumeCap  │  GetVolumeStats│
│                      │  ListVolumes        │  NodeExpand    │
│                      │  CreateSnapshot     │                │
│                      │  ControllerExpand   │                │
└─────────────────────────────────────────────────────────────┘
```

#### Identity Plugin

Отвечает на вопрос «кто ты и что умеешь»:

- `GetPluginInfo` - имя, версия (`ebs.csi.aws.com`)
- `GetPluginCapabilities` - controller service? snapshot? clone?
- `Probe` - health check

#### Controller Plugin

**Cluster-level** операции - не привязан к конкретному node:

| RPC | Когда вызывается |
|-----|------------------|
| `CreateVolume` | PVC → dynamic provisioning |
| `DeleteVolume` | PV deleted, reclaim Delete |
| `ControllerPublishVolume` | Attach диска к node |
| `ControllerUnpublishVolume` | Detach |
| `CreateSnapshot` | VolumeSnapshot создан |
| `DeleteSnapshot` | Snapshot удалён |
| `ControllerExpandVolume` | PVC resize |
| `ValidateVolumeCapabilities` | Проверка access mode / capability |

Controller plugin обычно в **Deployment** (2+ replicas, leader election).

#### Node Plugin

**Node-level** операции - на каждой машине:

| RPC | Когда вызывается |
|-----|------------------|
| `NodeStageVolume` | Форматирование + mount в global path на node |
| `NodeUnstageVolume` | Unmount global path |
| `NodePublishVolume` | Bind mount в pod directory |
| `NodeUnpublishVolume` | Unmount из pod |
| `NodeGetVolumeStats` | Метрики (usage, inodes) |
| `NodeExpandVolume` | FS resize после controller expand |

Node plugin - **DaemonSet** на всех nodes.

### Полная архитектура CSI в Kubernetes

```
                         Kubernetes Control Plane
┌────────────────────────────────────────────────────────────────────┐
│  API Server                                                        │
│    │                                                               │
│    ├── PVC, PV, StorageClass, VolumeAttachment, VolumeSnapshot    │
│    │                                                               │
│    ├── persistentvolume-controller                                 │
│    ├── attach-detach-controller                                    │
│    ├── persistentvolume-expander-controller                        │
│    └── volume-scheduler-binding (WFFC)                             │
└────────────────────────────┬───────────────────────────────────────┘
                             │ watch/list
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ external-       │ │ external-       │ │ external-       │
│ provisioner     │ │ attacher        │ │ resizer         │
│ (sidecar)       │ │ (sidecar)       │ │ (sidecar)       │
└────────┬────────┘ └────────┬────────┘ └────────┬────────┘
         │ gRPC              │ gRPC              │ gRPC
         ▼                   ▼                   ▼
┌────────────────────────────────────────────────────────────────────┐
│              CSI Controller Plugin (Deployment)                     │
│              ebs-plugin / nfs-plugin / ...                          │
└────────────────────────────┬───────────────────────────────────────┘
                             │ Cloud / Storage API
                             ▼
                    ┌─────────────────┐
                    │  AWS EBS / NFS  │
                    │  Ceph / SAN     │
                    └─────────────────┘

         Node (worker-1)
┌────────────────────────────────────────────────────────────────────┐
│  kubelet                                                           │
│    │                                                               │
│    ├── VolumeManager (реконсиляция volumes)                         │
│    │                                                               │
│    └── CSI Plugin Registrar (node-driver-registrar)                │
│              │ gRPC via Unix socket                                │
│              ▼                                                     │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  CSI Node Plugin (DaemonSet pod)                             │  │
│  │  /var/lib/kubelet/plugins/ebs.csi.aws.com/csi.sock          │  │
│  └─────────────────────────────────────────────────────────────┘  │
│              │                                                     │
│              ▼                                                     │
│  /var/lib/kubelet/pods/<pod-uid>/volumes/...  ──► Container mount │
└────────────────────────────────────────────────────────────────────┘
```

### Все CSI Sidecars

Sidecars - **отдельные контейнеры**, которые связывают Kubernetes API с gRPC CSI. Разрабатываются SIG-Storage (`kubernetes-csi` org).

| Sidecar | Образ (пример) | Роль | Watch / Trigger |
|---------|----------------|------|-----------------|
| **external-provisioner** | `csi-provisioner` | PVC → `CreateVolume` → PV | PVC с подходящим provisioner |
| **external-attacher** | `csi-attacher` | VolumeAttachment → `ControllerPublish` | VolumeAttachment CR |
| **external-resizer** | `csi-resizer` | PVC size↑ → `ControllerExpand` | PVC spec.resources |
| **external-snapshotter** | `csi-snapshotter` | VolumeSnapshot → `CreateSnapshot` | VolumeSnapshot CR |
| **external-snapshot-controller** | `snapshot-controller` | CRD lifecycle (не gRPC) | VolumeSnapshot CRD |
| **node-driver-registrar** | `csi-node-driver-registrar` | Регистрация socket в kubelet | Старт node pod |
| **livenessprobe** | `csi-livenessprobe` | Health CSI через socket | Probe gRPC |

#### external-provisioner (детально)

```
Watch: PVC (storageClassName → provisioner match)
         │
         ▼
Проверка: PVC не bound, provisioner совпадает
         │
         ▼
WFFC? ──► ждать Pod с selected node topology
         │
         ▼
gRPC CreateVolume(size, parameters, accessibilityRequirements)
         │
         ▼
Создать PV object в API Server
         │
         ▼
Patch PVC: volumeName = pv-name, status = Bound
```

Флаги: `--leader-election`, `--timeout`, `--extra-create-metadata`.

#### external-attacher (детально)

```
attach-detach-controller создаёт VolumeAttachment
         │
         ▼
external-attacher видит VolumeAttachment с needsAttachment=true
         │
         ▼
gRPC ControllerPublishVolume(volumeID, nodeID)
         │
         ▼
Cloud: attach disk to EC2 instance
         │
         ▼
Patch VolumeAttachment: attached=true
```

Без attacher block volumes **не примонтируются** на node.

#### external-resizer

```
PVC spec.resources.requests.storage увеличен
         │
         ▼
resizer → gRPC ControllerExpandVolume
         │
         ▼
Cloud: modify volume size
         │
         ▼
Node: NodeExpandVolume (filesystem grow)
```

Требует `allowVolumeExpansion: true` на SC.

#### external-snapshotter + snapshot-controller

```
VolumeSnapshot created
         │
         ▼
snapshot-controller: validate, set ReadyToUse
         │
         ▼
csi-snapshotter → gRPC CreateSnapshot
         │
         ▼
VolumeSnapshotContent с snapshotHandle
```

#### node-driver-registrar

```
Старт CSI Node pod
         │
         ▼
registrar: --kubelet-registration-path=/var/lib/kubelet/plugins/.../csi.sock
         │
         ▼
kubelet знает о драйвере → может вызывать NodePublish
```

#### livenessprobe

Проверяет gRPC `Probe` на CSI socket. При fail - kubelet перезапускает pod (с `livenessProbe` в pod spec).

### Kubernetes CRD / объекты CSI

| Объект | API group | Роль |
|--------|-----------|------|
| **CSIDriver** | `storage.k8s.io` | Регистрация драйвера, attachRequired, podInfoOnMount |
| **CSINode** | `storage.k8s.io` | Какие драйверы на node (автозаполняется) |
| **VolumeAttachment** | `storage.k8s.io` | Attach/detach state |
| **VolumeSnapshot** | `snapshot.storage.k8s.io` | Запрос snapshot |
| **VolumeSnapshotClass** | `snapshot.storage.k8s.io` | Параметры snapshot |
| **VolumeSnapshotContent** | `snapshot.storage.k8s.io` | Реальный snapshot |

#### CSIDriver важные поля

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: ebs.csi.aws.com
spec:
  attachRequired: true        # false для NFS-like (no attach)
  podInfoOnMount: false
  volumeLifecycleModes:
    - Persistent
  fsGroupPolicy: File         # chown при fsGroup в pod securityContext
```

### Полный жизненный цикл тома (CSI)

#### Фаза 1: Provisioning

```
User: kubectl apply PVC (storageClassName: gp3)
         │
         ▼
API Server: PVC записан, status=Pending
         │
         ▼
external-provisioner: match SC.provisioner == CSIDriver.name
         │
         ▼
[WFFC] volume-scheduler-binding: ждёт Pod
         │
         ▼
gRPC CreateVolume
         │
         ▼
AWS: CreateVolume (gp3, 10Gi, zone=eu-central-1a)
         │
         ▼
PV created: volumeHandle=vol-0abc..., nodeAffinity zone=1a
         │
         ▼
PVC Bound
```

#### Фаза 2: Scheduling + Binding

```
Pod created with PVC
         │
         ▼
Scheduler: учитывает nodeAffinity PV + resources
         │
         ▼
Pod assigned to worker-1 (zone 1a)
         │
         ▼
[WFFC] provisioning завершён (если ещё не был)
```

#### Фаза 3: Attach

```
kubelet: Pod assigned, нужен volume
         │
         ▼
attach-detach-controller: VolumeAttachment для vol-0abc + worker-1
         │
         ▼
external-attacher: ControllerPublishVolume(vol, worker-1)
         │
         ▼
AWS: AttachVolume vol-0abc → i-instance-worker1
         │
         ▼
VolumeAttachment.attached = true
```

#### Фаза 4: Mount (Node)

```
kubelet VolumeManager
         │
         ▼
CSI Node: NodeStageVolume
  → mkfs (если новый) + mount /dev/xvdf → /var/lib/kubelet/.../globalmount
         │
         ▼
CSI Node: NodePublishVolume
  → bind mount globalmount → /var/lib/kubelet/pods/<uid>/volumes/.../mount
         │
         ▼
Container start: /data доступен приложению
```

#### Фаза 5: Delete

```
kubectl delete PVC (reclaimPolicy: Delete)
         │
         ▼
PV finalizer → external-provisioner
         │
         ▼
Pod terminated → NodeUnpublish → NodeUnstage
         │
         ▼
ControllerUnpublish (detach)
         │
         ▼
gRPC DeleteVolume
         │
         ▼
AWS: DeleteVolume vol-0abc
         │
         ▼
PV удалён из API
```

### local-path vs CSI на homelab

**Важно для практики:** [local-path-provisioner](https://github.com/rancher/local-path-provisioner) v0.0.30 - это **legacy external provisioner**, **не** CSI driver.

```
CSI (EBS):
  PVC → csi-provisioner → gRPC → ebs-plugin → AWS API
  Pod → csi-attacher → attach → csi-node → mount

local-path (homelab):
  PVC → local-path-provisioner (один Deployment)
       → helper-pod на node → mkdir + hostPath PV
  Pod → kubelet mount hostPath (без attach/detach)
```

| | CSI (EBS) | local-path |
|---|-----------|------------|
| CSIDriver CR | Да | **Нет** |
| Sidecars | 4–6 контейнеров | **Нет** |
| VolumeAttachment | Да | **Нет** |
| Attach/Detach | Да | **Нет** (hostPath) |
| Topology | AZ-aware | Node-aware (WFFC) |

На homelab вы **учите CSI теорию**, а **практику** делаете на local-path + понимаете, что полноценный CSI появится при установке Longhorn, Rook-Ceph, или на EKS.

### In-tree → CSI миграция (историческая справка)

```
Phase 1: In-tree only
Phase 2: In-tree + CSI side-by-side (feature gate CSIMigration)
Phase 3: CSI default, in-tree deprecated
Phase 4: In-tree removed (1.31+)
```

Для AWS: `ebs.csi.aws.com` заменил `kubernetes.io/aws-ebs`.

### Производительность и ограничения

| Тема | Деталь |
|------|--------|
| **Attach limit** | У EC2 instance type лимит EBS attachments (например 27) |
| **Cold start** | CreateVolume 1–30 сек; первый mount дольше |
| **Leader election** | Один active provisioner/attacher при HA Deployment |
| **Socket** | CSI общается через Unix socket в `/var/lib/kubelet/plugins/` |
| **SELinux/AppArmor** | Node plugin нуждается в privileged или capabilities |
| **Talos** | CSI node pods требуют mount propagation, hostPath - проверяйте vendor docs |

### Best practices production

- Пиннить версии sidecars + driver (совместимость в [matrix](https://kubernetes-csi.github.io/docs/sidecar-containers.html))
- IRSA / workload identity вместо static cloud keys
- Мониторинг: CSI operation latency, `kubelet_volume_stats`
- Отдельные SC: `gp3-fast`, `gp3-retain`, `efs-shared`
- `PodDisruptionBudget` на controller Deployment
- Тестировать snapshot restore **до** аварии

### Типичные ошибки

| Ошибка | Причина |
|--------|---------|
| PVC Pending forever | Нет provisioner, wrong SC, WFFC без Pod |
| `FailedAttachVolume` | Attacher down, zone mismatch, attach limit |
| `FailedMount` | Node plugin, FS corrupt, wrong fstype |
| Multi-Attach error | RWO + второй node |
| Snapshot Pending | CRD не установлен, нет VolumeSnapshotClass |
| Driver not registered on node | node-driver-registrar fail, kubelet restart needed |

---

## Практика

### Цель

### Предусловия

```bash
kubectl get pods -n local-path-storage
kubectl get sc local-path
```

### Шаг 1. Подтвердить: local-path - не CSI

```bash
kubectl get csidrivers
kubectl get csinodes
kubectl get volumeattachments
```

Ожидаемо на homelab **до** установки CSI-драйвера - всё пусто. Это нормально.

### Шаг 2. Найти provisioner pods

```bash
kubectl get pods -n local-path-storage -o wide
kubectl describe deployment -n local-path-storage local-path-provisioner
kubectl get sa,role,clusterrole -n local-path-storage
```

ASCII того, что вы видите:

```
namespace: local-path-storage
    │
    └── Deployment: local-path-provisioner (replicas=1)
            │
            └── Pod: local-path-provisioner-xxxxx
                    │
                    └── container: local-path-provisioner:v0.0.30
                            │
                            ├── watch PVC (rancher.io/local-path)
                            ├── create helper-pod (setup script)
                            └── create/delete PV (hostPath)
```

### Шаг 3. Логи provisioner

```bash
kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=100
kubectl logs -n local-path-storage -l app=local-path-provisioner -f
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-csi-demo
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 500Mi
EOF
```

В логах provisioner ищите:

- `create PVC ...`
- `creating volume ...`
- `helper pod` / `helper-pod`

```bash
kubectl get pods -n local-path-storage
kubectl logs -n local-path-storage helper-pod-<suffix>   # если helper pod ещё жив
```

### Шаг 4. «Attacher» на homelab - не применимо

```bash
kubectl get volumeattachments
# No resources - local-path не использует attach
```

Для **настоящего CSI** (справочные команды на EKS/Longhorn):

```bash
# Пример EBS CSI
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n kube-system -l app=ebs-csi-node

# Логи sidecars
kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner --tail=50
kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-attacher --tail=50
kubectl logs -n kube-system -l app=ebs-csi-controller -c ebs-plugin --tail=50
kubectl logs -n kube-system -l app=ebs-csi-node -c ebs-plugin --tail=50
```

### Шаг 5. Карта контейнеров в полноценном CSI (reference)

Типичный `ebs-csi-controller` pod:

```
Pod: ebs-csi-controller-xxx (kube-system)
├── csi-provisioner      ← sidecar
├── csi-attacher         ← sidecar
├── csi-resizer          ← sidecar
├── csi-snapshotter      ← sidecar (опционально)
├── ebs-plugin           ← CSI controller gRPC
└── liveness-probe       ← sidecar

Pod: ebs-csi-node-xxx (DaemonSet, каждый node)
├── ebs-plugin           ← CSI node gRPC
├── node-driver-registrar← sidecar
└── liveness-probe       ← sidecar
```

Сопоставьте с тем, что видите на homelab:

| CSI компонент | local-path homelab |
|---------------|-------------------|
| csi-provisioner | **local-path-provisioner** (один контейнер) |
| csi-attacher | **отсутствует** |
| csi-node plugin | **отсутствует** (hostPath) |
| node-driver-registrar | **отсутствует** |

### Шаг 6. ConfigMap - «параметры» local-path

```bash
kubectl get configmap -n local-path-storage local-path-config -o yaml
```

Здесь `nodePathMap`, `setup`/`teardown` скрипты - аналог `parameters` + backend logic в CSI.

### Шаг 7. Cleanup demo PVC

```bash
kubectl delete pvc pvc-csi-demo -n storage-lab
kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=20
# teardown: rm -rf volume dir
```

### Ожидаемый результат

| Проверка | Homelab |
|----------|---------|
| `csidrivers` | пусто |
| `local-path-provisioner` | Running, логи показывают watch/provision |
| `volumeattachments` | пусто |
| Понимание | Можете объяснить 6 sidecars и где они в EBS |

---

## Что произошло внутри Kubernetes

### Dynamic PVC через local-path (упрощённый путь)

```
PVC pvc-csi-demo created (storage-lab, sc=local-path)
         │
         ▼
API Server: PVC Pending, annotation volume.kubernetes.io/selected-node (после Pod)
         │
         ▼
local-path-provisioner (informer on PVC)
         │
         ▼
WFFC: ждёт Pod ИЛИ selected-node annotation
         │
         ▼
Создаёт helper-pod на target node
         │
         ▼
helper: mkdir -p /opt/local-path-provisioner/pvc-<uuid>
         │
         ▼
PV created (hostPath, nodeAffinity на node)
         │
         ▼
PVC Bound (patch status + claimRef на PV)
```

### Полный CSI путь (reference, EBS)

```
PVC created
    → csi-provisioner → CreateVolume → PV
Pod scheduled
    → attach-detach → VolumeAttachment
    → csi-attacher → ControllerPublishVolume
kubelet
    → csi-node → NodeStageVolume → NodePublishVolume
Container
    → bind mount в mountPath
```

### Delete path local-path

```
kubectl delete PVC
         │
         ▼
PV protection finalizer
         │
         ▼
provisioner: helper-pod teardown (rm -rf)
         │
         ▼
Delete PV (reclaimPolicy: Delete)
```

---

## Troubleshooting

| Симптом | CSI контекст | local-path homelab |
|---------|--------------|-------------------|
| PVC Pending `ExternalProvisioning` | csi-provisioner не лидер / crash | provisioner pod down |
| `FailedAttachVolume` | attacher, zone, limit | **N/A** - нет attach |
| `Driver not found` | CSINode не зарегистрирован | **N/A** |
| `rpc error: deadline exceeded` | Cloud API latency / creds | helper-pod timeout, disk full |
| Controller 0/N Running | Image pull, RBAC, leader election | Single replica - один pod |
| Node pod CrashLoop | Socket path, privileged | **N/A** |
| Snapshot Pending | CRD/snapshotter missing | CRD нет на homelab |

```bash
# Универсальный чеклист CSI
kubectl get csidrivers
kubectl get csinodes
kubectl get volumeattachments
kubectl get pods -A | grep -iE 'csi|provisioner'
kubectl describe pvc <name> -n <ns>
kubectl describe volumeattachment
kubectl get events -A --sort-by='.lastTimestamp' | grep -i volume
```

**Порядок диагностики:**

1. PVC Events → provisioner работает?
2. PV создан? → если нет, логи provisioner
3. Pod Pending? → VolumeAttachment / Multi-Attach
4. Pod Running, mount fail? → node plugin logs
5. Inside pod `df` → expand / FS issue

