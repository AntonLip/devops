# iptables: таблица nat (SNAT, DNAT, проброс портов)

Таблица **nat** используется для **трансляции адресов и портов**:

- **SNAT (Source NAT)** — подмена адреса/порта **источника** (исходящие пакеты). Типично: «все хосты за шлюзом выходят в интернет с одним внешним IP».
- **DNAT (Destination NAT)** — подмена адреса/порта **назначения** (входящие пакеты). Типично: «запрос на внешний IP:порт перенаправить на внутренний сервер».

Работа с nat — всегда с указанием таблицы: **-t nat**.

---

## Цепочки в таблице nat

| Цепочка      | Когда обрабатывается | Частое применение |
|--------------|----------------------|--------------------|
| **PREROUTING**  | До принятия решения о маршруте (входящий пакет только что пришёл) | DNAT: перенаправить входящий трафик на другой IP/порт |
| **POSTROUTING** | После маршрутизации, перед отправкой пакета наружу | SNAT: подменить источник на внешний IP шлюза |
| **OUTPUT**      | Пакеты, сгенерированные самим хостом | Реже: DNAT для исходящих с самого шлюза |

Для типового шлюза (NAT в интернет + проброс портов) достаточно **PREROUTING** (DNAT) и **POSTROUTING** (SNAT).

---

## Включение пересылки пакетов (IP forwarding)

Чтобы хост работал как маршрутизатор и трафик проходил через него (FORWARD), нужно включить **IP forwarding**:

```bash
# Временно
sudo sysctl -w net.ipv4.ip_forward=1

# Постоянно: в /etc/sysctl.conf или в /etc/sysctl.d/
net.ipv4.ip_forward=1
```

После правки: `sudo sysctl -p` (или перезагрузка).

В цепочке **filter** для проходящего трафика нужно разрешить **FORWARD** (и при необходимости связанные с NAT правила в filter).

---

## SNAT: выход в интернет с одного внешнего IP (маскарадинг)

Сценарий: шлюз с двумя интерфейсами — **eth0** (внешний, в интернет) и **eth1** (внутренняя сеть 192.168.1.0/24). Нужно, чтобы хосты из 192.168.1.0/24 выходили в интернет с IP шлюза на eth0.

Подмена источника на адрес исходящего интерфейса (маскарадинг):

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o eth0 -j MASQUERADE
```

**MASQUERADE** — частный случай SNAT: автоматически подставляется текущий IP интерфейса **-o eth0**, удобно при динамическом IP на шлюзе. Если внешний IP статический, можно явно указать SNAT:

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o eth0 -j SNAT --to-source 203.0.113.1
```

Правила **filter** для FORWARD (минимум): разрешить уже установленные и связанные, разрешить исходящие из внутренней сети наружу и ответы. Пример:

```bash
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state ESTABLISHED,RELATED -j ACCEPT
```

---

## DNAT: проброс порта на внутренний хост (port forwarding)

Сценарий: на шлюзе один внешний IP. Запросы из интернета на порт 80 (HTTP) нужно перенаправить на внутренний веб-сервер 192.168.1.10:80.

1. **DNAT** в **PREROUTING** — заменить адрес и порт назначения на внутренний хост.
2. В **filter** разрешить **FORWARD** для этого трафика (и ответы).

```bash
# Входящий на порт 80 перенаправить на 192.168.1.10:80
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:80
```

Если сервис слушает другой порт на внутреннем хосте (например, 8080):

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:8080
```

Разрешить пересылку в filter:

```bash
sudo iptables -A FORWARD -p tcp -d 192.168.1.10 --dport 80 -j ACCEPT
sudo iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
```

Порядок и полный набор правил FORWARD зависят от вашей политики (по умолчанию ACCEPT или DROP); выше — минимальная идея.

---

## Проброс SSH на внутренний хост

Внешние подключаются к шлюзу на порт 2222, трафик уходит на 192.168.1.20:22:

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 192.168.1.20:22
```

В filter — разрешить FORWARD для этого соединения (и ESTABLISHED,RELATED для ответов).

---

## Просмотр правил nat

```bash
sudo iptables -t nat -L -n -v
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
```

Удаление — по номеру или по копии правила, с указанием таблицы:

```bash
sudo iptables -t nat -D POSTROUTING 1
sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:80
```

---

## Сохранение правил с nat

При использовании **iptables-save** сохраняются все таблицы, включая nat:

```bash
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

При **iptables-persistent** (netfilter-persistent) также сохраняются правила nat. Восстановление: `sudo iptables-restore < /etc/iptables/rules.v4` или перезагрузка с настроенным netfilter-persistent.

---

## Краткий чек-лист

- **SNAT/MASQUERADE** — в **POSTROUTING**, для исходящего трафика (источник подменяется).
- **DNAT** — в **PREROUTING**, для входящего трафика (назначение подменяется на внутренний хост).
- Не забыть **net.ipv4.ip_forward=1** и правила **FORWARD** в таблице filter.
- Все команды для nat — с **-t nat**.