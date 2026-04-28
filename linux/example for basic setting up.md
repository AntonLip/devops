Команды для настройки имени хоста, времени, таймзоны и сервера времени


```bash
# установить "статический" hostname
sudo hostnamectl set-hostname my-server

# постоянный hostname (Debian/Ubuntu и многие другие)
echo "my-server" | sudo tee /etc/hostname

# поправить /etc/hosts (важно для корректного резолва локального имени)
sudo nano /etc/hosts
```

```bash
timedatectl
timedatectl list-timezones | grep -i europe
sudo timedatectl set-timezone Europe/Minsk # пример
timedatectl
```
### Включить синхронизацию времени (NTP)

На Ubuntu обычно используется systemd-timesyncd:
```bash
sudo timedatectl set-ntp true
timedatectl
systemctl status systemd-timesyncd
```

настроить ntp-сервер можно в файл

```bash
sudo nano /etc/systemd/timesyncd.conf


# Пример
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org
FallbackNTP=ntp.ubuntu.com
```

Применим командой

```bash
sudo systemctl restart systemd-timesyncd
timedatectl
```
Настройка сети
Пример настройки статического IP + gateway + DNS
файл находиться по пути /etc/netplan/
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: false
      addresses:
        - 192.168.1.50/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
```

После внесения в файл изменений можно сначала проверить конфигурацию командой
```bash
sudo netplan try      # безопасно: откатит, если ты потеряешь сеть
sudo netplan apply
```

Работа с пользователями



```bash
# Создание пользователя с параметрами
sudo useradd -m -s /bin/bash -c "Full Name" newuser
# Параметры:
# -m  : создать домашнюю директорию
# -s  : указать shell
# -c  : комментарий (полное имя)
# Установка пароля
sudo passwd newuser
```

Получение информации о пользователе

```bash
# Кто я?
whoami
# Мои группы
groups
# Детальная информация
id
# Информация о другом пользователе
id username
groups username
# Все пользователи системы
getent passwd
# Только обычные пользователи
getent passwd | awk -F: '$3 >= 1000'
```
Примеры команд для изменения прав доступа
**Типичные комбинации для директорий:**
```bash
# 755 - стандартные права для директорий
chmod 755 directory/
# rwxr-xr-x
# Владелец: все, группа и остальные: чтение и вход

# 775 - для совместной работы
chmod 775 directory/
# rwxrwxr-x
# Владелец и группа: все права, остальные: чтение и вход

# 700 - приватная директория
chmod 700 directory/
# rwx------
# Только владелец имеет доступ

# 750 - доступ для группы
chmod 750 directory/
# rwxr-x---
# Владелец: все, группа: чтение и вход, остальные: нет доступа
```
Создание групп

```bash
# Создать группу
sudo groupadd developers
# С указанием GID
sudo groupadd -g 2000 developers
# С указанием системной группы (GID < 1000)
sudo groupadd -r systemgroup
```

Проверка создания группы

```bash
# Проверить, что группа создана
getent group developers
# Просмотр GID
getent group developers | cut -d: -f3
```

Добавление пользователя в группу
```bash
# Добавить пользователя в дополнительную группу

sudo usermod -aG developers username
# Параметры:
# -a : append (добавить, не заменять существующие группы)
# -G : дополнительные группы
# Добавить несколько пользователей
sudo usermod -aG developers user1 user2 user3
# Нет, так не работает. Нужно по одному:
sudo usermod -aG developers user1
sudo usermod -aG developers user2
```


```bash
# Изменить основную группу пользователя
sudo usermod -g developers username
# Проверка
id username
# Вывод: uid=1001(username) gid=2000(developers) groups=2000(developers)
```

```bash
# Удалить пользователя из группы
sudo gpasswd -d username developers
# Или через deluser (Debian/Ubuntu)
sudo deluser username developers
# Проверка
groups username

# Переименовать группу
sudo groupmod -n newname oldname
# Изменить GID группы
sudo groupmod -g 2001 developers
# ВАЖНО: После изменения GID нужно изменить владельца файлов
sudo find / -gid 2000 -exec chgrp -h developers {} \;
```


Пример скрипта по созданию пользователя 


```bash
#!/bin/bash
# Создание пользователя и настройка sudo с ограничениями

# 1. Создать группу
sudo groupadd developers

# 2. Создать пользователя
sudo useradd -m -s /bin/bash -G developers devuser
sudo passwd devuser

# 3. Создать файл sudoers для пользователя
sudo tee /etc/sudoers.d/devuser << 'EOF'
# Правила для devuser
devuser ALL=(ALL:ALL) \
    /usr/bin/git, \
    /usr/bin/docker, \
    /usr/bin/systemctl restart nginx, \
    /usr/bin/systemctl reload nginx, \
    /usr/bin/nano /etc/nginx/*, \
    /usr/bin/vim /etc/nginx/*

# Без пароля для определенных команд
devuser ALL=(ALL:ALL) NOPASSWD: /usr/bin/systemctl status *
EOF

# 4. Установить правильные права
sudo chmod 0440 /etc/sudoers.d/devuser

# 5. Проверить синтаксис
sudo visudo -c

echo "Пользователь создан и sudo настроен!"
```





