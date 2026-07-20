# Kubernetes - Probes


## 2. Зачем probes

Container может быть **Running**, но приложение **не готово** (warming cache) или **зависло** (deadlock). Docker `HEALTHCHECK` - аналог на уровне одного container; в Kubernetes **kubelet** на node выполняет probes и **действует**:

| Probe | При fail | Действие kubelet |
|-------|--------|------------------|
| **Liveness** | App «мертво» | **Restart** container |
| **Readiness** | App не принимает traffic | Pod **Not Ready** → out of endpoints |
| **Startup** | Ещё стартует | Блокирует liveness/readiness до success |

Без readiness балансировщик (Service, Ingress) может слать traffic на Pod, который ещё не слушает port.

---

## 3. Liveness, readiness, startup

### Liveness

«Жив ли процесс?» Fail → **kill + restart** container (с учётом restartPolicy).

Используйте для **deadlock detection**, не для «БД недоступна».

### Readiness

«Можно ли слать пользовательский traffic?» Fail → Pod **Ready=False**; **не** перезапускает container.

При recover - Pod снова в endpoints. Критично для **rolling update**: новые Pod'ы получают traffic только когда ready.

### Startup

Для **медленного старта** (JVM, large migrations). Пока startup не success - liveness/readiness **не** считаются failed.

```yaml
startupProbe:
  httpGet:
    path: /
    port: 8080
  failureThreshold: 30
  periodSeconds: 2
# до 60 сек на старт
```

После startup success - работают liveness/readiness.

---

## 4. Типы probe: HTTP, TCP, exec

### HTTP GET

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
    httpHeaders:
      - name: Custom-Header
        value: Awesome
  initialDelaySeconds: 5
  periodSeconds: 10
```

Success: HTTP 200–399 (настраивается). Path **должен существовать** - иначе fail.

### TCP socket

```yaml
livenessProbe:
  tcpSocket:
    port: 5432
```

Проверяет только «port open», не семантику приложения.

### exec

```yaml
livenessProbe:
  exec:
    command:
      - cat
      - /tmp/healthy
```

Команда exit 0 = success.

---

## 5. Параметры timing

| Поле | Смысл | Default |
|------|--------|---------|
| `initialDelaySeconds` | Ждать перед первой probe | 0 |
| `periodSeconds` | Интервал | 10 |
| `timeoutSeconds` | Timeout одной probe | 1 |
| `successThreshold` | Success подряд для «healthy» | 1 |
| `failureThreshold` | Fail подряд для «unhealthy» | 3 |

**CrashLoopBackOff:** liveness fail → restart → снова fail → exponential backoff.

---

## 6. Probes и Endpoints / rolling update

```text
Deployment rollout new version
  → new Pod starting
  → readiness fail (app warming)
  → Pod NOT in endpoints
  → old Pods still serve traffic
  → readiness success
  → new Pod in endpoints
  → old Pod terminated (maxUnavailable/maxSurge)
```

**Readiness** = gate для zero-downtime deploy. **Liveness** не влияет на endpoints напрямую - только restart.

Проверка:

```bash
kubectl get endpoints web-svc -n lab-space
kubectl describe pod <name> | grep -A10 Conditions
```

---

## 7. Anti-patterns

| Anti-pattern | Проблема |
|--------------|----------|
| Liveness проверяет **DB connection** | DB down → все Pod'ы restart loop |
| Один path для всего | `/health` должен быть лёгким |
| `initialDelaySeconds: 0` на JVM | liveness kill до старта |
| Readiness = liveness на один path | restart вместо temporary not ready |

**Правило:** liveness - «процесс застрял»; readiness - «не готов к traffic».

