# Kubernetes - Secret и ConfigMap

## 2. Конфиг вне образа

**Anti-pattern:** пароли и URLs зашиты в Docker image.

**Правильно:** image **immutable** (версия кода); конфиг и секреты - **Kubernetes objects**, меняются без rebuild.

| Данные | Объект |
|--------|--------|
| URLs, feature flags, non-secret config | **ConfigMap** |
| Passwords, tokens, TLS keys | **Secret** |

---

## 3. ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: lab-space
data:
  LOG_LEVEL: info
  APP_MODE: production
  config.json: |
    {"retry": 3}
```

Использование в Pod:

```yaml
env:
  - name: LOG_LEVEL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: LOG_LEVEL
volumeMounts:
  - name: config-vol
    mountPath: /etc/config
volumes:
  - name: config-vol
    configMap:
      name: app-config
```

Изменение ConfigMap **не** перезапускает Pod автоматически (env immutable at start; volume sync с delay).

---

## 4. Secret и типы

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: lab-space
type: Opaque
stringData:
  DB_USER: demo_user
  DB_PASSWORD: change-me-in-prod
```

| type | Назначение |
|------|------------|
| **Opaque** | generic key-value (default) |
| **kubernetes.io/tls** | `tls.crt`, `tls.key` для Ingress |
| **kubernetes.io/dockerconfigjson** | pull private registry |
| **kubernetes.io/service-account-token** | legacy SA token (deprecated flow) |

**Opaque** - 99% user secrets в приложениях.


---

## 5. Mount: env vs volume

### Environment variable

```yaml
env:
  - name: DB_USER
    valueFrom:
      secretKeyRef:
        name: app-secret
        key: DB_USER
```

Плюсы: просто. Минусы: visible in `kubectl describe pod`; не rotate без restart.

### Volume mount

```yaml
volumeMounts:
  - name: secret-vol
    mountPath: /etc/secrets
    readOnly: true
volumes:
  - name: secret-vol
    secret:
      secretName: app-secret
      items:
        - key: API_TOKEN
          path: API_TOKEN
```

Файлы в filesystem; приложение читает path. Подходит для TLS certs, token files.

---

## 6. stringData и base64

В YAML можно `stringData` - Kubernetes encode в base64 в etcd.

```bash
kubectl get secret app-secret -n lab-space -o yaml
# data: DB_USER: ZGVtb191c2Vy  (base64)
```

**Base64 ≠ encryption.** Любой с RBAC `get secrets` читает значения. В prod: **encryption at rest** для etcd, **External Secrets Operator**, cloud KMS.

---

## 7. Безопасность

- Не commit secrets в Git; use Sealed Secrets / SOPS / vault.
- Limit RBAC `get/list secrets`.
- Prefer workload identity (IRSA on EKS) over long-lived keys.
- Rotate secrets; restart or reload app.

ConfigMap **не** для passwords - даже если «только внутри cluster».


---

