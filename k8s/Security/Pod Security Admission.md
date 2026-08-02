# Pod Security Admission (PSA)

## Цель

Понять **Pod Security Admission** - встроенный admission controller Kubernetes; сравнить уровни **privileged / baseline / restricted** на namespace `sec-psa-*`; объяснить разницу с ручным SecurityContext и почему `lab-space` намеренно «дырявый».

---

## Теория

### Зачем PSA, если есть SecurityContext

**SecurityContext** - declarative настройка **конкретного** Pod. **PSA** - **политика namespace**, которая **отклоняет или предупреждает** о Pod'ах, не соответствующих [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/).

```
Без PSA enforce:
  Admin создаёт privileged Pod → API принимает → kubelet запускает

С PSA enforce=restricted:
  Admin создаёт privileged Pod → Admission DENY → Pod не создаётся
```

### Три режима label

| Label | Значения | Поведение |
|-------|----------|-----------|
| `pod-security.kubernetes.io/enforce` | privileged / baseline / restricted | **Блокирует** create/update |
| `pod-security.kubernetes.io/audit` | то же | Пишет **Audit** event |
| `pod-security.kubernetes.io/warn` | то же | **Warning** пользователю |

```
                    enforce          audit           warn
                      │               │               │
                      ▼               ▼               ▼
              reject request    audit log      kubectl warning
```

**Production:** `enforce: restricted`, `audit/warn: restricted` - единый уровень.

### Три уровня стандарта

```
┌─────────────────────────────────────────────────────────────┐
│  privileged  - без ограничений (как до PSA)                 │
├─────────────────────────────────────────────────────────────┤
│  baseline    - минимум: no privileged, no hostPath*,        │
│                no NET_RAW, runAsNonRoot рекомендуется       │
├─────────────────────────────────────────────────────────────┤
│  restricted  - baseline + must runAsNonRoot, drop ALL caps, │
│                readOnlyRootFS, seccomp RuntimeDefault       │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │                              │
    lab-space                    sec-psa-restricted
  enforce=privileged             enforce=restricted
```

### PSA vs SecurityContext vs Kyverno

| Механизм | Где | Что делает | На стенде |
|----------|-----|------------|-----------|
| **SecurityContext** | Pod spec | Настройка runtime | Пустой на web-dep |
| **PSA** | Namespace labels | Встроенный admission | `lab-space: privileged` |
| **Kyverno/Gatekeeper** | CRD policies | Кастом validate/mutate | **Нет** (установим позже) |

**На собеседовании:** «PSA - встроенный, быстрый baseline по namespace. Kyverno - когда нужны кастомные правила (только `:latest`, обязательные labels, mutate).»

### Как PSA оценивает Pod

```
Pod spec (create/update)
        │
        ▼
┌───────────────────────────┐
│ Pod Security Admission    │
│  - read ns labels         │
│  - evaluate PSS level     │
│  - compare pod fields     │
└─────────────┬─────────────┘
              │
     ┌────────┴────────┐
     ▼                 ▼
  enforce           audit/warn
  pass/fail         log only
```

Проверяются: `privileged`, `hostNetwork`, `hostPID`, `volumes`, `runAsNonRoot`, `capabilities`, `seccompProfile`, `readOnlyRootFilesystem` и др.

### Production-примеры

**EKS / GKE:** часто `enforce: baseline` на system ns, `restricted` на app namespaces.

**Multi-tenant:** каждый tenant namespace → `restricted`; `kube-system` → `privileged` только для platform team.


### Что спрашивают на собеседованиях

1. Разница PSA **enforce** и **warn**?
2. Что произойдёт при RBAC allow + PSA deny?
3. Можно ли обойти PSA через `kubectl replace`? (admission на update тоже)
4. Чем **restricted** отличается от **baseline** по capabilities?
5. Нужен ли отдельный PodSecurityPolicy (PSP)? - **Deprecated**, заменён PSA.

---

## Практика

### Цель

Создать namespace `sec-psa-privileged`, `sec-psa-baseline`, `sec-psa-restricted` и `sec-lab`; прогнать один и тот же insecure Pod через все уровни; сравнить с `lab-space`.

### Почему это важно

PSA - **первый рубеж** после RBAC без установки сторонних инструментов. На Talos homelab он уже работает - нужно научиться **читать deny** и проектировать namespace labels.

### Шаг 1 - Создать учебные namespace

```bash
cd "15. K8s/15.3 Security"
kubectl apply -f lab/security-homelab/manifests/00-namespace-sec-lab.yaml
kubectl apply -f lab/security-homelab/manifests/03-psa-namespace.yaml

kubectl get ns -l 'pod-security.kubernetes.io/enforce' --show-labels
```

**Ожидаемо:**

| Namespace | enforce |
|-----------|---------|
| `sec-lab` | baseline |
| `sec-psa-privileged` | privileged |
| `sec-psa-baseline` | baseline |
| `sec-psa-restricted` | restricted |
| `lab-space` | privileged (уже был) |

### Шаг 2 - Insecure Pod в restricted (должен FAIL)

```bash
kubectl apply -f lab/security-homelab/manifests/04-insecure-pod.yaml
```

Манифест нацелен на `sec-psa-restricted`:

```yaml
securityContext:
  privileged: true
  runAsUser: 0
```

**Ожидаемо:**

```
Error from server (Forbidden): pods "sec-insecure-root" is forbidden:
  violates PodSecurity "restricted:latest": privileged (container "nginx" must not set securityContext.privileged=true)
```

```bash
kubectl get events -n sec-psa-restricted --field-selector reason=FailedCreate
```

### Шаг 3 - Тот же Pod в lab-space (должен PASS)

```bash
kubectl apply -f lab/security-homelab/manifests/04-insecure-pod-lab-space.yaml
# или inline:
kubectl run sec-insecure-lab --image=nginx:1.27-alpine -n lab-space \
  --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.27-alpine","securityContext":{"privileged":true,"runAsUser":0}}]}}'
kubectl get pod -n lab-space -l run=sec-insecure-lab 2>/dev/null || kubectl get pod sec-insecure-root -n lab-space
```

**Ожидаемо:** Pod **Running** - `lab-space` enforce=**privileged**.

### Шаг 4 - Secure deployment в restricted (должен PASS)

```bash
kubectl apply -f lab/security-homelab/manifests/05-secure-deployment.yaml
kubectl get deploy sec-secure-echo -n sec-psa-restricted
kubectl get pods -n sec-psa-restricted -l app=sec-secure-echo
```

**Ожидаемо:** Deployment **Ready** - манифест соответствует restricted (non-root, drop ALL, ro fs, seccomp).

### Шаг 5 - baseline: NET_RAW experiment

```bash
kubectl run netraw-test -n sec-psa-baseline --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","3600"],"securityContext":{"capabilities":{"add":["NET_RAW"]}}}]}}'
```

**Ожидаемо:** при **enforce=baseline** - **Forbidden** (NET_RAW запрещён). Если только warn - Pod создастся с warning.

### Шаг 6 - Сравнение с devops-lab

```bash
kubectl get ns devops-lab --show-labels
# PSA enforce не задан - кластерный default warn/audit

kubectl auth can-i create pods --namespace=devops-lab   # yes (admin)
# Privileged pod в devops-lab технически возможен для admin - PSA не enforce
```

**Вывод:** `devops-lab` без enforce - **gap** для production; добавьте label после lab.

### Откат

```bash
kubectl delete -f lab/security-homelab/manifests/05-secure-deployment.yaml --ignore-not-found
kubectl delete -f lab/security-homelab/manifests/04-insecure-pod.yaml --ignore-not-found
kubectl delete pod sec-insecure-root -n lab-space --ignore-not-found
kubectl delete pod netraw-test -n sec-psa-baseline --ignore-not-found 2>/dev/null
# Namespace оставить для следующих глав или:
# kubectl delete -f lab/security-homelab/manifests/00-namespace-sec-lab.yaml
```

---

## Что произошло внутри Kubernetes

```
kubectl apply -f 04-insecure-pod.yaml (namespace: sec-psa-restricted)
        │
        ▼
┌───────────────────┐
│ Authentication    │  admin / system:masters
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Authorization     │  RBAC: create pods → allow
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Mutating webhooks │  Istio (если ns с injection) - skip для sec-psa-*
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Pod Security      │  read ns label enforce=restricted
│ Admission         │  evaluate: privileged=true → FAIL
└─────────┬─────────┘
          │
          ▼
   403 Forbidden (Pod NOT in etcd)

─────────────────────────────────────────

Успешный 05-secure-deployment.yaml:
          │
          ▼
┌───────────────────┐
│ PSA restricted    │  runAsNonRoot ✓ drop ALL ✓ seccomp ✓ → PASS
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ etcd → scheduler → kubelet → containerd
└───────────────────┘
```

PSA срабатывает **до** записи в etcd - объект не создаётся при enforce deny.

---

## Типичные ошибки

| Ошибка | Симптом | Диагностика | Исправление |
|--------|---------|-------------|-------------|
| Только `warn`, без `enforce` | Insecure Pod Running | `kubectl get ns --show-labels` | Добавить `enforce: restricted` |
| PSA restricted + образ root | CreateContainerConfigError | describe pod | SC + USER в image |
| Думать, PSA = SecurityContext | «PSA включён, SC не нужен» | pod yaml | Явный SC всё равно best practice |
| Privileged ns для apps | Компромисс Pod = host risk | ns labels | Отдельный `lab-space`, apps в restricted |
| Забыть `enforce-version` | Разное поведение на версиях K8s | label `enforce-version` | `latest` или pin version |
| Kyverno дублирует PSA | Двойные deny, confusion | policy logs | Kyverno для custom, PSA для PSS |

---
