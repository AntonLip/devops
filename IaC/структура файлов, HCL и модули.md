# Cтруктура файлов, HCL и модули

## 1. Главное правило

Terraform **не требует** имён `main.tf`, `variables.tf` и т.д. В одной папке все файлы `*.tf` **склеиваются** в одну конфигурацию. Имена файлов - **договорённость** для читаемости.

```text
terraform-getting-started/
├── versions.tf          # метаданные: версии CLI и provider
├── provider.tf          # подключение к AWS
├── variables.tf         # входные параметры
├── outputs.tf           # значения «наружу» после apply
├── s3.tf                # ресурсы (Step 1) - аналог «main»
├── security_group.tf    # ресурсы (Step 2)
├── ec2.tf               # ресурсы (Step 3)
├── terraform.tfvars     # локальные значения (не в Git)
└── terraform.tfvars.example
```

**Root module** - это весь каталог, где вы запускаете `terraform init/plan/apply`.

---

## 2. `versions.tf` - версии и backend

### Зачем

- Зафиксировать **минимальную версию Terraform CLI** - чтобы у всех было одинаковое поведение.
- Объявить **какие provider-плагины** нужны (`hashicorp/aws`) и **диапазон версий**.
- блок **`backend`** для remote state в S3.

Без `required_providers` Terraform может скачать не ту версию AWS provider → другой plan.

### Что содержит (построчно)

```hcl
# Файл versions.tf - только блок terraform { }.
# Не смешивайте сюда resource/provider (лучше отдельные файлы).

terraform {
  # Минимальная версия бинарника terraform на вашей машине / в CI.
  # Если версия ниже - init/plan сразу упадёт с понятной ошибкой.
  required_version = ">= 1.5.0"

  required_providers {
    # Ключ "aws" - локальное имя провайдера в HCL: provider "aws" { }
    aws = {
      # Откуда скачивать плагин (реестр HashiCorp).
      source = "hashicorp/aws"

      # ~> 5.0 = любая 5.x, но не 6.0 (защита от breaking changes).
      version = "~> 5.0"
    }
  }

  # backend "s3" { ... }  - в 14.1 не используем; см. 14.2.2
}
```

### После `terraform init`

| Артеfact | Где | Коммитить? |
|----------|-----|------------|
| `.terraform/providers/` | кэш плагинов | **Нет** |
| `.terraform.lock.hcl` | точная версия provider | **Да** |

### Частые ошибки

| Ошибка | Причина |
|--------|---------|
| Разный plan у коллег | нет lock file в Git |
| Provider v6 ломает код | не зафиксирован `~> 5.0` |

---

## 3. `variables.tf` - входные параметры

### Зачем

Вынести **настраиваемое** из кода ресурсов:

- регион, profile;
- имя bucket (уникально у каждого студента);
- тип EC2, CIDR для SSH.

Один и тот же `.tf` в Git, разные `terraform.tfvars` локально.

### Анатомия блока `variable`

```hcl
variable "aws_region" {
  # description - документация; показывается в terraform plan (подсказки).
  description = "AWS region для всех ресурсов lab"

  # type - string, number, bool, list(), map(), object({ ... }).
  type = string

  # default - необязательное значение, если не задано в tfvars / -var / TF_VAR_.
  default = "eu-central-1"
}

variable "bucket_name" {
  description = "Глобально уникальное имя S3 bucket"
  type        = string
  # default нет - студент ОБЯЗАН задать в terraform.tfvars (Step 1+).
}

variable "ssh_cidr" {
  description = "Откуда разрешён SSH к SG"
  type        = string
  default     = "0.0.0.0/0"

  # validation - проверка до plan; необязательно в 14.1.
  # validation {
  #   condition     = can(cidrhost(var.ssh_cidr, 0))
  #   error_message = "ssh_cidr must be valid CIDR."
  # }
}
```

### Откуда Terraform берёт значения (приоритет)

1. `-var 'name=value'` в CLI
2. `terraform.tfvars`, `*.auto.tfvars`
3. env `TF_VAR_bucket_name=...`
4. `default` в блоке `variable`

### `terraform.tfvars` vs `terraform.tfvars.example`

| Файл | В Git? | Назначение |
|------|--------|------------|
| `.example` | да | шаблон для команды |
| `terraform.tfvars` | **нет** | ваши реальные bucket_name, profile |

```hcl
# terraform.tfvars - локально
aws_profile = "default"
bucket_name = "devops-tf-start-student-123"
```

### Использование в коде

В любом `.tf`: **`var.имя_переменной`**

```hcl
provider "aws" {
  region = var.aws_region
}
```

---

## 4. `provider.tf` - подключение к облаку

### Зачем

Блок **`provider "aws"`** говорит Terraform:

- **какой регион** API;
- **какие credentials** (profile или env `AWS_*`);
- **какие теги** навесить на все поддерживаемые ресурсы (`default_tags`).

Provider - **мост** между Core и AWS API. Сам по себе ресурсы не создаёт.

### Построчно

```hcl
# provider.tf - настройка плагина hashicorp/aws (объявлен в versions.tf).

provider "aws" {
  # region - регион по умолчанию для ресурсов без явного region.
  region = var.aws_region

  # profile - секция в ~/.aws/credentials + ~/.aws/config.
  # Admin-профиль нужен для создания S3, SG, EC2.
  profile = var.aws_profile

  # default_tags - AWS provider v4+: теги на все create/update ресурсы.
  # Удобно для cost allocation и поиска lab-ресурсов.
  default_tags {
    tags = {
      Project = var.project   # меняется на Step 4 - demo update in-place
      Managed = "terraform"
      Lesson  = "14.1"
    }
  }
}

# data - read-only. Не создаёт ресурс, только читает AWS API.
# caller identity - account ID, ARN текущего principal (admin profile).
data "aws_caller_identity" "current" {}
```

### Цепочка credentials

```text
env AWS_ACCESS_KEY_ID / AWS_PROFILE
    → profile в provider "aws"
    → (на EC2, если Terraform запущен там) IAM role через metadata
```

### Частые ошибки

| Ошибка | Решение |
|--------|---------|
| `failed to get shared config profile, lab` | нет profile → `aws_profile = "default"` |
| `No valid credential sources` | `aws configure` или env |

---

## 5. `main.tf` и файлы ресурсов - что создавать в облаке

### Зачем «main»

Исторически всё клали в **`main.tf`**. В lab 14.1 ресурсы **разбиты по темам**:

| Файл | Step | Содержимое |
|------|------|------------|
| `s3.tf` | 1 | bucket, public access block |
| `security_group.tf` | 2 | data VPC/subnet, SG |
| `ec2.tf` | 3 | data AMI, aws_instance |

Смысл тот же, что у `main.tf`: **`resource`**, **`data`**, **`locals`**, вызовы **`module`**.

### Блок `resource`

```hcl
# Тип ресурса в AWS API - логическое имя в Terraform (уникально в модуле).
resource "aws_s3_bucket" "lab" {
  # bucket - аргумент API; var.bucket_name - из variables.tf / tfvars.
  bucket = var.bucket_name
}

# Второй resource ссылается на первый → implicit dependency.
# Terraform создаст bucket ДО public_access_block.
resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id   # .id - атрибут после create

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

**Адрес в state:** `aws_s3_bucket.lab` → реальный ID bucket в AWS.

### Блок `data`

Read-only lookup существующего:

```hcl
data "aws_vpc" "default" {
  default = true   # default VPC аккаунта
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name"; values = ["al2023-ami-2023*"] }
}
```

### Блок `locals`

Локальные вычисления (не inputs, не outputs):

```hcl
locals {
  name_prefix = "${var.project}-tf"
}
# использование: local.name_prefix
```

### Важно про AWS API и ASCII

Строки, уходящие в **AWS API** (`description` SG, некоторые `name`), должны быть **ASCII**. Комментарии `#` и `description` в `variable` могут быть на русском - API их не видит.

```hcl
# Плохо для SG:
# description = "Lab 14.1 - SSH"   # символ - (em dash) не ASCII

# Хорошо:
description = "Lab 14.1 - SSH for EC2"
```

---

## 6. `outputs.tf` - результат после apply

### Зачем

- Показать студенту **bucket_id**, **public IP** без чтения state вручную.
- Передать значения в **другие системы** (Ansible inventory, CI).
- Связать **модули**: output child → input root.

```hcl
output "account_id" {
  description = "AWS Account ID admin-профиля"
  value       = data.aws_caller_identity.current.account_id
}

output "bucket_id" {
  description = "Имя bucket для aws s3 ls"
  value       = aws_s3_bucket.lab.id
}

output "instance_public_ip" {
  description = "SSH: ec2-user@<this ip>"
  value       = aws_instance.lab.public_ip
}

# sensitive = true - скрывает в консоли; в state всё равно может быть секрет.
# output "secret" {
#   value     = ...
#   sensitive = true
# }
```

Команды:

```bash
terraform output
terraform output -raw bucket_id
```

---

## 7. Сводная таблица файлов

| Файл | Блоки HCL | Создаёт ресурсы в AWS? | Коммитить? |
|------|-----------|------------------------|------------|
| `versions.tf` | `terraform { }` | нет | да |
| `variables.tf` | `variable` | нет | да |
| `provider.tf` | `provider`, `data` | data - только read | да |
| `s3.tf`, `ec2.tf`, … | `resource`, `data`, `locals` | да (resource) | да |
| `outputs.tf` | `output` | нет | да |
| `terraform.tfvars` | значения variables | нет | **нет** |
| `terraform.tfstate` | snapshot state | - | **нет** |
| `.terraform/` | кэш provider | - | **нет** |

---

## 8. Модули - что это

### Определение

**Модуль** - переиспользуемый **подпроект** Terraform в отдельной папке:

- свои `main.tf` / `variables.tf` / `outputs.tf`;
- вызывается из root через `module "имя" { source = "..." }`.

**Root module** - каталог, где вы запускаете CLI (`terraform-getting-started/`).

**Child module** - подпапка, например `modules/network/`.

| Без модулей | С модулями |
|-------------|------------|
| копипаст VPC в каждый проект | один модуль `network`, разные tfvars |
| длинный root | границы: network / security / app |
| сложно переиспользовать | один модуль - dev и prod |


### Адрес ресурса в state

| Root | Module |
|------|--------|
| `aws_s3_bucket.lab` | `module.network.aws_vpc.this` |

---

## 9. Как написать модуль - пошагово

### Шаг 1. Выделить логический блок

Пример: «S3 bucket + public access block» или «VPC + public subnets».

### Шаг 2. Создать структуру

```text
modules/s3-lab/
├── main.tf       # resource blocks
├── variables.tf  # inputs модуля
└── outputs.tf    # exports модуля
```

### Шаг 3. `variables.tf` модуля - только inputs

```hcl
# modules/s3-lab/variables.tf
variable "bucket_name" {
  description = "Globally unique bucket name"
  type        = string
}

variable "block_public_access" {
  description = "Enable S3 Block Public Access"
  type        = bool
  default     = true
}
```

Внутри модуля **нет** `var.aws_profile` root - только то, что передали явно.

### Шаг 4. `main.tf` модуля - resources

```hcl
# modules/s3-lab/main.tf
resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "this" {
  count  = var.block_public_access ? 1 : 0
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Имя ресурса `this` - распространённый convention внутри модуля.

### Шаг 5. `outputs.tf` модуля - только наружу

```hcl
output "bucket_id" {
  description = "Bucket name (id)"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}
```

Не экспортируйте лишнее - каждый output - контракт модуля.

### Шаг 6. Вызов из root

```hcl
# root main.tf (или s3.tf)
module "lab_bucket" {
  source = "./modules/s3-lab"

  bucket_name = var.bucket_name
}

output "bucket_id" {
  value = module.lab_bucket.bucket_id
}
```

После добавления модуля: **`terraform init`** (скачивает/регистрирует module source).

### Шаг 7. Зависимости между модулями

```hcl
module "network" {
  source = "./modules/network"
  # ...
}

module "security" {
  source = "./modules/security"

  vpc_id = module.network.vpc_id   # output → input
}
```

Terraform построит граф: сначала network, потом security.

### Пример из курса (14.2)

```hcl
module "network" {
  source = "./modules/network"

  name_prefix         = var.name_prefix
  vpc_cidr            = var.vpc_cidr
  azs                 = local.azs
  public_subnet_cidrs = var.public_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  name_prefix = var.name_prefix
  vpc_id      = module.network.vpc_id
}
```

---

## 10. Модуль vs отдельный `.tf` (14.1)

| Критерий | `s3.tf` в root (14.1) | `module "s3"` (14.2+) |
|----------|------------------------|------------------------|
| Сложность | минимальная | inputs/outputs, init |
| Переиспользование | один lab | много проектов |
| Обучение | первый plan/apply | DRY, команда |

Рекомендация: **14.1** - файлы по этапам; **14.2** - вынести network/security в modules.

---


## 12. Чеклист понимания

- [ ] Понимаю, что имя файла не важно для Terraform, важны блоки HCL
- [ ] Могу объяснить разницу `variable` / `resource` / `output` / `provider`
- [ ] Знаю, что коммитить lock file, не коммитить tfstate и tfvars
- [ ] Понимаю implicit dependency через `aws_s3_bucket.lab.id`
- [ ] Могу описать структуру child module и вызов `module { source = ... }`
- [ ] Знаю, что SG `description` в AWS - только ASCII
