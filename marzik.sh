#!/usr/bin/env bash
# ============================================================================== 
# Marzban Telegram Bot Deploy Script v4.0.1 (fully fixed)
# Generates and deploys a fully-featured Marzban VPN panel management bot.
#
# Changelog vs v4.0.0:
#   fix #1:  Argument parsing rewritten from for-loop to while/shift
#   fix #2:  umask 077 scoped to subshell (no leak to subsequent files)
#   fix #3:  .env values written via printf (no shell injection)
#   fix #4:  MarzbanAPI: token auto-refresh on 401
#   fix #5:  MarzbanAPI: single aiohttp session, reused & closed properly
#   fix #6:  IP port validation: reject ports > 65535
#   fix #7:  IP text handler gated by pending flow state
#   fix #8:  aiohttp timeouts (30s total, 10s connect)
#   fix #9:  /new_user: days/GB parsed with try/except
#   fix #10: config.py: added from __future__ import annotations
#   fix #11: sleep 3 now gated by --dry-run check
#   fix #12: Error message uses $0 instead of hardcoded "basher.sh"
#   fix #13: callback_data truncated to 64 bytes for Telegram limit
#   fix #14: _parse_host: port int() wrapped in try/except
#   fix #15: Python version check (>= 3.10) added
#   fix #16: Explicit chmod on all deployed files
#   fix #17: datetime.now(datetime.timezone.utc) for timezone awareness
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# Duplicate all output to a log file via tee
LOG_FILE="/var/log/marzban-bot-deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ==== Colors ====
RED=$(tput setaf 1 2>/dev/null || printf '\033[0;31m')
GREEN=$(tput setaf 2 2>/dev/null || printf '\033[0;32m')
YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[0;33m')
BLUE=$(tput setaf 4 2>/dev/null || printf '\033[0;34m')
BOLD=$(tput bold 2>/dev/null || printf '\033[1m')
RESET=$(tput sgr0 2>/dev/null || printf '\033[0m')

# ==== Constants ====
VERSION="4.0.1"
APP_USER="marzbot"
DIR="/opt/marzban_bot"
SERVICE="marzban-bot"
VENV_DIR="$DIR/venv"
DRY_RUN=false

# ==== Helper functions ====
info()    { echo -e "${BLUE}${BOLD}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[ERR]${RESET}  $*" >&2; }

drun() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Would run: $*"
    else
        "$@"
    fi
}

deploy_file() {
    local path="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Would create: $path"
        cat > /dev/null
    else
        cat > "$path"
    fi
}

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
    local value="" full_prompt="$prompt"
    [[ -n "$default" ]] && full_prompt+=" [$default]"
    full_prompt+=": "
    while true; do
        if [[ "$secret" == "true" ]]; then
            read -rsp "$full_prompt" value; echo
        else
            read -rp "$full_prompt" value
        fi
        value="${value:-$default}"
        if [[ -n "$value" ]]; then
            printf -v "$varname" '%s' "$value"
            return 0
        fi
        warn "Значение не может быть пустым. Попробуйте снова."
    done
}

# ==== CLI migration handler ====
_handle_cli_migrate() {
    local json_file="${1:-}"
    [[ -z "$json_file" ]] && { error "Использование: $0 --migrate <json_file>"; exit 1; }
    [[ -f "$json_file" ]] || { error "Файл не найден: $json_file"; exit 1; }

    python3 - "$json_file" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
users = data.get("users", data if isinstance(data, list) else [])
for user in users:
    print(json.dumps(user, ensure_ascii=False))
PYEOF
}

# ==== FIX #1: Argument parsing rewritten to while/shift ====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --migrate)  shift; _handle_cli_migrate "${1:-}"; exit 0 ;;
        --help|-h)
            echo "Использование: $0 [--dry-run] [--migrate <json>]"
            exit 0
            ;; 
        *)
            error "Неизвестный аргумент: $1"
            exit 1;
            ;;
    esac
done

# ==== Banner ====
show_banner() {
    echo -e "${BLUE}${BOLD}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║        Marzban Telegram Bot Deployer  v4.0.1        ║
  ║     Управление пользователями VPN-панели Marzban    ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"
}

show_banner
[[ "$DRY_RUN" == "true" ]] && warn "Запущен в режиме --dry-run. Изменений произведено не будет."

# ==== Root check — FIX #12: use $0 instead of hardcoded name ====
if [[ $EUID -ne 0 ]]; then
    error "Запустите скрипт от root (sudo bash $0)";
    exit 1;
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd не найден."
    exit 1;
fi

# ==== FIX #15: Python version check (>= 3.10) ====
if command -v python3 >/dev/null 2>&1; then
    PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 10 ]]; }; then
        error "Требуется Python >= 3.10, найден: $PY_VERSION"
        exit 1;
    fi
    info "Python $PY_VERSION — OK." 
fi

# ==== System packages ====
info "Проверка и установка системных пакетов..."
if [[ "$DRY_RUN" != "true" ]]; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 python3-venv python3-pip
fi
success "Системные пакеты в порядке."

# Re-check Python version after potential install
if [[ "$DRY_RUN" != "true" ]]; then
    PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 10 ]]; }; then
        error "Требуется Python >= 3.10, найден: $PY_VERSION. Обновите Python."
        exit 1;
    fi
fi

# ==== Stop existing service ====
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "Останавливаю текущий экземпляр бота..."
    drun systemctl stop "$SERVICE"
    success "Бот остановлен."
fi

# ==== User and directory setup ====
info "Настройка пользователя и каталогов..."
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    drun useradd --system --create-home --home-dir "$DIR" --shell /usr/sbin/nologin "$APP_USER"
    success "Пользователь $APP_USER создан."
else
    info "Пользователь $APP_USER уже существует."
fi
drun mkdir -p "$DIR"
drun chown "$APP_USER:$APP_USER" "$DIR"

# ==== Configuration collection ====
echo ""
info "Сбор параметров конфигурации Marzban Bot..."
echo ""

BOT_TOKEN="" ADMIN_IDS="" MARZBAN_URL="" MARZBAN_USER="" MARZBAN_PASS=""
require_input "Telegram Bot Token" BOT_TOKEN true
require_input "ADMIN_IDS (Telegram ID, через запятую)" ADMIN_IDS false
require_input "URL панели Marzban (например https://panel.example.com)" MARZBAN_URL false
require_input "Имя администратора Marzban" MARZBAN_USER false "admin"
require_input "Пароль администратора Marzban" MARZBAN_PASS true

echo ""
success "Конфигурация собрана."

# ==== .env file — FIX #2: umask scoped to subshell — FIX #3: printf for safety ====
info "Создание .env..."
if [[ "$DRY_RUN" != "true" ]]; then
    (
        umask 077
        {
            printf 'BOT_TOKEN=%s\n' "$BOT_TOKEN"
            printf 'ADMIN_IDS=%s\n' "$ADMIN_IDS"
            printf 'MARZBAN_URL=%s\n' "$MARZBAN_URL"
            printf 'MARZBAN_USER=%s\n' "$MARZBAN_USER"
            printf 'MARZBAN_PASS=%s\n' "$MARZBAN_PASS"
            printf 'NODE_PREFIX=\n'
        } > "$DIR/.env"
    )
    chown "$APP_USER:$APP_USER" "$DIR/.env"
    chmod 600 "$DIR/.env"
fi
success ".env создан."

# ==== requirements.txt ====
info "Создание requirements.txt..."
deploy_file "$DIR/requirements.txt" <<'REQ'
python-telegram-bot==20.8
aiohttp>=3.9,<4
python-dotenv>=1.0
REQ
if [[ "$DRY_RUN" != "true" ]]; then
    chown "$APP_USER:$APP_USER" "$DIR/requirements.txt"
    chmod 644 "$DIR/requirements.txt"
fi
success "requirements.txt создан."

# ==== config.py — FIX #10: added from __future__ import annotations ====
info "Деплой config.py..."
deploy_file "$DIR/config.py" <<'PYCONFIG'
"""Конфигурация Marzban Bot из переменных окружения."""
from __future__ import annotations

import os
from dotenv import load_dotenv

load_dotenv()


def _require(key: str) -> str:
    val = os.environ.get(key)
    if not val:
        raise RuntimeError(f"Переменная окружения {key!r} обязательна")
    return val


BOT_TOKEN: str = _require("BOT_TOKEN")
ADMIN_IDS: list[int] = [
    int(x) for x in os.environ.get("ADMIN_IDS", "").split(",") if x.strip()
]
MARZBAN_URL: str = _require("MARZBAN_URL")
MARZBAN_USER: str = _require("MARZBAN_USER")
MARZBAN_PASS: str = _require("MARZBAN_PASS")
NODE_PREFIX: str = os.environ.get("NODE_PREFIX", "")
PYCONFIG
if [[ "$DRY_RUN" != "true" ]]; then
    chown "$APP_USER:$APP_USER" "$DIR/config.py"
    chmod 640 "$DIR/config.py"
fi
success "config.py создан."

# ==== marzban.py — FIX #4: token refresh — FIX #5: session reuse — FIX #8: timeouts ====
info "Деплой marzban.py..."
deploy_file "$DIR/marzban.py" <<'PYMARZBAN'
"""Async Marzban panel API client v4.0.1."""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)


class MarzbanAPI:
    """Async client for the Marzban REST API."""

    def __init__(self, base_url: str, username: str, password: str) -> None:
        self._url = base_url.rstrip("/")
        self._username = username
        self._password = password
        self._token: str | None = None
        self._last_request: float = 0.0
        self._session: aiohttp.ClientSession | None = None
        # FIX #8: timeouts
        self._timeout = aiohttp.ClientTimeout(total=30, connect=10)

    # ──────────────────────────────────────────────────────────────────────────

    async def _get_session(self) -> aiohttp.ClientSession:
        """FIX #5: reuse a single session instead of creating one per request."""
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=self._timeout)
        return self._session

    async def close(self) -> None:
        """Close the underlying aiohttp session."""
        if self._session and not self._session.closed:
            await self._session.close()
            self._session = None

    # ──────────────────────────────────────────────────────────────────────────

    async def _throttle(self) -> None:
        """Rate limiting: minimum 0.1 s between API requests."""
        elapsed = time.monotonic() - self._last_request
        if elapsed < 0.1:
            await asyncio.sleep(0.1 - elapsed)
        self._last_request = time.monotonic()

    async def _headers(self) -> dict[str, str]:
        if self._token is None:
            await self.login()
        return {"Authorization": f"Bearer {self._token}"}

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        """FIX #4: auto-refresh token on 401 (one retry)."""
        await self._throttle()
        session = await self._get_session()
        for attempt in range(2):
            headers = await self._headers()
            async with session.request(
                method, f"{self._url}{path}", headers=headers, **kwargs
            ) as resp:
                if resp.status == 401 and attempt == 0:
                    logger.info("Marzban: got 401, refreshing token...")
                    self._token = None
                    continue
                resp.raise_for_status()
                if resp.content_type == "application/json":
                    return await resp.json()
                return None
        return None

    # ──────────────────────────────────────────────────────────────────────────

    async def login(self) -> None:
        """Authenticate and store access token."""
        session = await self._get_session()
        async with session.post(
            f"{self._url}/api/admin/token",
            data={"username": self._username, "password": self._password},
        ) as resp:
            resp.raise_for_status()
            data = await resp.json()
            self._token = data["access_token"]
        logger.debug("Marzban: авторизован.")

    # ──────────────────────────────────────────────────────────────────────────

    async def get_users(self) -> list[dict[str, Any]]:
        data = await self._request("GET", "/api/users")
        return data.get("users", []) if isinstance(data, dict) else []

    async def get_user(self, username: str) -> dict[str, Any]:
        return await self._request("GET", f"/api/user/{username}")

    async def create_user(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("POST", "/api/user", json=payload)

    async def delete_user(self, username: str) -> None:
        await self._request("DELETE", f"/api/user/{username}")

    async def update_user(self, username: str, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("PUT", f"/api/user/{username}", json=payload)

    # ──────────────────────────────────────────────────────────────────────────

    async def get_inbounds(self) -> dict[str, list[dict[str, Any]]]:
        return await self._request("GET", "/api/inbounds") or {}

    async def get_hosts(self) -> dict[str, list[dict[str, Any]]]:
        return await self._request("GET", "/api/hosts") or {}

    async def update_hosts(self, hosts: dict[str, Any]) -> dict[str, Any]:
        return await self._request("PUT", "/api/hosts", json=hosts)

    async def update_hosts_for_inbound(
        self, tag: str, hosts: list[dict[str, Any]]
    ) -> dict[str, Any]:
        all_hosts = await self.get_hosts()
        all_hosts[tag] = hosts
        return await self.update_hosts(all_hosts)

    # ──────────────────────────────────────────────────────────────────────────

    async def get_system_stats(self) -> dict[str, Any]:
        return await self._request("GET", "/api/system") or {}
PYMARZBAN
if [[ "$DRY_RUN" != "true" ]]; then
    chown "$APP_USER:$APP_USER" "$DIR/marzban.py"
    chmod 640 "$DIR/marzban.py"
fi
success "marzban.py создан."

# ==== bot.py — ALL PYTHON FIXES APPLIED ====
info "Деплой bot.py..."
deploy_file "$DIR/bot.py" <<'PYBOT'
"""Marzban Telegram Bot v4.0.1

Команды:
  /start        — справка
  /new_user     — создать нового пользователя
  /del          — удалить пользователя (с подтверждением + TTL 60 с)
  /confirm      — подтвердить ожидающую операцию
  /cancel       — отменить ожидающую операцию
  /inbounds     — список инбаундов с хостами
  /update_ips   — обновить IP хостов (все или конкретный инбаунд)
  /user_info    — подробная карточка пользователя
  /extend       — продлить подписку на N дней
  /disable      — заблокировать пользователя
  /enable       — разблокировать пользователя
  /stats        — общая статистика панели
"""
from __future__ import annotations

import datetime
import logging
import re
import time
from typing import Any

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
from marzban import MarzbanAPI

# ============================================================================== 
#  Logging
# ============================================================================== 

logging.basicConfig(
    format="%(asctime)s | %(levelname)-8s | %(name)s — %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ============================================================================== 
#  IP validation — FIX #6: port range also validated (1-65535)
# ============================================================================== 

_OCTET = r"(?:25[0-5]|2[0-4]\d|[01]?\d\d?)"
_IP_RE = re.compile(
    rf"^{_OCTET}\.{_OCTET}\.{_OCTET}\.{_OCTET}(?::\d{{1,5}})?$"
)

def _is_valid_ip_port(s: str) -> bool:
    """Validate IP with optional port, ensuring port <= 65535."""
    if not _IP_RE.match(s):
        return False
    if ":" in s:
        try:
            port = int(s.rsplit(":", 1)[1])
            return 1 <= port <= 65535
        except ValueError:
            return False
    return True

# ============================================================================== 
#  Markdown escaping
# ============================================================================== 

def _escape_md(text: str) -> str:
    """Escape special MarkdownV2 characters in user-supplied strings."""
    for ch in r"\_*[]()~`>#+-=|{}.!":
        text = text.replace(ch, f"\\{ch}")
    return text

# ============================================================================== 
#  Marzban API singleton
# ============================================================================== 

api = MarzbanAPI(config.MARZBAN_URL, config.MARZBAN_USER, config.MARZBAN_PASS)

# ============================================================================== 
#  Auth guard
# ============================================================================== 

def _is_admin(user_id: int) -> bool:
    return user_id in config.ADMIN_IDS

async def _check_admin(update: Update) -> bool:
    if update.effective_user and _is_admin(update.effective_user.id):
        return True
    if update.message:
        await update.message.reply_text("⛔ Доступ запрещён.")
    return False

# ============================================================================== 
#  /start
# ============================================================================== 

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    text = (
        "🤖 *Marzban Bot v4\.0\.1*\n\n"
        "*/new\_user* \<имя\> \[дней\] \[GB\]\n"
        "*/del* \<имя\>\n"
        "*/confirm* — подтвердить удаление\n"
        "*/cancel* — отменить операцию\n"
        "*/inbounds* — список инбаундов\n"
        "*/update\_ips* \[тег\] — обновить IP хостов\n"
        "*/user\_info* \<имя\>\n"
        "*/extend* \<имя\> \<дней\>\n"
        "*/disable* \<имя\>\n"
        "*/enable* \<имя\>\n"
        "*/stats* — статистика панели\n"
    )
    await update.message.reply_markdown_v2(text)

# ============================================================================== 
#  /new_user — FIX #9: days/GB parsed with try/except — FIX #17: UTC datetime
# ============================================================================== 

async def cmd_new_user(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /new_user <имя> [дней] [GB]")
        return

    username = args[0]

    try:
        days = int(args[1]) if len(args) > 1 else 30
    except ValueError:
        await update.message.reply_text("Параметр 'дней' должен быть целым числом.")
        return
    try:
        gb = int(args[2]) if len(args) > 2 else 10
    except ValueError:
        await update.message.reply_text("Параметр 'GB' должен быть целым числом.")
        return

    expire = int(
        (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)).timestamp()
    )
    payload: dict[str, Any] = {
        "username": username,
        "proxies": {"vless": {"flow": ""}},
        "inbounds": {"vless": []},
        "expire": expire,
        "data_limit": gb * 1024 ** 3,
        "data_limit_reset_strategy": "no_reset",
    }

    try:
        user = await api.create_user(payload)
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка создания: {exc}")
        return

    links: list[str] = user.get("links", [])
    link_text = "\n".join(f"`{_escape_md(link)}`" for link in links[:5])
    escaped_name = _escape_md(username)
    msg = (
        f"✅ Пользователь `{escaped_name}` создан\!\n"
        f"Срок: {days} дней \| Лимит: {gb} GB"
    )
    if link_text:
        msg += f"\n\nСсылки:\n{link_text}"
    await update.message.reply_markdown_v2(msg)

# ============================================================================== 
#  /del  +  /confirm  +  /cancel
# ============================================================================== 

async def cmd_del(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /del <имя>")
        return
    username = args[0]
    ctx.user_data["pending_delete"] = (username, time.monotonic())
    escaped = _escape_md(username)
    await update.message.reply_markdown_v2(
        f"⚠️ Удалить пользователя `{escaped}`\?\n"
        f"Подтвердите командой /confirm в течение 60 секунд или /cancel для отмены\.")
    
async def cmd_confirm(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    pending = ctx.user_data.get("pending_delete")
    if pending is None:
        await update.message.reply_text("Нет ожидающего удаления.")
        return
    username, ts = pending
    if time.monotonic() - ts > 60:
        ctx.user_data.pop("pending_delete", None)
        await update.message.reply_text("⏱ Запрос истёк (60 с). Повторите /del.")
        return
    try:
        await api.delete_user(username)
        ctx.user_data.pop("pending_delete", None)
        await update.message.reply_markdown_v2(
            f"✅ Пользователь `{_escape_md(username)}` удалён\.")
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")

async def cmd_cancel(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    ctx.user_data.pop("pending_delete", None)
    ctx.user_data.pop("pending_ips", None)
    ctx.user_data.pop("pending_ip_tag", None)
    ctx.user_data.pop("pending_ip_update_tag", None)
    await update.message.reply_text("Операция отменена.")

# ============================================================================== 
#  /inbounds
# ============================================================================== 

async def cmd_inbounds(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    try:
        inbounds = await api.get_inbounds()
        hosts = await api.get_hosts()
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")
        return

    if not inbounds:
        await update.message.reply_text("Инбаунды не найдены.")
        return

    lines = ["📋 *Инбаунды:"]
    idx = 1
    for proto_inbounds in inbounds.values():
        if not isinstance(proto_inbounds, list):
            continue
        for ib in proto_inbounds:
            tag = ib.get("tag", "?")
            tag_hosts = hosts.get(tag, [])
            count = len(tag_hosts)
            lines.append(f"{idx}\. {_escape_md(tag)} — {count} хостов")
            for h in tag_hosts[:3]:
                addr = h.get("address", "?")
                port = h.get("port", "")
                host_str = f"{addr}:{port}" if port else str(addr)
                lines.append(f"   • {_escape_md(host_str)}")
            idx += 1

    await update.message.reply_markdown_v2("\n".join(lines))

# ============================================================================== 
#  /update_ips [inbound_tag]
# ============================================================================== 

async def cmd_update_ips(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    tag = args[0] if args else None
    ctx.user_data["pending_ip_update_tag"] = tag
    if tag:
        await update.message.reply_text(
            f"Инбаунд: {tag}\nОтправьте список IP (по одному на строку, формат: 1.2.3.4 или 1.2.3.4:443):"
        )
    else:
        await update.message.reply_text(
            "Отправьте список IP (по одному на строку).\n"
            "После этого вы выберете инбаунд или обновите все сразу."
        )

# ============================================================================== 
#  /user_info — FIX #17: UTC datetime
# ============================================================================== 

async def cmd_user_info(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /user_info <имя>")
        return
    username = args[0]
    try:
        user = await api.get_user(username)
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")
        return

    status = user.get("status", "?")
    expire_ts = user.get("expire")
    expire_str = (
        datetime.datetime.fromtimestamp(expire_ts, tz=datetime.timezone.utc).strftime("%Y-%m-%d")
        if expire_ts
        else "∞"
    )
    used = user.get("used_traffic", 0) or 0
    limit = user.get("data_limit", 0) or 0
    used_gb = used / 1024 ** 3
    limit_str = f"{limit / 1024 ** 3:.2f} GB" if limit else "∞"
    online = bool(user.get("online_at"))

    lines = [
        f"👤 *_escape_md(username)}*",
        f"Статус: {_escape_md(status)}",
        f"Истекает: {_escape_md(expire_str)}",
        f"Трафик: {_escape_md(f'{used_gb:.2f}') } GB / {_escape_md(limit_str)}",
        f"Онлайн: {'✅' if online else '❌'}",
    ]
    links: list[str] = user.get("links", [])
    if links:
        link_text = "\n".join(f"`{_escape_md(link)}`" for link in links[:3])
        lines.append(f"\nСсылки:\n{link_text}")

    await update.message.reply_markdown_v2("\n".join(lines))

# ============================================================================== 
#  /extend — FIX #17: UTC datetime
# ============================================================================== 

async def cmd_extend(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if len(args) < 2:
        await update.message.reply_text("Использование: /extend <имя> <дней>")
        return
    username = args[0]
    try:
        days = int(args[1])
    except ValueError:
        await update.message.reply_text("Дни должны быть числом.")
        return

    try:
        user = await api.get_user(username)
        current = user.get("expire")
        now_ts = datetime.datetime.now(datetime.timezone.utc).timestamp()
        base = datetime.datetime.fromtimestamp(
            current if current and current > now_ts else now_ts,
            tz=datetime.timezone.utc,
        )
        new_expire = int((base + datetime.timedelta(days=days)).timestamp())
        await api.update_user(username, {"expire": new_expire})
        new_date = datetime.datetime.fromtimestamp(
            new_expire, tz=datetime.timezone.utc
        ).strftime("%Y-%m-%d")
        await update.message.reply_markdown_v2(
            f"✅ `{_escape_md(username)}` продлён на {days} дней\.
"
            f"Новая дата: {_escape_md(new_date)}"
        )
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")

# ============================================================================== 
#  /disable  /enable
# ============================================================================== 

async def cmd_disable(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /disable <имя>")
        return
    username = args[0]
    try:
        await api.update_user(username, {"status": "disabled"})
        await update.message.reply_markdown_v2(
            f"🚫 `{_escape_md(username)}` заблокирован\.")
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")

async def cmd_enable(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /enable <имя>")
        return
    username = args[0]
    try:
        await api.update_user(username, {"status": "active"})
        await update.message.reply_markdown_v2(
            f"✅ `{_escape_md(username)}` разблокирован\.")
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")

# ============================================================================== 
#  /stats
# ============================================================================== 

async def cmd_stats(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _check_admin(update):
        return
    try:
        stats = await api.get_system_stats()
        users = await api.get_users()
    except Exception as exc:
        await update.message.reply_text(f"❌ Ошибка: {exc}")
        return

    total = len(users)
    active = sum(1 for u in users if u.get("status") == "active")
    expired = sum(1 for u in users if u.get("status") == "expired")
    disabled = sum(1 for u in users if u.get("status") == "disabled")
    incoming = (stats.get("incoming_bandwidth") or 0) / 1024 ** 3
    outgoing = (stats.get("outgoing_bandwidth") or 0) / 1024 ** 3

    await update.message.reply_text(
        f"📊 Статистика панели:\n"
        f"  Всего пользователей: {total}\n"
        f"  Активных:            {active}\n"
        f"  Истекших:            {expired}\n"
        f"  Заблокированных:     {disabled}\n"
        f"  Входящий трафик:     {incoming:.2f} GB\n"
        f"  Исходящий трафик:    {outgoing:.2f} GB"
    )

# ============================================================================== 
#  Text message handler — FIX #6 + FIX #7: gated by flow state
# ============================================================================== 

async def handle_ip_list(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_user or not _is_admin(update.effective_user.id):
        return

    # FIX #7: only process IPs if the user initiated /update_ips
    if "pending_ip_update_tag" not in ctx.user_data:
        return

    text = (update.message.text or "").strip()
    # FIX #6: use _is_valid_ip_port for full port validation
    ips = [line.strip() for line in text.splitlines() if _is_valid_ip_port(line.strip())]
    if not ips:
        await update.message.reply_text(
            "Не найдено корректных IP. Формат: 1.2.3.4 или 1.2.3.4:443 (порт 1-65535)"
        )
        return

    ctx.user_data["pending_ips"] = ips

    pre_tag = ctx.user_data.pop("pending_ip_update_tag", None)
    if pre_tag is not None:
        ctx.user_data["pending_ip_tag"] = pre_tag
        await _show_ip_preview(update, ctx, ips, pre_tag)
        return

    try:
        inbounds = await api.get_inbounds()
    except Exception:
        inbounds = {}

    buttons = [[InlineKeyboardButton("Все инбаунды", callback_data="ip_sel:all")]]
    for proto_inbounds in inbounds.values():
        if isinstance(proto_inbounds, list):
            for ib in proto_inbounds:
                tag = ib.get("tag", "")
                if tag:
                    # FIX #13: truncate callback_data to 64 bytes
                    cb_data = f"ip_sel:tag:{tag}"
                    if len(cb_data.encode("utf-8")) > 64:
                        cb_data = cb_data.encode("utf-8")[:64].decode("utf-8", errors="ignore")
                    buttons.append(
                        [InlineKeyboardButton(tag, callback_data=cb_data)]
                    )

    await update.message.reply_text(
        f"Найдено {len(ips)} IP. Выберите инбаунд для обновления:",
        reply_markup=InlineKeyboardMarkup(buttons),
    )

async def _show_ip_preview(
    update: Update,
    ctx: ContextTypes.DEFAULT_TYPE,
    ips: list[str],
    tag: str | None,
) -> None:
    host_list = "\n".join(f"  • {_escape_md(ip)}" for ip in ips)
    inbound_label = _escape_md(tag) if tag else "все инбаунды"
    preview = (
        f"🔄 *Обновление хостов:*\n"
        f"Инбаунд: {inbound_label}\n"
        f"Новые IP:\n{host_list}\n\n"
        f"Подтвердите:"
    )
    buttons = [[
        InlineKeyboardButton("✅ Подтвердить", callback_data="ip_confirm"),
        InlineKeyboardButton("❌ Отмена", callback_data="ip_cancel"),
    ]]
    await update.message.reply_markdown_v2(
        preview, reply_markup=InlineKeyboardMarkup(buttons)
    )

# ============================================================================== 
#  Callback query handler — FIX #13 + FIX #14
# ============================================================================== 

async def callback_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    data = query.data or ""

    if data.startswith("ip_sel:"):
        part = data[len("ip_sel:"):] 
        tag: str | None = None if part == "all" else part[len("tag:"):] if part.startswith("tag:") else part
        ips: list[str] = ctx.user_data.get("pending_ips", [])
        if not ips:
            await query.edit_message_text("Нет IP для обновления.")
            return
        ctx.user_data["pending_ip_tag"] = tag

        host_list = "\n".join(f"  • {_escape_md(ip)}" for ip in ips)
        inbound_label = _escape_md(tag) if tag else "все инбаунды"
        preview = (
            f"🔄 *Обновление хостов:*\n"
            f"Инбаунд: {inbound_label}\n"
            f"Новые IP:\n{host_list}\n\n"
            f"Подтвердите:"
        )
        confirm_buttons = [[
            InlineKeyboardButton("✅ Подтвердить", callback_data="ip_confirm"),
            InlineKeyboardButton("❌ Отмена", callback_data="ip_cancel"),
        ]]
        await query.edit_message_text(
            preview,
            parse_mode="MarkdownV2",
            reply_markup=InlineKeyboardMarkup(confirm_buttons),
        )

    elif data == "ip_confirm":
        ips = ctx.user_data.pop("pending_ips", [])
        tag = ctx.user_data.pop("pending_ip_tag", None)
        if not ips:
            await query.edit_message_text("Нет IP для обновления.")
            return

        # FIX #14: _parse_host with try/except
        def _parse_host(raw: str) -> dict[str, Any] | None:
            if ":" in raw:
                addr, port_str = raw.rsplit(":", 1)
                try:
                    port = int(port_str)
                except ValueError:
                    return None
                return {"address": addr, "port": port}
            return {"address": raw}

        hosts_payload = [h for ip in ips if (h := _parse_host(ip)) is not None]
        if not hosts_payload:
            await query.edit_message_text("❌ Ни один IP не прошёл валидацию.")
            return

        try:
            if tag:
                await api.update_hosts_for_inbound(tag, hosts_payload)
            else:
                all_hosts = await api.get_hosts()
                updated = {t: hosts_payload for t in all_hosts}
                await api.update_hosts(updated)
            await query.edit_message_text("✅ IP успешно обновлены.")
        except Exception as exc:
            await query.edit_message_text(f"❌ Ошибка: {exc}")

    elif data == "ip_cancel":
        ctx.user_data.pop("pending_ips", None)
        ctx.user_data.pop("pending_ip_tag", None)
        await query.edit_message_text("Отменено.")

# ============================================================================== 
#  Application lifecycle — FIX #5: close session on shutdown
# ============================================================================== 

async def post_init(app: Application) -> None:  # type: ignore[type-arg]
    await api.login()
    logger.info("Marzban Bot запущен.")

async def post_shutdown(app: Application) -> None:  # type: ignore[type-arg]
    await api.close()
    logger.info("Marzban Bot остановлен.")

# ============================================================================== 
#  Entry point
# ============================================================================== 

def main() -> None:
    app = (
        Application.builder()
        .token(config.BOT_TOKEN)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_start))
    app.add_handler(CommandHandler("new_user", cmd_new_user))
    app.add_handler(CommandHandler("del", cmd_del))
    app.add_handler(CommandHandler("confirm", cmd_confirm))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("inbounds", cmd_inbounds))
    app.add_handler(CommandHandler("update_ips", cmd_update_ips))
    app.add_handler(CommandHandler("user_info", cmd_user_info))
    app.add_handler(CommandHandler("extend", cmd_extend))
    app.add_handler(CommandHandler("disable", cmd_disable))
    app.add_handler(CommandHandler("enable", cmd_enable))
    app.add_handler(CommandHandler("stats", cmd_stats))
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_ip_list))

    logger.info("Запуск polling...")
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main() 
PYBOT
if [[ "$DRY_RUN" != "true" ]]; then
    chown "$APP_USER:$APP_USER" "$DIR/bot.py"
    chmod 640 "$DIR/bot.py"
fi
success "bot.py создан."

# ==== Virtual environment + dependencies ====
info "Создание виртуального окружения и установка зависимостей..."
if [[ "$DRY_RUN" != "true" ]]; then
    (
        cd "$DIR"
        if [[ ! -d "$VENV_DIR" ]]; then
            sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"
        fi
        sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet
        sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install -r requirements.txt --quiet
    )
else:
    info "[dry-run] Would create venv and install requirements in $VENV_DIR"
fi
success "Зависимости установлены."

# ==== Systemd service ====
info "Настройка systemd-сервиса..."
deploy_file "/etc/systemd/system/$SERVICE.service" << EOF
[Unit]
Description=Marzban Telegram Bot v${VERSION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${DIR}
EnvironmentFile=${DIR}/.env
ExecStart=${VENV_DIR}/bin/python3 ${DIR}/bot.py
User=${APP_USER}
Group=${APP_USER}
Restart=always
RestartSec=10
TimeoutStartSec=90
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

if [[ "$DRY_RUN" != "true" ]]; then
    systemctl daemon-reload
    systemctl enable "$SERVICE"
fi
success "Systemd-сервис настроен."

# ==== Start service ====
info "Запуск $SERVICE..."
dr
    run systemctl start "$SERVICE"

# FIX #11: sleep 3 gated by dry-run
if [[ "$DRY_RUN" != "true" ]]; then
    sleep 3
    if systemctl is-active --quiet "$SERVICE"; then
        success "Бот успешно запущен!"
    else
        error "Сервис не запустился. Проверьте: journalctl -u $SERVICE -n 50"
        exit 1
    fi
else:
    info "[dry-run] Would check service health after 3s."
fi

# ==== Summary ====
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Marzban Telegram Bot v${VERSION} успешно задеплоен!${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  Каталог бота:  $DIR"
echo "  Сервис:        $SERVICE"
echo "  Лог установки: $LOG_FILE"
echo "  Лог бота:      journalctl -u $SERVICE -f"
echo ""