# Authentication

## Теория

### Зачем Authentication

API Server должен ответить: **кто** делает запрос, прежде чем решать **можно ли**. Без auth — anonymous (если не отключён) или `401`.

### Способы аутентификации

| Метод                       | Кто использует         | Ваш стенд                                 |
| --------------------------- | ---------------------- | ----------------------------------------- |
| **X509 Client Certificate** | Админы, CI с cert      | **Вы сейчас** (`admin`, `system:masters`) |
| **Bearer Token**            | SA token, static token | Создадим для `sec-lab`                    |
| **ServiceAccount**          | Pods в кластере        | default SA в каждом ns                    |
| **OIDC**                    | SSO (Keycloak, Dex)    | Argo CD **dex** есть, кластер OIDC — нет  |
| **Webhook Token**           | Внешний IdP            | Не настроен                               |
| **Bootstrap Token**         | Join nodes             | `bootstrap-token-*` в kube-system         |

Ниже — что происходит «под капотом» для каждого метода, как API Server превращает credential в **Username** и **Groups**, и как это выглядит на вашем Talos homelab.

---

#### 1. X509 Client Certificate

**Суть:** mutual TLS на уровне transport. Клиент (kubectl, CI-скрипт) предъявляет client certificate при HTTPS-handshake с API Server. Сервер читает поля сертификата и мапит их в identity Kubernetes.

**Как мапится identity:**

| Поле сертификата | Становится в K8s |
| ---------------- | ---------------- |
| `CN` (Common Name) | **Username** |
| `O` (Organization) | **Group** (может быть несколько O → несколько групп) |

**На вашем стенде:**

```bash
kubectl auth whoami
# Username: admin
# Groups:   [system:masters system:authenticated]
# Credential: X509 client certificate

kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject
# subject=CN=admin, O=system:masters
```

Talos при `talosctl kubeconfig` выдаёт kubeconfig с встроенным client cert + CA cluster. Группа `system:masters` привязана к ClusterRoleBinding `cluster-admin` — полный доступ без отдельного RBAC.

**Кто обычно использует:**
- Администраторы кластера (ваш `admin`)
- CI/CD с выданным cert (GitLab Runner, Jenkins)
- Второй admin (`admin2`) — через CSR + kubeconfig (см. практику ниже)

**Плюсы:** не нужен внешний IdP; cert встроен в TLS; отзыв через удаление CSR/User из RBAC или rotation CA.

**Минусы:** управление жизненным циклом cert вручную; утечка kubeconfig = полный доступ; с K8s 1.22+ **нельзя** выпустить CSR с `O=system:masters` — нужен отдельный CN + RoleBinding.

**Проверка на стенде:**

```bash
kubectl auth whoami
kubectl config view --minify
```

---

#### 2. Bearer Token

**Суть:** HTTP-заголовок `Authorization: Bearer <token>`. API Server получает токен **после** TLS (transport security остаётся), затем определяет тип токена и валидирует его одним из механизмов ниже.

**Виды Bearer token в Kubernetes:**

| Вид                             | Откуда                                             | Срок жизни                 | Ваш стенд                                |
| ------------------------------- | -------------------------------------------------- | -------------------------- | ---------------------------------------- |
| **SA token (TokenRequest API)** | `kubectl create token` / projected volume          | Заданный (`--duration=1h`) | Создаём для `developer` в `sec-lab`      |
| **Legacy SA token secret**      | Secret `type: kubernetes.io/service-account-token` | До удаления Secret         | K8s 1.24+ **не создаётся автоматически** |
| **Static token file**           | `--token-auth-file` на API Server                  | Бессрочный (пока в файле)  | Не используется на Talos                 |
| **OIDC JWT**                    | Внешний IdP                                        | По `exp` в JWT             | Кластерный OIDC не настроен              |

**Как API Server валидирует SA token (TokenRequest API, K8s 1.24+):**

```
kubectl create token developer -n sec-lab
        │
        ▼
POST .../serviceaccounts/developer/token  (TokenRequest subresource)
        │
        ▼
API Server подписывает JWT (issuer, sub, namespace, exp, audience)
        │
        ▼
Клиент: Authorization: Bearer eyJhbG...
        │
        ▼
API Server проверяет подпись → Username: system:serviceaccount:sec-lab:developer
```


**Плюсы:** короткий TTL, audience binding, не нужен client cert на машине разработчика.

**Минусы:** украденный token = identity SA до истечения; long-lived static tokens — антипаттерн.

---

#### 3. ServiceAccount

**Суть:** ServiceAccount — это **ресурс Kubernetes** (не метод auth сам по себе), но основной способ, которым **Pod'ы** аутентифицируются в API. Каждый Pod привязан к SA; SA token — это Bearer token (см. выше).

**Жизненный цикл identity Pod'а:**

```
Pod spec.serviceAccountName: developer
        │
        ▼
kubelet монтирует projected volume (или legacy secret)
  /var/run/secrets/kubernetes.io/serviceaccount/
    ├── token          ← JWT для API calls
    ├── ca.crt         ← CA кластера
    └── namespace
        │
        ▼
Приложение в Pod: Authorization: Bearer $(cat token)
        │
        ▼
Username: system:serviceaccount:<ns>:<sa-name>
```

**Группы SA автоматически:**
- `system:serviceaccounts` — все SA кластера
- `system:serviceaccounts:<namespace>` — все SA в namespace
- `system:authenticated` — любой успешно аутентифицированный субъект


**Важно:** SA — это **кто** Pod в API. **RBAC** (RoleBinding) решает, **что** этот SA может делать. Authentication и Authorization — разные этапы.

---

#### 4. OIDC (OpenID Connect)

**Суть:** API Server настроен как OIDC Relying Party. Клиент получает JWT от внешнего Identity Provider и передаёт его как Bearer token. API Server проверяет подпись JWT по публичным ключам IdP (`--oidc-issuer-url`).

**Флаги API Server (типичная настройка):**

```text
--oidc-issuer-url=https://keycloak.example.com/realms/k8s
--oidc-client-id=kubernetes
--oidc-username-claim=sub          # или email
--oidc-groups-claim=groups
--oidc-username-prefix=oidc:
--oidc-groups-prefix=oidc:
```

**Поток:**

```
Пользователь → IdP (Keycloak / Google / Azure AD) → JWT
        │
        ▼
kubectl --token=<JWT>  или  kubeconfig user.token
        │
        ▼
API Server: проверка issuer + signature + exp
        │
        ▼
Username: oidc:<sub>    Groups: [oidc:developers, system:authenticated]
        │
        ▼
RBAC RoleBinding на oidc:<sub> или oidc:developers
```

**Где OIDC обычно включают:** EKS (`aws eks get-token`), GKE, AKS, enterprise-кластеры с Keycloak/Okta.

**На Talos:** OIDC настраивается в machine config API Server (`extraArgs`); для homelab не включён — достаточно X509 + SA tokens.

---

#### 5. Webhook Token Authentication

**Суть:** API Server **делегирует** проверку токена внешнему сервису через **Authentication Webhook**. При каждом запросе с Bearer token API Server вызывает webhook:

```
POST https://auth-webhook.example.com/authenticate
Body: { "apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview", "spec": { "token": "..." } }

Response: { "status": { "authenticated": true, "user": { "username": "bob", "groups": ["devs"] } } }
```

**Флаг API Server:**

```text
--authentication-token-webhook-config-file=/etc/kubernetes/webhook-config.yaml
```

**Типичные реализации:**
- **Vault** (`vault-k8s-auth`) — токен Vault → K8s user
- **Keycloak** через custom webhook adapter
- **Corporate LDAP/AD** gateway
- **Boundary**, custom corporate IdP

**На вашем стенде:** не настроен. Validating/Mutating webhooks есть (Istio, ingress-nginx admission), но это **admission**, не **authentication** — другой этап pipeline.

**Отличие от OIDC:**

| | OIDC | Webhook Token |
| - | ---- | ------------- |
| Кто валидирует | API Server сам (JWT signature) | Внешний сервис по HTTP |
| Протокол | Стандарт OIDC/JWT | TokenReview API |
| Гибкость | Стандартные claims | Любая логика в webhook |

---

#### 6. Bootstrap Token

**Суть:** специальный тип Secret в `kube-system` для **первичного присоединения** worker/control plane нод к кластеру и для **временной** аутентификации при bootstrap. Формат токена: `abcdef.0123456789abcdef` (id.secret).

**Где хранится:**

```bash
kubectl get secrets -n kube-system | grep bootstrap-token
# bootstrap-token-xxxxx   kubernetes.io/bootstrap-token
```

**Кто использует:**
- `kubeadm join` — нода предъявляет bootstrap token → получает kubelet client cert
- Talos — свой механизм join (не kubeadm), но bootstrap-token secrets могут присутствовать

**Особенности identity:**
- Username: `system:bootstrap:<token-id>`
- Groups: `system:bootstrappers`, `system:bootstrappers:<group>`
- Права **строго ограничены** через ClusterRoleBinding `system:node-bootstrapper` — только CSR для kubelet cert, не admin-доступ

**На стенде:** secrets `bootstrap-token-*` в `kube-system` — артефакт создания/жизни кластера. Для ежедневной работы **не используются**; ваш `kubectl` идёт через X509 admin cert.

```bash
kubectl get secrets -n kube-system -l 'kubernetes.io/bootstrapping-token' 2>/dev/null \
  || kubectl get secrets -n kube-system | grep bootstrap-token
```

**Безопасность:** bootstrap tokens — высокий риск при утечке; после join нод ротация/удаление; TTL обычно 24h при создании через `kubeadm token create`.

---

#### Сводка: что выбрать и когда

| Сценарий | Метод на homelab | Production-аналог |
| -------- | ---------------- | ----------------- |
| Админ kubectl | X509 (`admin`) | X509 или OIDC admin group |
| Разработчик CI/CD | SA token / отдельный X509 | OIDC + RBAC group |
| Pod → API | ServiceAccount + RBAC | То же + least privilege |
| SSO для всей команды | Не настроено | OIDC (Keycloak, Okta) |
| Корпоративный IdP с кастомной логикой | — | Webhook Token |
| Join новой ноды | Bootstrap token (системный) | kubeadm / облачный managed |

**Общее правило:** Authentication отвечает только на **«кто ты?»** → `Username` + `Groups`. Что можно делать — решает **Authorization**

### Архитектура

```
Client
  │
  ├─ TLS client cert ──► API Server ──► CN/O mapping ──► User "admin"
  ├─ Authorization: Bearer <token> ──► ServiceAccount validation
  └─ OIDC JWT ──► API Server OIDC plugin ──► User + groups
```

### X509 на Talos

Talos выдаёт kubeconfig с client certificate. Группа `system:masters` даёт неограниченный доступ через binding `cluster-admin`.

**На собеседовании:** «Как ограничить admin cert?» — не давать `system:masters`, выдать отдельный CN + RoleBinding.

### ServiceAccount

```
Pod создаётся
    │
    ▼
ServiceAccount (sec-lab/developer)
    │
    ▼
Token projected volume / legacy secret
    │
    ▼
API calls от имени system:serviceaccount:sec-lab:developer
```

Kubernetes 1.24+: long-lived SA token secrets **не создаются автоматически** — используйте `kubectl create token` или projected volume.

### OIDC и IAM

- **OIDC:** API server flags `--oidc-issuer-url`, `--oidc-client-id` — типично EKS/GKE/enterprise
- **AWS IAM (EKS):** `aws eks update-kubeconfig` → IAM → STS → кластер
- На **Talos homelab** — X509 + SA; IAM не применим

### Ограничения

- Authentication **не** проверяет права — только личность
- SA token в Pod — если украден, атакующий = SA
- Shared kubeconfig с `system:masters` — single point of failure

### Best practices

- Отдельные kubeconfig per role (developer, ci, admin)
- Короткоживущие токены (`kubectl create token --duration`)
- Отключить anonymous auth в production
- Rotate client certificates



# Authorization (RBAC)

## Теория

### Зачем RBAC

После Authentication API знает **кто вы**. Authorization отвечает: **разрешено ли** действие с **этим** ресурсом.

```
Authenticated identity
        │
        ▼
┌─────────────────────┐
│ RBAC Authorizer     │
│  - Role / ClusterRole│
│  - Bindings          │
└─────────────────────┘
        │
   allow / deny
```

### Объекты RBAC

| Объект | Scope | Назначение |
|--------|-------|------------|
| **Role** | Namespace | Правила внутри ns |
| **ClusterRole** | Cluster | Правила cluster-wide |
| **RoleBinding** | Namespace | Связь Role ↔ Subject |
| **ClusterRoleBinding** | Cluster | Связь ClusterRole ↔ Subject |

**Subject:** User, Group, ServiceAccount.

### Aggregation

`ClusterRole` может агрегировать другие роли через labels `rbac.authorization.k8s.io/aggregate-to-admin` — встроенные `admin`, `edit`, `view` собираются автоматически.

### Escalation (критично на собеседованиях)

Запрещено: пользователь без `bind`/`escalate` не может выдать себе права выше текущих.

Опасные permissions:

```yaml
verbs: ["create"]
resources: ["clusterrolebindings"]  # создать binding на cluster-admin
```

Или:

```yaml
resources: ["roles", "rolebindings"]
verbs: ["*"]  # в namespace с правом bind
```

### Impersonation

```bash
kubectl auth can-i --list --as=system:serviceaccount:sec-lab:developer -n devops-lab
```

Admin может симулировать другого subject — инструмент аудита, не обход security.

---

# Практика

### Цель

Создать namespace `sec-lab`, ServiceAccount и проверить identity через token.


### Шаги

```bash
# Путь к манифестам (из корня 15.3 Security)
cd "15. K8s/15.3 Security"

kubectl apply -f lab/security-homelab/manifests/00-namespace-sec-lab.yaml

# ServiceAccount для разработчика
kubectl apply -f lab/security-homelab/manifests/10-auth-developer-sa.yaml

# Текущий admin
kubectl auth whoami
```

**Проверено на homelab (2026-07-08):**

```
Username    admin
Groups      [system:masters system:authenticated]
```

```bash
# Токен SA (1 час) — JWT ~1200 байт
kubectl create token developer -n sec-lab --duration=1h > /tmp/dev-token.txt

# ⚠️ ВАЖНО: kubectl auth whoami --token=... НЕ работает, если в ~/.kube/config
# есть client-certificate — kubectl предпочитает cert и покажет admin!
# НЕ используйте эту команду для проверки токена:
# kubectl auth whoami --token="$(cat /tmp/dev-token.txt)"   # ← покажет admin (ложь)

# Способ 1 — impersonation (admin симулирует SA, токен не нужен):
kubectl auth whoami --as=system:serviceaccount:sec-lab:developer
```

**Ожидаемый вывод impersonation:**

```
Username    system:serviceaccount:sec-lab:developer
Groups      [system:serviceaccounts system:serviceaccounts:sec-lab system:authenticated]
```

```bash
# Способ 2 — отдельный kubeconfig ТОЛЬКО с token (без client cert) — см. ниже
# Способ 3 — после сборки kubeconfig:
kubectl --kubeconfig=/tmp/dev-kubeconfig.yaml auth whoami
```

### Создание kubeconfig с token (обязательно для проверки identity)

```bash
TOKEN=$(cat /tmp/dev-token.txt)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
# CA в файл — set-cluster не принимает --certificate-authority-data напрямую
kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt

kubectl config set-cluster homelab-dev \
  --server="$SERVER" \
  --certificate-authority=/tmp/ca.crt \
  --embed-certs \
  --kubeconfig=/tmp/dev-kubeconfig.yaml

kubectl config set-credentials developer-sa \
  --token="$TOKEN" \
  --kubeconfig=/tmp/dev-kubeconfig.yaml

kubectl config set-context developer@homelab \
  --cluster=homelab-dev \
  --user=developer-sa \
  --namespace=sec-lab \
  --kubeconfig=/tmp/dev-kubeconfig.yaml

kubectl config use-context developer@homelab --kubeconfig=/tmp/dev-kubeconfig.yaml

# Проверка identity через token
kubectl --kubeconfig=/tmp/dev-kubeconfig.yaml auth whoami
```

**Проверено на homelab:**

```
Username    system:serviceaccount:sec-lab:developer
Groups      [system:serviceaccounts system:serviceaccounts:sec-lab system:authenticated]
```

```bash
# RBAC ещё не применён — доступа к devops-lab нет (ожидаемо no):
kubectl --kubeconfig=/tmp/dev-kubeconfig.yaml auth can-i get pods -n devops-lab

# После RoleBinding из 15.3.3:
kubectl apply -f lab/security-homelab/manifests/01-rbac-developer.yaml
kubectl --kubeconfig=/tmp/dev-kubeconfig.yaml auth can-i get deployments -n devops-lab   # yes
kubectl --kubeconfig=/tmp/dev-kubeconfig.yaml auth can-i delete secrets -n devops-lab    # no
```

### Ожидаемый результат

- Namespace `sec-lab` Active, PSA `enforce: baseline`
- SA `developer`, `readonly`, `devops`, `cicd`, `monitoring` существуют
- Token через **отдельный kubeconfig** → SA identity, **не** admin
- Без `01-rbac-developer.yaml` — `can-i` в `devops-lab` = **no**

### Откат

```bash
kubectl delete -f lab/security-homelab/manifests/10-auth-developer-sa.yaml
rm -f /tmp/dev-token.txt
```

---

## Практика: второй пользователь admin + kubeconfig (X509)

Это **отдельный** способ аутентификации от ServiceAccount token выше. Так создают **второго человека-админа** с собственным kubeconfig — стандартный production-подход на любой Kubernetes, включая Talos.

### Цель

Выпустить client certificate для пользователя `admin2`, собрать kubeconfig, убедиться что он имеет те же права что `admin`, и уметь откатить.

### Шаг 0 — посмотреть, как устроен ваш текущий admin

```bash
# Кто вы сейчас
kubectl auth whoami
# Ожидаемо:
#   Username: admin
#   Groups: [system:masters system:authenticated]

# Расшифровать subject client-сертификата из kubeconfig
openssl x509 -in <(kubectl config view --minify --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d) \
  -noout -subject
# Ожидаемо: subject=O=system:masters, CN=admin

# Почему admin = cluster-admin:
# ClusterRoleBinding "cluster-admin" привязан к ГРУППЕ system:masters, не к CN "admin"
kubectl get clusterrolebinding cluster-admin -o yaml
```

**Как API определяет identity из сертификата:**

```
client cert TLS handshake
        │
        ▼
CN  → Username   (например "admin2")
O   → Groups     (например "system:masters")
        │
        ▼
RBAC: system:masters → cluster-admin
```

### Шаг 1 — рабочая директория и приватный ключ


```bash
mkdir -p ~/kube-users/admin2
chmod 700 ~/kube-users/admin2
cd ~/kube-users/admin2

# Генерируем 2048-bit RSA ключ для admin2
# Файл admin2.key — СЕКРЕТ, хранить как пароль
openssl genrsa -out admin2.key 2048
chmod 600 admin2.key
```

### Шаг 2 — Certificate Signing Request (CSR)

> **На K8s 1.22+ (ваш v1.34.1):** CSR с `O=system:masters` **запрещён** API:
>
> ```
> Forbidden: use of kubernetes.io/kube-apiserver-client signer
> with system:masters group is not allowed
> ```
>
> Это защита от privilege escalation через CSR. Ваш `admin` получил `system:masters` при **bootstrap Talos**, не через CSR API.  
> **Рабочий путь:** CSR **без** `system:masters` + явный `ClusterRoleBinding` (вариант B).

```bash
# CN = имя пользователя в API (kubectl auth whoami → Username: admin2)
# БЕЗ O=system:masters — иначе Forbidden на K8s 1.34
openssl req -new -key admin2.key -out admin2.csr \
  -subj "/CN=admin2"

openssl req -in admin2.csr -noout -subject
# subject=CN = admin2
```

### Шаг 3 — отправить CSR в Kubernetes API

```bash
# Kubernetes подпишет сертификат только после approve человеком/контроллером
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: admin2                          # имя объекта CSR в API
spec:
  request: $(base64 -w0 admin2.csr)      # тело CSR в base64 (-w0 без переносов)
  signerName: kubernetes.io/kube-apiserver-client   # подписант для client auth
  usages:
    - client auth                        # только клиентский сертификат, не server
  expirationSeconds: 31536000            # 1 год (опционально)
EOF

# Статус должен быть Pending — ждёт approve
kubectl get csr admin2
# NAME     AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
# admin2   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   1y                  Pending
```

### Шаг 4 — одобрить CSR (только существующий admin)

```bash
# Текущий admin (вы) подтверждает: "да, этому CSR можно выдать сертификат"
kubectl certificate approve admin2

# Проверить — Condition Approved=True, в status.certificate появится base64 cert
kubectl get csr admin2
kubectl describe csr admin2 | tail -15
```

**Что произошло внутри Kubernetes:**

```
kubectl certificate approve admin2
        │
        ▼
API Server записывает Approved condition в CSR object
        │
        ▼
CSR Signing Controller (kube-controller-manager на maste1)
        │
        ▼
Подписывает CSR CA кластера → status.certificate
```

### Шаг 5 — извлечь подписанный сертификат

```bash
# Вытаскиваем готовый client certificate из объекта CSR
kubectl get csr admin2 -o jsonpath='{.status.certificate}' | base64 -d > admin2.crt
chmod 600 admin2.crt

# Проверить кому выдан и срок
openssl x509 -in admin2.crt -noout -subject -dates
# subject=CN=admin2
```

### Шаг 5b — выдать cluster-admin через RBAC (обязательно без system:masters)

```bash
# Явный ClusterRoleBinding — production-подход + работает на K8s 1.34
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin2-cluster-admin
subjects:
  - kind: User
    name: admin2                    # совпадает с CN в сертификате
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl auth can-i '*' '*' --all-namespaces --as=admin2
# yes
```

### Шаг 6 — собрать kubeconfig для admin2

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt

kubectl config set-cluster homelab \
  --server="$SERVER" \
  --certificate-authority=/tmp/ca.crt \
  --embed-certs \
  --kubeconfig=./admin2.kubeconfig

kubectl config set-credentials admin2 \
  --client-certificate=./admin2.crt \
  --client-key=./admin2.key \
  --embed-certs \
  --kubeconfig=./admin2.kubeconfig

kubectl config set-context admin2@homelab \
  --cluster=homelab \
  --user=admin2 \
  --namespace=default \
  --kubeconfig=./admin2.kubeconfig

kubectl config use-context admin2@homelab --kubeconfig=./admin2.kubeconfig

chmod 600 ./admin2.kubeconfig
```

### Шаг 7 — проверить новый kubeconfig

```bash
# Identity admin2
kubectl --kubeconfig=./admin2.kubeconfig auth whoami
# ATTRIBUTE   VALUE
# Username    admin2
# Groups      [system:authenticated]    # НЕТ system:masters — это нормально

# Права через ClusterRoleBinding admin2-cluster-admin
kubectl --kubeconfig=./admin2.kubeconfig auth can-i '*' '*' --all-namespaces
# yes

kubectl --kubeconfig=./admin2.kubeconfig get nodes
kubectl --kubeconfig=./admin2.kubeconfig get pods -A | head
```

### Шаг 8 — передать admin2 (безопасно)

```bash
# Передавать ТОЛЬКО admin2.kubeconfig (ключ и cert уже внутри embed-certs)
# НЕ отправлять admin2.key отдельно по email/slack

# На машине admin2:
export KUBECONFIG=~/admin2.kubeconfig
kubectl auth whoami
```

### Откат

```bash
kubectl delete clusterrolebinding admin2-cluster-admin
kubectl delete csr admin2
cd ~/kube-users/admin2
shred -u admin2.key admin2.crt admin2.csr admin2.kubeconfig 2>/dev/null || rm -f admin2.*
```

---

### Почему нельзя O=system:masters в CSR (K8s 1.22+)

| Способ получить admin | Работает на v1.34? |
|-----------------------|-------------------|
| Bootstrap cert Talos (`admin` + `system:masters`) | Да — выдан при создании кластера |
| CSR API с `O=system:masters` | **Нет** — Forbidden |
| CSR с `CN=admin2` + ClusterRoleBinding | **Да** — рекомендуется |

Ошибка которую вы получили — **ожидаемое поведение**, не баг. Kubernetes блокирует выдачу `system:masters` через CSR, чтобы любой пользователь с правом create CSR не мог эскалировать привилегии до cluster-admin.

**Исправление:** пересоздайте CSR **без** `O=system:masters`:

```bash
cd ~/kube-users/admin2
openssl req -new -key admin2.key -out admin2.csr -subj "/CN=admin2"
# затем шаги 3–7 с ClusterRoleBinding admin2-cluster-admin
```

---

### Вариант A (устарел для CSR API): O=system:masters

Вместо `O=system:masters` создайте **явный** ClusterRoleBinding — проще аудит и отзыв.

```bash
# CSR БЕЗ system:masters
openssl req -new -key admin2.key -out admin2.csr -subj "/CN=admin2"
# ... apply CSR, approve, получить admin2.crt как выше ...

# Явно выдать cluster-admin только пользователю admin2
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin2-cluster-admin
subjects:
  - kind: User
    name: admin2
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl auth can-i '*' '*' --all-namespaces --as=admin2
# yes
```

**Отзыв доступа вариант B** — одна команда:

```bash
kubectl delete clusterrolebinding admin2-cluster-admin
# admin2.crt ещё валиден для auth, но RBAC даст Forbidden
```

---

### Сравнение: admin vs admin2 vs SA developer

|            | admin (Talos)           | admin2 (CSR)                   | developer (SA token)                      |
| ---------- | ----------------------- | ------------------------------ | ----------------------------------------- |
| Auth       | X509 cert               | X509 cert                      | Bearer JWT                                |
| Username   | `admin`                 | `admin2`                       | `system:serviceaccount:sec-lab:developer` |
| Groups     | `system:masters`        | `system:masters` или через CRB | `system:serviceaccounts:...`              |
| kubeconfig | `~/.kube/config`        | `admin2.kubeconfig`            | token-based config                        |
| Для кого   | break-glass / bootstrap | второй админ-человек           | CI/CD, разработчик                        |

---

### Типичные ошибки (admin CSR)

| Ошибка | Почему | Fix |
|--------|--------|-----|
| CSR Pending forever | Не сделали approve | `kubectl certificate approve admin2` |
| CSR Forbidden system:masters | K8s 1.22+ блокирует escalation | CSR без O=system:masters + CRB |
| `401` с новым kubeconfig | Неверный key/cert или просрочен | Проверить `openssl x509 -dates` |
| `403` после auth OK | Нет ClusterRoleBinding | `kubectl apply` admin2-cluster-admin CRB |
| base64 ошибка в CSR | Перенос строки в `request:` | `base64 -w0` на Linux |
| Утечка admin2.key | Полный доступ к кластеру | `chmod 600`, rotate, вариант B для отзыва |

---

## Что произошло внутри Kubernetes

```
kubectl create token developer
        │
        ▼
API Server: Authentication (admin cert OK)
        │
        ▼
TokenRequest subresource на SA
        │
        ▼
Signed JWT bound to SA + namespace + audience
```

При использовании токена:

```
Request + Bearer JWT
        │
        ▼
API Server: validate signature, expiry, SA exists
        │
        ▼
Identity = system:serviceaccount:sec-lab:developer
        │
        ▼
Authorization (RBAC) — следующая глава
```

