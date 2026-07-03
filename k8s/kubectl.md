# kubectl Commands

kubectl — основной инструмент командной строки для управления кластерами Kubernetes.

## Базовая конфигурация

### Контексты и конфигурация

```bash
# Просмотр текущего контекста
kubectl config current-context

# Список всех контекстов
kubectl config get-contexts

# Переключение контекста
kubectl config use-context <context-name>

# Просмотр конфигурации
kubectl config view

# Просмотр конфигурации конкретного контекста
kubectl config view --context=<context-name>

# Добавить новый контекст
kubectl config set-context <context-name> --cluster=<cluster> --user=<user> --namespace=<namespace>

# Установить namespace по умолчанию для контекста
kubectl config set-context <context-name> --namespace=<namespace>
```

## Основные команды для ресурсов

### Get (получение информации)

```bash
# Список всех подов
kubectl get pods

# Список подов в namespace
kubectl get pods -n <namespace>

# Список всех подов во всех namespace
kubectl get pods --all-namespaces
kubectl get pods -A

# Детальная информация о поде
kubectl get pod <pod-name> -o wide

# Список всех ресурсов
kubectl get all

# Список deployments
kubectl get deployments
kubectl get deploy

# Список services
kubectl get services
kubectl get svc

# Список nodes
kubectl get nodes

# Список namespaces
kubectl get namespaces
kubectl get ns

# Вывод в YAML
kubectl get pod <pod-name> -o yaml

# Вывод в JSON
kubectl get pod <pod-name> -o json

# С кастомными колонками
kubectl get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

### Describe (детальная информация)

```bash
# Информация о поде
kubectl describe pod <pod-name>

# Информация о deployment
kubectl describe deployment <deployment-name>

# Информация о node
kubectl describe node <node-name>

# Информация о service
kubectl describe service <service-name>

# Информация о namespace
kubectl describe namespace <namespace-name>
```

### Create (создание)

```bash
# Создать из файла
kubectl create -f <file.yaml>

# Создать из директории
kubectl create -f <directory>/

# Создать namespace
kubectl create namespace <namespace-name>

# Создать deployment
kubectl create deployment <name> --image=<image>

# Создать secret
kubectl create secret generic <name> --from-literal=key=value

# Создать configmap
kubectl create configmap <name> --from-literal=key=value
```

### Apply (применение)

```bash
# Применить манифест
kubectl apply -f <file.yaml>

# Применить из директории
kubectl apply -f <directory>/

# Применить с dry-run
kubectl apply -f <file.yaml> --dry-run=client

# Применить с валидацией на сервере
kubectl apply -f <file.yaml> --dry-run=server
```

### Delete (удаление)

```bash
# Удалить из файла
kubectl delete -f <file.yaml>

# Удалить под
kubectl delete pod <pod-name>

# Удалить deployment
kubectl delete deployment <deployment-name>

# Удалить все поды в namespace
kubectl delete pods --all -n <namespace>

# Удалить все ресурсы
kubectl delete all --all -n <namespace>

# Принудительное удаление
kubectl delete pod <pod-name> --force --grace-period=0
```

## Работа с логами

```bash
# Логи пода
kubectl logs <pod-name>

# Логи контейнера в поде
kubectl logs <pod-name> -c <container-name>

# Логи с follow (как tail -f)
kubectl logs -f <pod-name>

# Логи за последние N минут
kubectl logs <pod-name> --since=10m

# Логи за определенное время
kubectl logs <pod-name> --since-time=2023-01-01T00:00:00Z

# Логи предыдущего контейнера (после перезапуска)
kubectl logs <pod-name> --previous

# Логи всех подов с label
kubectl logs -l app=web
```

## Выполнение команд в контейнере

```bash
# Выполнить команду
kubectl exec <pod-name> -- <command>

# Примеры
kubectl exec <pod-name> -- ls -la
kubectl exec <pod-name> -- ps aux
kubectl exec <pod-name> -- env

# Интерактивный shell
kubectl exec -it <pod-name> -- /bin/bash
kubectl exec -it <pod-name> -- /bin/sh

# Выполнить в конкретном контейнере
kubectl exec <pod-name> -c <container-name> -- <command>
```

## Port Forward

```bash
# Проброс порта
kubectl port-forward <pod-name> <local-port>:<pod-port>

# Пример
kubectl port-forward <pod-name> 8080:80

# Проброс через service
kubectl port-forward service/<service-name> <local-port>:<service-port>

# Проброс через deployment
kubectl port-forward deployment/<deployment-name> <local-port>:<pod-port>
```

## Копирование файлов

```bash
# Копировать из контейнера
kubectl cp <pod-name>:/path/to/file ./local-file

# Копировать в контейнер
kubectl cp ./local-file <pod-name>:/path/to/file

# С указанием контейнера
kubectl cp <pod-name>:/path/to/file ./local-file -c <container-name>
```

## Масштабирование

```bash
# Масштабировать deployment
kubectl scale deployment <deployment-name> --replicas=3

# Масштабировать replicaset
kubectl scale replicaset <replicaset-name> --replicas=3

# Масштабировать statefulset
kubectl scale statefulset <statefulset-name> --replicas=3
```

## Откат (Rollout)

```bash
# Статус rollout
kubectl rollout status deployment <deployment-name>

# История rollout
kubectl rollout history deployment <deployment-name>

# Откат на предыдущую версию
kubectl rollout undo deployment <deployment-name>

# Откат на конкретную ревизию
kubectl rollout undo deployment <deployment-name> --to-revision=2

# Пауза rollout
kubectl rollout pause deployment <deployment-name>

# Возобновление rollout
kubectl rollout resume deployment <deployment-name>

# Откат daemonset
kubectl rollout undo daemonset <daemonset-name>
```

## Метки и аннотации

```bash
# Добавить метку
kubectl label pod <pod-name> key=value

# Добавить метку с перезаписью
kubectl label pod <pod-name> key=value --overwrite

# Удалить метку
kubectl label pod <pod-name> key-

# Добавить аннотацию
kubectl annotate pod <pod-name> key=value

# Удалить аннотацию
kubectl annotate pod <pod-name> key-
```

## Редактирование ресурсов

```bash
# Редактировать ресурс
kubectl edit pod <pod-name>
kubectl edit deployment <deployment-name>

# Редактировать с указанием редактора
KUBE_EDITOR=nano kubectl edit pod <pod-name>
```

## Патчинг

```bash
# Применить JSON patch
kubectl patch pod <pod-name> -p '{"spec":{"containers":[{"name":"app","image":"nginx:1.21"}]}}'

# Применить стратегический merge patch
kubectl patch deployment <deployment-name> --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":3}]'
```

## События и отладка

```bash
# Просмотр событий
kubectl get events

# События в namespace
kubectl get events -n <namespace>

# События с сортировкой по времени
kubectl get events --sort-by='.lastTimestamp'

# События для конкретного ресурса
kubectl get events --field-selector involvedObject.name=<pod-name>

# Проверка API ресурсов
kubectl api-resources

# Проверка API версий
kubectl api-versions

# Проверка версии
kubectl version

# Проверка конфигурации кластера
kubectl cluster-info

# Проверка доступа
kubectl auth can-i get pods
kubectl auth can-i create deployments --namespace <namespace>

# Просмотр использования ресурсов
kubectl top nodes
kubectl top pods
kubectl top pods --all-namespaces
```

## Полезные алиасы

Добавьте в `~/.bashrc` или `~/.zshrc`:

```bash
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kdel='kubectl delete'
alias ka='kubectl apply'
alias kl='kubectl logs'
alias ke='kubectl exec -it'
alias kpf='kubectl port-forward'
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
```

## Плагины kubectl

### kube-ps1 (prompt)
```bash
# Показывает текущий контекст и namespace в prompt
source <(kubectl completion bash)
```

### kubectx и kubens
```bash
# Переключение контекстов
kubectx <context-name>

# Переключение namespace
kubens <namespace-name>
```

### k9s
```bash
# TUI для Kubernetes
# Установка через brew/apt/etc
```

## Полезные комбинации команд

```bash
# Удалить все поды в статусе Error
kubectl get pods --field-selector=status.phase=Failed -o json | jq -r '.items[].metadata.name' | xargs kubectl delete pod

# Просмотр всех образов в namespace
kubectl get pods -n <namespace> -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort | uniq

# Просмотр всех меток подов
kubectl get pods --show-labels

# Просмотр ресурсов подов
kubectl get pods -o custom-columns=NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory

# Просмотр всех секретов (только имена)
kubectl get secrets --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}'
```

## Best Practices

1. **Всегда указывайте namespace** при работе с несколькими namespace
2. **Используйте `-o yaml`** для сохранения конфигурации перед изменениями
3. **Используйте `--dry-run=client`** для проверки перед применением
4. **Используйте labels и selectors** для работы с группами ресурсов
5. **Мониторьте события** для понимания происходящего в кластере
6. **Используйте алиасы** для ускорения работы
7. **Изучите `kubectl explain`** для понимания структуры ресурсов

## kubectl explain

```bash
# Объяснение структуры ресурса
kubectl explain pod
kubectl explain pod.spec
kubectl explain pod.spec.containers
kubectl explain pod.spec.containers.resources
```
