# Volumes

## Цель

Разобрать **все основные типы volumes** в `Pod.spec.volumes`: emptyDir, hostPath, configMap, secret, projected, persistentVolumeClaim и CSI; на практике развернуть Pod с **несколькими типами одновременно** в namespace `storage-lab`.

---

## Теория

### Общая модель

Volume объявляется на уровне **Pod**, монтируется в **контейнер** через `volumeMounts`.

```
Pod.spec
├── volumes[]          ← источник данных (имя + тип)
└── containers[]
    └── volumeMounts[] ← name + mountPath + readOnly + subPath
```

Один volume → несколько контейнеров (sidecar pattern). Один контainer → несколько volumeMounts.

---

### emptyDir

**Зачем:** scratch space и обмен данными между контейнерами **одного** Pod.

```yaml
volumes:
  - name: cache
    emptyDir:
      medium: ""        # "" = disk, "Memory" = tmpfs
      sizeLimit: 256Mi  # optional
```

**Lifecycle:** создаётся при назначении Pod на node → удаляется при удалении Pod.

```
Pod scheduled on worker-2
        │
        ▼
kubelet: mkdir /var/lib/kubelet/pods/<pod-uid>/volumes/.../cache/
        │
        ▼
bind mount → /cache в container A и B
        │
Pod deleted
        │
        ▼
directory removed
```

**Limits:** не для persistence; `Memory` emptyDir учитывается в memory limit Pod.
**Production:** Istio proxy buffer, sort temp files, handoff между app и log-shipper sidecar.

---

### hostPath

**Зачем:** доступ к файлам **node** (legacy, system daemons, lab).

```yaml
volumes:
  - name: node-logs
    hostPath:
      path: /var/log
      type: Directory  # Directory | DirectoryOrCreate | File | ...
```

| type | Поведение |
|------|-----------|
| DirectoryOrCreate | создать если нет |
| Directory | должен существовать |
| File | один файл |

**Limits:** node binding, security risk, не migrates с Pod.

**Ваш кластер:** Cilium agents - hostPath для bpf maps и runtime.

---

### configMap

**Зачем:** монтировать конфигурацию как файлы без пересборки образа.

```yaml
volumes:
  - name: config
    configMap:
      name: app-config
      items:
        - key: app.properties
          path: app.properties
```

**Limits:**
- max ~1 MiB на ConfigMap (etcd limit);
- изменение ConfigMap **не** всегда мгновенно видно - kubelet sync с delay (default ~60s);
- для hot reload - watch файл или use subPath carefully.

**Production:** nginx.conf, app.properties, feature flags (осторожно с size).
**Ваш кластер:** `argocd-cmd-params-cm`, `argocd-ssh-known-hosts-cm` в argocd pods.

---

### secret

**Зачем:** монтировать чувствительные данные (TLS, passwords, tokens).

```yaml
volumes:
  - name: tls
    secret:
      secretName: app-tls
      defaultMode: 0400
```

**Limits:** base64 в etcd (encryption at rest - отдельная настройка); тот же sync delay что ConfigMap.
**Production:** TLS certs для ingress sidecar, DB credentials (prefer external secret operators).
**Ваш кластер:** `argocd-repo-server-tls`, dex TLS secrets.

---

### projected

**Зачем (K8s 1.11+):** объединить **несколько источников** в один mount - уменьшить число volumes, atomic-ish updates для SA token.

```yaml
volumes:
  - name: all-in-one
    projected:
      sources:
        - configMap: { name: cfg }
        - secret: { name: sec }
        - downwardAPI:
            items:
              - path: labels
                fieldRef: { fieldPath: metadata.labels }
        - serviceAccountToken:
            path: token
            expirationSeconds: 3600
```

**Production:** стандартный pattern Kubernetes 1.24+ для SA tokens (вместо auto-created secret).
**Ваш кластер:** `devops-lab` web/api pods - **только projected** (SA token); ingress-nginx - projected.

---

### persistentVolumeClaim

**Зачем:** decouple потребление storage (developer) от provisioning (admin/CSI).

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-pvc
      readOnly: false
```

PVC - отдельный API object; binding в главе 15.4.4. PV - 15.4.3.

```
Pod ──► PVC (namespace-scoped)
           │
           ▼ Bound
         PV (cluster-scoped)
           │
           ▼
       disk / NFS / CSI volume
```

**На вашем кластере:** пока **нет** PVC в production namespaces - создадим в lab.

---

### CSI volumes

**Зачем:** динамическое создание block/file volumes через стандартный интерфейс.
Pod не ссылается на CSI напрямую - только через PVC → PV с `csi:` section:

```yaml
# В PV (создаёт provisioner):
csi:
  driver: ebs.csi.aws.com
  volumeHandle: vol-0abc123
  fsType: ext4
```

Sidecars: **provisioner** (CreateVolume), **attacher** (AttachVolume), **node** plugin (NodeStage/Publish), **resizer**, **snapshotter**.
**Homelab:** CSI drivers **отсутствуют** - static hostPath PV для обучения.

---

### Сводная таблица

| Тип | Scope | Persists Pod delete | Multi-Pod share |
|-----|-------|---------------------|-----------------|
| emptyDir | Pod | No | Same Pod only |
| hostPath | Node | On node | No (dangerous) |
| configMap | Cluster CM | N/A (ref) | Many pods |
| secret | Cluster Secret | N/A (ref) | Many pods |
| projected | Mixed | Token rotates | Same Pod |
| PVC | Namespace | Yes (via PV) | Depends on accessMode |
| CSI | Via PV/PVC | Yes | Backend-dependent |

---

### Best practices

- **subPath** - монтировать один ключ CM/secret; осторожно: не обновляется при изменении CM.
- **readOnly: true** для configMap/secret где возможно.
- Не хранить большие бинарники в CM/secret - использовать object storage или PVC.
- **defaultMode** для secret - ограничить permissions.
- Для SA: projected token с `expirationSeconds` и `audience`.
- Имена volumes уникальны в пределах Pod.

---

## Практика

### Цель

Создать Pod `pod-multi-volumes` с **emptyDir + hostPath + configMap + secret + projected** в `storage-lab`.

### Зачем

Перед PV/PVC нужно уверенно читать `spec.volumes` - это основа всех storage troubleshooting.

### Предусловия

```bash
kubectl apply -f storage-home00-namespace.yaml
```

> **PodSecurity:** namespace `storage-lab` помечен `pod-security.kubernetes.io/enforce: privileged` - иначе **baseline** блокирует hostPath volumes (ошибка `violates PodSecurity "baseline:latest": hostPath volumes`).

### Шаг 1 - применить манифест

```bash
kubectl apply -f storage-home10-pod-multi-volumes.yaml
```

Манифест: [`storage-home10-pod-multi-volumes.yaml`](storage-home10-pod-multi-volumes.yaml)

Содержит:
- ConfigMap `multi-vol-config`
- Secret `multi-vol-secret`
- Pod `pod-multi-volumes` с 5 типами volumes

### Шаг 2 - дождаться Running

```bash
kubectl get pod -n storage-lab pod-multi-volumes -w
```

### Шаг 3 - проверить mounts

```bash
# emptyDir - запись
kubectl exec -n storage-lab pod-multi-volumes -- sh -c 'echo test > /scratch/file.txt && cat /scratch/file.txt'

# configMap
kubectl exec -n storage-lab pod-multi-volumes -- cat /config/greeting.txt

# secret
kubectl exec -n storage-lab pod-multi-volumes -- cat /secrets/api-key

# projected - комбинация
kubectl exec -n storage-lab pod-multi-volumes -- ls -la /projected/
kubectl exec -n storage-lab pod-multi-volumes -- cat /projected/greeting.txt

# hostPath на node (данные на worker где запущен Pod)
kubectl exec -n storage-lab pod-multi-volumes -- sh -c 'echo node-persist > /node-data/persist.txt'
NODE=$(kubectl get pod -n storage-lab pod-multi-volumes -o jsonpath='{.spec.nodeName}')
echo "Pod runs on: $NODE"
```

### Шаг 4 - сравнить с production

```bash
kubectl get pod -n devops-lab -l app=web-dep -o yaml | grep -A30 'volumes:'
```

**Contrast:** devops-lab - только projected SA token; lab pod - полный набор типов.

### Verify

| Проверка | Ожидание |
|----------|----------|
| Pod status | Running |
| /scratch/file.txt | `test` |
| /config/greeting.txt | `Hello from ConfigMap` |
| /secrets/api-key | `lab-secret-key-not-for-production` |
| /projected/token | JWT exists |
| /projected/labels | JSON labels pod |

### Rollback

```bash
kubectl delete -f storage-home10-pod-multi-volumes.yaml
# hostPath data on node останется в /var/lib/k8s-storage/multi-volumes - удалить вручную при необходимости
```

---

## Что произошло внутри Kubernetes

```
kubectl apply -f 10-pod-multi-volumes.yaml
        │
        ▼
API Server → etcd: ConfigMap, Secret, Pod objects
        │
        ▼
Scheduler → выбирает worker (нет PVC/WFFC)
        │
        ▼
kubelet на worker-N:
        │
        ├── pull busybox image
        │
        ├── emptyDir: create under pod dir
        │
        ├── hostPath: mount /var/lib/k8s-... (DirectoryOrCreate)
        │
        ├── configMap: kubelet fetches CM, writes files, bind mount
        │
        ├── secret: same flow, decode base64
        │
        ├── projected: merge sources → single mount
        │     ├── CM subset
        │     ├── secret subset
        │     ├── downwardAPI (labels from API)
        │     └── SA token from TokenRequest API
        │
        └── start container sleep 3600
```

---

## Troubleshooting

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `MountVolume.SetUp failed for volume "config"` | ConfigMap не существует | apply манифест целиком |
| `secret "multi-vol-secret" not found` | Secret не создан | проверить namespace storage-lab |
| `hostPath type check failed` | path invalid on node | type: DirectoryOrCreate |
| Pod forbidden hostPath | PodSecurity baseline on namespace | label `storage-lab` privileged (см. `00-namespace.yaml`) |
| Pod Pending | resource quota / taints | describe pod |
| Empty /projected/token | SA automount disabled | automountServiceAccountToken: true (default) |
| Permission denied on /secrets | defaultMode | проверить securityContext |
| ConfigMap update not visible | kubelet sync delay | подождать или restart pod |

---
