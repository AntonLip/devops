### Настройка Firewall

**Firewall (Файрвол, Межсетевой экран)** - система контроля сетевого трафика.

**Типы firewall:**
- **Сетевой firewall** - на уровне сети
- **Хостовой firewall** - на уровне отдельного сервера
- **Прикладной firewall** - на уровне приложений

**В Linux используются:**
- **iptables** - традиционный firewall
- **ufw (Uncomplicated Firewall)** - упрощенный интерфейс для iptables
- **firewalld** - используется в RHEL/CentOS/Fedora
- **nftables** - современная замена iptables

### UFW (Uncomplicated Firewall)

**UFW** - простой интерфейс для управления iptables.

**Базовые команды:**
```bash
# Проверка статуса
sudo ufw status
sudo ufw status verbose
sudo ufw status numbered

# Включение/отключение
sudo ufw enable
sudo ufw disable

# Разрешение/блокировка портов
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw deny 3306/tcp

# Разрешение по имени сервиса
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https

# Разрешение с указанием IP
sudo ufw allow from 192.168.1.100
sudo ufw allow from 192.168.1.0/24

# Разрешение с указанием порта и IP
sudo ufw allow from 192.168.1.100 to any port 22

# Удаление правила
sudo ufw delete 2
sudo ufw delete allow 22/tcp

# Сброс всех правил
sudo ufw reset
```

**Конфигурация:**
- Правила хранятся в `/etc/ufw/`
- Основной файл: `/etc/ufw/ufw.conf`
- Правила: `/etc/ufw/user.rules`

**Логирование:**
```bash
# Включить логирование
sudo ufw logging on
sudo ufw logging off

# Логи находятся в /var/log/ufw.log
```
