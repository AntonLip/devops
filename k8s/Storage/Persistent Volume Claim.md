# Persistent Volume Claim

## Цель

Понять **binding** PVC к PV, **selector**, **capacity**, **accessModes**; на практике создать **несколько PVC** в `storage-.`, увидеть Bound vs Pending и подключить тома к Pod.

---

## Теория

### Зачем PVC

Developer не должен знать, NFS это или EBS, путь на server или volume ID. Developer создаёт **PVC** - декларативный запрос:
«Дай мне ≥1Gi, RWO, storage class manual».
Admin/CSI обеспечивает matching **PV** или создаёт динамически.

```
Namespace: storage-.
┌─────────────────────────────────────┐
│  PVC pvc-.-static                 │
│  request: 2Gi, RWO, SC: manual      │
└──────────────────┬──────────────────┘
                   │ bind
                   ▼
Cluster-scoped:
┌─────────────────────────────────────┐
│  PV pv-.-static                   │
│  capacity: 2Gi, RWO, SC: manual       │
└─────────────────────────────────────┘
```

---

### Структура PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-.-static
  namespace: storage-.
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual      # "" = only PV without SC or default SC
  volumeName: pv-.-static     # optional - pre-bind конкретный PV
  selector:                     # optional - match.els на PV
    match.els:
      tier: secondary
  resources:
    requests:
      storage: 2Gi
```

| Поле | Назначение |
|------|------------|
| `resources.requests.storage` | Минимальный размер; PV capacity must be ≥ |
| `accessModes` | Должен быть subset PV accessModes |
| `storageClassName` | Filter PV / trigger dynamic provisioner |
| `volumeName` | Жёсткая привязка к PV (optional) |
| `selector` | .el selector на PV |
| `dataSource` | Clone/restore from snapshot (не на home. без CRD) |

---

### Binding - как работает

**Static provisioning** (ваш home.):

```
1. PV Avai.le in cluster
2. User creates PVC
3. PV controller finds matching PV:
   ├── storageClassName equal (or both empty)
   ├── PV capacity >= PVC request
   ├── accessModes compatible
   ├── selector match (if set)
   └── PV not already bound
4. Bind: PV.claimRef, PVC.spec.volumeName
5. Both → phase Bound
```

**Dynamic** (нет на вашем кластере):

```
PVC + StorageClass → external-provisioner → CreateVolume → PV created → Bound
```

ASCII flow:

```
 PVC created                    PV pool
     │                    ┌── Avai.le ──┐
     │                    │ pv-1  2Gi    │
     ▼                    │ pv-2  1Gi    │
 Controller scans ────────►│ pv-3  5Gi    │
     │                    └── Bound ──────┘
     │ match pv-1
     ▼
 PVC Bound ───────────────► PV Bound
```

---

### Capacity matching

| PVC request | PV capacity | Result |
|-------------|-------------|--------|
| 1Gi | 2Gi | **Bind OK** (PV больше) |
| 2Gi | 2Gi | **Bind OK** |
| 3Gi | 2Gi | **No bind** - PVC Pending |
| 10Gi | none | **Pending** (ваш pvc-.-unbound) |

PVC **не** может «отрезать» кусок PV - bind целого PV object.
**Expansion:** отдельная глава 15.4.5 (`allowVolumeExpansion` на SC).

---

### Access Modes matching
PVC request must be satisfied by PV:
- PVC: `[ReadWriteOnce]` + PV: `[ReadWriteOnce, ReadOnlyMany]` → **OK**
- PVC: `[ReadWriteMany]` + PV: `[ReadWriteOnce]` → **Fail**
**Home. hostPath PV:** только **RWO** в . manifests.

---

### Selector
Привязка по **.els** на PV:

```yaml
# PVC
selector:
  match.els:
    tier: secondary

# PV pv-.-static-2
metadata:
  .els:
    tier: secondary
```

Без selector - любой matching Avai.le PV подходит (first-fit).
**volumeName** - stronger: указать exact PV name (static pre-provisioned apps).

---

### storageClassName edge cases

| PVC SC | PV SC | Bind? |
|--------|-------|-------|
| manual | manual | Yes |
| manual | gp3 | No |
| "" (omit) | "" | Yes |
| nil vs "" | Kubernetes 1.26+ semantics | см. docs |

**No default StorageClass** на вашем кластере - PVC **без** `storageClassName` не trigger dynamic; ищет PV с `storageClassName: ""` или unset.
**Pending forever:** SC не существует, нет provisioner, нет matching PV - классический home. до ./02.

---

### Phases PVC

| Phase | Значение |
|-------|----------|
| Pending | ждёт bind или provisioning |
| Bound | volumeName установлен |
| Lost | PV deleted out-of-band (rare) |

```bash
kubectl get pvc -n storage-.
```

---

### Best practices

- Явный `storageClassName` в prod.
- Requests.storage - реальный нужный размер + headroom через expansion если включено.
- Один PVC на StatefulSet replica через **volumeClaimTemplates**.
- .els на PVC для backup tools (Velero).
- Не полагаться на Pending без monitoring - alert на Pending > N min.
- ResourceQuota на total storage requests (. `06-resourcequota-storage.yaml`).

---

### Production scenarios

| Scenario | PVC pattern |
|----------|-------------|
| PostgreSQL StatefulSet | vct: 20Gi RWO gp3 |
| Shared config | ConfigMap, не PVC |
| ReadWriteMany shared files | EFS PVC RWX |
| Git. artifacts | S3 или RWO + backup |
| Home. DB | local-path или static hostPath |

---

### Interview tips

- «PVC Pending - первые 3 проверки?» - describe pvc, get sc, get pv, events.
- «Можно ли уменьшить PVC?» - generally **no** (K8s не support shrink).
- «Размер PV 100Gi, PVC 10Gi?» - bind OK, app видит 100Gi (FS size).
- «Что если удалить PVC с Delete policy?» - PV и disk удаляются (CSI).

---

## Практика

### Цель

Применить **несколько PVC** из ./03: два Bound (2Gi + 1Gi) и один Pending (10Gi); проверить binding rules.

### Зачем

В production один namespace - десятки PVC; понимание Pending vs Bound критично для troubleshooting.

### Предусловия

```bash
kubectl apply -f ./storage-home./00-namespace.yaml
kubectl apply -f ./storage-home./02-pv-static-hostpath.yaml
```

Два PV: `pv-.-static` (2Gi) и `pv-.-static-2` (1Gi, .el `tier: secondary`).

### Шаг 1 - создать все PVC

```bash
kubectl apply -f ./storage-home./03-pvc-static.yaml
kubectl get pvc -n storage-.
kubectl get pv
```

Манифест: [`./storage-home./03-pvc-static.yaml`](./storage-home./03-pvc-static.yaml)

Содержит:
- `pvc-.-static` - 2Gi → `pv-.-static`
- `pvc-.-static-2` - 1Gi → `pv-.-static-2`
- `pvc-.-unbound` - 10Gi → **Pending** (нет PV ≥10Gi)

**Ожидаемый результат:**

```
NAME               STATUS    VOLUME            CAPACITY   STORAGECLASS
pvc-.-static     Bound     pv-.-static     2Gi        manual
pvc-.-static-2   Bound     pv-.-static-2   1Gi        manual
pvc-.-unbound    Pending   -                 -          manual
```

### Шаг 2 - диагностика Pending

```bash
kubectl describe pvc -n storage-. pvc-.-unbound
```

**Ожидаемый Events:**

```
no persistent volumes avai.le for this claim and no storage class is set up for provisioning
```

или similar - no matching PV capacity.

### Шаг 3 - selector demo (optional)

Создайте PVC с selector (отдельный apply или patch):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-.-selector
  namespace: storage-.
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  selector:
    match.els:
      tier: secondary
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc -n storage-. pvc-.-selector
# Bound → pv-.-static-2 (only PV with tier: secondary)
```

Если `pv-.-static-2` уже bound `pvc-.-static-2` - selector PVC останется Pending (demonstrates 1:1).

### Шаг 4 - mount первого PVC

```bash
kubectl apply -f ./storage-home./04-pod-with-pvc.yaml
kubectl exec -n storage-. pod-with-pvc -- sh -c 'echo from-pvc > /data/pvc.txt && cat /data/pvc.txt'
```

### Шаг 5 - второй Pod на второй PVC

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-pvc-2
  namespace: storage-.
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-.-static-2
EOF
kubectl exec -n storage-. pod-with-pvc-2 -- sh -c 'echo second-pvc > /data/test.txt'
```

### Verify

| PVC | Status | PV | Pod mount |
|-----|--------|-----|-----------|
| pvc-.-static | Bound | pv-.-static | pod-with-pvc |
| pvc-.-static-2 | Bound | pv-.-static-2 | pod-with-pvc-2 |
| pvc-.-unbound | Pending | - | - |

### Rollback

```bash
kubectl delete pod -n storage-. pod-with-pvc pod-with-pvc-2 --ignore-not-found
kubectl delete pvc -n storage-. --all
kubectl patch pv pv-.-static pv-.-static-2 -p '{"spec":{"claimRef":null}}' 2>/dev/null || true
kubectl delete pv pv-.-static pv-.-static-2 --ignore-not-found
kubectl delete pvc -n storage-. pvc-.-selector --ignore-not-found
```

---

## Что произошло внутри Kubernetes

```
apply 03-pvc-static.yaml (3 PVC objects)
        │
        ▼
For each PVC - PV controller loop:
        │
        ├── pvc-.-static (2Gi, manual)
        │       └── match pv-.-static (2Gi) → Bound
        │
        ├── pvc-.-static-2 (1Gi, manual)
        │       └── match pv-.-static-2 (1Gi) → Bound
        │
        └── pvc-.-unbound (10Gi, manual)
                └── scan: max PV 2Gi < 10Gi → Pending

Pod create with claimName
        │
        ▼
Scheduler (no topology on home.)
        │
        ▼
kubelet: WaitForAttach (N/A hostPath) → MountVolume → publish to pod
        │
        ▼
Container sees /data with PV filesystem
```

---

## Troubleshooting

| Симптом | Причина | Решение |
|---------|---------|---------|
| PVC Pending | No PV / no SC provisioner | create PV or install CSI+SC |
| PVC Pending | Capacity | reduce request or add bigger PV |
| PVC Pending | accessMode mismatch | align RWO/RWX |
| PVC Pending | selector no match | fix .els on PV |
| PVC Bound, Pod Pending | RWO mounted elsewhere | one node only for block |
| `storageclass.storage.k8s.io "x" not found` | typo in SC name | fix or create SC |
| Two PVCs one PV | impossible | 1:1 - second stays Pending |
| Lost phase | PV manually deleted | restore PV or recreate |
