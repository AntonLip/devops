# Storage homelab (15.4)

Практика для **Talos homelab** без облачного CSI: static **hostPath** PV + опционально **local-path-provisioner**.

**Уроки:** [15.4 Plan](../../15.4%20Plan.md)

## Предусловия

- `kubectl` на homelab cluster
- Для dynamic / StatefulSet: установить local-path:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f 01-storageclass-local-path.yaml
```

> **hostPath** — только lab. На multi-node кластере static PV привязан к node, где создан path.

## Порядок

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 02-pv-static-hostpath.yaml
kubectl apply -f 03-pvc-static.yaml
kubectl get pv,pvc -n storage-lab   # 2× Bound + 1× Pending (10Gi)

# Multi-volume types (15.4.2)
kubectl apply -f 10-pod-multi-volumes.yaml
kubectl exec -n storage-lab pod-multi-volumes -- ls /projected/
kubectl apply -f 04-pod-with-pvc.yaml
kubectl exec -n storage-lab pod-with-pvc -- sh -c 'echo hello > /data/test.txt'

# Dynamic + StatefulSet (нужен local-path)
kubectl apply -f 05-statefulset-vct.yaml
kubectl get pvc -n storage-lab

# Quotas
kubectl apply -f 06-resourcequota-storage.yaml

# Troubleshooting
kubectl apply -f 08-troubleshoot-pending-pvc.yaml
kubectl describe pvc -n storage-lab pvc-broken-sc

# Read-only mount
kubectl apply -f 09-pod-readonly-pvc.yaml
```

## Expansion (07)

```bash
kubectl apply -f 07-pvc-expand-demo.yaml
# дождаться Bound, подключить Pod, затем:
kubectl patch pvc pvc-expand-demo -n storage-lab -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```

## Cleanup

```bash
chmod +x scripts/cleanup.sh
./scripts/cleanup.sh
```

## AWS EKS

На EKS замените `local-path` / `manual` на `gp3` StorageClass (EBS CSI) — см. [15.4.15](../../15.4.15%20Kubernetes%20—%20AWS%20Storage.md) и [15.4.17](../../15.4.17%20Kubernetes%20—%20Финальная%20lab%20и%20справочники.md).

## Файлы

| Файл | Назначение |
|------|------------|
| `00-namespace.yaml` | `storage-lab` |
| `01-storageclass-local-path.yaml` | SC для dynamic |
| `02-pv-static-hostpath.yaml` | Static PV |
| `03-pvc-static.yaml` | PVC → Bound |
| `04-pod-with-pvc.yaml` | Mount + persistence demo |
| `05-statefulset-vct.yaml` | StatefulSet + PVC per pod |
| `06-resourcequota-storage.yaml` | Quota + LimitRange |
| `07-pvc-expand-demo.yaml` | Resize exercise |
| `08-troubleshoot-pending-pvc.yaml` | Broken SC |
| `09-pod-readonly-pvc.yaml` | readOnly mount |
| `10-pod-multi-volumes.yaml` | emptyDir, hostPath, CM, secret, projected (15.4.2) |
