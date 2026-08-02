# Persistent Volume

## Цель

Понять **жизненный цикл PV**, **reclaimPolicy**, **node affinity**; на практике создать **static hostPath PV** на Talos home., привязать PVC, удалить PVC и наблюдать фазу **Released**.

---

## Теория

### Зачем появился PersistentVolume
До PV админы монтировали NFS/hostPath **напрямую** в Pod — нет централизованного inventory, нет policy на удаление, developer видит пути на disk.
**PV** — cluster-scoped API object представляющий **кусок storage**, подготовленный админом или CSI.
**PVC** — namespace-scoped **запрос** на storage. Разделение ролей: admin — PV/SC, developer — PVC.

```
┌──────── Admin / CSI ────────┐
│  Create PV (2Gi, RWO, NFS)  │
└──────────────┬──────────────┘
               │
┌──────── Developer ──────────┐
│  Create PVC (2Gi, RWO)      │
└──────────────┬──────────────┘
               │
               ▼
         Binding controller
               │
               ▼
         PV.status.phase = Bound
         PVC.status.phase = Bound
```

---

### Структура PV

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-.-static
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:                    # home. . only
    path: /var/lib/k8s-./storage/static
    type: DirectoryOrCreate
  nodeAffinity:                # optional, critical for local/hostPath
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - worker-1
```

| Поле | Назначение |
|------|------------|
| `capacity.storage` | Размер (binding сравнивает с PVC request) |
| `accessModes` | RWO, RWX, ROX |
| `persistentVolumeReclaimPolicy` | Retain / Delete / Recycle (deprecated) |
| `storageClassName` | Группировка для binding и dynamic SC |
| `claimRef` | Заполняется при bind — ссылка на PVC |
| `nodeAffinity` | Ограничение nodes для local/hostPath volumes |

---

### Access Modes

| Mode | Abbrev | Значение |
|------|--------|----------|
| ReadWriteOnce | RWO | один node, read-write (может быть несколько pods на **том же** node) |
| ReadOnlyMany | ROX | many nodes read-only |
| ReadWriteMany | RWX | many nodes read-write (NFS, EFS) |

**Block storage (EBS, iSCSI):** обычно **RWO only**.

**На собеседовании:** RWO ≠ «только один Pod» — несколько Pod на одном node могут mount RWO (зависит от setup), но **не** на разных nodes одновременно для block.

---

### Жизненный цикл PV (phases)

```
    ┌──────────┐
    │ Avai.le │  PV создан, не привязан
    └─────┬────┘
          │ PVC match + bind
          ▼
    ┌──────────┐
    │  Bound   │  claimRef установлен
    └─────┬────┘
          │ PVC deleted
          ▼
    ┌──────────┐
    │ Released │  PV освобождён, claimRef может остаться
    └─────┬────┘
          │ reclaim policy
          ├─ Retain → manual cleanup, Avai.le после admin patch
          ├─ Delete → CSI/backend удаляет volume → PV object deleted
          └─ Recycle → rm -rf (deprecated)
```

**Avai.le → Bound:** synchronous binding controller (static) или provisioner (dynamic).
**Released + Retain:** PV **не** переиспользуется автоматически — admin must remove `claimRef` и reset phase.

---

### Reclaim Policy

| Policy | PVC deleted | Данные | PV object |
|--------|-------------|--------|-----------|
| **Retain** | PV → Released | **Сохраняются** на disk | Остаётся |
| **Delete** | provisioner удаляет backend | Удаляются (CSI) | Удаляется |
| Recycle | scrub + Avai.le | basic wipe | deprecated |

**Production:** Retain для critical data + manual lifecycle; Delete для dev/ephemeral dynamic volumes.
**Home. . PV** (`02-pv-static-hostpath.yaml`): **Retain** — безопасно для обучения, данные остаются на node.

---

### Node Affinity

**Зачем:** local disk и hostPath существуют **на конкретной node**. Scheduler должен знать, куда можно schedule Pod с этим PV.

```
PV nodeAffinity: worker-1 only
        │
        ▼
Pod с PVC → scheduler filter → только worker-1
        │
        ▼
kubelet mount hostPath с worker-1
```

**Без nodeAffinity на multi-node:** Pod может schedule на worker-2, mount fail — **Failed**.
**Topology .els:** `topology.kubernetes.io/zone` на вашем кластере **не заданы** — WFFC (WaitForFirstConsumer) менее критичен; для local storage важнее **hostname**.
**Cloud:** EBS PV имеет zone topology — scheduler + volume topology aware binding.

---

### Static vs Dynamic PV

| | Static | Dynamic |
|---|--------|---------|
| Кто создаёт PV | Admin | CSI provisioner |
| Trigger | YAML apply | PVC + StorageClass |
| Home. сейчас | **Да** (./02) | Нет SC/CSI |
| storageClassName | manual / "" | gp3, local-path |

---

### hostPath PV — ограничения home.

На **Talos bare metal** без CSI:
- path создаётся на **node где kubelet** выполняет mount;
- static PV без nodeAffinity — Pod может land на любой worker → **ошибка mount**;
- для .: один worker или добавить nodeAffinity в PV.
**Production:** hostPath PV **не** используют — local-path, NFS, Longhorn, cloud CSI.

---

### Best practices

- Явный `storageClassName` на PV и PVC (match).
- Retain + backup для irreplaceable data.
- nodeAffinity для local/hostPath.
- .el PV (`.: storage-home.`) для cleanup.
- Capacity ≥ PVC request; PV может быть больше.
- Document manual recovery для Released+Retain PV.

## Практика

### Цель

Создать static PV, привязать PVC, удалить PVC, наблюдать **Released** и понять manual reclaim.

### Предусловия

```bash
kubectl apply -f ./storage-home./00-namespace.yaml
```

### Шаг 1 — создать PV

```bash
kubectl apply -f ./storage-home./02-pv-static-hostpath.yaml
kubectl get pv pv-.-static
```

Манифест: [`./storage-home./02-pv-static-hostpath.yaml`](./storage-home./02-pv-static-hostpath.yaml)

**Ожидаемый результат:**

```
NAME            CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      STORAGECLASS
pv-.-static   2Gi        RWO            Retain           Avai.le   manual
```

### Шаг 2 — создать PVC (binding)

```bash
kubectl apply -f ./storage-home./03-pvc-static.yaml
kubectl get pv pv-.-static
kubectl get pvc -n storage-. pvc-.-static
```

Манифест: [`./storage-home./03-pvc-static.yaml`](./storage-home./03-pvc-static.yaml)

**Ожидаемый результат:**

```
PV:  STATUS Bound, CLAIM storage-./pvc-.-static
PVC: STATUS Bound, VOLUME pv-.-static
```

### Шаг 3 — записать данные через Pod

```bash
kubectl apply -f ./storage-home./04-pod-with-pvc.yaml
kubectl exec -n storage-. pod-with-pvc -- sh -c 'echo persistent-data > /data/test.txt'
kubectl exec -n storage-. pod-with-pvc -- cat /data/test.txt
```

Манифест: [`./storage-home./04-pod-with-pvc.yaml`](./storage-home./04-pod-with-pvc.yaml)

### Шаг 4 — удалить PVC, watch Released

```bash
kubectl delete pod -n storage-. pod-with-pvc
kubectl delete pvc -n storage-. pvc-.-static
kubectl get pv pv-.-static -w
```

**Ожидаемый результат:**

```
NAME            STATUS     CLAIM                          RECLAIM POLICY
pv-.-static   Released   storage-./pvc-.-static     Retain
```

`claimRef` **остаётся** — новый PVC с тем же именем **не** bind автоматически.

### Шаг 5 — manual reclaim (admin)

```bash
kubectl patch pv pv-.-static -p '{"spec":{"claimRef":null}}'
kubectl get pv pv-.-static
# STATUS → Avai.le (после patch)
```

Данные на node в `/var/lib/k8s-./storage/static/test.txt` **всё ещё есть** (Retain).

### Verify

| Шаг | STATUS PV | Данные на disk |
|-----|-----------|----------------|
| После bind | Bound | через pod |
| После delete PVC | Released | сохранены |
| После patch claimRef | Avai.le | сохранены |

### Rollback

```bash
kubectl delete pod -n storage-. pod-with-pvc --ignore-not-found
kubectl delete pvc -n storage-. pvc-.-static --ignore-not-found
kubectl delete pv pv-.-static --ignore-not-found
# опционально на node: rm -rf /var/lib/k8s-./storage/static
```

---

## Что произошло внутри Kubernetes

```
apply PV
    │
    ▼
API Server → etcd: PV phase=Avai.le

apply PVC (2Gi, RWO, manual)
    │
    ▼
PersistentVolumeController (kube-controller-manager)
    │
    ├── filter PV: Avai.le, storageClass match, capacity OK, accessMode OK
    │
    ├── bind: PV.claimRef = PVC, PV.phase = Bound
    │
    └── PVC.spec.volumeName = pv-.-static, PVC.phase = Bound

apply Pod with PVC volume
    │
    ▼
Scheduler → node (для hostPath без affinity — любой worker!)
    │
    ▼
kubelet → ValidatePodMountedVolume → mount hostPath → container /data

delete PVC
    │
    ▼
PV phase → Released (Retain: no wipe)
claimRef UID remains → blocks re-bind

patch claimRef: null
    │
    ▼
PV phase → Avai.le
```

