# Mysql Clone Local

Утилита скачивает удаленную MySQL/MariaDB базу через SSH и импортирует ее в локальную базу

## Возможности

- интерактивный запуск одной командой;
- SSH-доступ по ключу, агенту или паролю;
- импорт в локальную MySQL/MariaDB базу;
- создание локальной базы, если ее еще нет;
- опциональное удаление и пересоздание локальной базы перед импортом;
- два режима скачивания дампа:
  - `ssh-dump` - запускает `mysqldump` на удаленном сервере и сжимает скачанный дамп локально;
  - `tunnel` - открывает SSH-туннель и запускает локальный `mysqldump` через него.

## Зависимости

Локально нужны:

- `bash`;
- `ssh`;
- `gzip`;
- `mysql`;
- `mysqldump`, если используется `--mode tunnel`;
- `sshpass`, если нужно передать SSH-пароль неинтерактивно или использовать пароль в tunnel-режиме.

Для режима по умолчанию `ssh-dump` на удаленном сервере должен быть доступен `mysqldump`.

## Быстрый старт

```bash
./script.sh --interactive
```

Скрипт спросит параметры SSH, параметры удаленной базы и параметры локальной базы. Пароли вводятся скрыто.

Если файл не исполняемый:

```bash
chmod +x script.sh
```

## Пример запуска одной командой

```bash
./script.sh \
  --ssh-host example.com \
  --ssh-user deploy \
  --ssh-key ~/.ssh/id_rsa \
  --remote-db app_prod \
  --remote-user app_user \
  --remote-password 'remote-db-password' \
  --local-db app_local \
  --local-user root \
  --local-password 'local-db-password'
```

Локальная база `app_local` будет создана, если ее нет. Дамп хранится во временном файле в `/tmp` и удаляется после успешного или неуспешного завершения, если не указан `--keep-dump`.

## SSH по паролю

Интерактивно:

```bash
./script.sh --interactive
```

Оставьте путь к ключу пустым и введите SSH-пароль, когда скрипт его спросит.

Неинтерактивно:

```bash
SSH_PASSWORD='ssh-password' ./script.sh \
  --ssh-host example.com \
  --ssh-user deploy \
  --remote-db app_prod \
  --remote-user app_user \
  --remote-password 'remote-db-password' \
  --local-db app_local \
  --local-user root \
  --local-password 'local-db-password'
```

Для неинтерактивного SSH-пароля нужен `sshpass`. По возможности используйте ключи или SSH agent, потому что пароль в аргументах команды и переменных окружения может попасть в историю shell или список процессов.

## Режимы работы

### `ssh-dump`

Режим по умолчанию. Скрипт подключается по SSH, запускает `mysqldump` на удаленном сервере, скачивает дамп и сжимает его локально через `gzip`.

```bash
./script.sh --mode ssh-dump --interactive
```

Этот режим хорошо подходит, когда MySQL доступна только с удаленного сервера как `127.0.0.1:3306`.

### `tunnel`

Скрипт открывает SSH-туннель и запускает локальный `mysqldump`.

```bash
./script.sh --mode tunnel --tunnel-port 3307 --interactive
```

Этот режим полезен, если на удаленном сервере нет `mysqldump`, но порт MySQL доступен через SSH-туннель. Для SSH-пароля в этом режиме нужен `sshpass`, потому что туннель запускается в фоне.

## Удалить локальную базу перед импортом

По умолчанию скрипт импортирует дамп в существующую локальную базу. Чтобы полностью пересоздать базу:

```bash
./script.sh --interactive --drop-local-db
```

В интерактивном режиме скрипт попросит подтверждение. Для CI или Makefile можно добавить `--yes`.

## Переменные окружения

Все основные параметры можно передавать через env:

```bash
SSH_HOST=example.com \
SSH_USER=deploy \
SSH_KEY=~/.ssh/id_rsa \
REMOTE_DB_NAME=app_prod \
REMOTE_DB_USER=app_user \
REMOTE_DB_PASS='remote-db-password' \
LOCAL_DB_NAME=app_local \
LOCAL_DB_USER=root \
LOCAL_DB_PASS='local-db-password' \
./script.sh
```

Поддерживаемые переменные:

- `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY`, `SSH_PASSWORD`;
- `REMOTE_DB_HOST`, `REMOTE_DB_PORT`, `REMOTE_DB_USER`, `REMOTE_DB_PASS`, `REMOTE_DB_NAME`;
- `LOCAL_DB_HOST`, `LOCAL_DB_PORT`, `LOCAL_DB_USER`, `LOCAL_DB_PASS`, `LOCAL_DB_NAME`;
- `MODE`, `TUNNEL_LOCAL_PORT`, `DUMP_DIR`, `KEEP_DUMP`, `DROP_LOCAL_DB`, `YES`, `INTERACTIVE`.

## Справка по флагам

```bash
./script.sh --help
```

## Безопасность

Не храните реальные пароли в скрипте. Лучше вводить их интерактивно или передавать через защищенное окружение CI. Если используете флаги `--ssh-password`, `--remote-password` или `--local-password`, учитывайте, что они могут сохраниться в истории shell.
