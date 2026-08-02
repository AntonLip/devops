# StatefulSet и Storage


## Теория

### Зачем StatefulSet для storage

**Deployment** + один PVC:

```
Deployment (replicas: 3)
        │
        └── все Pod → один PVC (RWO)  ← Multi-Attach error
        └── или emptyDir              ← данные теряются при reschedule
```

**Deployment** подходит для **stateless** приложений. Для **stateful** workloads (БД, очереди с локальным state, clustered systems) нужно:

| Требование | Deployment | StatefulSet |
|------------|------------|-------------|
| Стабильное имя Pod | ❌ random suffix | ✅ `app-0`, `app-1` |
| Стабильный network ID | ❌ | ✅ `app-0.app-svc.ns.svc` |
| **Свой диск** на Pod | ❌ (shared или emptyDir) | ✅ **volumeClaimTemplates** |
| Ordered rollout/scale | parallel | sequential (default) |

### emptyDir vs PVC (связь с 15.2.7)


```
Pod storage-demo-0
  └── volume: emptyDir
        │
        ▼
  данные на node локально
        │
        ▼
  delete Pod → новый Pod → ПУСТОЙ emptyDir
```

**emptyDir** - для cache, temp, scratch. **Жизненный цикл = Pod**.

```
Pod storage-demo-0
  └── volumeClaimTemplates: data
        │
        ▼
  PVC: data-storage-demo-0  ──► PV ──► disk
        │
        ▼
  delete Pod → recreate storage-demo-0 → тот же PVC → данные на месте
```

Это **главный смысл** StatefulSet + PVC для DevOps: **identity + persistence** decoupled from Pod lifecycle.

### volumeClaimTemplates

Шаблон PVC, который controller **материализует** для каждого ordinal:

```yaml
spec:
  volumeClaimTemplates:
    - metadata:
        name: data          # suffix имени PVC
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path
        resources:
          requests:
            storage: 1Gi
```

При `replicas: 3` создаются:

```
Pod                 PVC (auto)
───────────────     ──────────────────────
storage-demo-0  →   data-storage-demo-0
storage-demo-1  →   data-storage-demo-1
storage-demo-2  →   data-storage-demo-2
```

**Naming rule:** `<templateName>-<statefulsetName>-<ordinal>`

### Архитектура StatefulSet + Storage

```
                    ┌─────────────────────────┐
                    │  StatefulSet controller │
                    │  (kube-controller-mgr)  │
                    └───────────┬─────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
   Pod storage-demo-0    Pod storage-demo-1    Pod storage-demo-2
   hostname: ...-0       hostname: ...-1       hostname: ...-2
          │                     │                     │
          ▼                     ▼                     ▼
   PVC data-...-0        PVC data-...-1        PVC data-...-2
          │                     │                     │
          ▼                     ▼                     ▼
   PV (local-path)        PV (local-path)        PV (local-path)
   node A                 node B                 node C
```

Каждый ordinal **всегда** переподключается к **своему** PVC - даже после delete Pod и reschedule.

### Headless Service

```yaml
spec:
  serviceName: storage-demo   # ← обязательно для StatefulSet DNS
```

```
storage-demo-0.storage-demo.storage-lab.svc.cluster.local
storage-demo-1.storage-demo.storage-lab.svc.cluster.local
```

Peer discovery в кластерах (Kafka, Cassandra) строится на **stable DNS** + **stable disk**.

### Scale up / scale down и PVC

```
Scale 1 → 3:
  создаются Pod-1, Pod-2 + PVC data-...-1, data-...-2

Scale 3 → 1:
  Pod-2, Pod-1 удаляются
  PVC data-...-1, data-...-2 **остаются** (по умолчанию)
```

**Orphan PVC** после scale down - частая причина «утечки» storage. Admin должен удалять PVC вручную, если данные не нужны.

```
Scale down НЕ удаляет PVC автоматически
        │
        ▼
  orphan PVC → продолжают занимать quota / disk
```

### Ordered operations

| Operation | Default behavior |
|-----------|------------------|
| **Create** | 0 → 1 → 2 (ждёт Ready каждого) |
| **Delete** | 2 → 1 → 0 |
| **Update** | reverse ordinal |

Для БД это важно: bootstrap кластера часто требует **leader first** (pod-0).

### StorageClass на homelab vs AWS

| Параметр | local-path (Talos) | gp3 (EKS) |
|----------|-------------------|-----------|
| Access | RWO | RWO |
| Binding | WaitForFirstConsumer | WaitForFirstConsumer |
| Topology | node-local path | AZ-bound EBS |
| Scale to 3 | 3 PV на 3 nodes (если scheduler распределит) | 3 EBS в AZ workers |

На **single-node** homelab все ordinal могут оказаться на **одной** node - RWO допускает несколько Pod **на одном node** с разными PVC (разные PV).

### Когда StatefulSet + PVC не нужен

| Workload | Альтернатива |
|----------|--------------|
| Stateless API | Deployment |
| Shared files (CMS) | Deployment + **RWX** PVC (EFS/NFS) |
| Single DB без cluster | Deployment + один PVC (проще) |
| External managed DB | RDS - storage вне K8s |

StatefulSet + volumeClaimTemplates - когда **каждая replica = свой диск + stable ID**.

---

## Практика

### Предусловия

```bash
kubectl apply -f storage-homelab/00-namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f storage-homelab/01-storageclass-local-path.yaml
```

### Шаг 1 - StatefulSet с volumeClaimTemplates

```bash
kubectl apply -f lab/storage-homelab/05-statefulset-vct.yaml
kubectl get sts -n storage-lab storage-demo
kubectl get pods -n storage-lab -l app=storage-demo -w
kubectl get pvc -n storage-lab
```

**Ожидаемый результат:**

```
NAME                   STATUS   VOLUME     CAPACITY   STORAGECLASS
data-storage-demo-0    Bound    pvc-xxx    1Gi        local-path

Pod: storage-demo-0   Running
```

Lab manifest:

```yaml
# storage-homelab/05-statefulset-vct.yaml (фрагмент)
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: local-path
      resources:
        requests:
          storage: 1Gi
```

### Шаг 2 - Headless Service (для DNS demo)

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: storage-demo
  namespace: storage-lab
spec:
  clusterIP: None
  selector:
    app: storage-demo
  ports:
    - port: 80
      name: dummy
EOF

kubectl run -n storage-lab dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- \
  nslookup storage-demo-0.storage-demo.storage-lab.svc.cluster.local
```

### Шаг 3 - Запись данных и persistence

```bash
kubectl exec -n storage-lab storage-demo-0 -- sh -c 'echo pod-0-data > /data/id.txt'
kubectl exec -n storage-lab storage-demo-0 -- cat /data/id.txt
```

### Шаг 4 - Delete Pod, проверить persistence

```bash
kubectl delete pod -n storage-lab storage-demo-0
kubectl wait -n storage-lab pod/storage-demo-0 --for=condition=Ready --timeout=120s
kubectl exec -n storage-lab storage-demo-0 -- cat /data/id.txt
# pod-0-data - данные сохранились
```

```
delete Pod storage-demo-0
        │
        ▼
StatefulSet controller: desired 1 replica, ordinal 0 missing
        │
        ▼
create Pod storage-demo-0 (новый UID)
        │
        ▼
volumeClaimTemplates: PVC data-storage-demo-0 уже exists
        │
        ▼
Pod mount тот же PVC → те же данные
```

### Шаг 5 - Scale up (если кластер multi-node)

```bash
kubectl scale sts -n storage-lab storage-demo --replicas=3
kubectl get pods -n storage-lab -l app=storage-demo -o wide
kubectl get pvc -n storage-lab | grep storage-demo
```

Появятся `storage-demo-1`, `storage-demo-2` и PVC `data-storage-demo-1`, `data-storage-demo-2`.

Запишите уникальные данные:

```bash
kubectl exec -n storage-lab storage-demo-1 -- sh -c 'echo pod-1 > /data/id.txt'
kubectl exec -n storage-lab storage-demo-2 -- sh -c 'echo pod-2 > /data/id.txt'
```

### Шаг 6 - Scale down и orphan PVC

```bash
kubectl scale sts -n storage-lab storage-demo --replicas=1
kubectl get pvc -n storage-lab
# data-storage-demo-1 и data-storage-demo-2 остались!
```

Очистка orphan:

```bash
kubectl delete pvc -n storage-lab data-storage-demo-1 data-storage-demo-2
```

### Шаг 7 - Expansion PVC StatefulSet ([15.4.9](15.4.9%20Kubernetes%20-%20Volume%20Expansion.md))

```bash
kubectl patch pvc data-storage-demo-0 -n storage-lab \
  -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl exec -n storage-lab storage-demo-0 -- df -h /data
```

### Откат

```bash
kubectl delete sts -n storage-lab storage-demo
kubectl delete svc -n storage-lab storage-demo
kubectl delete pvc -n storage-lab -l app=storage-demo 2>/dev/null
kubectl delete pvc -n storage-lab data-storage-demo-0
```


## Что произошло внутри Kubernetes

### Создание StatefulSet

```
kubectl apply StatefulSet (replicas: 1, volumeClaimTemplates)
        │
        ▼
StatefulSet controller
        │
        ├── создаёт PVC: data-storage-demo-0
        │         │
        │         ▼
        │   PVC Pending (WFFC: WaitForFirstConsumer)
        │
        └── создаёт Pod: storage-demo-0
                  │
                  ▼
            Scheduler → node X
                  │
                  ▼
            WFFC: provisioner создаёт PV на node X
                  │
                  ▼
            PVC Bound → kubelet mount → container /data
```

### Reschedule Pod после delete

```
Pod storage-demo-0 deleted
        │
        ▼
StatefulSet: observedGeneration, replicas 1, current 0
        │
        ▼
Create Pod storage-demo-0 (новый sandbox)
        │
        ▼
Pod spec: volumeClaimTemplates → claimName data-storage-demo-0
        │
        ▼
PVC уже Bound → attach (same node or re-attach) → mount
        │
        ▼
Container видит старые файлы
```

**PVC не привязан к Pod UID** - привязан к **ordinal** через naming convention и StatefulSet ownership.

### Controller interaction map

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ StatefulSet     │────►│ PVC (from VCT)   │────►│ PV (dynamic)    │
│ controller      │     │                  │     │ local-path      │
└────────┬────────┘     └────────┬─────────┘     └────────┬────────┘
         │                       │                        │
         ▼                       ▼                        ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Pod ordinal N   │     │ external-        │     │ CSI Node mount  │
│                 │     │ provisioner      │     │ on worker       │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

