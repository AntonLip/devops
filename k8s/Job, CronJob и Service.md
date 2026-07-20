
# Kubernetes - Job, CronJob и Service

## 2. Типы workload

| Тип | Controller | Pod живёт | Пример |
|-----|------------|-----------|--------|
| **Long-running** | Deployment, StatefulSet | Пока не delete / crash policy | Web API, nginx |
| **Batch (разово)** | **Job** | До **Successful** completion | migrate DB, render |
| **Scheduled** | **CronJob** | Job по cron | backup nightly, report |
| **Serverless-like** | Job / CronJob | Короткий run | ETL, cleanup |

```text
Deployment  →  «всегда N реплик HTTP-сервера»
Job         →  «выполни задачу один раз до успеха»
CronJob     →  «создавай Job каждый день в 03:00»
Service     →  «стабильный DNS/IP на группу Pod'ов»
```

---

## 3. Job

### 3.1. Теория

**Job** создаёт один или несколько Pod'ов, которые **должны успешно завершиться** (exit 0).

| Поле | Смысл |
|------|--------|
| `completions` | Сколько успешных завершений нужно (default 1) |
| `parallelism` | Сколько Pod'ов Job запускает параллельно |
| `backoffLimit` | Сколько **retry** после fail (default 6) |
| `activeDeadlineSeconds` | Макс. время жизни Job |
| `restartPolicy` | **`Never`** или **`OnFailure`** (не `Always`) |

Жизненный цикл:

```text
Job created → Pod Running → container exits 0 → Pod Succeeded → Job Complete
                         → container exits !=0 → retry до backoffLimit → Job Failed
```

Job **не** пересоздаёт Pod после success - в отличие от Deployment.

### 3.2. Манифест

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: hello-job
  labels:
    app: hello-job
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: hello-job
    spec:
      restartPolicy: Never
      containers:
        - name: hello
          image: busybox:1.36
          command:
            - sh
            - -c
            - echo "Hello from Kubernetes Job" && date
```

### 3.3. Команды

```bash
kubectl apply -f manifests/04-job-hello.yaml
kubectl get jobs
kubectl get pods -l app=hello-job
kubectl logs job/hello-job
kubectl describe job hello-job
```

Статус Job: `Complete` или `Failed`.

---

## 4. CronJob

### 4.1. Теория

**CronJob** - controller, который **периодически** создаёт **Job** по расписанию cron.

| Поле | Смысл |
|------|--------|
| `schedule` | Cron expression (`分 时 日 月 周`) |
| `concurrencyPolicy` | `Allow`, `Forbid`, `Replace` |
| `successfulJobsHistoryLimit` | Сколько успешных Job хранить |
| `failedJobsHistoryLimit` | Сколько failed Job хранить |
| `jobTemplate` | Шаблон Job (как spec у Job) |

```text
CronJob hello-cron
    schedule: "0 3 * * *"
        → каждый день 03:00 создаёт Job hello-cron-29328480
            → Pod runs → completes
```

### 4.2. Манифест

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello-cron
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: hello
              image: busybox:1.36
              command:
                - sh
                - -c
                - echo "CronJob at $(date -Iseconds)"
```

### 4.3. Команды

```bash
kubectl apply -f manifests/05-cronjob-hello.yaml
kubectl get cronjobs
kubectl get jobs -l app=hello-cron
kubectl logs -l job-name=hello-cron-XXXXX --tail=5
kubectl delete cronjob hello-cron   # stop creating new jobs
```

---

## 5. Service - зачем нужен

### 5.1. Проблема Pod IP

Pod **эфемерен**:

- IP меняется при redeploy;
- несколько Pod'ов за Deployment - **разные IP**;
- клиенту нужна **одна** точка входа.

**Service** - абстракция **stable endpoint** на группу Pod'ов, отобранных **selector** по labels.

```text
Deployment nginx-dep → Pod 10.244.0.5, 10.244.0.6, 10.244.0.7
Service nginx-svc    → ClusterIP 10.96.xxx.xxx :80
                       → kube-proxy → один из Pod IP:80
```

### 5.2. Selector - связь с Deployment

Service **не** создаёт Pod'ы - только **маршрутизирует** к существующим:

```yaml
spec:
  selector:
    app: nginx
    tier: frontend   # must match Pod template labels
  ports:
    - port: 80        # port Service
      targetPort: 80  # port container
```

Если selector **не match** ни одного Pod → Service есть, **endpoints пуст** (`kubectl get endpoints`).

---

## 6. Типы Service

| type | Доступ | Minikube / prod |
|------|--------|-----------------|
| **ClusterIP** | Только **внутри** cluster | Default; `curl` из другого Pod |
| **NodePort** | `<NodeIP>:30000-32767` | `minikube service --url` |
| **LoadBalancer** | External IP (cloud LB) | AWS ELB, если cloud provider |
| **ExternalName** | CNAME DNS | Редко в begin |

### 6.1. ClusterIP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
spec:
  type: ClusterIP
  selector:
    app: nginx
    tier: frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
```


**Проверка из cluster:**

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://nginx-svc.default.svc.cluster.local
```

### 6.2. NodePort

```yaml
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080   # optional, 30000-32767
```

```bash
minikube service nginx-svc --url
curl $(minikube service nginx-svc --url)
```


### 6.3. LoadBalancer (обзор)

В AWS **EKS** `type: LoadBalancer` создаёт **ELB/NLB** через cloud controller. На Minikube часто **pending** external IP - используйте NodePort или `minikube tunnel`.

---

## 7. DNS и kube-proxy

### 7.1. CoreDNS

Внутри cluster DNS имя Service:

```text
<service>.<namespace>.svc.cluster.local
nginx-svc.default.svc.cluster.local → ClusterIP
```

Short names в том же namespace: `http://nginx-svc`

### 7.2. kube-proxy

На каждой node **kube-proxy** обновляет правила (iptables/IPVS/eBPF) при изменении **Endpoints** - списка Pod IP за Service.

```text
Service nginx-svc
Endpoints: 10.244.0.5:80, 10.244.0.6:80, 10.244.0.7:80
kube-proxy: traffic to ClusterIP:80 → round-robin to endpoints
```
