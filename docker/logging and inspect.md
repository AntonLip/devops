
# Docker — инспекция и логирование

Эксплуатация контейнеров опирается на **наблюдаемость**: что за объект создан, какие у него сеть, тома, переменные окружения, лимиты; что пишет приложение в stdout/stderr; как не переполнить диск логами. Ниже — инструменты Docker CLI и настройки **драйвера логирования** на демоне.

Документация: [`docker inspect`](https://docs.docker.com/reference/cli/docker/inspect/), [`docker logs`](https://docs.docker.com/reference/cli/docker/container/logs/), [Configure logging drivers](https://docs.docker.com/config/containers/logging/configure/), [JSON-file log options](https://docs.docker.com/config/containers/logging/json-file/).

---

## 1. Инспекция: `docker inspect`

Команда выводит **JSON** с полной конфигурацией объекта Docker.

```bash
docker inspect имя_контейнера_или_id
docker inspect имя_образа
docker inspect имя_volume
docker inspect имя_network
```

### 1.1. Шаблоны Go (`--format`)

Без постобработки JSON неудобен; **`--format`** вытаскивает поле:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mycontainer
docker inspect -f '{{json .Mounts}}' mycontainer | jq .
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' mycontainer
```

Синтаксис шаблонов — как в [Go `text/template`](https://pkg.go.dev/text/template); корень для контейнера — структура с полями `NetworkSettings`, `Config`, `HostConfig` и т.д.

### 1.2. Утилита `jq`

Для сложной фильтрации удобно передавать JSON в **`jq`**:

```bash
docker inspect mycontainer | jq '.[0].NetworkSettings.Ports'
docker inspect mycontainer | jq '.[0].HostConfig.Memory'
```

---

## 2. Состояние и живые метрики

| Команда                      | Назначение                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `docker ps` / `docker ps -a` | Список контейнеров, статус, порты                                                               |
| `docker stats [контейнеры]`  | CPU, память, сеть, диск I/O в реальном времени                                                  |
| `docker top контейнер`       | Процессы внутри контейнера (через cgroup/namespace на хосте)                                    |
| `docker events`              | Поток событий демона (create, start, die, destroy…) — полезно для отладки интеграций и скриптов |

Пример **stats** одного контейнера:

```bash
docker stats --no-stream mycontainer
```

**События** с фильтром по контейнеру:

```bash
docker events --filter container=mycontainer --since 10m
```

---

## 3. Логи контейнера: `docker logs`

Приложение в контейнере обычно пишет в **stdout** и **stderr**; Docker **собирает** эти потоки через драйвер логирования.

| Опция | Назначение |
|-------|------------|
| `-f` / `--follow` | Поток в реальном времени (как `tail -f`) |
| `--tail N` | Только последние N строк |
| `--since` / `--until` | Временной диапазон (RFC3339 или относительный, например `10m`) |
| `-t` / `--timestamps` | Добавить временные метки |

Пример:

```bash
docker logs -f --since 5m --tail 100 mycontainer
```

Логи доступны для **остановленного** контейнера, пока он не удалён (`docker rm`), если драйвер сохраняет их на диске (для `json-file` так и есть).

---

## 4. Драйверы логирования (концепция)

Драйвер определяет, **куда** демон складывает логи. Задаётся:

- для контейнера: **`docker run --log-driver ... --log-opt ...`**;
- по умолчанию для демона: в **`daemon.json`** (`"log-driver"`, `"log-opts"`).

Частые драйверы:

| Драйвер                             | Куда пишутся логи                                        | Заметки                                         |
| ----------------------------------- | -------------------------------------------------------- | ----------------------------------------------- |
| **json-file**                       | Файлы на диске хоста (по умолчанию на многих установках) | Простая отладка; нужна **ротация** (см. ниже)   |
| **local**                           | Бинарный сжатый формат Docker                            | Меньше накладных расходов, те же задачи ротации |
| **syslog**                          | Удалённый или локальный syslog                           | Централизация в SIEM                            |
| **journald**                        | systemd journal на хосте                                 | Типично на дистрибутивах с systemd              |
| **gelf**, **fluentd**, **awslogs**… | Внешние системы                                          | Продакшен и облака                              |

Список поддерживаемых драйверов на вашем демоне:

```bash
docker info --format '{{.Plugins.Log}}'
```

---

## 5. Ротация и лимиты: `json-file` и демон (подробно)

Проблема: при **json-file** каждый контейнер пишет в один или несколько файлов в каталоге данных Docker (часто под `/var/lib/docker/containers/<id>/<id>-json.log`). Без лимитов **быстрый спам в stdout** заполняет корневой раздел — классический инцидент.

### 5.1. Опции на уровне контейнера (`--log-opt`)

Для драйвера **`json-file`** (имена опций см. [документацию](https://docs.docker.com/config/containers/logging/json-file/)):

| Опция | Смысл |
|-------|--------|
| `max-size` | Максимальный размер **одного** лог-файла до ротации (например `10m`, `100k`) |
| `max-file` | Сколько файлов ротации **хранить** (циклическая ротация) |

Пример запуска с ротацией:

```bash
docker run -d --name apilog --log-driver json-file \
  --log-opt max-size=5m --log-opt max-file=3 \
  alpine:3.19 sh -c 'while true; do date; sleep 0.1; done'
```

Проверка роста и чтение:

```bash
docker logs --tail 5 apilog
docker inspect -f '{{.HostConfig.LogConfig}}' apilog
docker rm -f apilog
```

### 5.2. Глобальные настройки демона (`daemon.json`)

Файл обычно **`/etc/docker/daemon.json`** (путь может отличаться). Пример фрагмента для дефолтного логирования всех новых контейнеров:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "25m",
    "max-file": "5"
  }
}
```

После изменения **`daemon.json`** нужен **перезапуск Docker** (`systemctl restart docker` и аналоги). На проде делают в окно обслуживания и проверяют, что оркестратор/k8s не ломается (в k8s логи часто забирает kubelet другим путём).

### 5.3. Rootless и пути

В **rootless** режиме данные и логи лежат в домашнем каталоге пользователя; принципы **`max-size` / `max-file`** те же.

### 5.4. Внешняя агрегация

Когда логи уходят в **ELK**, **Loki**, **CloudWatch**, драйвер меняют на соответствующий; ротация на диске хоста становится менее критичной, но появляются **сетевые сбои**, **буферы** и **стоимость** приёма — это уже дизайн платформы.

---

## 6. Практика — inspect и логи

Запустите контейнер с переменной окружения и томом (упрощённо):

```bash
docker volume create insp-demo-vol
docker run -d --name insp-demo -e DEMO=123 \
  -v insp-demo-vol:/data \
  alpine:3.19 sh -c 'echo start; while true; do date >>/data/tick.log; sleep 2; done'
```

Задания:

1. Найти IP в пользовательской сети по умолчанию:  
   `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' insp-demo`
2. Вывести маунты:  
   `docker inspect insp-demo | jq '.[0].Mounts'`
3. Стрим логов с ограничением:  
   `docker logs -f --tail 3 insp-demo` (остановить `Ctrl+C` — контейнер не останавливается)
4. Остановить и убрать:  
   `docker rm -f insp-demo && docker volume rm insp-demo-vol`
