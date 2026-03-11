#!/usr/bin/env bash
# ============================================================================
# Bot-Links-GitFlic Installer v9.1 (Smart JSON + Migration Edition)
# + Автоопределение формата (JSON / текст)
# + Инъекция правил блокировки (Block .tm, Ads, Porn) — идемпотентная
# + Автообновление каждые N часов (APScheduler)
# + Извлечение имени клиента из контента подписки
# + Расширение фиксируется при создании — RAW-ссылки навсегда стабильны
# + Миграция на новый сервер с сохранением базы данных клиентов
# + /append — добавление конфигов к существующему клиенту
# + /removeconfig — удаление отдельных конфигов из файла клиента
# + /appendall — добавление конфигов сразу всем клиентам
# + /removeconfigall — удаление конфигов сразу у всех клиентов
# + /cancel — отмена текущей операции
# + /rename — переименование клиента
# + /seturl — обновление источника конфига
# + /info — подробная информация о клиенте
# + /refresh [name] — выборочное обновление одного клиента
# + Подтверждение удаления через inline-кнопки
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ==== Логирование установки ====
LOG_FILE="/var/log/botlinks-install.log"
exec > >(tee "$LOG_FILE") 2>&1

# ==== Цвета ====
RED=$(tput setaf 1 2>/dev/null || echo '\033[0;31m')
GREEN=$(tput setaf 2 2>/dev/null || echo '\033[0;32m')
YELLOW=$(tput setaf 3 2>/dev/null || echo '\033[0;33m')
BLUE=$(tput setaf 4 2>/dev/null || echo '\033[0;34m')
BOLD=$(tput bold 2>/dev/null || echo '\033[1m')
RESET=$(tput sgr0 2>/dev/null || echo '\033[0m')

# ==== Константы ====
APP_USER="botlinks"
DIR="/opt/bot_links_qr"
SERVICE="bot-links-qr"
VENV_DIR="$DIR/venv"
SSH_DIR="$DIR/.ssh"
KEY_PATH="$SSH_DIR/id_ed25519"

# ==== Функции ====
info()    { echo -e "${BLUE}${BOLD}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[ERR]${RESET}  $*"; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Ошибка в строке ${BASH_LINENO[0]} (код $exit_code). Скрипт остановлен."
        error "Лог установки: $LOG_FILE"
    fi
}
trap cleanup EXIT

require_input() {
    local prompt="$1" varname="$2" secret="${3:-false}" default="${4:-}"
    local value=""
    local full_prompt="$prompt"
    [[ -n "$default" ]] && full_prompt+=" [$default]"
    full_prompt+=": "

    while true; do
        if [[ "$secret" == "true" ]]; then
            read -rsp "$full_prompt" value
            echo
        else
            read -rp "$full_prompt" value
        fi
        value="${value:-$default}"
        if [[ -n "$value" ]]; then
            # FIX: использовать printf -v вместо eval (безопасность)
            printf -v "$varname" '%s' "$value"
            return 0
        fi
        warn "Значение не может быть пустым. Попробуйте снова."
    done
}

require_numeric() {
    local prompt="$1" varname="$2"
    local value=""
    while true; do
        read -rp "$prompt: " value
        if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -gt 0 ]]; then
            # FIX: использовать printf -v вместо eval
            printf -v "$varname" '%s' "$value"
            return 0
        fi
        warn "Введите положительное число."
    done
}

# ============================================================================
# ФУНКЦИЯ МИГРАЦИИ — импорт данных со старого сервера
# ============================================================================
do_migration() {
    echo ""
    info "=== Миграция данных со старого сервера ==="
    echo ""
    info "Этот режим перенесёт базу данных клиентов, SSH-ключи и конфигурацию"
    info "со старого сервера на новый. Все RAW-ссылки останутся рабочими."
    echo ""

    local OLD_HOST="" OLD_USER="" OLD_PORT="" OLD_DIR=""
    require_input "IP или hostname старого сервера" OLD_HOST false
    require_input "SSH-пользователь старого сервера" OLD_USER false "root"
    require_input "SSH-порт старого сервера" OLD_PORT false "22"
    require_input "Каталог бота на старом сервере" OLD_DIR false "/opt/bot_links_qr"

    local MIGRATE_DIR
    MIGRATE_DIR=$(mktemp -d /tmp/botlinks-migrate.XXXXXX)

    info "Проверка SSH-подключения к старому серверу..."
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         -p "$OLD_PORT" "${OLD_USER}@${OLD_HOST}" "echo ok" >/dev/null 2>&1; then
        error "Не удалось подключиться к ${OLD_USER}@${OLD_HOST}:${OLD_PORT}"
        error "Убедитесь, что SSH-ключ добавлен или настроен доступ по паролю."
        rm -rf "$MIGRATE_DIR"
        exit 1
    fi
    success "Подключение к старому серверу установлено."

    info "Скачиваю базу данных клиентов (db.json)..."
    if scp -P "$OLD_PORT" "${OLD_USER}@${OLD_HOST}:${OLD_DIR}/db.json" \
         "$MIGRATE_DIR/db.json" 2>/dev/null; then
        success "db.json скопирован."
    else
        warn "db.json не найден на старом сервере. Возможно, бот ещё не использовался."
    fi

    info "Скачиваю конфигурацию (.env)..."
    if scp -P "$OLD_PORT" "${OLD_USER}@${OLD_HOST}:${OLD_DIR}/.env" \
         "$MIGRATE_DIR/.env" 2>/dev/null; then
        success ".env скопирован."
    else
        warn ".env не найден."
    fi

    info "Скачиваю SSH-ключи (deploy key)..."
    if scp -P "$OLD_PORT" \
         "${OLD_USER}@${OLD_HOST}:${OLD_DIR}/.ssh/id_ed25519" \
         "${OLD_USER}@${OLD_HOST}:${OLD_DIR}/.ssh/id_ed25519.pub" \
         "$MIGRATE_DIR/" 2>/dev/null; then
        success "SSH-ключи скопированы."
    else
        warn "SSH-ключи не найдены. Будут сгенерированы новые."
    fi

    info "Скачиваю лог бота (необязательно)..."
    scp -P "$OLD_PORT" "${OLD_USER}@${OLD_HOST}:${OLD_DIR}/bot.log" \
        "$MIGRATE_DIR/bot.log" 2>/dev/null || true

    # Показываем содержимое мигрируемой базы
    if [[ -f "$MIGRATE_DIR/db.json" ]]; then
        local CLIENT_COUNT
        CLIENT_COUNT=$(python3 -c "
import json, sys
try:
    with open('$MIGRATE_DIR/db.json') as f:
        db = json.load(f)
    print(len(db))
except:
    print(0)
" 2>/dev/null || echo "0")
        info "В базе данных найдено клиентов: $CLIENT_COUNT"
    fi

    echo ""
    info "Скачанные файлы:"
    ls -la "$MIGRATE_DIR/"
    echo ""

    # Экспортируем путь к мигрируемым файлам для основного скрипта
    MIGRATE_FROM="$MIGRATE_DIR"
    export MIGRATE_FROM

    success "Данные для миграции подготовлены."
    echo ""
}

apply_migration() {
    # Применяем мигрируемые файлы после установки
    if [[ -z "${MIGRATE_FROM:-}" ]]; then
        return 0
    fi

    info "Применяю мигрируемые данные..."

    # Восстанавливаем базу данных клиентов (самое важное!)
    if [[ -f "$MIGRATE_FROM/db.json" ]]; then
        cp "$MIGRATE_FROM/db.json" "$DIR/db.json"
        chown "$APP_USER:$APP_USER" "$DIR/db.json"
        chmod 600 "$DIR/db.json"
        success "База данных клиентов (db.json) восстановлена."
    fi

    # Восстанавливаем SSH-ключи (чтобы не перерегистрировать deploy key)
    if [[ -f "$MIGRATE_FROM/id_ed25519" ]]; then
        cp "$MIGRATE_FROM/id_ed25519" "$KEY_PATH"
        cp "$MIGRATE_FROM/id_ed25519.pub" "${KEY_PATH}.pub"
        chown "$APP_USER:$APP_USER" "$KEY_PATH" "${KEY_PATH}.pub"
        chmod 600 "$KEY_PATH"
        chmod 644 "${KEY_PATH}.pub"
        success "SSH-ключи восстановлены (deploy key тот же, перерегистрация не нужна)."
        KEYS_MIGRATED=true
    fi

    # Восстанавливаем лог (опционально)
    if [[ -f "$MIGRATE_FROM/bot.log" ]]; then
        cp "$MIGRATE_FROM/bot.log" "$DIR/bot.log.old"
        chown "$APP_USER:$APP_USER" "$DIR/bot.log.old"
        info "Старый лог бота сохранён как bot.log.old"
    fi

    # Извлекаем конфигурацию из старого .env (если нужна)
    if [[ -f "$MIGRATE_FROM/.env" ]]; then
        cp "$MIGRATE_FROM/.env" "$DIR/.env.migrated"
        chown "$APP_USER:$APP_USER" "$DIR/.env.migrated"
        info "Старый .env сохранён как .env.migrated (для справки)"
    fi

    # Очистка
    rm -rf "$MIGRATE_FROM"

    success "Миграция данных завершена. База клиентов не изменена."
}

# ============================================================================
echo ""
info "=== Установка Bot-Links-GitFlic (v9.1 Smart JSON + Migration) ==="
echo ""

# ==== 0. Проверки окружения ====
info "Проверка окружения..."

if [[ $EUID -ne 0 ]]; then
    error "Запустите скрипт от root (sudo)."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd не найден. Скрипт рассчитан на systemd."
    exit 1
fi

# ==== Режим: миграция или чистая установка ====
MIGRATE_FROM=""
KEYS_MIGRATED=false

echo ""
echo "  Выберите режим установки:"
echo ""
echo "    ${BOLD}1${RESET} — Чистая установка (новый сервер, нет данных)"
echo "    ${BOLD}2${RESET} — Миграция со старого сервера (перенос БД клиентов)"
echo "    ${BOLD}3${RESET} — Переустановка (обновить код, сохранить данные)"
echo ""

read -rp "Режим [1/2/3]: " INSTALL_MODE
INSTALL_MODE="${INSTALL_MODE:-1}"

case "$INSTALL_MODE" in
    2)
        do_migration
        ;;
    3)
        if [[ -f "$DIR/db.json" ]]; then
            info "Режим переустановки: db.json будет сохранён."
            MIGRATE_FROM=$(mktemp -d /tmp/botlinks-migrate.XXXXXX)
            cp "$DIR/db.json" "$MIGRATE_FROM/db.json"
            if [[ -f "$KEY_PATH" ]]; then
                cp "$KEY_PATH" "$MIGRATE_FROM/id_ed25519"
                cp "${KEY_PATH}.pub" "$MIGRATE_FROM/id_ed25519.pub"
            fi
            if [[ -f "$DIR/.env" ]]; then
                cp "$DIR/.env" "$MIGRATE_FROM/.env"
            fi
            export MIGRATE_FROM
        else
            warn "db.json не найден, будет чистая установка."
        fi
        ;;
    1|*)
        info "Чистая установка."
        ;;
esac

if [[ -f "$DIR/bot.py" ]]; then
    warn "Бот уже установлен в $DIR."
    if [[ "$INSTALL_MODE" != "3" ]]; then
        read -rp "Перезаписать установку? [y/N]: " OVERWRITE
        if [[ "${OVERWRITE,,}" != "y" ]]; then
            info "Установка отменена пользователем."
            exit 0
        fi
    fi
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        info "Останавливаю текущий экземпляр бота..."
        systemctl stop "$SERVICE"
        success "Бот остановлен."
    fi
fi

success "Окружение в порядке."

# ==== 1. Сбор данных ====
echo ""
info "Сбор параметров конфигурации..."
echo ""

# При миграции пытаемся прочитать параметры из старого .env
if [[ -n "${MIGRATE_FROM:-}" ]] && [[ -f "${MIGRATE_FROM}/.env" ]]; then
    info "Читаю параметры из мигрированного .env..."

    _migrated_env="${MIGRATE_FROM}/.env"
    _get_env_val() {
        grep "^$1=" "$_migrated_env" 2>/dev/null | head -1 | cut -d= -f2-
    }

    _OLD_TOKEN=$(_get_env_val "TELEGRAM_TOKEN" || true)
    _OLD_OWNER=$(_get_env_val "OWNER_ID" || true)
    _OLD_GIT_USER=$(_get_env_val "GIT_USER" || true)
    _OLD_GIT_REPO=$(_get_env_val "GIT_REPO" || true)
    _OLD_GIT_BRANCH=$(_get_env_val "GIT_BRANCH" || true)

    echo "  Найдены значения из старого сервера:"
    [[ -n "$_OLD_OWNER" ]] && echo "    OWNER_ID: $_OLD_OWNER"
    [[ -n "$_OLD_GIT_USER" ]] && echo "    GIT_USER: $_OLD_GIT_USER"
    [[ -n "$_OLD_GIT_REPO" ]] && echo "    GIT_REPO: $_OLD_GIT_REPO"
    [[ -n "$_OLD_GIT_BRANCH" ]] && echo "    GIT_BRANCH: $_OLD_GIT_BRANCH"
    echo ""

    require_input "Введите TELEGRAM TOKEN" TELEGRAM_TOKEN true "${_OLD_TOKEN:-}"
    # Validate OWNER_ID is numeric even in migration mode
    while true; do
        require_input "Введите ваш OWNER_ID (число)" OWNER_ID false "${_OLD_OWNER:-}"
        if [[ "$OWNER_ID" =~ ^[0-9]+$ ]] && [[ "$OWNER_ID" -gt 0 ]]; then
            break
        fi
        warn "OWNER_ID должен быть положительным числом."
    done
    require_input "Введите ваш логин на GitFlic" GIT_USER false "${_OLD_GIT_USER:-admin1993}"
    require_input "Введите название репозитория" GIT_REPO false "${_OLD_GIT_REPO:-subs}"
    require_input "Введите ветку Git" GIT_BRANCH false "${_OLD_GIT_BRANCH:-master}"
else
    require_input "Введите TELEGRAM TOKEN" TELEGRAM_TOKEN true
    require_numeric "Введите ваш OWNER_ID (число)" OWNER_ID
    require_input "Введите ваш логин на GitFlic" GIT_USER false "admin1993"
    require_input "Введите название репозитория" GIT_REPO false "subs"
    require_input "Введите ветку Git" GIT_BRANCH false "master"
fi

echo ""
success "Конфигурация собрана."

# ==== 2. Подготовка системы ====
info "Установка системных пакетов..."

APT_CACHE="/var/cache/apt/pkgcache.bin"
if [[ ! -f "$APT_CACHE" ]] || [[ -n "$(find "$APT_CACHE" -mmin +60 2>/dev/null || true)" ]]; then
    apt-get update -qq
else
    info "Кеш apt свежий, пропускаю update."
fi

apt-get install -y -qq --no-install-recommends \
    git python3 python3-venv python3-pip openssh-client

success "Пакеты установлены."

# ==== 3. Создание пользователя и каталогов ====
info "Настройка пользователя и каталогов..."

if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$DIR" --shell /usr/sbin/nologin "$APP_USER"
    success "Пользователь $APP_USER создан."
else
    info "Пользователь $APP_USER уже существует."
fi

mkdir -p "$DIR"
chown "$APP_USER:$APP_USER" "$DIR"

# ==== 4. SSH ключ ====
info "Настройка SSH..."

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$APP_USER:$APP_USER" "$SSH_DIR"

# Сначала добавляем known_hosts (ДО проверки ключа)
if ! grep -q "gitflic.ru" "$SSH_DIR/known_hosts" 2>/dev/null; then
    sudo -u "$APP_USER" ssh-keyscan -H gitflic.ru >> "$SSH_DIR/known_hosts" 2>/dev/null || true
    success "gitflic.ru добавлен в known_hosts."
fi

if [[ "$KEYS_MIGRATED" == "true" ]]; then
    info "SSH-ключи восстановлены из миграции. Новая генерация не нужна."
elif [[ ! -f "$KEY_PATH" ]]; then
    info "Генерация deploy-ключа (ed25519)..."
    sudo -u "$APP_USER" ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "botlinks-deploy@$(hostname)"
    success "Ключ сгенерирован."
else
    info "Deploy-ключ уже существует."
fi

SSH_CONFIG="$SSH_DIR/config"
if [[ ! -f "$SSH_CONFIG" ]] || ! grep -q "gitflic.ru" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

Host gitflic.ru
    HostName gitflic.ru
    User git
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    ConnectTimeout 10
EOF
    chmod 600 "$SSH_CONFIG"
    chown "$APP_USER:$APP_USER" "$SSH_CONFIG"
    success "SSH config создан."
fi

if [[ "$KEYS_MIGRATED" == "true" ]]; then
    echo ""
    echo "${GREEN}${BOLD}SSH-ключ перенесён со старого сервера.${RESET}"
    echo "${GREEN}Если deploy key уже был добавлен в GitFlic — повторно добавлять НЕ нужно.${RESET}"
    echo ""
else
    echo ""
    echo "${RED}${BOLD}!!! ВАЖНО: Добавьте этот публичный ключ как Deploy Key в GitFlic !!!${RESET}"
    echo ""
    echo "  Откройте: https://gitflic.ru/project/${GIT_USER}/${GIT_REPO}/settings/keys"
    echo "  Вставьте этот ключ (с правом ЗАПИСИ):"
    echo ""
    cat "${KEY_PATH}.pub"
    echo ""
    echo "${YELLOW}Нажмите Enter после добавления ключа в GitFlic...${RESET}"
    read -r
fi

# ==== 5. Проверка SSH ====
info "Проверка связи с GitFlic..."

GIT_TEST_URL="git@gitflic.ru:${GIT_USER}/${GIT_REPO}.git"

if sudo -u "$APP_USER" \
    GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -i $KEY_PATH" \
    git ls-remote --exit-code "$GIT_TEST_URL" HEAD >/dev/null 2>&1; then
    success "Связь с GitFlic установлена!"
else
    LS_REMOTE_OUTPUT=$(sudo -u "$APP_USER" \
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -i $KEY_PATH" \
        git ls-remote "$GIT_TEST_URL" HEAD 2>&1 || true)

    echo ""
    error "Не удалось получить доступ к репозиторию: $GIT_TEST_URL"
    echo ""
    echo "  Возможные причины:"
    echo "    1. Deploy key не добавлен в репозиторий"
    echo "    2. Неверный логин (${BOLD}$GIT_USER${RESET}) или репозиторий (${BOLD}$GIT_REPO${RESET})"
    echo "    3. Репозиторий не создан"
    echo "    4. Нет прав на запись"
    echo ""
    echo "  Ответ: $LS_REMOTE_OUTPUT"
    echo ""

    read -rp "Продолжить без проверки? [y/N]: " SKIP_CHECK
    if [[ "${SKIP_CHECK,,}" != "y" ]]; then
        exit 1
    fi
    warn "Проверка пропущена."
fi

# ==== 6. Конфигурация (.env) ====
info "Создание конфигурации..."

(
    umask 077
    cat > "$DIR/.env" <<EOF
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
OWNER_ID=$OWNER_ID
GIT_URL=git@gitflic.ru:$GIT_USER/$GIT_REPO.git
GIT_BRANCH=$GIT_BRANCH
GIT_USER=$GIT_USER
GIT_REPO=$GIT_REPO
DB_FILE=$DIR/db.json
LOG_FILE=$DIR/bot.log
APP_DIR=$DIR
SSH_KEY=$KEY_PATH
MAX_SIZE=2097152
SHORTENER_TIMEOUT=5
GIT_CMD_TIMEOUT=60
REFRESH_CONCURRENT=5
AUTO_REFRESH_HOURS=6
INJECT_RULES=true
EOF
)
chown "$APP_USER:$APP_USER" "$DIR/.env"
success "Файл .env создан."

# ==== 7. requirements.txt ====
cat > "$DIR/requirements.txt" <<'REQ'
python-telegram-bot==20.8
aiohttp>=3.9,<4
apscheduler>=3.10,<4
qrcode[pil]>=7.4
Pillow>=10.0
python-dotenv>=1.0
aiofiles>=23.0
REQ
chown "$APP_USER:$APP_USER" "$DIR/requirements.txt"
success "requirements.txt создан."

# ==== 8. Код бота ====
info "Деплой кода бота..."

# --- config.py ---
cat > "$DIR/config.py" <<'PYCONFIG'
"""Конфигурация бота из переменных окружения."""

import os
from dotenv import load_dotenv

load_dotenv()


def _env(key: str, default: str | None = None, *, cast=str, required: bool = False):
    val = os.getenv(key, default)
    if required and not val:
        raise RuntimeError(f"Переменная окружения {key} обязательна")
    if val is None:
        return val
    return cast(val)


def _bool(val: str) -> bool:
    return val.lower() in ("true", "1", "yes", "on")


TOKEN: str = _env("TELEGRAM_TOKEN", required=True)
OWNER_ID: int = _env("OWNER_ID", cast=int, required=True)
GIT_URL: str = _env("GIT_URL", required=True)
GIT_BRANCH: str = _env("GIT_BRANCH", default="master")
GIT_USER: str = _env("GIT_USER", required=True)
GIT_REPO: str = _env("GIT_REPO", required=True)
DIR: str = _env("APP_DIR", required=True)
DB_FILE: str = _env("DB_FILE", required=True)
LOG_FILE: str = _env("LOG_FILE", required=True)
SSH_KEY: str = _env("SSH_KEY", default="")
MAX_SIZE: int = _env("MAX_SIZE", default="2097152", cast=int)
SHORTENER_TIMEOUT: int = _env("SHORTENER_TIMEOUT", default="5", cast=int)
GIT_CMD_TIMEOUT: int = _env("GIT_CMD_TIMEOUT", default="60", cast=int)
REFRESH_CONCURRENT: int = _env("REFRESH_CONCURRENT", default="5", cast=int)
AUTO_REFRESH_HOURS: int = _env("AUTO_REFRESH_HOURS", default="6", cast=int)
INJECT_RULES: bool = _env("INJECT_RULES", default="true", cast=_bool)
PYCONFIG

# --- bot.py ---
cat > "$DIR/bot.py" <<'PYBOT'
"""Bot-Links-GitFlic v9.1 (Smart JSON + Migration Edition)

Возможности:
  - Извлечение имени клиента из контента подписки (vless://#Name, vmess ps, JSON tag)
  - Автоопределение формата: JSON (sing-box/xray) или текст (base64/URI)
  - Идемпотентная инъекция правил блокировки в JSON-конфиги
  - Автообновление каждые N часов через APScheduler с уведомлением в Telegram
  - Расширение фиксируется при создании — RAW-ссылки навсегда стабильны
  - Экспорт/импорт базы данных для миграции на новый сервер
  - /append — добавление конфигов к существующему клиенту
  - /removeconfig — удаление отдельных конфигов из файла клиента
  - /cancel — отмена текущей операции
  - /rename — переименование клиента (git mv + новая short-ссылка)
  - /seturl — обновление источника конфига с немедленным re-fetch
  - /info — подробная карточка клиента с action-кнопками
  - /refresh [name] — выборочное обновление одного клиента
  - Подтверждение удаления через inline-кнопки

Архитектура refresh:
  1. Скачать все конфиги параллельно → dict в RAM
  2. Обработать (инъекция правил если JSON)
  3. git fetch + reset --hard
  4. Записать из RAM на диск
  5. Один git commit + push
"""

import asyncio
import base64 as b64
import io
import json
import logging
import os
import re
import shutil
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from functools import wraps

import aiofiles
import aiohttp
import qrcode
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from logging.handlers import RotatingFileHandler
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

import config

# ── Логирование ──────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        RotatingFileHandler(
            config.LOG_FILE, maxBytes=10*1024*1024, backupCount=3, encoding="utf-8"
        ),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("bot-links")

# ── Состояние ────────────────────────────────────────────────────────────────

_git_lock = asyncio.Lock()
_db_lock = asyncio.Lock()
_refresh_lock = asyncio.Lock()
_scheduler: AsyncIOScheduler | None = None
_app_ref: Application | None = None

REPO_DIR = os.path.join(config.DIR, "repo")
TG_MSG_LIMIT = 4000

# Маркер инъекции — защита от дублирования правил
INJECT_MARKER = "__botlinks_injected__"

# Cache: message_id → client_name (for reply-based append)
_save_msg_to_client: dict[int, str] = {}
_SAVE_MSG_CACHE_MAX = 200

# GIT_SSH_COMMAND для всех git-операций
GIT_SSH_CMD = f"ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10"
if config.SSH_KEY:
    GIT_SSH_CMD += f" -i {config.SSH_KEY}"


# ══════════════════════════════════════════════════════════════════════════════
#  УТИЛИТЫ
# ══════════════════════════════════════════════════════════════════════════════


def owner_only(func):
    """Декоратор: пропускает только OWNER_ID."""

    @wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        if user is None or user.id != config.OWNER_ID:
            logger.warning(
                "Доступ запрещён: user_id=%s",
                getattr(user, "id", "?"),
            )
            return
        return await func(update, context)

    return wrapper


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def is_valid_url(url: str) -> bool:
    try:
        p = urllib.parse.urlparse(url)
        return p.scheme in ("http", "https") and bool(p.netloc)
    except Exception:
        return False


async def run_cmd(
    *args: str, cwd: str | None = None, timeout: int | None = None,
    env: dict | None = None,
) -> str:
    """Запуск внешней команды с таймаутом."""
    timeout = timeout or config.GIT_CMD_TIMEOUT

    # Добавляем GIT_SSH_COMMAND в окружение для git-команд
    cmd_env = os.environ.copy()
    cmd_env["GIT_SSH_COMMAND"] = GIT_SSH_CMD
    if env:
        cmd_env.update(env)

    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=cmd_env,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        raise RuntimeError(f"Таймаут ({timeout}с): {' '.join(args)}")

    if proc.returncode != 0:
        err = stderr.decode().strip() or f"код {proc.returncode}"
        raise RuntimeError(f"[{' '.join(args)}]: {err}")

    return stdout.decode().strip()


# ══════════════════════════════════════════════════════════════════════════════
#  GIT
# ══════════════════════════════════════════════════════════════════════════════


async def init_git():
    if not os.path.exists(REPO_DIR):
        logger.info("Клонирование %s ...", config.GIT_URL)
        await run_cmd(
            "git", "clone", "-b", config.GIT_BRANCH,
            config.GIT_URL, REPO_DIR,
            timeout=120,
        )
        await run_cmd("git", "config", "user.name", "Bot", cwd=REPO_DIR)
        await run_cmd("git", "config", "user.email", "bot@local", cwd=REPO_DIR)
        logger.info("Репозиторий клонирован.")
    else:
        logger.info("Репозиторий существует, синхронизирую...")
        await git_sync()


async def git_sync():
    await run_cmd("git", "fetch", "origin", config.GIT_BRANCH, cwd=REPO_DIR)
    await run_cmd(
        "git", "reset", "--hard", f"origin/{config.GIT_BRANCH}", cwd=REPO_DIR
    )


async def git_has_changes(cwd: str) -> bool:
    """Проверить, есть ли staged или unstaged изменения."""
    try:
        result = await run_cmd("git", "status", "--porcelain", cwd=cwd)
        return bool(result.strip())
    except Exception:
        return False


async def git_commit_push(message: str, files: list[str]):
    for f in files:
        await run_cmd("git", "add", f, cwd=REPO_DIR)

    # FIX: проверяем, что есть что коммитить
    if not await git_has_changes(REPO_DIR):
        logger.info("git: нечего коммитить, пропускаю.")
        return

    await run_cmd("git", "commit", "-m", message, cwd=REPO_DIR)
    await run_cmd("git", "push", "origin", config.GIT_BRANCH, cwd=REPO_DIR)


# ══════════════════════════════════════════════════════════════════════════════
#  БАЗА ДАННЫХ
# ══════════════════════════════════════════════════════════════════════════════


async def load_db() -> dict:
    async with _db_lock:
        if not os.path.exists(config.DB_FILE):
            return {}
        try:
            async with aiofiles.open(config.DB_FILE, "r", encoding="utf-8") as f:
                content = await f.read()
            return json.loads(content) if content.strip() else {}
        except (json.JSONDecodeError, IOError) as e:
            logger.error("Ошибка чтения БД: %s", e)
            return {}


async def save_db(db: dict):
    async with _db_lock:
        # FIX: атомарная запись через tmp-файл
        tmp_path = config.DB_FILE + ".tmp"
        async with aiofiles.open(tmp_path, "w", encoding="utf-8") as f:
            await f.write(json.dumps(db, indent=2, ensure_ascii=False))
        os.replace(tmp_path, config.DB_FILE)


async def export_db() -> str:
    """Экспорт базы данных в JSON-строку для миграции."""
    db = await load_db()
    export_data = {
        "version": "9.1",
        "exported_at": now_iso(),
        "git_user": config.GIT_USER,
        "git_repo": config.GIT_REPO,
        "git_branch": config.GIT_BRANCH,
        "clients_count": len(db),
        "clients": db,
    }
    return json.dumps(export_data, indent=2, ensure_ascii=False)


async def import_db(data: str) -> dict:
    """Импорт базы данных из JSON-строки. Возвращает статистику."""
    parsed = json.loads(data)

    if "clients" in parsed:
        # Формат экспорта v9.1
        clients = parsed["clients"]
    elif isinstance(parsed, dict) and all(
        isinstance(v, dict) for v in parsed.values()
    ):
        # Прямой формат db.json
        clients = parsed
    else:
        raise ValueError("Неизвестный формат данных для импорта")

    existing_db = await load_db()
    imported = 0
    skipped = 0
    updated = 0

    for name, entry in clients.items():
        if name in existing_db:
            # Обновляем только если запись свежее
            existing_time = existing_db[name].get("created_at", "")
            new_time = entry.get("created_at", "")
            if new_time > existing_time:
                existing_db[name] = entry
                updated += 1
            else:
                skipped += 1
        else:
            existing_db[name] = entry
            imported += 1

    await save_db(existing_db)

    return {
        "imported": imported,
        "updated": updated,
        "skipped": skipped,
        "total": len(existing_db),
    }


# ══════════════════════════════════════════════════════════════════════════════
#  ИЗВЛЕЧЕНИЕ ИМЕНИ КЛИЕНТА
# ══════════════════════════════════════════════════════════════════════════════


def _sanitize_name(raw: str) -> str:
    """Очистить имя: убрать спецсимволы, ограничить длину."""
    if not raw:
        return ""

    # URL-декод (%D0%90%D0%BD%D0%B4%D1%80%D0%B5%D0%B9 → Андрей)
    name = urllib.parse.unquote(raw).strip()

    # Убираем эмодзи и спецсимволы, оставляем буквы/цифры/дефис/подчёркивание/точку
    name = re.sub(r"[^\w\s.\-]", "", name, flags=re.UNICODE)

    # Пробелы → подчёркивания
    name = re.sub(r"\s+", "_", name).strip("_.")

    # Ограничиваем длину
    name = name[:40]

    return name


def _extract_name_from_uri(line: str) -> str:
    """Извлечь имя из URI-строки (vless://#Name, vmess://base64→ps, и т.д.)."""
    line = line.strip()

    # vless://...#ClientName, trojan://...#Name, ss://...#Name
    if "#" in line:
        fragment = line.rsplit("#", 1)[1]
        return _sanitize_name(fragment)

    # vmess://base64 → декодируем JSON, берём "ps"
    if line.lower().startswith("vmess://"):
        try:
            payload = line[8:]
            payload += "=" * (-len(payload) % 4)
            decoded = b64.b64decode(payload).decode("utf-8", errors="ignore")
            data = json.loads(decoded)
            ps = data.get("ps", "") or data.get("remarks", "")
            return _sanitize_name(ps)
        except Exception:
            pass

    return ""


def _extract_name_from_json(data: dict) -> str:
    """Извлечь имя из JSON-конфига (sing-box / xray): первый proxy outbound tag."""
    skip_tags = {"direct", "block", "dns", "dns-out", "bypass", "reject"}
    skip_types = {"direct", "block", "blackhole", "dns", "selector", "urltest"}

    for ob in data.get("outbounds", []):
        tag = ob.get("tag", "")
        ob_type = ob.get("type", ob.get("protocol", ""))

        if tag.lower() in skip_tags:
            continue
        if ob_type in skip_types:
            continue

        name = _sanitize_name(tag)
        if name:
            return name

    # Fallback: remarks / ps / name в верхнем уровне
    for key in ("remarks", "ps", "name", "tag"):
        val = data.get(key, "")
        if val:
            name = _sanitize_name(str(val))
            if name:
                return name

    return ""


def extract_client_name(content: str) -> str:
    """Извлечь имя клиента из любого формата подписки.

    Приоритет:
      1. JSON → outbounds[].tag (первый proxy)
      2. URI-строки → фрагмент после #
      3. Base64-декод → URI-строки внутри
      4. Пустая строка (fallback на uuid в вызывающем коде)
    """
    stripped = content.strip()

    # Попытка 1: JSON
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            data = json.loads(stripped)
            if isinstance(data, dict):
                name = _extract_name_from_json(data)
                if name:
                    return name
        except json.JSONDecodeError:
            pass

    # Попытка 2: URI-строки
    lines = stripped.splitlines()

    # Если одна строка и не URI — возможно base64-кодированный список
    if len(lines) == 1 and not any(
        lines[0].startswith(p) for p in ("vless://", "vmess://", "trojan://", "ss://")
    ):
        try:
            payload = lines[0].strip()
            payload += "=" * (-len(payload) % 4)
            decoded = b64.b64decode(payload).decode("utf-8", errors="ignore")
            if any(
                decoded.startswith(p)
                for p in ("vless://", "vmess://", "trojan://", "ss://")
            ):
                lines = decoded.strip().splitlines()
        except Exception:
            pass

    # Берём имя из первой URI-строки с именем
    for line in lines:
        line = line.strip()
        if any(
            line.startswith(p)
            for p in ("vless://", "vmess://", "trojan://", "ss://")
        ):
            name = _extract_name_from_uri(line)
            if name:
                return name

    return ""


# ══════════════════════════════════════════════════════════════════════════════
#  ИНЪЕКЦИЯ ПРАВИЛ БЛОКИРОВКИ (ИДЕМПОТЕНТНАЯ)
# ══════════════════════════════════════════════════════════════════════════════


def _detect_format(text: str) -> str:
    """Определить формат: 'json' или 'txt'."""
    stripped = text.strip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            json.loads(stripped)
            return "json"
        except json.JSONDecodeError:
            pass
    return "txt"


def _remove_old_injections(rules: list) -> list:
    """Удалить ранее инъецированные правила (по маркеру)."""
    return [r for r in rules if not r.get(INJECT_MARKER)]


def inject_rules(text: str) -> tuple[str, str]:
    """Обработать контент: определить формат и внедрить правила блокировки.

    Возвращает (обработанный_текст, расширение).
    Идемпотентна: маркер предотвращает дублирование при повторных вызовах.
    """
    fmt = _detect_format(text)

    if fmt != "json" or not config.INJECT_RULES:
        return text, fmt

    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return text, "txt"

    if isinstance(data, list):
        return text, "json"  # Can't inject rules into array format

    # ── Sing-box формат ──
    if "route" in data:
        route = data.setdefault("route", {})
        rules = route.setdefault("rules", [])

        # Удаляем старые инъекции (идемпотентность)
        route["rules"] = _remove_old_injections(rules)

        # Outbound "block"
        outbounds = data.setdefault("outbounds", [])
        if not any(o.get("tag") == "block" for o in outbounds):
            outbounds.append({"type": "block", "tag": "block"})

        # Правило первым (с маркером)
        route["rules"].insert(0, {
            INJECT_MARKER: True,
            "domain_suffix": [".tm"],
            "geosite": ["category-ads-all", "category-porn"],
            "outbound": "block",
        })

    # ── Xray / V2Ray формат ──
    elif "routing" in data:
        routing = data.setdefault("routing", {})
        rules = routing.setdefault("rules", [])

        routing["rules"] = _remove_old_injections(rules)

        outbounds = data.setdefault("outbounds", [])
        if not any(o.get("tag") == "block" for o in outbounds):
            outbounds.append({"protocol": "blackhole", "tag": "block"})

        routing["rules"].insert(0, {
            INJECT_MARKER: True,
            "type": "field",
            "outboundTag": "block",
            "domain": [
                "domain:.tm",
                "geosite:category-ads-all",
                "geosite:category-porn",
            ],
        })

    return json.dumps(data, indent=2, ensure_ascii=False), "json"


# ══════════════════════════════════════════════════════════════════════════════
#  HTTP
# ══════════════════════════════════════════════════════════════════════════════


async def get_short(session: aiohttp.ClientSession, url: str) -> str:
    try:
        timeout = aiohttp.ClientTimeout(total=config.SHORTENER_TIMEOUT)
        async with session.get(
            f"https://clck.ru/--?url={url}", timeout=timeout
        ) as r:
            if r.status == 200:
                short = (await r.text()).strip()
                if short:
                    return short
    except Exception as e:
        logger.warning("Сокращатель: %s", e)
    return url


def build_raw_url(name: str, ext: str) -> str:
    """Постоянная RAW-ссылка. Расширение фиксируется при создании."""
    return (
        f"https://gitflic.ru/project/{config.GIT_USER}/{config.GIT_REPO}"
        f"/blob/raw?file={name}.{ext}&branch={config.GIT_BRANCH}"
    )


async def download_content(session: aiohttp.ClientSession, url: str) -> str:
    timeout = aiohttp.ClientTimeout(total=30)
    async with session.get(url, timeout=timeout, allow_redirects=True) as resp:
        if resp.status != 200:
            raise ValueError(f"HTTP {resp.status}")

        cl = resp.content_length
        if cl and cl > config.MAX_SIZE:
            raise ValueError(
                f"Размер {cl // 1024}KB > {config.MAX_SIZE // 1024}KB"
            )

        data = await resp.read()
        if len(data) > config.MAX_SIZE:
            raise ValueError(
                f"Размер {len(data) // 1024}KB > {config.MAX_SIZE // 1024}KB"
            )

        return data.decode("utf-8", errors="replace")


# ══════════════════════════════════════════════════════════════════════════════
#  ЗАГРУЗКА ОДНОГО ФАЙЛА
# ══════════════════════════════════════════════════════════════════════════════


async def upload_single(
    name: str, content: str, ext: str, session: aiohttp.ClientSession
) -> str:
    """Записать один файл в репо, вернуть короткую ссылку."""
    fname = f"{name}.{ext}"
    fpath = os.path.join(REPO_DIR, fname)

    async with _git_lock:
        await git_sync()
        async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
            await f.write(content)
        await git_commit_push(f"Add {name}", [fname])

    return await get_short(session, build_raw_url(name, ext))


# ══════════════════════════════════════════════════════════════════════════════
#  REFRESH — МАССОВОЕ ОБНОВЛЕНИЕ
# ══════════════════════════════════════════════════════════════════════════════


async def _download_and_process(
    session: aiohttp.ClientSession,
    name: str,
    entry: dict,
) -> dict:
    """Скачать и обработать один конфиг В ПАМЯТЬ."""
    original_url = entry.get("original_url")
    if not original_url:
        return {"name": name, "ok": False, "error": "нет original_url"}

    ext = entry.get("ext", "txt")

    try:
        raw_content = await download_content(session, original_url)
        processed, _ = inject_rules(raw_content)

        return {
            "name": name,
            "ok": True,
            "content": processed,
            "ext": ext,
            "size": len(processed),
        }
    except Exception as e:
        return {"name": name, "ok": False, "error": str(e)}


async def _execute_refresh(
    db: dict,
    *,
    notify_callback=None,
    source: str = "manual",
) -> dict:
    """Общая логика refresh для ручного и автоматического режимов."""

    # FIX: используем Lock вместо bool-флага для потокобезопасности
    if _refresh_lock.locked():
        return {"ok": 0, "fail": 0, "elapsed": 0, "errors": ["Уже выполняется"]}

    async with _refresh_lock:
        start_time = time.monotonic()
        total = len(db)

        # ── Шаг 1: Скачиваем все конфиги в RAM ──
        if notify_callback:
            await notify_callback(
                f"🔄 <b>Обновление {total} записей...</b>\n\n"
                f"📥 Шаг 1/3 — Скачиваю конфиги..."
            )

        semaphore = asyncio.Semaphore(config.REFRESH_CONCURRENT)

        async with aiohttp.ClientSession() as session:

            async def limited(name, entry):
                async with semaphore:
                    return await _download_and_process(session, name, entry)

            tasks = [limited(name, entry) for name, entry in db.items()]
            results = await asyncio.gather(*tasks)

        ok_results = [r for r in results if r["ok"]]
        fail_results = [r for r in results if not r["ok"]]

        content_map: dict[str, dict] = {r["name"]: r for r in ok_results}

        if not content_map:
            return {
                "ok": 0,
                "fail": len(fail_results),
                "elapsed": round(time.monotonic() - start_time, 1),
                "errors": [
                    {"name": r["name"], "error": r["error"]}
                    for r in fail_results
                ],
            }

        # ── Шаг 2: git sync → запись из RAM → коммит ──
        if notify_callback:
            await notify_callback(
                f"🔄 <b>Обновление {total} записей...</b>\n\n"
                f"📥 Скачано: {len(ok_results)}/{total}\n"
                f"❌ Ошибок: {len(fail_results)}\n\n"
                f"📤 Шаг 2/3 — Запись в GitFlic..."
            )

        async with _git_lock:
            await git_sync()

            changed_files: list[str] = []
            for name, r in content_map.items():
                fname = f"{name}.{r['ext']}"
                fpath = os.path.join(REPO_DIR, fname)
                async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                    await f.write(r["content"])
                changed_files.append(fname)

            if changed_files:
                prefix = "Auto-refresh" if source == "auto" else "Refresh"
                await git_commit_push(
                    f"{prefix} {len(changed_files)} configs ({now_iso()})",
                    changed_files,
                )

        # ── Шаг 3: Обновляем БД ──
        if notify_callback:
            await notify_callback(
                f"🔄 <b>Обновление {total} записей...</b>\n\n"
                f"💾 Шаг 3/3 — Обновляю базу данных..."
            )

        current_db = await load_db()
        refresh_time = now_iso()
        for r in ok_results:
            if r["name"] in current_db:
                current_db[r["name"]]["last_refresh"] = refresh_time
                current_db[r["name"]]["last_refresh_size"] = r["size"]
            else:
                logger.debug("Refresh: %s not in current_db (possibly deleted during refresh)", r["name"])
        await save_db(current_db)

        elapsed = round(time.monotonic() - start_time, 1)
        return {
            "ok": len(ok_results),
            "fail": len(fail_results),
            "elapsed": elapsed,
            "errors": [
                {"name": r["name"], "error": r["error"]}
                for r in fail_results
            ],
        }


# ══════════════════════════════════════════════════════════════════════════════
#  АВТООБНОВЛЕНИЕ (APScheduler)
# ════════════════════════════════════════════════  ═════════════════════════════


async def auto_refresh_job():
    """Фоновая задача: обновление всех конфигов."""
    logger.info(
        "Автообновление запущено (каждые %dч)...", config.AUTO_REFRESH_HOURS
    )

    db = await load_db()
    if not db:
        logger.info("Автообновление: БД пуста, пропускаю.")
        return

    result = await _execute_refresh(db, source="auto")

    logger.info(
        "Автообновление: ok=%d fail=%d time=%.1fs",
        result["ok"], result["fail"], result["elapsed"],
    )

    # Уведомляем владельца в Telegram
    if _app_ref and (result["ok"] > 0 or result["fail"] > 0):
        report = (
            f"🔄 <b>Автообновление завершено</b>\n\n"
            f"✅ Успешно: <code>{result['ok']}</code>\n"
            f"❌ Ошибок: <code>{result['fail']}</code>\n"
            f"⏱ Время: <code>{result['elapsed']}с</code>"
        )
        if result["errors"]:
            report += "\n\n<b>Ошибки:</b>\n"
            for e in result["errors"][:5]:
                report += f"• <code>{e['name']}</code>: {e['error']}\n"

        try:
            await _app_ref.bot.send_message(
                config.OWNER_ID, report, parse_mode="HTML"
            )
        except Exception as e:
            logger.warning("Уведомление не отправлено: %s", e)


# ══════════════════════════════════════════════════════════════════════════════
#  APPEND / REMOVECONFIG — ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════════════════════════


def _decode_if_base64(text: str) -> tuple[str, bool]:
    """Try to decode base64. Returns (decoded_text, was_base64)."""
    stripped = text.strip()
    if any(stripped.startswith(p) for p in ("vless://", "vmess://", "trojan://", "ss://", "{", "[")):
        return stripped, False
    try:
        payload = stripped
        payload += "=" * (-len(payload) % 4)
        decoded = b64.b64decode(payload).decode("utf-8", errors="ignore")
        if any(decoded.startswith(p) for p in ("vless://", "vmess://", "trojan://", "ss://")):
            return decoded, True
    except Exception:
        pass
    return stripped, False


def merge_text_configs(existing: str, new_configs: str) -> tuple[str, int]:
    """Merge URI-based configs. Returns (merged, added_count)."""
    existing_decoded, was_base64 = _decode_if_base64(existing)
    new_decoded, _ = _decode_if_base64(new_configs)

    existing_lines = [l.strip() for l in existing_decoded.splitlines() if l.strip()]
    new_lines = [l.strip() for l in new_decoded.splitlines() if l.strip()]

    existing_set = set(existing_lines)
    added = [l for l in new_lines if l not in existing_set]

    merged_lines = existing_lines + added
    merged = "\n".join(merged_lines) + "\n"

    if was_base64:
        merged = b64.b64encode(merged.encode()).decode()

    return merged, len(added)


def merge_json_configs(existing: str, new_configs: str) -> tuple[str, int]:
    """Merge JSON configs. Deduplicate outbounds by tag. Returns (merged, added_count)."""
    existing_data = json.loads(existing)

    new_stripped = new_configs.strip()
    new_outbounds = []

    if new_stripped.startswith("{"):
        new_data = json.loads(new_stripped)
        new_outbounds = new_data.get("outbounds", [])
    elif new_stripped.startswith("["):
        new_outbounds = json.loads(new_stripped)
    else:
        return existing, 0

    existing_tags = {ob.get("tag", "") for ob in existing_data.get("outbounds", [])}

    added = 0
    for ob in new_outbounds:
        tag = ob.get("tag", "")
        if tag and tag not in existing_tags:
            existing_data.setdefault("outbounds", []).append(ob)
            existing_tags.add(tag)
            added += 1

    result, _ = inject_rules(json.dumps(existing_data, indent=2, ensure_ascii=False))
    return result, added


async def _do_append(client_name: str, new_configs: str, update: Update) -> None:
    """Execute the append operation."""
    db = await load_db()
    if client_name not in db:
        await update.message.reply_text(f"⚠️ Клиент <code>{client_name}</code> не найден.", parse_mode="HTML")
        return

    entry = db[client_name]
    ext = entry.get("ext", "txt")
    fname = f"{client_name}.{ext}"
    fpath = os.path.join(REPO_DIR, fname)

    m = await update.message.reply_text("⏳ Добавляю конфиги...")

    try:
        async with _git_lock:
            await git_sync()

            if not os.path.exists(fpath):
                await m.edit_text(f"❌ Файл {fname} не найден в репозитории.")
                return

            async with aiofiles.open(fpath, "r", encoding="utf-8") as f:
                existing_content = await f.read()

            if ext == "json":
                merged, added_count = merge_json_configs(existing_content, new_configs)
            else:
                merged, added_count = merge_text_configs(existing_content, new_configs)

            if added_count == 0:
                await m.edit_text("ℹ️ Нечего добавлять — все конфиги уже есть.")
                return

            async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                await f.write(merged)

            await git_commit_push(f"Append {added_count} configs to {client_name}", [fname])

        # Reload DB before saving to avoid overwriting concurrent changes
        current_db = await load_db()
        if client_name in current_db:
            current_db[client_name]["size_bytes"] = len(merged.encode("utf-8"))
            current_db[client_name]["last_refresh"] = now_iso()
            await save_db(current_db)

        await m.edit_text(
            f"✅ <b>Конфиги добавлены!</b>\n\n"
            f"📛 Клиент: <code>{client_name}</code>\n"
            f"➕ Добавлено: <code>{added_count}</code>\n"
            f"📏 Размер: {len(merged) // 1024} KB\n"
            f"📤 Обновлено в GitFlic",
            parse_mode="HTML",
        )
        logger.info("Append: %s +%d configs", client_name, added_count)

    except Exception as e:
        logger.error("Append %s: %s", client_name, e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


@owner_only
async def cmd_append(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /append <client_name>."""
    if not context.args:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/append &lt;name&gt;</code>\n"
            "Затем отправьте конфиги для добавления.\n/list",
            parse_mode="HTML",
        )

    name = context.args[0]
    db = await load_db()
    if name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{name}</code> не найден.\n/list",
            parse_mode="HTML",
        )

    context.user_data["append_pending"] = {
        "client_name": name,
        "created_at": time.monotonic(),
    }

    await update.message.reply_text(
        f"📝 <b>Дополнение клиента</b> <code>{name}</code>\n\n"
        f"Отправьте конфиги для добавления:\n"
        f"• URI-строки (vless://, vmess://, trojan://, ss://)\n"
        f"• JSON с outbounds\n"
        f"• Base64-кодированный список\n\n"
        f"Или /cancel для отмены.",
        parse_mode="HTML",
    )


async def _do_appendall(new_configs: str, message) -> None:
    """Execute the append-all operation: add configs to every client."""
    db = await load_db()
    if not db:
        await message.reply_text("ℹ️ Нет клиентов в базе данных.")
        return

    m = await message.reply_text(f"⏳ Добавляю конфиги всем {len(db)} клиентам...")

    total_added = 0
    updated_clients = 0
    errors = []
    changed_files = []

    try:
        async with _git_lock:
            await git_sync()

            for client_name, entry in db.items():
                ext = entry.get("ext", "txt")
                fname = f"{client_name}.{ext}"
                fpath = os.path.join(REPO_DIR, fname)

                try:
                    if not os.path.exists(fpath):
                        errors.append({"name": client_name, "error": "файл не найден"})
                        continue

                    async with aiofiles.open(fpath, "r", encoding="utf-8") as f:
                        existing_content = await f.read()

                    if ext == "json":
                        merged, added_count = merge_json_configs(existing_content, new_configs)
                    else:
                        merged, added_count = merge_text_configs(existing_content, new_configs)

                    if added_count > 0:
                        async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                            await f.write(merged)
                        entry["size_bytes"] = len(merged.encode("utf-8"))
                        entry["last_refresh"] = now_iso()
                        total_added += added_count
                        updated_clients += 1
                        changed_files.append(fname)
                        logger.info("AppendAll: %s +%d configs", client_name, added_count)

                except Exception as e:
                    logger.error("AppendAll %s: %s", client_name, e, exc_info=True)
                    errors.append({"name": client_name, "error": str(e)})

            if changed_files:
                await git_commit_push(
                    f"AppendAll: +{total_added} configs to {updated_clients} clients",
                    changed_files,
                )

        if changed_files:
            await save_db(db)

        if total_added == 0 and not errors:
            await m.edit_text("ℹ️ Нечего добавлять — все конфиги уже есть у всех клиентов.")
            return

        report = (
            f"✅ <b>Массовое добавление завершено!</b>\n\n"
            f"👥 Клиентов обновлено: <code>{updated_clients}</code> / <code>{len(db)}</code>\n"
            f"➕ Конфигов добавлено: <code>{total_added}</code>\n"
        )
        if errors:
            report += f"❌ Ошибок: <code>{len(errors)}</code>\n\n<b>Ошибки:</b>\n"
            for e in errors[:10]:
                report += f"• <code>{e['name']}</code>: {e['error']}\n"

        await m.edit_text(report, parse_mode="HTML")
        logger.info("AppendAll done: %d clients, +%d configs", updated_clients, total_added)

    except Exception as e:
        logger.error("AppendAll: %s", e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


@owner_only
async def cmd_appendall(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /appendall — add configs to all clients at once."""
    db = await load_db()
    if not db:
        return await update.message.reply_text("ℹ️ Нет клиентов в базе данных.")

    context.user_data["appendall_pending"] = {"created_at": time.monotonic()}

    await update.message.reply_text(
        f"📝 <b>Массовое добавление конфигов</b>\n\n"
        f"Конфиги будут добавлены <b>всем {len(db)} клиентам</b>.\n\n"
        f"Отправьте конфиги для добавления:\n"
        f"• URI-строки (vless://, vmess://, trojan://, ss://)\n"
        f"• JSON с outbounds\n"
        f"• Base64-кодированный список\n\n"
        f"Или /cancel для отмены.",
        parse_mode="HTML",
    )


def parse_line_selection(text: str, max_num: int) -> list[int]:
    """Parse '1 3-5 8' or 'all' into sorted 0-based indices."""
    text = text.strip().lower()
    if text == "all":
        return list(range(max_num))

    indices = set()
    for token in text.replace(",", " ").split():
        token = token.strip()
        if not token:
            continue
        if "-" in token:
            parts = token.split("-", 1)
            start, end = int(parts[0]), int(parts[1])
            if start < 1 or end > max_num or start > end:
                raise ValueError(f"Неверный диапазон: {token}")
            for i in range(start, end + 1):
                indices.add(i - 1)
        else:
            num = int(token)
            if num < 1 or num > max_num:
                raise ValueError(f"Номер {num} вне диапазона [1, {max_num}]")
            indices.add(num - 1)

    if not indices:
        raise ValueError("Не выбрано ни одного номера")

    return sorted(indices)


def list_text_configs(content: str) -> tuple[list[dict], bool]:
    """Parse text/base64 into numbered config entries."""
    decoded, was_base64 = _decode_if_base64(content)
    lines = [l.strip() for l in decoded.splitlines() if l.strip()]

    configs = []
    for i, line in enumerate(lines):
        proto = "?"
        for p in ("vless", "vmess", "trojan", "ss"):
            if line.lower().startswith(f"{p}://"):
                proto = p.upper()
                break

        name_extracted = _extract_name_from_uri(line)
        display = f"{i+1}. [{proto}] {name_extracted or line[:50]}"
        configs.append({"line": line, "display": display, "index": i})

    return configs, was_base64


def list_json_configs(content: str) -> tuple[list[dict], list[dict]]:
    """List JSON outbounds. Returns (proxy_list, system_list)."""
    data = json.loads(content)
    outbounds = data.get("outbounds", [])

    skip_tags = {"direct", "block", "dns", "dns-out", "bypass", "reject"}
    skip_types = {"direct", "block", "blackhole", "dns", "selector", "urltest"}

    proxy_list = []
    system_list = []
    proxy_idx = 0

    for i, ob in enumerate(outbounds):
        tag = ob.get("tag", "")
        ob_type = ob.get("type", ob.get("protocol", ""))
        server = ob.get("server", "")
        port = ob.get("server_port", ob.get("port", ""))

        if tag.lower() in skip_tags or ob_type in skip_types:
            system_list.append({"tag": tag, "type": ob_type, "ob_index": i})
            continue

        addr = f"{server}:{port}" if server else ""
        display = f"{proxy_idx+1}. [{ob_type}] {tag}" + (f" → {addr}" if addr else "")
        proxy_list.append({"display": display, "tag": tag, "ob_index": i, "proxy_idx": proxy_idx})
        proxy_idx += 1

    return proxy_list, system_list


def remove_text_configs(content: str, indices: list[int], was_base64: bool) -> tuple[str, int, int]:
    """Remove lines at 0-based indices. Returns (new_content, removed, remaining)."""
    decoded, _ = _decode_if_base64(content)
    lines = [l.strip() for l in decoded.splitlines() if l.strip()]

    indices_set = set(indices)
    remaining = [l for i, l in enumerate(lines) if i not in indices_set]
    removed = len(lines) - len(remaining)

    result = "\n".join(remaining) + "\n" if remaining else ""
    if was_base64 and result:
        result = b64.b64encode(result.encode()).decode()

    return result, removed, len(remaining)


def remove_json_configs(content: str, proxy_indices: list[int]) -> tuple[str, int, int]:
    """Remove proxy outbounds at given proxy-relative indices."""
    data = json.loads(content)
    outbounds = data.get("outbounds", [])

    skip_tags = {"direct", "block", "dns", "dns-out", "bypass", "reject"}
    skip_types = {"direct", "block", "blackhole", "dns", "selector", "urltest"}

    proxy_idx = 0
    remove_ob_indices = set()
    for i, ob in enumerate(outbounds):
        tag = ob.get("tag", "")
        ob_type = ob.get("type", ob.get("protocol", ""))
        if tag.lower() in skip_tags or ob_type in skip_types:
            continue
        if proxy_idx in proxy_indices:
            remove_ob_indices.add(i)
        proxy_idx += 1

    new_outbounds = [ob for i, ob in enumerate(outbounds) if i not in remove_ob_indices]
    data["outbounds"] = new_outbounds

    result, _ = inject_rules(json.dumps(data, indent=2, ensure_ascii=False))

    remaining_proxy = sum(1 for ob in new_outbounds
                          if ob.get("tag", "").lower() not in skip_tags
                          and ob.get("type", ob.get("protocol", "")) not in skip_types)

    return result, len(remove_ob_indices), remaining_proxy


async def _handle_removeconfig_selection(pending: dict, text: str, update: Update):
    """Process number selection for removeconfig."""
    client_name = pending["client_name"]
    content = pending["content"]
    ext = pending["ext"]
    configs = pending["configs"]
    was_base64 = pending.get("was_base64", False)

    try:
        indices = parse_line_selection(text, len(configs))
    except ValueError as e:
        await update.message.reply_text(f"⚠️ {e}\nПопробуйте ещё раз или /cancel")
        return

    if len(indices) == len(configs):
        await update.message.reply_text(
            f"⚠️ Вы удаляете <b>все</b> {len(configs)} конфигов.\n"
            f"Используйте <code>/delete {client_name}</code> чтобы удалить клиента целиком.",
            parse_mode="HTML",
        )
        return

    m = await update.message.reply_text("⏳ Удаляю конфиги...")

    try:
        if ext == "json":
            new_content, removed, remaining = remove_json_configs(content, indices)
        else:
            new_content, removed, remaining = remove_text_configs(content, indices, was_base64)

        fname = f"{client_name}.{ext}"
        fpath = os.path.join(REPO_DIR, fname)

        async with _git_lock:
            await git_sync()
            async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                await f.write(new_content)
            await git_commit_push(f"Remove {removed} configs from {client_name}", [fname])

        db = await load_db()
        if client_name in db:
            db[client_name]["size_bytes"] = len(new_content.encode("utf-8"))
            db[client_name]["last_refresh"] = now_iso()
            await save_db(db)

        await m.edit_text(
            f"✅ <b>Удалено!</b>\n\n"
            f"📛 Клиент: <code>{client_name}</code>\n"
            f"🗑 Удалено: <code>{removed}</code>\n"
            f"📄 Осталось: <code>{remaining}</code>\n"
            f"📤 Обновлено в GitFlic",
            parse_mode="HTML",
        )
        logger.info("Removeconfig: %s -%d configs, %d remaining", client_name, removed, remaining)

    except Exception as e:
        logger.error("Removeconfig %s: %s", client_name, e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


@owner_only
async def cmd_removeconfig(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /removeconfig <client_name>."""
    if not context.args:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/removeconfig &lt;name&gt;</code>\n/list",
            parse_mode="HTML",
        )

    name = context.args[0]
    db = await load_db()
    if name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{name}</code> не найден.\n/list", parse_mode="HTML"
        )

    ext = db[name].get("ext", "txt")
    fname = f"{name}.{ext}"
    fpath = os.path.join(REPO_DIR, fname)

    if not os.path.exists(fpath):
        return await update.message.reply_text(
            f"❌ Файл <code>{fname}</code> не найден в репозитории.\n"
            f"Выполните /refresh для обновления.",
            parse_mode="HTML",
        )

    async with aiofiles.open(fpath, "r", encoding="utf-8") as f:
        content = await f.read()

    was_base64 = False
    if ext == "json":
        proxy_list, system_list = list_json_configs(content)
        if not proxy_list:
            return await update.message.reply_text("ℹ️ Нет proxy-конфигов для удаления.")

        lines = [c["display"] for c in proxy_list]
        header = f"📄 <b>Outbound'ы клиента</b> <code>{name}</code> ({len(proxy_list)} proxy"
        if system_list:
            header += f" + {len(system_list)} system"
        header += "):\n\n"

        footer = ""
        if system_list:
            sys_tags = ", ".join(s["tag"] for s in system_list[:5])
            footer = f"\n⚙️ <i>Системные (не удаляются): {sys_tags}</i>\n"

        configs_for_state = proxy_list
    else:
        configs, was_base64 = list_text_configs(content)
        if not configs:
            return await update.message.reply_text("ℹ️ Нет конфигов для удаления.")

        lines = [c["display"] for c in configs]
        header = f"📄 <b>Конфиги клиента</b> <code>{name}</code> ({len(configs)} шт.):\n\n"
        footer = ""
        configs_for_state = configs

    body = "\n".join(lines)
    prompt = (
        "\n\n<b>Отправьте номера для удаления:</b>\n"
        "  • Отдельные: <code>3 5 12</code>\n"
        "  • Диапазон: <code>3-7</code>\n"
        "  • Смешанно: <code>1 3-5 8</code>\n"
        "  • Все: <code>all</code>\n"
        "  • Отмена: /cancel"
    )

    full_text = header + body + footer + prompt

    if len(full_text) > TG_MSG_LIMIT:
        await update.message.reply_text(header, parse_mode="HTML")
        chunk = ""
        for line in lines:
            if len(chunk) + len(line) + 2 > TG_MSG_LIMIT - 200:
                await update.message.reply_text(f"<code>{chunk}</code>", parse_mode="HTML")
                chunk = ""
            chunk += line + "\n"
        if chunk:
            await update.message.reply_text(f"<code>{chunk}</code>", parse_mode="HTML")
        await update.message.reply_text(footer + prompt, parse_mode="HTML")
    else:
        await update.message.reply_text(full_text, parse_mode="HTML")

    context.user_data["removeconfig_pending"] = {
        "client_name": name,
        "content": content,
        "ext": ext,
        "configs": configs_for_state,
        "was_base64": was_base64,
        "created_at": time.monotonic(),
    }


def remove_text_configs_by_value(content: str, uris_to_remove: set) -> tuple[str, int]:
    """Remove lines that exactly match provided URIs. Returns (new_content, removed_count)."""
    decoded, was_base64 = _decode_if_base64(content)
    lines = [l.strip() for l in decoded.splitlines() if l.strip()]
    remaining = [l for l in lines if l not in uris_to_remove]
    removed = len(lines) - len(remaining)
    result = "\n".join(remaining) + "\n" if remaining else ""
    if was_base64 and result:
        result = b64.b64encode(result.encode()).decode()
    return result, removed


def remove_json_configs_by_tags(content: str, tags_to_remove: set) -> tuple[str, int]:
    """Remove outbounds whose tag is in tags_to_remove. Returns (new_content, removed_count)."""
    data = json.loads(content)
    outbounds = data.get("outbounds", [])
    new_outbounds = [ob for ob in outbounds if ob.get("tag", "") not in tags_to_remove]
    removed = len(outbounds) - len(new_outbounds)
    data["outbounds"] = new_outbounds
    result, _ = inject_rules(json.dumps(data, indent=2, ensure_ascii=False))
    return result, removed


async def _do_removeconfigall(configs_to_remove: str, message) -> None:
    """Execute the remove-all operation: remove matching configs from every client."""
    db = await load_db()
    if not db:
        await message.reply_text("ℹ️ Нет клиентов в базе данных.")
        return

    # Parse provided configs into a set of URIs and a set of JSON tags
    decoded, _ = _decode_if_base64(configs_to_remove)
    uris_to_remove = {l.strip() for l in decoded.splitlines() if l.strip()}

    tags_to_remove: set[str] = set()
    stripped = configs_to_remove.strip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            if stripped.startswith("{"):
                obj = json.loads(stripped)
                outbounds = obj.get("outbounds", [])
            else:
                outbounds = json.loads(stripped)
            tags_to_remove = {ob.get("tag", "") for ob in outbounds if ob.get("tag")}
        except Exception:
            pass

    # Fall back to using URI lines as tags for JSON clients.
    # This allows passing plain URI strings to also remove outbounds from JSON
    # clients if their tag happens to match one of the provided URIs.
    if not tags_to_remove:
        tags_to_remove = uris_to_remove

    m = await message.reply_text(f"⏳ Удаляю конфиги у всех {len(db)} клиентов...")

    total_removed = 0
    affected_clients = 0
    errors = []
    changed_files = []

    try:
        async with _git_lock:
            await git_sync()

            for client_name, entry in db.items():
                ext = entry.get("ext", "txt")
                fname = f"{client_name}.{ext}"
                fpath = os.path.join(REPO_DIR, fname)

                try:
                    if not os.path.exists(fpath):
                        errors.append({"name": client_name, "error": "файл не найден"})
                        continue

                    async with aiofiles.open(fpath, "r", encoding="utf-8") as f:
                        existing_content = await f.read()

                    if ext == "json":
                        new_content, removed = remove_json_configs_by_tags(existing_content, tags_to_remove)
                    else:
                        new_content, removed = remove_text_configs_by_value(existing_content, uris_to_remove)

                    if removed > 0:
                        async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                            await f.write(new_content)
                        entry["size_bytes"] = len(new_content.encode("utf-8"))
                        entry["last_refresh"] = now_iso()
                        total_removed += removed
                        affected_clients += 1
                        changed_files.append(fname)
                        logger.info("RemoveConfigAll: %s -%d configs", client_name, removed)

                except Exception as e:
                    logger.error("RemoveConfigAll %s: %s", client_name, e, exc_info=True)
                    errors.append({"name": client_name, "error": str(e)})

            if changed_files:
                await git_commit_push(
                    f"RemoveConfigAll: -{total_removed} configs from {affected_clients} clients",
                    changed_files,
                )

        if changed_files:
            await save_db(db)

        if total_removed == 0 and not errors:
            await m.edit_text("ℹ️ Ни у одного клиента не найдено совпадений для удаления.")
            return

        report = (
            f"✅ <b>Массовое удаление завершено!</b>\n\n"
            f"👥 Клиентов затронуто: <code>{affected_clients}</code> / <code>{len(db)}</code>\n"
            f"🗑 Конфигов удалено: <code>{total_removed}</code>\n"
        )
        if errors:
            report += f"❌ Ошибок: <code>{len(errors)}</code>\n\n<b>Ошибки:</b>\n"
            for e in errors[:10]:
                report += f"• <code>{e['name']}</code>: {e['error']}\n"

        await m.edit_text(report, parse_mode="HTML")
        logger.info("RemoveConfigAll done: %d clients, -%d configs", affected_clients, total_removed)

    except Exception as e:
        logger.error("RemoveConfigAll: %s", e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


@owner_only
async def cmd_removeconfigall(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /removeconfigall — remove matching configs from all clients at once."""
    db = await load_db()
    if not db:
        return await update.message.reply_text("ℹ️ Нет клиентов в базе данных.")

    context.user_data["removeconfigall_pending"] = {"created_at": time.monotonic()}

    await update.message.reply_text(
        f"🗑 <b>Массовое удаление конфигов</b>\n\n"
        f"Конфиги будут удалены у <b>всех {len(db)} клиентов</b>.\n\n"
        f"Отправьте конфиги для удаления:\n"
        f"• URI-строки (vless://, vmess://, trojan://, ss://)\n"
        f"• JSON с outbounds (удаляются по тегу)\n"
        f"• Base64-кодированный список\n\n"
        f"⚠️ <b>Внимание:</b> операция необратима!\n"
        f"Или /cancel для отмены.",
        parse_mode="HTML",
    )


@owner_only
async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Cancel any pending operation."""
    pending_keys = {
        "removeconfig_pending": "removeconfig",
        "append_pending": "append",
        "appendall_pending": "appendall",
        "removeconfigall_pending": "removeconfigall",
        "removeconfigall_data": "removeconfigall",
    }
    cleared = []
    for key, label in pending_keys.items():
        if context.user_data.pop(key, None) and label not in cleared:
            cleared.append(label)
    if cleared:
        await update.message.reply_text("❌ Операция отменена.")
    else:
        await update.message.reply_text("ℹ️ Нет активных операций для отмены.")


# ══════════════════════════════════════════════════════════════════════════════
#  RENAME / SETURL / INFO / SINGLE REFRESH
# ══════════════════════════════════════════════════════════════════════════════


@owner_only
async def cmd_rename(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /rename <old_name> <new_name>."""
    if len(context.args) != 2:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/rename &lt;old_name&gt; &lt;new_name&gt;</code>",
            parse_mode="HTML",
        )

    old_name, raw_new = context.args
    new_name = _sanitize_name(raw_new)

    if not new_name:
        return await update.message.reply_text(
            "⚠️ Недопустимое новое имя. Используйте буквы, цифры, дефис, подчёркивание."
        )

    db = await load_db()
    if old_name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{old_name}</code> не найден.\n/list", parse_mode="HTML"
        )
    if new_name in db:
        return await update.message.reply_text(
            f"⚠️ <code>{new_name}</code> уже существует.", parse_mode="HTML"
        )

    m = await update.message.reply_text("⏳ Переименование...")

    ext = db[old_name].get("ext", "txt")
    old_fname = f"{old_name}.{ext}"
    new_fname = f"{new_name}.{ext}"

    try:
        async with _git_lock:
            await git_sync()
            old_fpath = os.path.join(REPO_DIR, old_fname)
            if os.path.exists(old_fpath):
                await run_cmd("git", "mv", old_fname, new_fname, cwd=REPO_DIR)
                await run_cmd(
                    "git", "commit", "-m", f"Rename {old_name} to {new_name}", cwd=REPO_DIR
                )
                await run_cmd("git", "push", "origin", config.GIT_BRANCH, cwd=REPO_DIR)
    except Exception as e:
        logger.error("git rename %s → %s failed: %s", old_name, new_name, e)
        await m.edit_text(f"❌ Ошибка git при переименовании: {e}")
        return

    # Build new short URL for the renamed file
    new_raw = build_raw_url(new_name, ext)
    try:
        async with aiohttp.ClientSession() as session:
            new_short = await get_short(session, new_raw)
    except Exception:
        new_short = new_raw

    # Reload DB and update atomically
    current_db = await load_db()
    if old_name in current_db:
        entry = current_db.pop(old_name)
        entry["short"] = new_short
        current_db[new_name] = entry
        await save_db(current_db)

    await m.edit_text(
        f"✅ <b>Переименовано!</b>\n\n"
        f"📛 Было: <code>{old_name}</code>\n"
        f"📛 Стало: <code>{new_name}</code>\n"
        f"🔗 Новая ссылка: {new_short}",
        parse_mode="HTML",
    )
    logger.info("Renamed: %s → %s", old_name, new_name)


@owner_only
async def cmd_seturl(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /seturl <name> <new_url> — update source URL and re-fetch."""
    if len(context.args) < 2:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/seturl &lt;name&gt; &lt;new_url&gt;</code>",
            parse_mode="HTML",
        )

    name = context.args[0]
    new_url = context.args[1]

    if not is_valid_url(new_url):
        return await update.message.reply_text(
            "⚠️ Некорректный URL (http:// или https://)."
        )

    db = await load_db()
    if name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{name}</code> не найден.\n/list", parse_mode="HTML"
        )

    m = await update.message.reply_text("⏳ Обновляю источник и скачиваю конфиг...")

    ext = db[name].get("ext", "txt")
    fname = f"{name}.{ext}"
    fpath = os.path.join(REPO_DIR, fname)

    try:
        async with aiohttp.ClientSession() as session:
            raw_content = await download_content(session, new_url)
            processed, _ = inject_rules(raw_content)

        async with _git_lock:
            await git_sync()
            async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                await f.write(processed)
            await git_commit_push(f"Update source URL for {name}", [fname])

        current_db = await load_db()
        if name in current_db:
            current_db[name]["original_url"] = new_url
            current_db[name]["size_bytes"] = len(processed.encode("utf-8"))
            current_db[name]["last_refresh"] = now_iso()
            await save_db(current_db)

        await m.edit_text(
            f"✅ <b>Источник обновлён!</b>\n\n"
            f"📛 Клиент: <code>{name}</code>\n"
            f"🔗 Новый источник:\n<code>{new_url}</code>\n"
            f"📏 Размер: {len(processed) // 1024} KB\n"
            f"📤 Обновлено в GitFlic",
            parse_mode="HTML",
        )
        logger.info("seturl: %s → %s", name, new_url)

    except Exception as e:
        logger.error("seturl %s: %s", name, e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


@owner_only
async def cmd_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /info <name> — show detailed info about a single client."""
    if not context.args:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/info &lt;name&gt;</code>",
            parse_mode="HTML",
        )

    name = context.args[0]
    db = await load_db()
    if name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{name}</code> не найден.\n/list", parse_mode="HTML"
        )

    entry = db[name]
    ext = entry.get("ext", "txt")
    fpath = os.path.join(REPO_DIR, f"{name}.{ext}")

    # Count configs if file is present
    config_count = "—"
    if os.path.exists(fpath):
        try:
            async with aiofiles.open(fpath, "r", encoding="utf-8") as f:
                content = await f.read()
            if ext == "json":
                proxy_list, system_list = list_json_configs(content)
                config_count = f"{len(proxy_list)} proxy + {len(system_list)} system"
            else:
                configs, _ = list_text_configs(content)
                config_count = str(len(configs))
        except Exception:
            pass

    name_source = entry.get("name_source", "?")
    source_label = "👤 из конфига" if name_source == "config" else "🔀 сгенерировано"
    size_bytes = entry.get("size_bytes", 0)
    size_kb = size_bytes // 1024 if size_bytes else 0
    raw_url = build_raw_url(name, ext)

    text = (
        f"ℹ️ <b>Клиент:</b> <code>{name}</code>\n\n"
        f"📄 Формат: <code>{ext.upper()}</code>\n"
        f"👤 Имя: {source_label}\n"
        f"📊 Конфигов: <code>{config_count}</code>\n"
        f"📏 Размер: <code>{size_kb} KB</code> ({size_bytes} байт)\n\n"
        f"🔗 Ссылка: {entry.get('short', '—')}\n"
        f"🌐 RAW:\n<code>{raw_url}</code>\n\n"
        f"📎 Источник:\n<code>{entry.get('original_url', '—')}</code>\n\n"
        f"📅 Создан: <code>{entry.get('created_at', '—')}</code>\n"
        f"🔄 Обновлён: <code>{entry.get('last_refresh', '—')}</code>"
    )

    keyboard = InlineKeyboardMarkup([
        [
            InlineKeyboardButton("➕ Дополнить", callback_data=f"append_{name}"),
            InlineKeyboardButton("🔄 Обновить", callback_data=f"refresh_one_{name}"),
        ],
        [
            InlineKeyboardButton("🗑 Удалить", callback_data=f"delete_confirm_{name}"),
        ],
    ])

    await update.message.reply_text(
        text, parse_mode="HTML", disable_web_page_preview=True, reply_markup=keyboard
    )


async def _refresh_single_client(name: str, entry: dict) -> dict:
    """Refresh a single client: download, write to git, update DB."""
    original_url = entry.get("original_url")
    if not original_url:
        return {"ok": False, "error": "нет original_url"}

    ext = entry.get("ext", "txt")
    fname = f"{name}.{ext}"
    fpath = os.path.join(REPO_DIR, fname)

    try:
        async with aiohttp.ClientSession() as session:
            raw_content = await download_content(session, original_url)
            processed, _ = inject_rules(raw_content)

        async with _git_lock:
            await git_sync()
            async with aiofiles.open(fpath, "w", encoding="utf-8") as f:
                await f.write(processed)
            await git_commit_push(f"Refresh {name}", [fname])

        current_db = await load_db()
        if name in current_db:
            current_db[name]["last_refresh"] = now_iso()
            current_db[name]["size_bytes"] = len(processed.encode("utf-8"))
            await save_db(current_db)

        return {"ok": True, "size": len(processed)}

    except Exception as e:
        return {"ok": False, "error": str(e)}


# ══════════════════════════════════════════════════════════════════════════════
#  ХЭНДЛЕРЫ
# ══════════════════════════════════════════════════════════════════════════════


@owner_only
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    keyboard = InlineKeyboardMarkup([
        [
            InlineKeyboardButton(
                "🔄 Обновить всех", callback_data="refresh_confirm"
            ),
            InlineKeyboardButton("📋 Список", callback_data="list"),
        ],
        [
            InlineKeyboardButton("📊 Статус", callback_data="status"),
            InlineKeyboardButton("📦 Миграция", callback_data="migrate_menu"),
        ],
    ])

    rules_status = "✅ включена" if config.INJECT_RULES else "❌ выключена"
    await update.message.reply_text(
        f"🤖 <b>Bot-Links-GitFlic v9.1</b>\n\n"
        f"Отправьте URL подписки — бот:\n"
        f"  1. Скачает конфиг\n"
        f"  2. Определит имя клиента из контента\n"
        f"  3. Определит формат (JSON / текст)\n"
        f"  4. Внедрит правила блокировки (если JSON)\n"
        f"  5. Сохранит в GitFlic + QR-код\n\n"
        f"🛡 Инъекция правил: {rules_status}\n"
        f"⏰ Автообновление: каждые {config.AUTO_REFRESH_HOURS}ч\n\n"
        f"<b>Команды:</b>\n"
        f"/list — список ссылок\n"
        f"/info &lt;name&gt; — ℹ️ подробная информация\n"
        f"/delete &lt;name&gt; — удалить\n"
        f"/rename &lt;old&gt; &lt;new&gt; — переименовать\n"
        f"/seturl &lt;name&gt; &lt;url&gt; — обновить источник\n"
        f"/refresh [name] — 🔄 обновить (все или одного)\n"
        f"/append &lt;name&gt; — ➕ добавить конфиги к клиенту\n"
        f"/removeconfig &lt;name&gt; — 🗑 удалить отдельные конфиги\n"
        f"/appendall — ➕➕ добавить конфиги сразу всем клиентам\n"
        f"/removeconfigall — 🗑🗑 удалить конфиги у всех клиентов\n"
        f"/cancel — ❌ отменить текущую операцию\n"
        f"/status — статус бота\n"
        f"/export — экспорт БД для миграции\n"
        f"/import — импорт БД (ответом на файл)\n"
        f"/help — справка",
        parse_mode="HTML",
        reply_markup=keyboard,
    )


@owner_only
async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = await load_db()
    repo_exists = os.path.exists(REPO_DIR)

    # FIX: корректное определение последнего времени обновления
    last_refresh = ""
    json_count = 0
    txt_count = 0
    auto_names = 0
    for entry in db.values():
        lr = entry.get("last_refresh", "")
        if lr and (not last_refresh or lr > last_refresh):
            last_refresh = lr
        if entry.get("ext") == "json":
            json_count += 1
        else:
            txt_count += 1
        if entry.get("name_source") == "auto":
            auto_names += 1

    last_refresh = last_refresh or "никогда"

    try:
        stat = os.statvfs(config.DIR)
        free_mb = (stat.f_bavail * stat.f_frsize) // (1024 * 1024)
        disk_info = f"💾 Свободно: <code>{free_mb} MB</code>"
    except Exception:
        disk_info = "💾 Свободно: <i>н/д</i>"

    next_run = "—"
    if _scheduler and _scheduler.running:
        jobs = _scheduler.get_jobs()
        if jobs:
            nr = jobs[0].next_run_time
            if nr:
                next_run = nr.strftime("%H:%M:%S UTC")

    text = (
        f"📊 <b>Статус</b>\n\n"
        f"📁 Записей: <code>{len(db)}</code> "
        f"(JSON: {json_count}, TXT: {txt_count})\n"
        f"👤 Имена из конфигов: <code>{len(db) - auto_names}</code>, "
        f"авто: <code>{auto_names}</code>\n"
        f"📂 Репозиторий: {'✅' if repo_exists else '❌'}\n"
        f"🌿 Ветка: <code>{config.GIT_BRANCH}</code>\n"
        f"🛡 Инъекция: {'✅' if config.INJECT_RULES else '❌'}\n"
        f"🔄 Последний refresh: <code>{last_refresh}</code>\n"
        f"⏰ Следующий авто: <code>{next_run}</code>\n"
        f"{disk_info}"
    )

    if update.callback_query:
        await update.callback_query.answer()
        await update.callback_query.edit_message_text(text, parse_mode="HTML")
    else:
        await update.message.reply_text(text, parse_mode="HTML")


@owner_only
async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = await load_db()

    if not db:
        text = "📋 Список пуст."
        if update.callback_query:
            await update.callback_query.answer()
            return await update.callback_query.edit_message_text(text)
        return await update.message.reply_text(text)

    lines = []
    for n, d in db.items():
        short = d.get("short", "—")
        src = d.get("original_url", "")
        lr = d.get("last_refresh", "—")
        ext = d.get("ext", "txt").upper()
        source = "👤" if d.get("name_source") == "config" else "🔀"
        lines.append(
            f"• {source} <code>{n}</code> [{ext}]\n"
            f"  🔗 {short}\n"
            f"  📎 <code>{src[:55]}{'…' if len(src) > 55 else ''}</code>\n"
            f"  🔄 {lr}"
        )

    header = f"📋 <b>Список ({len(db)} шт.):</b>\n\n"
    chunks: list[str] = []
    chunk = header
    for line in lines:
        if len(chunk) + len(line) + 2 > TG_MSG_LIMIT:
            chunks.append(chunk)
            chunk = ""
        chunk += line + "\n\n"
    if chunk:
        chunks.append(chunk)

    if update.callback_query:
        await update.callback_query.answer()
        await update.callback_query.edit_message_text(
            chunks[0], parse_mode="HTML", disable_web_page_preview=True
        )
        for c in chunks[1:]:
            await update.callback_query.message.reply_text(
                c, parse_mode="HTML", disable_web_page_preview=True
            )
    else:
        for i, c in enumerate(chunks):
            if len(chunks) > 1:
                c += f"<i>Страница {i + 1}/{len(chunks)}</i>"
            await update.message.reply_text(
                c, parse_mode="HTML", disable_web_page_preview=True
            )


@owner_only
async def cmd_delete(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        return await update.message.reply_text(
            "⚠️ Использование: <code>/delete &lt;name&gt;</code>\n/list",
            parse_mode="HTML",
        )

    name = context.args[0]
    db = await load_db()

    if name not in db:
        return await update.message.reply_text(
            f"⚠️ <code>{name}</code> не найден.\n/list",
            parse_mode="HTML",
        )

    ext = db[name].get("ext", "txt")
    keyboard = InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🗑 Да, удалить", callback_data=f"delete_confirm_{name}"),
            InlineKeyboardButton("❌ Отмена", callback_data="delete_cancel"),
        ]
    ])
    await update.message.reply_text(
        f"⚠️ <b>Удалить клиента?</b>\n\n"
        f"📛 Имя: <code>{name}</code> [{ext.upper()}]\n"
        f"🔗 Ссылка: {db[name].get('short', '—')}\n\n"
        f"<i>Файл будет удалён из GitFlic. Отменить нельзя.</i>",
        parse_mode="HTML",
        reply_markup=keyboard,
    )


async def _do_delete(name: str, query) -> None:
    """Execute confirmed deletion: git rm + DB delete."""
    db = await load_db()
    if name not in db:
        await query.edit_message_text(f"⚠️ <code>{name}</code> уже удалён.", parse_mode="HTML")
        return

    ext = db[name].get("ext", "txt")
    fname = f"{name}.{ext}"
    git_file_existed = True

    try:
        async with _git_lock:
            await git_sync()
            fpath = os.path.join(REPO_DIR, fname)
            if os.path.exists(fpath):
                await run_cmd("git", "rm", "-f", fname, cwd=REPO_DIR)
                await run_cmd("git", "commit", "-m", f"Delete {name}", cwd=REPO_DIR)
                await run_cmd("git", "push", "origin", config.GIT_BRANCH, cwd=REPO_DIR)
            else:
                git_file_existed = False
    except Exception as e:
        logger.error("git delete %s failed: %s", fname, e)
        await query.edit_message_text(f"❌ Ошибка git при удалении: {e}", parse_mode="HTML")
        return

    current_db = await load_db()
    if name in current_db:
        del current_db[name]
        await save_db(current_db)

    note = "" if git_file_existed else "\n⚠️ <i>Файл в Git не найден, удалён из БД.</i>"
    await query.edit_message_text(
        f"🗑 <code>{name}</code> удалён.{note}", parse_mode="HTML"
    )
    logger.info("Удалён: %s (git_existed=%s)", name, git_file_existed)


@owner_only
async def cmd_refresh(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = await load_db()
    if not db:
        return await update.message.reply_text("📋 Нечего обновлять.")

    # Selective refresh: /refresh <name>
    if context.args:
        name = context.args[0]
        if name not in db:
            return await update.message.reply_text(
                f"⚠️ <code>{name}</code> не найден.\n/list", parse_mode="HTML"
            )
        m = await update.message.reply_text(f"⏳ Обновляю <code>{name}</code>...", parse_mode="HTML")
        result = await _refresh_single_client(name, db[name])
        if result["ok"]:
            size_kb = result["size"] // 1024
            await m.edit_text(
                f"✅ <b>Обновлено!</b>\n\n"
                f"📛 Клиент: <code>{name}</code>\n"
                f"📏 Размер: {size_kb} KB\n"
                f"📤 Обновлено в GitFlic",
                parse_mode="HTML",
            )
        else:
            await m.edit_text(f"❌ Ошибка обновления <code>{name}</code>: {result['error']}", parse_mode="HTML")
        return

    keyboard = InlineKeyboardMarkup([
        [
            InlineKeyboardButton(
                f"✅ Да, обновить {len(db)} шт.",
                callback_data="refresh_go",
            ),
            InlineKeyboardButton("❌ Отмена", callback_data="refresh_cancel"),
        ]
    ])
    await update.message.reply_text(
        f"🔄 <b>Обновить всех клиентов?</b>\n\n"
        f"Записей: <b>{len(db)}</b>\n"
        f"Бот скачает конфиги, обработает правила и запушит в GitFlic.\n"
        f"RAW-ссылки <b>не изменятся</b>.\n\n"
        f"<i>Для обновления одного: /refresh &lt;name&gt;</i>",
        parse_mode="HTML",
        reply_markup=keyboard,
    )


# ══════════════════════════════════════════════════════════════════════════════
#  МИГРАЦИЯ — КОМАНДЫ TELEGRAM
# ══════════════════════════════════════════════════════════════════════════════


@owner_only
async def cmd_export(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Экспорт базы данных как JSON-файл для миграции на новый сервер."""
    db = await load_db()
    if not db:
        return await update.message.reply_text("📋 База данных пуста, нечего экспортировать.")

    m = await update.message.reply_text("⏳ Подготовка экспорта...")

    try:
        export_json = await export_db()

        # Отправляем как файл
        bio = io.BytesIO(export_json.encode("utf-8"))
        bio.name = f"botlinks_backup_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.json"

        await m.delete()
        await update.message.reply_document(
            bio,
            caption=(
                f"📦 <b>Экспорт базы данных</b>\n\n"
                f"👥 Клиентов: <code>{len(db)}</code>\n"
                f"📅 Дата: <code>{now_iso()}</code>\n"
                f"🌿 Ветка: <code>{config.GIT_BRANCH}</code>\n\n"
                f"<i>Для импорта на новом сервере:\n"
                f"1. Отправьте этот файл боту\n"
                f"2. Ответьте на файл командой /import</i>"
            ),
            parse_mode="HTML",
        )
        logger.info("Экспорт БД: %d клиентов", len(db))

    except Exception as e:
        logger.error("Ошибка экспорта: %s", e, exc_info=True)
        await m.edit_text(f"❌ Ошибка экспорта: {e}")


@owner_only
async def cmd_import(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Импорт базы данных из JSON-файла (ответом на файл)."""
    reply = update.message.reply_to_message

    if not reply or not reply.document:
        return await update.message.reply_text(
            "⚠️ <b>Как импортировать:</b>\n\n"
            "1. Отправьте JSON-файл экспорта в чат\n"
            "2. Ответьте на сообщение с файлом командой /import\n\n"
            "<i>Файл можно получить командой /export на старом сервере.</i>",
            parse_mode="HTML",
        )

    m = await update.message.reply_text("⏳ Импорт базы данных...")

    try:
        # Скачиваем файл
        file = await reply.document.get_file()
        file_bytes = await file.download_as_bytearray()
        data = file_bytes.decode("utf-8")

        # Валидация
        try:
            json.loads(data)
        except json.JSONDecodeError:
            return await m.edit_text("❌ Файл не является валидным JSON.")

        # Импорт
        result = await import_db(data)

        await m.edit_text(
            f"✅ <b>Импорт завершён!</b>\n\n"
            f"📥 Добавлено: <code>{result['imported']}</code>\n"
            f"🔄 Обновлено: <code>{result['updated']}</code>\n"
            f"⏭ Пропущено: <code>{result['skipped']}</code>\n"
            f"📁 Всего в БД: <code>{result['total']}</code>\n\n"
            f"<i>Выполните /refresh чтобы обновить конфиги\n"
            f"и загрузить файлы в GitFlic нового сервера.</i>",
            parse_mode="HTML",
        )
        logger.info(
            "Импорт БД: added=%d updated=%d skipped=%d total=%d",
            result["imported"], result["updated"],
            result["skipped"], result["total"],
        )

    except Exception as e:
        logger.error("Ошибка импорта: %s", e, exc_info=True)
        await m.edit_text(f"❌ Ошибка импорта: {e}")


@owner_only
async def handle_msg(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Обработка нового URL подписки."""
    text = (update.message.text or "").strip()

    # Check for pending append
    pending_append = context.user_data.get("append_pending")
    if pending_append:
        if time.monotonic() - pending_append.get("created_at", 0) > 300:
            context.user_data.pop("append_pending", None)
        else:
            context.user_data.pop("append_pending", None)
            await _do_append(pending_append["client_name"], text, update)
            return

    # Check for pending removeconfig
    pending_remove = context.user_data.get("removeconfig_pending")
    if pending_remove:
        if time.monotonic() - pending_remove.get("created_at", 0) > 300:
            context.user_data.pop("removeconfig_pending", None)
        else:
            context.user_data.pop("removeconfig_pending", None)
            await _handle_removeconfig_selection(pending_remove, text, update)
            return

    # Check for pending appendall
    pending_appendall = context.user_data.get("appendall_pending")
    if pending_appendall:
        if time.monotonic() - pending_appendall.get("created_at", 0) > 300:
            context.user_data.pop("appendall_pending", None)
        else:
            context.user_data.pop("appendall_pending", None)
            await _do_appendall(text, update.message)
            return

    # Check for pending removeconfigall (show confirmation)
    pending_removeconfigall = context.user_data.get("removeconfigall_pending")
    if pending_removeconfigall:
        if time.monotonic() - pending_removeconfigall.get("created_at", 0) > 300:
            context.user_data.pop("removeconfigall_pending", None)
        else:
            context.user_data.pop("removeconfigall_pending", None)
            db = await load_db()
            context.user_data["removeconfigall_data"] = {
                "configs": text,
                "created_at": time.monotonic(),
            }
            keyboard = InlineKeyboardMarkup([
                [
                    InlineKeyboardButton(
                        f"✅ Да, удалить у всех {len(db)} клиентов",
                        callback_data="removeconfigall_confirm",
                    ),
                    InlineKeyboardButton("❌ Отмена", callback_data="removeconfigall_cancel"),
                ]
            ])
            await update.message.reply_text(
                f"⚠️ <b>Подтверждение массового удаления</b>\n\n"
                f"Конфиги будут удалены у <b>всех {len(db)} клиентов</b>.\n"
                f"Это действие необратимо!\n\n"
                f"Продолжить?",
                parse_mode="HTML",
                reply_markup=keyboard,
            )
            return

    # Check reply to saved message (append via reply)
    reply = update.message.reply_to_message
    if reply and reply.message_id in _save_msg_to_client and not is_valid_url(text):
        client_name = _save_msg_to_client[reply.message_id]
        await _do_append(client_name, text, update)
        return

    url = text

    if not is_valid_url(url):
        return await update.message.reply_text(
            "⚠️ Отправьте корректный URL (http:// или https://).",
        )

    m = await update.message.reply_text("⏳ Загрузка и анализ конфига...")

    try:
        async with aiohttp.ClientSession() as session:
            raw_content = await download_content(session, url)

            # Извлекаем имя клиента из контента
            client_name = extract_client_name(raw_content)

            if client_name:
                name_source = "config"
            else:
                client_name = f"cl_{uuid.uuid4().hex[:8]}"
                name_source = "auto"

            # Проверяем уникальность имени
            db = await load_db()
            base_name = client_name
            counter = 1
            while client_name in db:
                client_name = f"{base_name}_{counter}"
                counter += 1

            # Обработка: формат + инъекция правил
            processed, ext = inject_rules(raw_content)
            injected = ext == "json" and config.INJECT_RULES

            short = await upload_single(client_name, processed, ext, session)

        # Сохраняем в БД — расширение фиксируется ЗДЕСЬ навсегда
        db[client_name] = {
            "short": short,
            "original_url": url,
            "ext": ext,
            "size_bytes": len(processed.encode("utf-8")),
            "created_at": now_iso(),
            "last_refresh": now_iso(),
            "name_source": name_source,
        }
        await save_db(db)

        # QR-код
        qr_img = qrcode.make(short)
        bio = io.BytesIO()
        qr_img.save(bio, "PNG")
        bio.seek(0)

        rules_line = "🛡 Правила: ✅ Block .tm, Ads, Porn\n" if injected else ""
        name_icon = "👤 Имя из конфига" if name_source == "config" else "🔀 Имя сгенерировано"

        keyboard = InlineKeyboardMarkup([
            [InlineKeyboardButton("➕ Дополнить", callback_data=f"append_{client_name}")]
        ])

        await m.delete()
        saved_msg = await update.message.reply_photo(
            bio,
            caption=(
                f"✅ <b>Сохранено</b>\n\n"
                f"📛 Имя: <code>{client_name}</code> ({name_icon})\n"
                f"📄 Формат: <code>{ext.upper()}</code>\n"
                f"🔗 Ссылка: {short}\n"
                f"📎 Источник: <code>{url}</code>\n"
                f"{rules_line}"
                f"📏 Размер: {len(processed) // 1024} KB\n\n"
                f"<i>Автообновление каждые {config.AUTO_REFRESH_HOURS}ч.\n"
                f"Ручное: /refresh</i>"
            ),
            parse_mode="HTML",
            reply_markup=keyboard,
        )
        # Cache message_id → client_name for reply-based append
        _save_msg_to_client[saved_msg.message_id] = client_name
        if len(_save_msg_to_client) > _SAVE_MSG_CACHE_MAX:
            oldest = next(iter(_save_msg_to_client))
            del _save_msg_to_client[oldest]

        logger.info(
            "Сохранено: %s → %s [%s] name=%s source=%s",
            url, short, ext, client_name, name_source,
        )

    except asyncio.TimeoutError:
        await m.edit_text("❌ Таймаут загрузки.")
    except aiohttp.ClientError as e:
        await m.edit_text(f"❌ Ошибка сети: {e}")
    except Exception as e:
        logger.error("URL %s: %s", url, e, exc_info=True)
        await m.edit_text(f"❌ Ошибка: {e}")


# ════════════════════   ═════════════════════════════════════════════════════════
#  CALLBACK (INLINE-КНОПКИ)
# ══════════════════════════════════════════════════════════════════════════════


@owner_only
async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    data = query.data

    if data == "refresh_confirm":
        db = await load_db()
        if not db:
            await query.answer("Список пуст!", show_alert=True)
            return

        keyboard = InlineKeyboardMarkup([
            [
                InlineKeyboardButton(
                    f"✅ Да, обновить {len(db)} шт.",
                    callback_data="refresh_go",
                ),
                InlineKeyboardButton("❌ Отмена", callback_data="refresh_cancel"),
            ]
        ])
        await query.answer()
        await query.edit_message_text(
            f"🔄 <b>Обновить всех клиентов?</b>\n\n"
            f"Записей: <b>{len(db)}</b>\n"
            f"RAW-ссылки <b>не изменятся</b>.",
            parse_mode="HTML",
            reply_markup=keyboard,
        )

    elif data == "refresh_go":
        await query.answer()

        db = await load_db()
        if not db:
            return await query.edit_message_text("📋 Нечего обновлять.")

        async def notify(text):
            try:
                await query.edit_message_text(text, parse_mode="HTML")
            except Exception:
                pass

        result = await _execute_refresh(
            db, notify_callback=notify, source="manual"
        )

        report = (
            f"✅ <b>Обновление завершено!</b>\n\n"
            f"📊 Всего: <code>{result['ok'] + result['fail']}</code>\n"
            f"✅ Успешно: <code>{result['ok']}</code>\n"
            f"❌ Ошибок: <code>{result['fail']}</code>\n"
            f"⏱ Время: <code>{result['elapsed']}с</code>\n\n"
            f"<i>RAW-ссылки не изменились.</i>"
        )

        if result["errors"]:
            report += "\n\n<b>Ошибки:</b>\n"
            for e in result["errors"][:10]:
                report += f"• <code>{e['name']}</code>: {e['error']}\n"

        keyboard = InlineKeyboardMarkup(
            [[InlineKeyboardButton("📋 Список", callback_data="list")]]
        )
        await query.edit_message_text(
            report, parse_mode="HTML", reply_markup=keyboard
        )

    elif data == "refresh_cancel":
        await query.answer("Отменено.")
        await query.edit_message_text("❌ Обновление отменено.")

    elif data == "list":
        await cmd_list(update, context)

    elif data == "status":
        await cmd_status(update, context)

    elif data == "migrate_menu":
        await query.answer()
        await query.edit_message_text(
            f"📦 <b>Миграция на новый сервер</b>\n\n"
            f"<b>Экспорт (на старом сервере):</b>\n"
            f"/export — скачать БД клиентов как файл\n\n"
            f"<b>Импорт (на новом сервере):</b>\n"
            f"1. Отправьте файл экспорта в чат\n"
            f"2. Ответьте на файл командой /import\n\n"
            f"<b>Или через bash-скрипт:</b>\n"
            f"Выберите режим 2 (Миграция) при установке —\n"
            f"скрипт сам скопирует db.json и SSH-ключи.\n\n"
            f"<i>После импорта выполните /refresh\n"
            f"для загрузки конфигов в GitFlic.</i>",
            parse_mode="HTML",
        )

    elif data.startswith("append_"):
        client_name = data[len("append_"):]
        context.user_data["append_pending"] = {
            "client_name": client_name,
            "created_at": time.monotonic(),
        }
        await query.answer()
        await query.edit_message_caption(
            caption=(query.message.caption or "") + "\n\n📝 Отправьте конфиги для добавления:",
            parse_mode="HTML",
        )

    elif data.startswith("removeconfig_"):
        client_name = data[len("removeconfig_"):]
        context.args = [client_name]
        await query.answer()
        await cmd_removeconfig(update, context)

    elif data.startswith("delete_confirm_"):
        name = data[len("delete_confirm_"):]
        await query.answer()
        await query.edit_message_text(f"⏳ Удаляю <code>{name}</code>...", parse_mode="HTML")
        await _do_delete(name, query)

    elif data == "delete_cancel":
        await query.answer("Отменено.")
        await query.edit_message_text("❌ Удаление отменено.")

    elif data == "removeconfigall_confirm":
        await query.answer()
        pending_data = context.user_data.pop("removeconfigall_data", None)
        if not pending_data:
            await query.edit_message_text("❌ Данные устарели. Повторите /removeconfigall")
            return
        if time.monotonic() - pending_data.get("created_at", 0) > 300:
            await query.edit_message_text("❌ Время ожидания истекло. Повторите /removeconfigall")
            return
        await query.edit_message_text("⏳ Выполняю массовое удаление...", parse_mode="HTML")
        await _do_removeconfigall(pending_data["configs"], query.message)

    elif data == "removeconfigall_cancel":
        context.user_data.pop("removeconfigall_data", None)
        await query.answer("Отменено.")
        await query.edit_message_text("❌ Массовое удаление отменено.")

    elif data.startswith("refresh_one_"):
        name = data[len("refresh_one_"):]
        db = await load_db()
        if name not in db:
            await query.answer("Клиент не найден!", show_alert=True)
            return
        await query.answer()
        await query.edit_message_text(
            f"⏳ Обновляю <code>{name}</code>...", parse_mode="HTML"
        )
        result = await _refresh_single_client(name, db[name])
        if result["ok"]:
            size_kb = result["size"] // 1024
            await query.edit_message_text(
                f"✅ <b>Обновлено!</b>\n\n"
                f"📛 Клиент: <code>{name}</code>\n"
                f"📏 Размер: {size_kb} KB\n"
                f"📤 Обновлено в GitFlic",
                parse_mode="HTML",
            )
        else:
            await query.edit_message_text(
                f"❌ Ошибка: {result['error']}", parse_mode="HTML"
            )


# ══════════════════════════════════════════════════════════════════════════════
#  ЗАПУСК
# ══════════════════════════════════════════════════════════════════════════════


async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE):
    logger.error("Необработанное исключение:", exc_info=context.error)


async def post_init(app: Application):
    global _scheduler, _app_ref
    _app_ref = app

    await init_git()

    _scheduler = AsyncIOScheduler()
    _scheduler.add_job(
        auto_refresh_job,
        "interval",
        hours=config.AUTO_REFRESH_HOURS,
        id="auto_refresh",
        replace_existing=True,
    )
    _scheduler.start()

    logger.info(
        "Бот запущен. OWNER=%s branch=%s auto=%dh inject=%s",
        config.OWNER_ID,
        config.GIT_BRANCH,
        config.AUTO_REFRESH_HOURS,
        config.INJECT_RULES,
    )


async def post_shutdown(app: Application):
    global _scheduler
    if _scheduler and _scheduler.running:
        _scheduler.shutdown(wait=False)
        _scheduler = None
    logger.info("Бот остановлен.")


def main():
    app = (
        Application.builder()
        .token(config.TOKEN)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("list", cmd_list))
    app.add_handler(CommandHandler("delete", cmd_delete))
    app.add_handler(CommandHandler("refresh", cmd_refresh))
    app.add_handler(CommandHandler("export", cmd_export))
    app.add_handler(CommandHandler("import", cmd_import))
    app.add_handler(CommandHandler("append", cmd_append))
    app.add_handler(CommandHandler("removeconfig", cmd_removeconfig))
    app.add_handler(CommandHandler("appendall", cmd_appendall))
    app.add_handler(CommandHandler("removeconfigall", cmd_removeconfigall))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("rename", cmd_rename))
    app.add_handler(CommandHandler("seturl", cmd_seturl))
    app.add_handler(CommandHandler("info", cmd_info))
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_msg))
    app.add_error_handler(error_handler)

    logger.info("Запуск polling...")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYBOT

chown -R "$APP_USER:$APP_USER" "$DIR"
success "Код бота задеплоен."

# ==== Применение миграции (если есть) ====
apply_migration

# ==== 9. Виртуальное окружение ====
info "Создание виртуального окружения и установка зависимостей..."

(
    cd "$DIR"
    if [[ ! -d "$VENV_DIR" ]]; then
        sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"
    fi
    sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet
    sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install -r requirements.txt --quiet
)

success "Зависимости установлены."

# ==== 10. Systemd ====
info "Настройка systemd..."

cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Bot-Links-GitFlic Telegram Bot (Smart JSON v9.1)
Documentation=https://gitflic.ru/project/$GIT_USER/$GIT_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
EnvironmentFile=$DIR/.env
ExecStart=$VENV_DIR/bin/python3 $DIR/bot.py
User=$APP_USER
Group=$APP_USER
Restart=always
RestartSec=10
TimeoutStartSec=90
TimeoutStopSec=15
WatchdogSec=300

# ── SSH для Git ──
Environment="GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -i $KEY_PATH"

# ── Безопасность ──
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
RestrictSUIDSGID=true
ReadWritePaths=$DIR

# ── Ресурсы ──
MemoryMax=512M
MemoryHigh=384M
CPUQuota=80%

# ── Логирование ──
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"

success "Systemd-сервис создан и запущен."

# ==== 11. Финальная проверка ====
info "Проверка запуска..."
sleep 3

if systemctl is-active --quiet "$SERVICE"; then
    success "Бот работает!"
else
    warn "Бот не запустился. Проверьте логи:"
    echo "    journalctl -u $SERVICE --no-pager -n 20"
fi

# ==== 12. Проверка мигрированных данных ====
if [[ -f "$DIR/db.json" ]]; then
    CLIENT_COUNT=$(sudo -u "$APP_USER" python3 -c "
import json
with open('$DIR/db.json') as f:
    print(len(json.load(f)))
" 2>/dev/null || echo "0")
    if [[ "$CLIENT_COUNT" -gt 0 ]]; then
        success "База данных содержит $CLIENT_COUNT клиентов."
    fi
fi

# ==== 13. Итог ====
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Установка Bot-Links-GitFlic v9.1 завершена! 🎉"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  📂 Каталог:          $DIR"
echo "  👤 Пользователь:     $APP_USER"
echo "  🔧 Сервис:           $SERVICE"
echo "  🌿 Ветка:            $GIT_BRANCH"
echo "  📝 Лог установки:    $LOG_FILE"
echo "  📝 Лог бота:         $DIR/bot.log"
echo "  🛡 Инъекция правил:  включена"
echo "  ⏰ Автообновление:   каждые 6 часов"
echo "  👤 Имена клиентов:   из контента подписок"
echo ""
echo "  ${BOLD}Управление сервисом:${RESET}"
echo "    systemctl status  $SERVICE"
echo "    systemctl restart $SERVICE"
echo "    systemctl stop    $SERVICE"
echo "    journalctl -u $SERVICE -f"
echo "    cat $DIR/bot.log"
echo ""
echo "  ${BOLD}Команды бота в Telegram:${RESET}"
echo "    /start    — 🤖 меню с кнопками"
echo "    /refresh [name] — 🔄 обновить все или одного"
echo "    /list     — 📋 список ссылок (с именами клиентов)"
echo "    /info     — ℹ️ подробная информация о клиенте"
echo "    /delete   — 🗑  удалить запись (с подтверждением)"
echo "    /rename   — ✏️ переименовать клиента"
echo "    /seturl   — 🔗 обновить источник конфига"
echo "    /append   — ➕ добавить конфиги к клиенту"
echo "    /removeconfig — 🗑 удалить отдельные конфиги"
echo "    /appendall — ➕➕ добавить конфиги сразу всем клиентам"
echo "    /removeconfigall — 🗑🗑 удалить конфиги у всех клиентов"
echo "    /cancel   — ❌ отменить текущую операцию"
echo "    /status   — 📊 статус + время след. обновления"
echo "    /export   — 📦 экспорт БД для миграции"
echo "    /import   — 📥 импорт БД (ответом на файл)"
echo "    /help     — ❓ справка"
echo ""
echo "  ${BOLD}Миграция на новый сервер:${RESET}"
echo "    Вариант 1 (через Telegram):"
echo "      Старый сервер: /export → скачать файл"
echo "      Новый сервер:  отправить файл → /import → /refresh"
echo ""
echo "    Вариант 2 (через bash-скрипт):"
echo "      Запустите установщик и выберите режим 2 (Миграция)"
echo "      Скрипт сам скопирует db.json и SSH-ключи по SSH"
echo ""
echo "  ${BOLD}Конфигурация (.env):${RESET}"
echo "    AUTO_REFRESH_HOURS=6    # интервал автообновления (часы)"
echo "    INJECT_RULES=true       # инъекция блокировок (true/false)"
echo "    REFRESH_CONCURRENT=5    # параллельных загрузок"
echo "    MAX_SIZE=2097152        # макс. размер файла (байт)"
echo ""