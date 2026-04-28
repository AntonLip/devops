
# 1. Как устроено системное логирование

В современных дистрибутивах логирование строится в два слоя. Первый — **journald**, часть systemd: он первым принимает сообщения от ядра, от сервисов и от приложений, пишущих в syslog. Всё это попадает в единый журнал в бинарном формате с индексацией по полям (время, unit, PID, уровень и т.д.). Второй слой — **rsyslog**: он может читать данные из journald (модуль imjournal) и раскладывать их по привычным текстовым файлам в `/var/log/`, а также пересылать логи на удалённые серверы. В результате журнал даёт быстрый поиск и фильтрацию, а текстовые файлы остаются для старых скриптов, парсеров и людей, привыкших к `tail -f /var/log/syslog`.

## journald и journalctl

journald не требует отдельной настройки для сбора логов: он уже получает вывод сервисов (stdout/stderr), сообщения ядра (через `/dev/kmsg`) и то, что приложения шлют в syslog. По умолчанию журнал может храниться только в памяти или в `/run/log/journal/` и пропадает после перезагрузки. Чтобы логи переживали перезагрузку, в `/etc/systemd/journald.conf` выставляют `Storage=persistent` и создают каталог `/var/log/journal/` с нужными владельцем и правами (root:systemd-journal, 2755). После перезапуска `systemd-journald` журнал начнёт писаться на диск.

Просмотр и поиск — через **journalctl**. Без аргументов он выводит весь журнал (с пейджером). В жизни чаще нужны ограничения: логи одного сервиса (`journalctl -u sshd`), последние N строк (`-n 50`), поток в реальном времени (`-f`), только за последний час (`--since "1 hour ago"`) или только сообщения уровня error и выше (`-p err`). Удобно комбинировать: например, `journalctl -u myapp --since "10 min ago" -p err`. Вывод в JSON (`-o json`) пригождается для скриптов. Очистка старых записей — `journalctl --vacuum-time=30d` или `--vacuum-size=500M`; текущее занятие места покажет `journalctl --disk-usage`.

В `journald.conf` имеет смысл выставить лимиты, чтобы журнал не разросся: `SystemMaxUse=`, `SystemKeepFree=`, при необходимости `MaxRetentionSec=`. По умолчанию включено сжатие. Если нужна пересылка в классический syslog (в rsyslog), оставляют или включают `ForwardToSyslog=yes`.

## rsyslog

rsyslog настраивается в `/etc/rsyslog.conf` и в файлах из `/etc/rsyslog.d/`. Правила вида «что куда писать» задаются парами селектор + действие. Селектор — это facility и уровень (например, `mail.*`, `*.err`, `kern.warning`). Действие — путь к файлу, удалённый хост (UDP `@host:514`, TCP `@@host:514`) или ещё один модуль. Типичная схема: общий поток идёт в `/var/log/syslog` или `/var/log/messages`, auth — в `auth.log`/`secure`, kernel — в `kern.log`. Для проверки конфига перед применением: `rsyslogd -N1`; после правок — `systemctl restart rsyslog`.

## Уровни и категории сообщений (severity и facility)

Сообщения в syslog помечаются уровнем серьёзности (severity) от 0 до 7: 0 — emerg (система неработоспособна), 1 — alert, 2 — crit, 3 — err, 4 — warning, 5 — notice, 6 — info, 7 — debug. Чем меньше число, тем серьёзнее. Плюс указывается категория источника (facility): kern, user, mail, daemon, auth, syslog, cron и локальные local0–local7. В конфиге rsyslog это выглядит как `facility.level` (например, `*.crit` — всё с уровнем crit и выше). В journalctl фильтр по уровню: `-p err` (err и выше), `-p warning..err` (диапазон). Понимание уровней и facility помогает и при просмотре логов, и при настройке фильтров и маршрутизации.

| Уровень | Ключевое слово | Смысл |
|---------|----------------|--------|
| 0 | emerg | Система неработоспособна |
| 1 | alert | Требуется немедленное действие |
| 2 | crit | Критические условия |
| 3 | err | Ошибки |
| 4 | warning | Предупреждения |
| 5 | notice | Заметные, но нормальные события |
| 6 | info | Информационные |
| 7 | debug | Отладочные |

---

# 2. Логи ядра

До старта пользовательских демонов (в том числе rsyslog и в какой-то мере journald) ядро пишет сообщения в кольцевой буфер в памяти — kernel ring buffer. При загрузке туда попадают сообщения о драйверах, устройствах, сетевых интерфейсах; при заполнении старые записи затираются новыми. Смотреть этот буфер можно командой **dmesg**. Она просто читает текущее содержимое буфера. Полезные опции: `-T` — человекочитаемые временные метки, `-l err` — только сообщения уровня error, `-w` — ждать новые (аналог follow). Часто достаточно `dmesg | tail -50` или `dmesg | grep -i error`, чтобы увидеть последние события или только ошибки.

В работающей системе ядро продолжает писать в буфер, но обычно эти сообщения уже подхватывает journald (через `/dev/kmsg`) или классический демон klogd и передаёт в rsyslog. Поэтому те же сообщения ядра можно смотреть через `journalctl -k` (только kernel), в том числе за прошлую загрузку: `journalctl -k -b -1`. Файл `/proc/kmsg` — низкоуровневый интерфейс чтения того же потока; его, как правило, читает один процесс (klogd или аналог), вручную его дергать не стоит.

Для прикладных сервисов логи ядра нужны не всегда: они скорее про драйверы, железо, сеть. Но если сервис не видит устройство или падает при работе с сетью, после просмотра journalctl по unit имеет смысл глянуть dmesg или `journalctl -k` — там могут быть ошибки драйвера или отказ устройства.

---

# 3. Файлы логов и управление ими

Классическое место для текстовых логов — каталог `/var/log/`. В Debian/Ubuntu общий поток часто идёт в `syslog`, в RHEL/CentOS — в `messages`; аутентификация — в `auth.log` или `secure`, ядро — в `kern.log`. Отдельные сервисы (nginx, apache, почта) создают свои файлы или подкаталоги. Формат строки обычно: дата-время, хост, имя программы или сервиса, иногда PID, затем текст сообщения. Просматривают их через `less`, `tail -f`, поиск — через `grep`.

Чтобы логи не заполняли диск, используется **logrotate**. Он по расписанию (cron) или вручную переименовывает/архивирует текущий файл и даёт приложению снова писать в «свежий» файл. Настройки — в `/etc/logrotate.conf` (общие правила) и в `/etc/logrotate.d/` (отдельно по сервисам). В блоке для файла задают частоту (daily, weekly, size 100M), сколько ротаций хранить (rotate N), сжатие (compress, delaycompress), при необходимости — скрипт после ротации (postrotate), например перезагрузка конфига nginx. Проверка без применения: `logrotate -d /etc/logrotate.conf`; принудительный прогон: `logrotate -f /etc/logrotate.conf`.

Журнал journald тоже нужно ограничивать. Помимо настроек в `journald.conf` (SystemMaxUse, MaxRetentionSec) полезны команды vacuum: `journalctl --vacuum-time=30d`, `journalctl --vacuum-size=500M`. Постоянное хранение включается созданием `/var/log/journal` и параметром `Storage=persistent` (или `auto` при наличии этого каталога).

В целом стоит приучить себя: не хранить логи бесконечно, задавать лимиты и ротацию, при нескольких серверах думать о централизованном сборе (Loki, ELK, Graylog и т.п.), а для чувствительных систем — о правах на файлы логов и при необходимости шифровании при пересылке.

---

# Практика: один сервис — все уровни логов

### Просмотр логов сервиса в журнале

```bash
journalctl -u myapp
```

**Пояснение:** выводятся все записи журнала, относящиеся к unit `myapp`. Внизу — самые свежие. Выход из пейджера — `q`.

### Последние N строк

```bash
journalctl -u myapp -n 50
```

**Пояснение:** показываются только последние 50 записей. Удобно, когда не нужен весь поток с начала.

### Просмотр в реальном времени (follow)

```bash
journalctl -u myapp -f
```

**Пояснение:** новые записи по myapp выводятся по мере появления. Остановка — Ctrl+C. Используется при отладке «здесь и сейчас».

### Фильтр по времени

```bash
journalctl -u myapp --since "10 min ago"
```

**Пояснение:** только записи за последние 10 минут. Можно задать и по-другому: `--since "2025-01-31 09:00:00"`, `--until "1 hour ago"`.

### Только сообщения уровня error и выше

```bash
journalctl -u myapp -p err
```

**Пояснение:** выводятся записи с уровнем err, crit, alert, emerg. Помогает отсечь шум и смотреть только ошибки.

### Комбинация фильтров

```bash
journalctl -u myapp --since "1 hour ago" -p err -n 20
```

**Пояснение:** за последний час, только ошибки, не более 20 записей. Так обычно ищут недавние сбои.

### Логи приложения в /var/log/syslog

На большинстве дистрибутивов (Debian, Ubuntu и др.) логи от сервисов, пишущих в journal (в том числе myapp), **автоматически** попадают в `/var/log/syslog`: rsyslog читает журнал (модуль imjournal) или journald по умолчанию пересылает в syslog (`ForwardToSyslog=yes` в `journald.conf`). Дополнительно ничего настраивать не нужно.

**Проверка:**

```bash
grep myapp /var/log/syslog
```

На RHEL/CentOS общий лог чаще в `messages`:
```bash
grep myapp /var/log/messages
```

**Пояснение:** вы увидите те же сообщения myapp, что и в `journalctl -u myapp`, но в виде обычных строк в общем системном логе. Если логов там нет — проверьте, что запущен rsyslog (`systemctl status rsyslog`) и в `/etc/systemd/journald.conf` в секции `[Journal]` указано `ForwardToSyslog=yes` (в unit-файле сервиса этот параметр указывать нельзя — см. предупреждение во вступлении).

---

## Логи ядра (в контексте того же сервиса)

Сервис myapp сам в ядро не пишет; логи ядра нужны, когда подозреваете проблему с устройством, драйвером или сетью.

### Последние сообщения ядра с человекочитаемым временем

```bash
dmesg -T | tail -30
```

**Пояснение:** `dmesg` читает кольцевой буфер ядра; `-T` выводит время в привычном формате; `tail -30` — последние 30 строк.

### Только ошибки ядра

```bash
dmesg -l err
```

**Пояснение:** выводятся только сообщения ядра с уровнем err (и при необходимости можно добавить warn: `dmesg -l err,warn`).

### Логи ядра через journal (текущая и прошлая загрузка)

```bash
journalctl -k
journalctl -k -b -1
```

**Пояснение:** `-k` — только сообщения ядра; `-b -1` — за предыдущую загрузку. Удобно, если нужно посмотреть, что ядро писало при последнем boot.

---

## Вывод логов сервиса в файл и просмотр в /var/log

### Изменение unit: писать логи в файл

Откройте unit-файл:

```bash
sudo nano /etc/systemd/system/myapp.service
```

В секции `[Service]` замените (или добавьте) строки вывода на:

```ini
StandardOutput=append:/var/log/myapp.log
StandardError=append:/var/log/myapp.log
```

Сохраните файл (в nano: Ctrl+O, Enter, Ctrl+X).

**Пояснение:** `append:` означает, что новые записи дописываются в конец файла, а не перезаписывают его. Без этого при каждом рестарте сервиса файл бы обнулялся.

### Создание файла лога и прав (если systemd не создаст сам)

```bash
sudo touch /var/log/myapp.log
sudo chown myapp:myapp /var/log/myapp.log
sudo chmod 640 /var/log/myapp.log
```

**Пояснение:** сервис работает от пользователя `myapp`; файл должен быть ему доступен на запись. На части дистрибутивов systemd сам создаёт файл при первом выводе — тогда этот шаг можно пропустить.

### Перезагрузка конфигурации systemd и рестарт сервиса

```bash
sudo systemctl daemon-reload
sudo systemctl restart myapp
```

**Пояснение:** `daemon-reload` нужен после любого изменения unit-файла; иначе systemd продолжит использовать старый конфиг.

### Проверка появления логов в файле

```bash
tail -f /var/log/myapp.log
```

**Пояснение:** вывод в реальном времени. Остановка — Ctrl+C. Убедитесь, что в файле появляются строки от приложения.

```bash
ls -la /var/log/myapp.log
cat /var/log/myapp.log
```

**Пояснение:** проверка существования файла, прав и содержимого.

---

## Ротация лога приложения (logrotate)

### Создание конфигурации logrotate для myapp

```bash
sudo nano /etc/logrotate.d/myapp
```

Введите (или вставьте) конфигурацию:

```
/var/log/myapp.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    missingok
    create 0640 myapp myapp
}
```

Сохраните файл.

**Пояснение:**
- `daily` — ротация раз в день;
- `rotate 7` — хранить 7 старых файлов (неделя);
- `compress` — сжимать ротированные файлы (gzip);
- `delaycompress` — сжимать не текущий переименованный файл, а предыдущий (чтобы сервис мог ещё дописывать в переименованный);
- `notifempty` — не ротировать пустой файл;
- `missingok` — не считать ошибкой отсутствие файла;
- `create 0640 myapp myapp` — после ротации создать новый файл с такими правами и владельцем.

### Проверка конфигурации logrotate (dry-run)

```bash
sudo logrotate -d /etc/logrotate.conf
```

**Пояснение:** `-d` — режим отладки: показывается, что было бы сделано, без реального переименования и сжатия. Убедитесь, что в выводе есть обработка `/var/log/myapp.log` и нет синтаксических ошибок.

### Принудительный запуск ротации (для проверки)

```bash
sudo logrotate -f /etc/logrotate.conf
```

**Пояснение:** `-f` — принудительная ротация сейчас. После выполнения проверьте: в `/var/log/` должен появиться переименованный (и при следующем запуске — сжатый) старый лог и новый пустой или растущий `myapp.log`.

### Проверка результата

```bash
ls -la /var/log/myapp.log*
cat /var/lib/logrotate/status | grep myapp
```

**Пояснение:** первая команда показывает сам файл и ротированные копии (если уже была ротация); вторая — дату последней обработки этого файла в статусе logrotate.

---

## Управление размером журнала journald

### Текущее использование места журналом

```bash
journalctl --disk-usage
```

**Пояснение:** выводится объём, который занимает журнал на диске (или в памяти, если хранилище volatile).

### Очистка старых записей журнала (по возрасту)

```bash
sudo journalctl --vacuum-time=7d
```

**Пояснение:** удаляются записи старше 7 дней. Журнал станет меньше. На учебной машине можно взять меньший интервал (например, 1d) для наглядности.

### Очистка по размеру (оставить не более N мегабайт)

```bash
sudo journalctl --vacuum-size=200M
```

**Пояснение:** старые файлы журнала удаляются, пока общий размер не станет не больше указанного. Удобно, когда важнее лимит места, а не срок хранения.

### Проверка после очистки

```bash
journalctl --disk-usage
journalctl -u myapp -n 5
```

**Пояснение:** снова смотрим занятый объём и убеждаемся, что последние логи myapp по-прежнему доступны (если не удалили их vacuum).

---

# Материалы для ознакомления

Ниже — ссылки, которые помогут углубиться: официальная документация, руководства и статьи.

**Документация и man.** На системе: `man journalctl`, `man journald.conf`, `man logrotate`, `man dmesg`, `man rsyslog.conf`. В онлайне: [journald.conf(5)](https://man7.org/linux/man-pages/man5/journald.conf.5.html), [journalctl(1)](https://man7.org/linux/man-pages/man1/journalctl.1.html), [logrotate(8)](https://man7.org/linux/man-pages/man8/logrotate.8.html), [dmesg(1)](https://man7.org/linux/man-pages/man1/dmesg.1.html).

**Руководства (англ.).** Red Hat: [How to find and interpret system log files on Linux](https://www.redhat.com/sysadmin/rsyslog-systemd-journald-linux-logs), глава [Viewing and managing log files](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/system_administrators_guide/ch-viewing_and_managing_log_files). DigitalOcean: [How To Use journalctl](https://www.digitalocean.com/community/tutorials/how-to-use-journalctl-to-view-and-manipulate-systemd-logs). Arch Wiki: [Systemd/Journal](https://wiki.archlinux.org/title/Systemd/Journal). Обзор про хранение и очистку: [Linux Log Management: journalctl, Logrotate & Best Practices](https://emr3.me/posts/logging-logrotate/).

**На русском.** Habr: [Использование journalctl для просмотра и анализа логов](https://habr.com/ru/companies/ruvds/articles/533918), [journald вместо syslog](https://habr.com/ru/articles/546368). Selfops: раздел [journalctl, rsyslog, logrotate](https://selfops.ru/Linux-administration/7.-%D0%96%D1%83%D1%80%D0%BD%D0%B0%D0%BB%D0%B8%D1%80%D0%BE%D0%B2%D0%B0%D0%BD%D0%B8%D0%B5-%D0%B8-%D0%B0%D0%BD%D0%B0%D0%BB%D0%B8%D0%B7-%D0%BB%D0%BE%D0%B3%D0%BE%D0%B2-journalctl,-rsyslog,-logrotate). Arch Wiki (рус.): [Systemd/Journal](https://wiki.archlinux.org/title/Systemd_(%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9)/Journal_(%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9)). Введение: [Понимание системных журналов Linux](https://andreyex.ru/linux/ponimanie-sistemnyh-zhurnalov-linux-rukovodstvo-dlya-nachinayushhih/).

**Стандарты и практики.** Формат syslog: [RFC 5424](https://www.rfc-editor.org/rfc/rfc5424). Рекомендации по организации логирования: [Linux logging best practices](https://www.manageengine.com/products/eventlog/kb/linux/linux-logging-best-practices.html).
