## 4. Базовые команды Git (25 минут)

### 4.1. Настройка Git

**Первоначальная настройка:**
```bash
# Установка имени пользователя
git config --global user.name "Ваше Имя"

# Установка email
git config --global user.email "your.email@example.com"

# Установка редактора по умолчанию
git config --global core.editor "code --wait"  # VS Code
git config --global core.editor "vim"          # Vim
git config --global core.editor "nano"         # Nano

# Просмотр всех настроек
git config --list

# Просмотр конкретной настройки
git config user.name
```

**Уровни конфигурации:**
- `--system`: для всех пользователей системы
- `--global`: для текущего пользователя
- `--local`: для конкретного репозитория (по умолчанию)

### 4.2. Создание и клонирование репозиториев

**Создание нового репозитория:**
```bash
# Инициализация репозитория в текущей директории
git init

# Инициализация с указанием имени
git init my-project

# Создание bare репозитория (для сервера)
git init --bare
```

**Клонирование репозитория:**
```bash
# Клонирование по HTTPS
git clone https://github.com/user/repo.git

# Клонирование по SSH
git clone git@github.com:user/repo.git

# Клонирование в указанную директорию
git clone https://github.com/user/repo.git my-folder

# Клонирование конкретной ветки
git clone -b branch-name https://github.com/user/repo.git
```

### 4.3. Работа с файлами

**Проверка статуса:**
```bash
# Статус репозитория
git status

# Короткий формат статуса
git status -s
git status --short
```

**Добавление файлов:**
```bash
# Добавить конкретный файл
git add filename.txt

# Добавить все файлы в директории
git add .

# Добавить все файлы определенного типа
git add *.js

# Интерактивное добавление
git add -i
git add -p  # частичное добавление (patch mode)
```

**Удаление файлов:**
```bash
# Удалить файл из Git и рабочей директории
git rm filename.txt

# Удалить только из индекса (оставить в рабочей директории)
git rm --cached filename.txt

# Удалить директорию
git rm -r directory/
```

**Переименование и перемещение:**
```bash
# Переименовать файл
git mv old-name.txt new-name.txt

# Переместить файл
git mv file.txt new-directory/
```

### 4.4. Коммиты

**Создание коммита:**
```bash
# Коммит с сообщением
git commit -m "Описание изменений"

# Коммит с подробным сообщением
git commit -m "Краткое описание" -m "Подробное описание"

# Добавить все изменения и закоммитить
git commit -a -m "Сообщение"

# Коммит с открытием редактора
git commit

# Изменить последний коммит
git commit --amend

# Изменить последний коммит с новым сообщением
git commit --amend -m "Новое сообщение"
```

**Просмотр истории:**
```bash
# История коммитов
git log

# Компактный формат
git log --oneline

# Графическое представление веток
git 

# История конкретного файла
git log filename.txt

# История с изменениями
git log -p

# Статистика изменений
git log --stat

# Поиск в истории
git log --grep="текст поиска"
```

### 4.5. Работа с ветками

**Создание и переключение:**
```bash
# Создать новую ветку
git branch branch-name

# Создать и переключиться
git checkout -b branch-name

# Создать и переключиться (Git 2.23+)
git switch -c branch-name

# Переключиться на ветку
git checkout branch-name
git switch branch-name

# Переключиться на предыдущую ветку
git checkout -
git switch -
```

**Просмотр веток:**
```bash
# Список локальных веток
git branch

# Список всех веток (включая удаленные)
git branch -a

# Список удаленных веток
git branch -r

# Показать текущую ветку
git branch --show-current
```

**Удаление веток:**
```bash
# Удалить локальную ветку
git branch -d branch-name

# Принудительное удаление
git branch -D branch-name

# Удалить удаленную ветку
git push origin --delete branch-name
```

**Слияние веток:**
```bash
# Слить ветку в текущую
git merge branch-name

# Слияние без fast-forward (сохраняет историю)
git merge --no-ff branch-name

# Слияние только fast-forward (если возможно)
git merge --ff-only branch-name

# Отменить слияние
git merge --abort
```

### 4.6. Работа с удаленными репозиториями

**Настройка удаленных репозиториев:**
```bash
# Просмотр удаленных репозиториев
git remote

# Подробная информация
git remote -v

# Добавить удаленный репозиторий
git remote add origin https://github.com/user/repo.git

# Изменить URL удаленного репозитория
git remote set-url origin new-url

# Удалить удаленный репозиторий
git remote remove origin
```

**Получение изменений:**
```bash
# Получить изменения (без слияния)
git fetch origin

# Получить изменения конкретной ветки
git fetch origin branch-name

# Получить и слить изменения
git pull origin main

# Получить и слить (с rebase)
git pull --rebase origin main
```

**Отправка изменений:**
```bash
# Отправить изменения в удаленный репозиторий
git push origin branch-name

# Отправить в текущую ветку
git push

# Отправить и установить upstream
git push -u origin branch-name

# Отправить все ветки
git push --all origin

# Отправить теги
git push --tags
```

### 4.7. Отмена изменений

**Отмена в рабочей директории:**
```bash
# Отменить изменения в файле
git checkout -- filename.txt
git restore filename.txt

# Отменить все изменения
git checkout -- .
git restore .
```

**Отмена в staging area:**
```bash
# Убрать файл из staging
git reset HEAD filename.txt
git restore --staged filename.txt

# Убрать все файлы из staging
git reset HEAD
git restore --staged .
```

**Отмена коммитов:**
```bash
# Отменить последний коммит (сохранить изменения)
git reset --soft HEAD~1

# Отменить последний коммит (удалить изменения из staging)
git reset --mixed HEAD~1
git reset HEAD~1

# Отменить последний коммит (удалить все изменения)
git reset --hard HEAD~1

# Отменить несколько коммитов
git reset --hard HEAD~3
```

**Revert (безопасная отмена):**
```bash
# Создать новый коммит, отменяющий изменения
git revert HEAD

# Отменить конкретный коммит
git revert commit-hash
```

### 4.8. Полезные команды

**Просмотр изменений:**
```bash
# Показать изменения в рабочей директории
git diff

# Показать изменения в staging
git diff --staged
git diff --cached

# Показать изменения между коммитами
git diff commit1 commit2

# Показать изменения в файле
git diff filename.txt
```

**Stash (временное сохранение):**
```bash
# Сохранить изменения во временное хранилище
git stash

# Сохранить с сообщением
git stash save "описание"

# Показать список stash
git stash list

# Применить последний stash
git stash apply

# Применить и удалить stash
git stash pop

# Удалить stash
git stash drop stash@{0}

# Очистить все stash
git stash clear
```

**Теги:**
```bash
# Создать легковесный тег
git tag v1.0.0

# Создать аннотированный тег
git tag -a v1.0.0 -m "Версия 1.0.0"

# Показать все теги
git tag

# Показать информацию о теге
git show v1.0.0

# Удалить тег
git tag -d v1.0.0

# Отправить тег в удаленный репозиторий
git push origin v1.0.0

# Отправить все теги
git push --tags
```
