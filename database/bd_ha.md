
## 1. Зачем знать HA и DR

**Высокая доступность** обычно формулируют так: сервис с данными **продолжает отвечать** пользователям при **типичных** сбоях (выход из строя одного узла, перезапуск ОС, кратковременная деградация сети). **Аварийное восстановление (DR)** теснее связано с **катастрофами**: потеря дата-центра, длительный простой региона, массовые повреждения носителей — когда недостаточно «переключиться на второй сервер в той же стойке».

инженер отвечает за то, чтобы архитектура и процессы соответствовали **согласованным с бизнесом целям**:

- сколько **простоя** допустимо и сколько **данных** можно потерять в худшем случае;
- какие сценарии **ручного** вмешательства приемлемы, а где нужна **автоматика**;
- не путать **репликацию** с **резервным копированием** (подробно — [8.2.4](8.2.4%20PostgreSQL%20—%20резервное%20копирование%20(теория%20и%20практика).md)).

Разработчик в первую очередь думает о корректности запросов и схемы; админ — о том, **где** физически лежат данные, **кто** из узлов принимает запись и что произойдёт при обрыве питания или **разлете** кластера по сети.

---

## 2. RPO, RTO и SLA

Чтобы обсуждать HA/DR без расплывчатых «надо надёжно», вводят метрики **восстановления**:

| Метрика | Расшифровка | Смысл |
|--------|--------------|--------|
| **RPO** (Recovery Point Objective) | Целевая точка восстановления **по данным** | Насколько **далеко в прошлое** мы готовы откатиться: «теряем не больше N минут транзакций». Зависит от частоты бэкапов, синхронности реплик и журналирования. |
| **RTO** (Recovery Time Objective) | Целевое время **восстановления сервиса** | За какое время после инцидента сервис снова **доступен** клиентам. Зависит от резервного железа, автоматики failover, размера БД и регламентов. |

**SLA** (Service Level Agreement) — договорённость с внутренним или внешним заказчиком: например «доступность 99,9% в месяц» или «критичная БД — RTO 1 ч, RPO 15 мин». Цифры SLA **выводятся** из архитектуры (реплики, бэкапы, географическое разнесение), а не наоборот.

**Пример.** Интернет-магазин: бизнес готов потерять **до 5 минут** оформленных заказов при катастрофе (RPO ≈ 5 мин), но сервис должен **встать за 30 минут** (RTO ≈ 30 мин). Тогда одной асинхронной реплики без бэкапов может не хватить по RPO; а «только ежедневный дамп» даёт RPO до суток.

---

## 3. Классы отказов и единая точка отказа

Отказы удобно классифицировать по **границе**, которую они пересекают:

| Класс | Примеры | Типичные меры |
|-------|---------|----------------|
| **Процесс / ОС** | Упал `postmaster`, утечка памяти, зависание ВМ | Мониторинг, **systemd**, перезапуск, репликация |
| **Один узел целиком** | Сгорел диск, материнская плата, гипервизор | Реплика на **другом** хосте; избегать «второй диск в том же шасси» как единственной защиты |
| **Сеть** | Разрыв между приложением и БД, **partition** между узлами кластера | Резервные пути, правильная модель **кворума**, чтобы не получить два мастера |
| **Зона / дата-центр** | Пожар, отключение питания площадки | **DR**-площадка, асинхронная репликация в другой регион, офлайн-копии |

**Единая точка отказа (SPOF)** — компонент, без которого система целиком недоступна: один диск без RAID, один коммутатор, один экземпляр PostgreSQL без реплики, один DNS без резерва, один человек с паролем суперпользователя. Задача проектирования — **явно список SPOF** согласовать с RTO/RPO.

---

## 4. Репликация в PostgreSQL: концепции

**Физическая потоковая репликация (streaming replication)** в PostgreSQL основана на **WAL** (журнале опережающей записи): первичный (**primary**, иногда говорят **master** в старой литературе) пишет изменения в WAL; **реплика (standby)** получает поток WAL и применяет его к своей копии файлов данных. Реплика в режиме **горячего резерва (hot standby)** может обслуживать **только чтение**; **запись** в один момент времени идёт на одном узле (классическая схема).

| Режим | Идея | Плюсы | Минусы |
|-------|------|--------|--------|
| **Синхронная** репликация | Commit на primary **ждёт**, пока WAL дойдёт до одной (или нескольких) синхронных standby | Меньше потерь при падении primary (лучше **RPO**) | Выше задержка записи; при проблемах с standby **блокировка** коммитов или нужен fallback-политика |
| **Асинхронная** репликация | Commit завершается на primary **до** гарантии доставки на standby | Ниже задержка, проще выдерживать удалённую реплику | **Лаг**: при внезапном падении primary транзакции, ещё не дошедшие до реплики, **теряются** с точки зрения RPO |

Выбор — компромисс между «насколько свежая копия нужна» и «насколько дорого ждать удалённый диск».

---

## 5. Промоут, split-brain и кворум

**Промоут (promote)** — перевод standby в **самостоятельный primary** (начало принимать запись). Делается осознанно при **плановом переключении** или как часть **failover** после падения старого primary.

**Split-brain** — опасное состояние, когда **два узла считают себя primary** и оба принимают запись: данные **расходятся**, автоматическое «склеить» без боли часто нельзя. Так бывает, если сеть между узлами ухудшилась, а автоматика на каждой стороне решила «я главный».

Чтобы снизить риск, вводят:

- **Кворум** — решение «кто может быть лидером» принимают **большинство** узлов или голосов (типично **нечётное** число узлов);
- **Арбитра** / **DCS** (распределённое хранилище конфигурации): **etcd**, **Consul**, **ZooKeeper** — Patroni и аналоги держат там замок на роль primary;
- **fencing** — «отрубить» старый primary питанием или сетевым изолятором, чтобы он не ожил и не начал писать.

Для одной цели занятия важно **понимать термины**; полная установка Patroni+etcd выходит за рамки одной практики, но без этой теории нельзя честно говорить о «отказоустойчивом кластере» в проде.

---

## 6. «HA в лоб», оркестрация и облако

| Подход | Смысл |
|--------|--------|
| **Ручной** primary + одна-две реплики, ручной failover | Дёшево в ПО, дорого временем админа и **ошибками** при 3:00 ночи; RTO часто большой |
| **Patroni**, **repmgr**, облачные **операторы** / **RDS**, **Cloud SQL** и т.п. | Автоматический **выбор лидера**, интеграция с балансировщиками, привычные паттерны для Kubernetes |
| **Managed PostgreSQL** | Вы платите провайдеру за **реплики, бэкапы, патчи**; всё равно нужно понимать RPO/RTO и слабые места модели |

На занятии **практика** фокусируется на **потоковой репликации** как строительном блоке; в проде этот блок почти всегда «заворачивают» в оркестратор или сервис провайдера.

---

## 7. Шардирование (горизонтальное масштабирование)

**Шардирование** — разбиение данных по **нескольким независимым узлам** (шардам), чтобы распределить **нагрузку на запись** и объём хранения. Это **не то же самое**, что **репликация**: реплика даёт **копии одного и того же** набора данных для чтения и отказоустойчивости; шарды держат **разные подмножества** строк (или ключей), и приложение (или промежуточный слой) должно **направлять запрос** на нужный узел.

Типичный подход — выбрать **ключ шардирования** (например `tenant_id`, `user_id`, географический код), вычислить номер шарда **хешом** или диапазоном, и маршрутизировать `INSERT`/`SELECT` по первичному ключу. **Сквозные JOIN** и **транзакции между шардами** становятся дорогими или невозможными без специальной инфраструктуры — это плата за масштаб.

В экосистеме PostgreSQL встречаются:

- **Прикладное** шардирование: несколько экземпляров PostgreSQL и логика в сервисе или в **pgbouncer**/прокси;
- **Citus** (расширение) — «распределённый» PostgreSQL: координатор и воркеры, распределённые таблицы и распределённые запросы;
- В **облаках** — аналоги managed-кластеров с автошардированием у других продуктов.

Для **курса DevOps** важно: шардирование **увеличивает операционную сложность** (деплой, миграции схемы, бэкапы **по каждому** шарду, наблюдаемость), зато позволяет выйти за пределы одного узла по **пропускной способности записи**. Выбор «реплика vs шард» зависит от того, упираетесь ли вы в **один primary** или в **общий объём данных и QPS записи**.

## 1. Два сервера в одной сети (Docker)

Создайте каталог, например `pg-ha-lab/`, и три файла рядом:

1. `docker-compose.yml`
2. `init-replication.sh` (выполняется **один раз** при первом создании кластера primary)
3. *(опционально)* `.env` с переопределением паролей

### 1.1. Скрипт `init-replication.sh`

Сервис **postgres** при **пустом** томе выполняет скрипты из `/docker-entrypoint-initdb.d/`. Нужны роль с правом **репликации** и строка в **`pg_hba.conf`**:

```bash
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d postgres <<-EOSQL
  CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicpass';
EOSQL
# Разрешаем потоковую репликацию с любого хоста в compose-сети (в проде сузьте адреса)
echo "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
```

Сделайте файл исполняемым: `chmod +x init-replication.sh`.

### 1.2. Файл `docker-compose.yml`

```yaml
services:
  primary:
    image: postgres:16
    container_name: pg-primary
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: appdb
    command:
      - postgres
      - -c
      - wal_level=replica
      - -c
      - max_wal_senders=16
      - -c
      - max_replication_slots=10
      - -c
      - hot_standby=on
      - -c
      - listen_addresses=*
    ports:
      - "5432:5432"
    volumes:
      - primary_data:/var/lib/postgresql/data
      - ./init-replication.sh:/docker-entrypoint-initdb.d/01-init-replication.sh:ro
    networks:
      - pgnet
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d appdb"]
      interval: 5s
      timeout: 5s
      retries: 5

  # Одноразовое заполнение тома реплики (см. раздел 2)
  basebackup:
    image: postgres:16
    profiles:
      - init
    environment:
      PGPASSWORD: replicpass
    volumes:
      - replica_data:/var/lib/postgresql/data
    networks:
      - pgnet
    depends_on:
      primary:
        condition: service_healthy
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -e
        rm -rf /var/lib/postgresql/data/*
        pg_basebackup -h primary -p 5432 -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R --create-slot -S replica_slot
    restart: "no"

  replica:
    image: postgres:16
    container_name: pg-replica
    profiles:
      - replica
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      PGDATA: /var/lib/postgresql/data
    depends_on:
      primary:
        condition: service_healthy
    command:
      - postgres
      - -c
      - hot_standby=on
    ports:
      - "5433:5432"
    volumes:
      - replica_data:/var/lib/postgresql/data
    networks:
      - pgnet

volumes:
  primary_data:
  replica_data:

networks:
  pgnet:
    driver: bridge
```

Замечания:

- Слот **`replica_slot`** создаётся параметрами **`--create-slot -S`** у `pg_basebackup` (PostgreSQL 13+), чтобы primary не удалял WAL, нужный реплике. На более старой версии создайте слот вручную на primary: `SELECT pg_create_physical_replication_slot('replica_slot');` и уберите `--create-slot` из команды.
- Сервисы **`basebackup`** и **`replica`** вынесены в **profiles**, чтобы не стартовали сами при обычном `up`: порядок ручной — см. ниже.

---

## 2. Настройка репликации (первый запуск)

1. Поднимите только **primary**:

```bash
docker compose up -d primary
```

При **первом** создании тома выполнится `init-replication.sh`. Если том уже был — скрипт **не** повторится; при ошибках удалите том: `docker compose down -v` (осторожно: сотрёт данные лабы). Повторный **`basebackup`** при уже существующем слоте **`replica_slot`** может потребовать `SELECT pg_drop_replication_slot('replica_slot');` на primary или чистого тома реплики.

2. Убедитесь, что primary здоров: `docker compose ps`, затем подключение:

```bash
psql -h localhost -p 5432 -U postgres -d appdb -c "SELECT version();"
```

3. Выполните **базовый бэкап** в том реплики (слот создаётся автоматически из примера `docker-compose.yml`):

```bash
docker compose --profile init run --rm basebackup
```

4. Поднимите **реплику**:

```bash
docker compose --profile replica up -d replica
```

5. Проверьте, что реплика в **режиме восстановления** (читает WAL с primary):

```bash
psql -h localhost -p 5433 -U postgres -d appdb -c "SELECT pg_is_in_recovery();"
```

Ожидается **`t`** (true).

---

## 3. Проверка «изменения доходят до второго сервера»

На **primary** (порт **5432**):

```sql
CREATE TABLE IF NOT EXISTS repl_demo (id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now());
INSERT INTO repl_demo (note) VALUES ('from primary');
```

На **replica** (порт **5433**) — только чтение:

```sql
TABLE repl_demo;
```

Пока реплика не отстаёт критично, строка появится. Запись на **replica** в hot standby по умолчанию **запрещена** — попытка `INSERT` должна завершиться ошибкой (это нормально).

На **primary** посмотрите потоки репликации:

```sql
SELECT application_name, client_addr, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sending_lag_bytes
FROM pg_stat_replication;
```

---

## 4. Слот репликации и **WAL**

**Слот репликации** фиксирует для сервера **минимальный WAL**, который ещё нужен реплике: primary **не** удалит сегменты WAL, пока реплика их не получит (иначе при долгом простое реплики можно «оторвать» от потока). В проде следят за диском: накопление WAL при выключенной реплике — типичный риск.

Список слотов на primary:

```sql
SELECT slot_name, slot_type, active FROM pg_replication_slots;
```

---

## 5. Отказоустойчивость: учебный ручной failover

**Автоматическое** переключение с health-checks и кворумом в проде делают **Patroni**, **repmgr**, managed-сервисы облака. В лабе достаточно понять **механику**:

1. Остановите **primary** (имитация падения узла):

```bash
docker stop pg-primary
```

2. На **replica** выполните **промоут** — перевод в самостоятельный primary:

```bash
psql -h localhost -p 5433 -U postgres -d postgres -c "SELECT pg_promote(wait_seconds => 60);"
```

Или: `docker exec pg-replica pg_ctl promote -D /var/lib/postgresql/data` (путь данных в контейнере стандартный для образа postgres).

3. Проверьте:

```bash
psql -h localhost -p 5433 -U postgres -d appdb -c "SELECT pg_is_in_recovery();"
```

Ожидается **`f`** — экземпляр принимает запись.

4. **Важно:** старый primary, если снова поднять **со старым томом**, может нарушить целостность («два мастера» с разными историями). В учебной среде после промоута старый primary обычно **не** возвращают без процедуры **re-sync** или пересоздания тома. Это иллюстрация, зачем в проде нужен **оркестратор** и **единое мнение** о лидере.

---

## 6. Две виртуальные машины (Ubuntu / Debian): пошагово командами

Ниже — **один** связный сценарий: **ВМ-primary** принимает запись, **ВМ-replica** — горячий standby. Логика та же, что в Docker; отличаются пути конфигов и **systemd**. Ориентир по установке — [8.1.2 PostgreSQL — установка и первые шаги](../8.1%20Base%20db/8.1.2%20PostgreSQL%20—%20установка%20и%20первые%20шаги.md).

**Обозначения (подставьте свои адреса):**

| Узел | IP в примере | Роль |
|------|--------------|------|
| **vm-primary** | `10.0.0.10` | primary |
| **vm-replica** | `10.0.0.11` | physical standby |

**Версия кластера:** дальше в командах используется **`16`** — замените на свою (`ls /etc/postgresql`, вывод `psql --version`).

Каталог данных **PGDATA** у пакета Debian/Ubuntu: **`/var/lib/postgresql/16/main`**. Конфиги: **`/etc/postgresql/16/main/postgresql.conf`** и **`pg_hba.conf`**.

---

### 6.1. Сеть и часы

На **обеих** ВМ:

```bash
# Имя и IP (убедитесь, что машины пингуют друг друга по внутренней сети)
hostname -f
ip -br a
ping -c 2 10.0.0.10   # с replica
ping -c 2 10.0.0.11   # с primary
```

Желательно синхронизация времени (**NTP** / `systemd-timesyncd`), иначе длинные лаги в логах и сюрпризы с SSL/сертификатами.

**Файрвол:** с **replica** на **primary** должен быть доступ **TCP 5432** (для репликации и `pg_basebackup`).

Пример **ufw** на **primary** (сузьте источник до IP реплики):

```bash
sudo ufw allow from 10.0.0.11 to any port 5432 proto tcp
sudo ufw status
```

---

### 6.2. Установка PostgreSQL на обеих ВМ

На **vm-primary** и **vm-replica** одинаково:

```bash
sudo apt update
sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
sudo systemctl status postgresql --no-pager
```

Проверка версий (на обеих должны **совпадать** мажорные):

```bash
psql --version
sudo -u postgres psql -c "SELECT version();"
```

---

### 6.3. Только на **vm-primary**: параметры сервера

Редактируйте **`/etc/postgresql/16/main/postgresql.conf`** (через `sudo nano` / `sudoedit`). Раскомментируйте и задайте (или добавьте в конец):

```text
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
```

Перезапуск и проверка:

```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql --no-pager
sudo -u postgres psql -d postgres -c "SHOW listen_addresses; SHOW wal_level;"
```

Убедитесь, что слушает все интерфейсы:

```bash
sudo ss -tlnp | grep 5432
```

---

### 6.4. Только на **vm-primary**: роль репликации и `pg_hba.conf`

Подключитесь под **postgres** и создайте пользователя потоковой репликации (пароль замените):

```bash
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicpass';"
```

В файл **`/etc/postgresql/16/main/pg_hba.conf`** добавьте **поверх** существующих строк (не открывайте всему интернету — укажите **IP реплики**):

```text
host    replication     replicator      10.0.0.11/32           scram-sha-256
```

При необходимости добавьте строку для **обычного** подключения `psql` с админской машины (не для репликации) — по политике вашей сети.

Перечитать конфиг **без** полного рестарта:

```bash
sudo systemctl reload postgresql
```

Проверка с **vm-replica** (должен быть ответ «принимает соединения»):

```bash
# на vm-replica
sudo apt install -y postgresql-client   # если нет клиента
pg_isready -h 10.0.0.10 -p 5432
```

---

### 6.5. Только на **vm-replica**: остановить сервис и очистить каталог данных

На реплике кластер уже инициализирован пакетом — для **`pg_basebackup`** каталог **`main`** должен быть **пустым** (или его нужно заменить целиком). **Сотрёт локальные данные реплики.**

```bash
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/16/main "/var/lib/postgresql/16/main.bak.$(date +%Y%m%d%H%M%S)"
sudo mkdir -p /var/lib/postgresql/16/main
sudo chown postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main
```

---

### 6.6. Только на **vm-replica**: `pg_basebackup` с потоком WAL

Запуск от пользователя **postgres**. Пароль **`PGPASSWORD`** — тот же, что у **`replicator`** на primary:

```bash
sudo -u postgres bash -c 'export PGPASSWORD=replicpass
pg_basebackup \
  -h 10.0.0.10 -p 5432 \
  -U replicator \
  -D /var/lib/postgresql/16/main \
  -Fp -Xs -P -R \
  --create-slot -S replica_slot'
```

Флаги кратко: **`-Fp`** — plain (формат каталога), **`-Xs`** — стримить WAL при копировании, **`-P`** — прогресс, **`-R`** — записать **`primary_conninfo`** и создать **`standby.signal`** (PostgreSQL 12+), **`--create-slot -S`** — слот **`replica_slot`** на primary.

Если версия PostgreSQL **< 13**, уберите **`--create-slot`** и на primary заранее выполните:

```sql
SELECT pg_create_physical_replication_slot('replica_slot');
```

и в **`pg_basebackup`** укажите **`-S replica_slot`** без **`--create-slot`**.

Права после копирования (обычно уже верные):

```bash
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo chmod 700 /var/lib/postgresql/16/main
```

---

### 6.7. Запуск реплики и проверки

```bash
sudo systemctl start postgresql
sudo systemctl status postgresql --no-pager
sudo -u postgres psql -d postgres -c "SELECT pg_is_in_recovery();"
```

Ожидается **`t`**.

На **vm-primary**:

```bash
sudo -u postgres psql -d postgres -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
sudo -u postgres psql -d postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

Дальше повторите **§3** этой методички: создайте таблицу на primary, вставьте строку, прочитайте на replica (подключаясь к **`10.0.0.11`**). Приложение **`psql`**:

```bash
psql -h 192.168.1.21 -U postgres -d postgres   # primary
psql -h 10.0.0.11 -U postgres -d postgres   # replica
```

---

### 6.8. Учебный failover на ВМ (аналог §5)

1. На **vm-primary**:

```bash
sudo systemctl stop postgresql
```

2. На **vm-replica**:

```bash
sudo -u postgres psql -d postgres -c "SELECT pg_promote(wait_seconds => 120);"
sudo -u postgres psql -d postgres -c "SELECT pg_is_in_recovery();"
```

Должно стать **`f`**. Проверка записи:

```bash
sudo -u postgres psql -d postgres -c "CREATE TABLE IF NOT EXISTS promote_test(id int); INSERT INTO promote_test VALUES (1);"
```

3. Восстановление **старого primary** «как было» без оркестратора опасно: см. предупреждение в **§5**. Для новой попытки лабы часто проще **пересоздать** кластер или заново выполнить **§6.5–6.6** после приведения ролей к одному primary.

---

### 6.9. Типичные ошибки на ВМ

| Симптом | Что проверить |
|---------|----------------|
| `pg_basebackup: error: connection to server` | Файрвол primary, **`listen_addresses`**, маршрут до `10.0.0.10`, **`pg_hba`** с **IP реплики**, пароль **`replicator`**. |
| `password authentication failed` | Пароль в **`PGPASSWORD`**, метод **`scram-sha-256`** в **`pg_hba`**. |
| Реплика не стартует | Права на **`/var/lib/postgresql/16/main`**, целостность копии; лог **`journalctl -u postgresql -e`**. |
| Нет строк в **`pg_stat_replication`** | Реплика не подключилась к primary: сеть, **`primary_conninfo`** в **`postgresql.auto.conf`** на реплике (создаётся **`-R`**). |

---

# Часть I. Теория

## 1. Репликация не заменяет резервное копирование

**Реплика** защищает от отказа **узла**, но не от:

- **DROP DATABASE** или массового **DELETE**, **реплицированных** на все копии с тем же лагом;
- **взлома** с повреждением или шифрованием данных;
- **логической** ошибки приложения, испортившей данные и уже отправленной в WAL;
- сценария «удалили бэкап по ошибке только на одной копии» — реплики обычно синхронны по смыслу данных.

Отдельно хранимый **бэкап** (с **ретенцией**, **офлайн**-копией, иногда в другом регионе) задаёт верхнюю границу **RPO** при восстановлении **с нуля** или на **момент времени** (см. §2). Регулярная **проба восстановления** (хотя бы на тестовый стенд) — часть зрелой эксплуатации, иначе бэкап может оказаться битым годами.

---

## 2. Резервное копирование баз данных: виды и задачи

### 2.1. Логические бэкапы

Это **дамп SQL** или специального формата через клиентские утилиты (**`pg_dump`**, **`pg_dumpall`**). Плюсы: переносимость между версиями (с оговорками), можно бэкапить **одну БД** или **только схему**, удобно для миграций. Минусы: для очень больших БД долго и ресурсно; снимок **не мгновенный** (консистентность на уровне **транзакции снимка**, если не мешают долгие DDL в старых версиях). Типично **RPO** — интервал между запусками джоба (час, сутки).

**`pg_dumpall`** выгружает **глобальные** объекты (роли, права), что нужно для «поднять кластер с нуля» вместе с **`pg_dump`** по базам.

### 2.2. Физические бэкапы

Это копия **файлов кластера** (каталога данных) в согласованном состоянии: **`pg_basebackup`**, снимок ФС (если поддерживается **резервная копия** на уровне СХД с freeze), образ ВМ. Плюсы: быстрее для больших объёмов, база для **полного** восстановления узла. Минусы: привязка к **конкретной** major-версии PostgreSQL и платформе; без **архива WAL** вы восстанавливаетесь только на **момент** окончания копии.

**`pg_basebackup`** часто делают с **реплики** (где разрешено), чтобы не нагружать primary — при корректной настройке и версии.

### 2.3. Непрерывное архивирование WAL и PITR

Если настроен **`archive_mode`** и **`archive_command`** (или облачный аналог), сегменты **WAL** копируют в надёжное хранилище. Тогда при наличии **базового** физического бэкапа можно восстановиться на **произвольный момент времени** (**Point-in-Time Recovery, PITR**) — до сбоя, **до** ошибочного `DROP`, если известно время. Это сильно улучшает **RPO** по сравнению с «один дамп в сутки».

Эксплуатация: мониторинг **очереди** архива, место на носителе, **ретенция**, периодическое **тестовое восстановление**.

### 2.4. Политика и автоматизация

Фиксируют: **кто** отвечает за бэкапы, **куда** пишут (S3-совместимое, отдельный ДЦ), **как долго** хранят, **как часто** проверяют восстановление. Инструменты: **cron**/systemd timers, **WAL-G**, **pgBackRest**, **Barman** (практика в **части III** ниже), встроенные решения **managed PostgreSQL**.

Примеры команд **`pg_dump`** / **`pg_restore`** — в **части II**.

---

# Часть II. Практика: `pg_dump`, `pg_restore`, `pg_basebackup`

Команды выполняйте на хосте с установленным клиентом (**`postgresql-client`**), если не указано иное; пути к каталогам дампов — свои.

> Пароли в примерах замените; в проде — **отдельная роль** только на чтение/`BACKUP`, не суперпользователь без нужды.

## 1. Логический дамп одной БД (настраиваемый формат)

Удобно для **восстановления выборочно** (таблицы, параллель **`pg_restore`**):

```bash
mkdir -p ~/pg-backups
pg_dump -h localhost -p 5432 -U postgres -d appdb \
  -Fc -Z6 -f ~/pg-backups/appdb_$(date +%Y%m%d_%H%M).dump
```

- **`-Fc`** — custom (сжатый каталог объектов в одном файле).
- **`-Z6`** — степень сжатия (0–9).

Список содержимого дампа:

```bash
pg_restore --list ~/pg-backups/appdb_*.dump | head -40
```

(**`head -40`** — только чтобы не засыпать терминал; полный список без пайпа.)

Восстановление **в пустую** БД (создайте `appdb_restored` заранее):

```bash
createdb -h localhost -U postgres appdb_restored
pg_restore -h localhost -p 5432 -U postgres -d appdb_restored \
  --no-owner --no-privileges \
  ~/pg-backups/appdb_YYYYMMDD_HHMM.dump
```

## 2. Плоский SQL-дамп (один файл)

```bash
pg_dump -h localhost -p 5432 -U postgres -d appdb \
  --no-owner -f ~/pg-backups/appdb_$(date +%Y%m%d_%H%M).sql
```

Восстановление:

```bash
psql -h localhost -p 5432 -U postgres -d appdb_restored -f ~/pg-backups/appdb_YYYYMMDD_HHMM.sql
```

## 3. Только схема или только данные

```bash
pg_dump -h localhost -U postgres -d appdb -s -f ~/pg-backups/appdb_schema.sql
pg_dump -h localhost -U postgres -d appdb -a -t repl_demo -f ~/pg-backups/repl_demo_data.sql
```

## 4. Кластер целиком: роли и глобальные объекты

```bash
pg_dumpall -h localhost -p 5432 -U postgres --globals-only \
  -f ~/pg-backups/globals_$(date +%Y%m%d).sql
```

## 5. Физический бэкап каталога (`pg_basebackup`)

Пример в отдельный каталог на **сервере БД** (роль **`replicator`** должна существовать, см. [8.2.2](8.2.2%20PostgreSQL%20—%20репликация%20и%20кластер%20(практика).md)):

```bash
sudo install -d -o postgres -g postgres -m 0750 /var/backups/pg
sudo -u postgres bash -lc 'export PGPASSWORD="пароль_роли_replicator"
pg_basebackup -h 127.0.0.1 -p 5432 -U replicator \
  -D /var/backups/pg/base_$(date +%Y%m%d_%H%M) \
  -Fp -Xs -P -c -l "weekly base backup"'
```

- **`-c`** — checkpoint перед снятием копии.

Восстановление физической копии — по документации версии PostgreSQL (остановка инстанса, замена/подмена `PGDATA`, права, при PITR — **`recovery.signal`** / настройки в вашей ветке версии).

## 6. Минимальный чек «бэкап не пустой»

```bash
ls -lh ~/pg-backups/
pg_restore --list ~/pg-backups/appdb_*.dump | wc -l
```

Регулярно проверяйте **полное восстановление** на тестовый инстанс.

---

# Часть III. Практика: настройка Barman

**Barman** (Backup and Recovery Manager) — серверное ПО для **физических** бэкапов PostgreSQL, **архива WAL** и **PITR**. Официальная документация: [https://docs.pgbarman.org/](https://docs.pgbarman.org/). Ниже — **учебный минимум** на двух Linux-хостах; имена пакетов, пути и точный синтаксис **`archive_command`** сверяйте с докой и версией **Barman/PostgreSQL** у себя.

## 1. Топология

| Узел | Роль |
|------|------|
| **backup-srv** | Установлен **Barman**, каталоги бэкапов и WAL |
| **pg-srv** | Работающий **PostgreSQL** (`listen_addresses`, доступ с backup-srv) |

Требуется **безпарольный SSH** с **backup-srv** на **pg-srv** под пользователем, от которого вы будете делать **`ssh_command`** в конфиге (часто **`postgres`** на обеих машинах — только если политика ИБ позволяет; в проде иногда отдельный **системный** пользователь и доступ к `PGDATA` через sudo/doc).

**Время** на обоих узлах синхронизировано (**chrony**).

## 2. Установка Barman на backup-srv

Ориентир **Debian/Ubuntu**:

```bash
sudo apt update
sudo apt install -y barman
barman --version
```

Каталог задан по умолчанию в **`/etc/barman.conf`** (например **`barman_home`**); при необходимости вынесите на отдельный диск.

## 3. Доступ по SSH с backup-srv на pg-srv

На **backup-srv** от имени того пользователя, под которым будет работать Barman (пример — ваш обычный админ + `sudo`, или отдельный `barman`):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/barman_to_pg -N ""
ssh-copy-id -i ~/.ssh/barman_to_pg.pub postgres@<IP_pg-srv>
ssh -i ~/.ssh/barman_to_pg postgres@<IP_pg-srv> "hostname"
```

В конфиге ниже **`ssh_command`** должен совпадать с реальным вызовом (ключ, пользователь, хост).

## 4. Станза сервера в `/etc/barman.d/`

Создайте файл, например **`/etc/barman.d/pg.conf`** (как в поставляемых шаблонах дистрибутива):

```ini
[pg]
description = "Учебный PostgreSQL"
conninfo = host=<IP_pg-srv> user=postgres port=5432 dbname=postgres
ssh_command = ssh -i /home/<admin>/.ssh/barman_to_pg postgres@<IP_pg-srv>
backup_method = postgres
retention_policy_mode = auto
retention_policy = RECOVERY WINDOW OF 7 DAYS
wal_retention_policy = main
```

- **`backup_method = postgres`** — копия через протокол PostgreSQL (аналогично **`pg_basebackup`**), без прямого rsync `PGDATA`.
- Политики **retention** подстройте под **RPO**/место на диске.

Проверка конфигурации:

```bash
sudo barman check pg
```

Исправьте все **ERROR** до продолжения (доступ `conninfo`, SSH, версии, права каталогов).

## 5. Архив WAL с pg-srv на backup-srv

На **pg-srv** в **`postgresql.conf`** (и перезагрузка/перечитка по типу параметра):

```text
wal_level = replica
archive_mode = on
```

**`archive_command`** зависит от того, как пакет Barman предлагает передавать WAL: обычно на сервере PostgreSQL ставят клиент **`barman-cli`** и задают команду вроде передачи файла `%p` на **backup-srv** с указанием **имени станзы** (`pg`). Точная строка — в разделе «WAL archiving» документации для вашей версии; после правки:

```bash
sudo systemctl reload postgresql
```

На **backup-srv** снова:

```bash
sudo barman check pg
```

## 6. Первый полный бэкап и список копий

```bash
sudo barman backup pg
sudo barman list-backup pg
sudo barman show-backup pg latest
```

Планируйте **`barman backup`** через **cron** или **systemd timer** согласно **RPO**.

## 7. Восстановление (учебно)

Восстановление в новый каталог (пример — удалённый хост или локальный путь; **не** подменяйте рабочий `PGDATA` без остановки и runbook):

```bash
sudo barman recover pg latest /var/lib/postgresql/restore-demo --remote-ssh-command "ssh postgres@<IP_pg-srv>"
```

Флаги **`--target-time`**, **`--target-xid`** и удалённый запуск — по доке **barman recover** для **PITR**. После восстановления поднимайте PostgreSQL по процедуре для полученного каталога (версия совпадает с бэкапом).
