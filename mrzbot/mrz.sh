#!/usr/bin/env bash
###############################################################################
# deploy_marzban_bot.sh — atomic deploy of Marzban Telegram Bot
# v2.0.0 — 2026-02-22
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Конфигурация ─────────────────────────────────────────────────────────────
DIR="/opt/marzban_bot_full"
SERVICE="bot-marzban"
ENV_FILE="/etc/marzban-bot.env"
USER_NAME="marzbanbot"
GROUP_NAME="marzbanbot"
LOCK_FILE="/run/lock/${SERVICE}.lock"
BACKUP_DIR="/var/backups/marzban_bot"
MAX_BACKUPS=10
MIN_DISK_MB=200
DEPLOY_VERSION="2.0.0-$(date +%Y%m%d%H%M%S)"

# ─── Логирование ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { printf "[%s] %s\n"          "$(date -Iseconds)" "$*"; }
log_ok()  { printf "[%s] ${GREEN}✅ %s${NC}\n"  "$(date -Iseconds)" "$*"; }
log_warn(){ printf "[%s] ${YELLOW}⚠️  %s${NC}\n" "$(date -Iseconds)" "$*"; }
log_err() { printf "[%s] ${RED}❌ %s${NC}\n"    "$(date -Iseconds)" "$*" >&2; }

# ─── Cleanup / Rollback ───────────────────────────────────────────────────────
cleanup(){
  if [[ -n "${LOCK_FD:-}" ]]; then flock -u "${LOCK_FD}" 2>/dev/null || true; fi
  # Откат при неудачном деплое
  if [[ "${DEPLOY_FAILED:-0}" -eq 1 && -d "${DIR}.old" ]]; then
    log_warn "Deploy failed — rolling back to previous version"
    rm -rf "$DIR" 2>/dev/null || true
    mv "${DIR}.old" "$DIR"
  fi
  rm -rf "${DIR}.new" 2>/dev/null || true
}
trap cleanup EXIT

DEPLOY_FAILED=1  # сбросится в 0 при успехе

# ─── Файловый замок ───────────────────────────────────────────────────────────
exec {LOCK_FD}>"${LOCK_FILE}"
flock -n "${LOCK_FD}" || { log_err "Another deploy is already running"; exit 1; }

# ─── Preflight checks ─────────────────────────────────────────────────────────
# Проверка прав root
if [[ "$(id -u)" -ne 0 ]]; then
  log_err "This script must be run as root"
  exit 1
fi

# Проверка наличия необходимых команд
REQUIRED_CMDS=(python3 pip3 systemctl useradd flock dirname df mv rm cp mkdir chmod chown tee curl)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    log_err "Required command not found: $cmd"
    exit 1
  fi
done

# Проверка свободного места на диске
parent_dir="$(dirname "$DIR")"
avail_mb=$(df -m "$parent_dir" | awk 'NR==2{print $4}')
if [[ "${avail_mb}" -lt "${MIN_DISK_MB}" ]]; then
  log_err "Not enough disk space: ${avail_mb} MB available, ${MIN_DISK_MB} MB required"
  exit 1
fi
log_ok "Preflight checks passed (${avail_mb} MB available)"

# ─── Системный пользователь ───────────────────────────────────────────────────
if ! id -u "${USER_NAME}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin \
          --comment "Marzban Bot Service" "${USER_NAME}"
  log_ok "System user '${USER_NAME}' created"
else
  log "System user '${USER_NAME}' already exists"
fi

# ─── Остановка сервиса ────────────────────────────────────────────────────────
if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
  log "Stopping ${SERVICE}..."
  systemctl stop "${SERVICE}" || true
  for i in $(seq 1 10); do
    if ! systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then break; fi
    sleep 1
    if [[ "$i" -eq 10 ]]; then
      log_warn "Graceful stop timed out — force killing ${SERVICE}"
      systemctl kill --signal=SIGKILL "${SERVICE}" 2>/dev/null || true
    fi
  done
  log_ok "${SERVICE} stopped"
fi

# ─── Резервная копия ──────────────────────────────────────────────────────────
mkdir -p "${BACKUP_DIR}"
if [[ -d "${DIR}" ]]; then
  TS=$(date +%Y%m%d%H%M%S)
  BACKUP_PATH="${BACKUP_DIR}/backup_${TS}"
  cp -a "${DIR}" "${BACKUP_PATH}"
  log_ok "Backup created: ${BACKUP_PATH}"

  # Ротация: оставить MAX_BACKUPS последних бэкапов
  mapfile -t OLD_BACKUPS < <(ls -dt "${BACKUP_DIR}"/backup_* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))
  for old in "${OLD_BACKUPS[@]}"; do
    rm -rf "$old"
    log "Removed old backup: $old"
  done
fi

# ─── Атомарный деплой: подготовка DIR.new ─────────────────────────────────────
rm -rf "${DIR}.new"
mkdir -p "${DIR}.new"

# Восстановить файлы данных из последнего бэкапа
LATEST_BACKUP=$(ls -dt "${BACKUP_DIR}"/backup_* 2>/dev/null | head -n1 || true)
if [[ -n "${LATEST_BACKUP}" ]]; then
  for datafile in allowed_users.json bot_settings.json; do
    if [[ -f "${LATEST_BACKUP}/${datafile}" ]]; then
      cp "${LATEST_BACKUP}/${datafile}" "${DIR}.new/${datafile}"
      log "Restored ${datafile} from backup"
    fi
  done
fi

# ─── Версионный файл ──────────────────────────────────────────────────────────
echo "${DEPLOY_VERSION}" > "${DIR}.new/.version"

# ─── Генерация config.py ──────────────────────────────────────────────────────
tee "${DIR}.new/config.py" > /dev/null << 'PYEOF'
"""Bot configuration — values read from environment variables."""
from __future__ import annotations
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent


def _require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or value == "CHANGE_ME":
        raise RuntimeError(f"Environment variable '{name}' is not set or still set to CHANGE_ME")
    return value


# Telegram
BOT_TOKEN: str = _require("TOKEN")
OWNER_ID: int = int(_require("OWNER_ID"))

# Marzban panel
PANEL_URL: str = _require("PANEL_URL").rstrip("/")
PANEL_USER: str = _require("PANEL_USER")
PANEL_PASS: str = _require("PANEL_PASS")

# Optional
NODE_PREFIX: str = os.environ.get("NODE_PREFIX", "").strip()

# Paths
ALLOWED_USERS_FILE: Path = BASE_DIR / "allowed_users.json"
SETTINGS_FILE: Path = BASE_DIR / "bot_settings.json"
VERSION_FILE: Path = BASE_DIR / ".version"
PYEOF

# ─── Генерация requirements.txt ───────────────────────────────────────────────
tee "${DIR}.new/requirements.txt" > /dev/null << 'REQEOF'
python-telegram-bot==20.8
aiohttp==3.9.5
requests==2.32.3
nest_asyncio==1.6.0
REQEOF

# ─── Генерация marzban.py ─────────────────────────────────────────────────────
tee "${DIR}.new/marzban.py" > /dev/null << 'PYEOF'
"""Marzban panel API client."""
from __future__ import annotations

import asyncio
import logging
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)

_TIMEOUT = aiohttp.ClientTimeout(total=30, connect=10)


class MarzbanAPIError(Exception):
    """Raised on non-2xx responses from the Marzban panel."""


class MarzbanAPI:
    def __init__(self, base_url: str, username: str, password: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._username = username
        self._password = password
        self._token: str | None = None
        self._lock = asyncio.Lock()
        self._session: aiohttp.ClientSession | None = None
        self._own_session = False

    # ── Session management ────────────────────────────────────────────────────
    async def _get_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=_TIMEOUT)
            self._own_session = True
        return self._session

    async def close(self) -> None:
        if self._own_session and self._session and not self._session.closed:
            await self._session.close()
            self._session = None
            self._own_session = False

    async def __aenter__(self) -> "MarzbanAPI":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    # ── Auth ──────────────────────────────────────────────────────────────────
    async def _authenticate(self) -> None:
        async with self._lock:
            session = await self._get_session()
            url = f"{self._base_url}/api/admin/token"
            data = {"username": self._username, "password": self._password}
            async with session.post(url, data=data) as resp:
                if resp.status != 200:
                    text = await resp.text()
                    raise MarzbanAPIError(f"Auth failed ({resp.status}): {text}")
                body = await resp.json()
                self._token = body["access_token"]

    def _auth_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token}"}

    # ── Generic request with retry on 401 ─────────────────────────────────────
    async def _req(
        self,
        method: str,
        path: str,
        *,
        json: Any = None,
        params: dict[str, Any] | None = None,
    ) -> Any:
        if self._token is None:
            await self._authenticate()

        session = await self._get_session()
        url = f"{self._base_url}{path}"

        for attempt in range(2):
            async with session.request(
                method, url, headers=self._auth_headers(), json=json, params=params
            ) as resp:
                if resp.status == 401 and attempt == 0:
                    self._token = None
                    await self._authenticate()
                    continue
                if not (200 <= resp.status < 300):
                    text = await resp.text()
                    raise MarzbanAPIError(f"{method} {path} → {resp.status}: {text}")
                if resp.content_type == "application/json":
                    return await resp.json()
                return await resp.text()
        return None  # unreachable

    # ── Host management ───────────────────────────────────────────────────────
    async def get_hosts(self) -> dict[str, Any]:
        return await self._req("GET", "/api/hosts")

    async def update_all_hosts(self, hosts_payload: dict[str, Any]) -> dict[str, Any]:
        return await self._req("PUT", "/api/hosts", json=hosts_payload)

    # ── User management ───────────────────────────────────────────────────────
    async def create_user(self, username: str, days: int) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "username": username,
            "proxies": {"vless": {}, "vmess": {}},
            "expire": days * 86400,
            "data_limit": 0,
            "data_limit_reset_strategy": "no_reset",
            "status": "active",
            "inbounds": {},
        }
        return await self._req("POST", "/api/user", json=payload)

    async def delete_user(self, username: str) -> None:
        await self._req("DELETE", f"/api/user/{username}")

    async def get_users(self, offset: int = 0, limit: int = 100) -> dict[str, Any]:
        return await self._req(
            "GET", "/api/users", params={"offset": offset, "limit": limit}
        )

    async def get_all_users(self) -> list[dict[str, Any]]:
        all_users: list[dict[str, Any]] = []
        offset = 0
        limit = 100
        while True:
            page = await self.get_users(offset=offset, limit=limit)
            users = page.get("users", [])
            all_users.extend(users)
            if len(users) < limit:
                break
            offset += limit
        return all_users

    # ── Health check ──────────────────────────────────────────────────────────
    async def health(self) -> bool:
        try:
            await self._req("GET", "/api/core")
            return True
        except MarzbanAPIError:
            return False
PYEOF

# ─── Генерация bot.py ─────────────────────────────────────────────────────────
tee "${DIR}.new/bot.py" > /dev/null << 'PYEOF'
"""Marzban Telegram Bot — entry point."""
from __future__ import annotations

import asyncio
import io
import json
import logging
import re
from pathlib import Path
from typing import Any

import nest_asyncio
from telegram import Document, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

import config
from marzban import MarzbanAPI, MarzbanAPIError

nest_asyncio.apply()

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent

# ── Helpers ───────────────────────────────────────────────────────────────────
_IP_RE = re.compile(
    r"^(?:"
    r"(?:\d{1,3}\.){3}\d{1,3}"   # IPv4
    r"|"
    r"(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}"  # hostname
    r")"
    r"(?::\d{1,5})?$"
)


def _load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text()) if path.exists() else default
    except (json.JSONDecodeError, OSError):
        return default


def _save_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def _load_allowed() -> set[int]:
    raw = _load_json(config.ALLOWED_USERS_FILE, [])
    return {int(x) for x in raw}


def _save_allowed(users: set[int]) -> None:
    _save_json(config.ALLOWED_USERS_FILE, sorted(users))


def _load_settings() -> dict[str, Any]:
    return _load_json(config.SETTINGS_FILE, {})


def _save_settings(data: dict[str, Any]) -> None:
    _save_json(config.SETTINGS_FILE, data)


def _version() -> str:
    try:
        return config.VERSION_FILE.read_text().strip()
    except OSError:
        return "unknown"


def _is_allowed(user_id: int) -> bool:
    return user_id == config.OWNER_ID or user_id in _load_allowed()


def looks_like_ip_list(text: str) -> bool:
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    if not lines:
        return False
    return all(_IP_RE.match(l) for l in lines)


# ── Command handlers ──────────────────────────────────────────────────────────
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    await update.message.reply_text(
        f"🤖 *Marzban Bot* v{_version()}\n\n"
        "Доступные команды:\n"
        "/help — справка\n"
        "/update_ips — обновить хосты Marzban\n"
        "/new_user <имя> <дни> — создать пользователя\n"
        "/del [имя] — удалить пользователя или список\n"
        "/status — состояние бота\n"
        "/export — экспорт настроек\n"
        "/import_data — импорт настроек",
        parse_mode=ParseMode.MARKDOWN,
    )


async def cmd_help(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await cmd_start(update, ctx)


async def cmd_update_ips(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id is None or not _is_allowed(user_id):
        await update.message.reply_text("⛔ Нет доступа")
        return

    args = ctx.args or []
    raw = " ".join(args).strip()
    if not raw:
        await update.message.reply_text(
            "Укажите список ip:port, например:\n1.2.3.4:443\n5.6.7.8:8443"
        )
        return

    await _do_update_ips(update, raw)


async def _do_update_ips(update: Update, raw: str) -> None:
    if not update.message:
        return
    lines = [l.strip() for l in raw.splitlines() if l.strip()]
    entries = []
    for line in lines:
        if not _IP_RE.match(line):
            await update.message.reply_text(f"❌ Неверный формат: {line}")
            return
        parts = line.rsplit(":", 1)
        entries.append({"address": parts[0], "port": int(parts[1]) if len(parts) > 1 else 443})

    async with MarzbanAPI(config.PANEL_URL, config.PANEL_USER, config.PANEL_PASS) as api:
        try:
            hosts = await api.get_hosts()
            for inbound_tag, host_list in hosts.items():
                for i, entry in enumerate(entries):
                    if i < len(host_list):
                        host_list[i]["address"] = entry["address"]
                        if entry.get("port"):
                            host_list[i]["port"] = entry["port"]
            await api.update_all_hosts(hosts)
            await update.message.reply_text(f"✅ Обновлено {len(entries)} хостов")
        except MarzbanAPIError as e:
            await update.message.reply_text(f"❌ Ошибка панели: {e}")


async def cmd_new_user(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id is None or not _is_allowed(user_id):
        await update.message.reply_text("⛔ Нет доступа")
        return

    args = ctx.args or []
    if len(args) < 2:
        await update.message.reply_text("Использование: /new_user <имя> <дни>")
        return

    name, days_str = args[0], args[1]
    try:
        days = int(days_str)
    except ValueError:
        await update.message.reply_text("❌ Дни должны быть числом")
        return

    async with MarzbanAPI(config.PANEL_URL, config.PANEL_USER, config.PANEL_PASS) as api:
        try:
            result = await api.create_user(name, days)
            await update.message.reply_text(
                f"✅ Пользователь *{result['username']}* создан на {days} дней",
                parse_mode=ParseMode.MARKDOWN,
            )
        except MarzbanAPIError as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")


async def cmd_del(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id is None or not _is_allowed(user_id):
        await update.message.reply_text("⛔ Нет доступа")
        return

    args = ctx.args or []
    async with MarzbanAPI(config.PANEL_URL, config.PANEL_USER, config.PANEL_PASS) as api:
        if not args:
            try:
                users = await api.get_all_users()
                if not users:
                    await update.message.reply_text("Пользователи не найдены")
                    return
                names = "\n".join(u["username"] for u in users)
                await update.message.reply_text(f"👤 Пользователи:\n{names}")
            except MarzbanAPIError as e:
                await update.message.reply_text(f"❌ Ошибка: {e}")
            return

        name = args[0]
        try:
            await api.delete_user(name)
            await update.message.reply_text(f"✅ Пользователь *{name}* удалён", parse_mode=ParseMode.MARKDOWN)
        except MarzbanAPIError as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")


async def cmd_grant(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    owner_id = config.OWNER_ID
    user_id = update.effective_user.id if update.effective_user else None
    if user_id != owner_id:
        await update.message.reply_text("⛔ Только владелец")
        return

    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /grant <user_id>")
        return

    try:
        target = int(args[0])
    except ValueError:
        await update.message.reply_text("❌ user_id должен быть числом")
        return

    allowed = _load_allowed()
    allowed.add(target)
    _save_allowed(allowed)
    await update.message.reply_text(f"✅ Пользователь {target} добавлен в список разрешённых")


async def cmd_revoke(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    owner_id = config.OWNER_ID
    user_id = update.effective_user.id if update.effective_user else None
    if user_id != owner_id:
        await update.message.reply_text("⛔ Только владелец")
        return

    args = ctx.args or []
    if not args:
        await update.message.reply_text("Использование: /revoke <user_id>")
        return

    try:
        target = int(args[0])
    except ValueError:
        await update.message.reply_text("❌ user_id должен быть числом")
        return

    if target == owner_id:
        await update.message.reply_text("❌ Нельзя удалить владельца")
        return

    allowed = _load_allowed()
    allowed.discard(target)
    _save_allowed(allowed)
    await update.message.reply_text(f"✅ Пользователь {target} удалён из списка разрешённых")


async def cmd_export(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id != config.OWNER_ID:
        await update.message.reply_text("⛔ Только владелец")
        return

    data = {
        "allowed_users": sorted(_load_allowed()),
        "settings": _load_settings(),
        "version": _version(),
    }
    buf = io.BytesIO(json.dumps(data, ensure_ascii=False, indent=2).encode())
    buf.name = "marzban_bot_export.json"
    await update.message.reply_document(document=buf, filename="marzban_bot_export.json")


async def cmd_import_data(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id != config.OWNER_ID:
        await update.message.reply_text("⛔ Только владелец")
        return

    doc: Document | None = None
    if update.message.document:
        doc = update.message.document
    elif update.message.reply_to_message and update.message.reply_to_message.document:
        doc = update.message.reply_to_message.document

    if doc is None:
        await update.message.reply_text("Прикрепите JSON-файл или ответьте на него командой /import_data")
        return

    file = await ctx.bot.get_file(doc.file_id)
    buf = io.BytesIO()
    await file.download_to_memory(buf)
    buf.seek(0)

    try:
        payload = json.loads(buf.read().decode())
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        await update.message.reply_text(f"❌ Неверный JSON: {e}")
        return

    if "allowed_users" in payload:
        _save_allowed({int(x) for x in payload["allowed_users"]})
    if "settings" in payload:
        _save_settings(payload["settings"])

    await update.message.reply_text("✅ Данные успешно импортированы")


async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id is None or not _is_allowed(user_id):
        await update.message.reply_text("⛔ Нет доступа")
        return

    allowed_count = len(_load_allowed())
    ver = _version()

    async with MarzbanAPI(config.PANEL_URL, config.PANEL_USER, config.PANEL_PASS) as api:
        panel_ok = await api.health()

    panel_status = "✅ подключена" if panel_ok else "❌ недоступна"
    files_exist = all(
        (BASE_DIR / f).exists() for f in ["config.py", "marzban.py", "bot.py", "requirements.txt"]
    )

    await update.message.reply_text(
        f"📊 *Статус Marzban Bot*\n\n"
        f"Версия: `{ver}`\n"
        f"Панель: {panel_status}\n"
        f"Разрешённых: {allowed_count}\n"
        f"Файлы: {'✅ OK' if files_exist else '⚠️ не все файлы на месте'}",
        parse_mode=ParseMode.MARKDOWN,
    )


# ── Plain-text IP list handler ────────────────────────────────────────────────
async def handle_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message or not update.message.text:
        return
    user_id = update.effective_user.id if update.effective_user else None
    if user_id is None or not _is_allowed(user_id):
        return
    if looks_like_ip_list(update.message.text):
        await _do_update_ips(update, update.message.text)


# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> None:
    app = (
        Application.builder()
        .token(config.BOT_TOKEN)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("update_ips", cmd_update_ips))
    app.add_handler(CommandHandler("new_user", cmd_new_user))
    app.add_handler(CommandHandler("del", cmd_del))
    app.add_handler(CommandHandler("grant", cmd_grant))
    app.add_handler(CommandHandler("revoke", cmd_revoke))
    app.add_handler(CommandHandler("export", cmd_export))
    app.add_handler(CommandHandler("import_data", cmd_import_data))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))

    logger.info("Starting Marzban Bot v%s", _version())
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYEOF

# ─── Права доступа ────────────────────────────────────────────────────────────
chmod 750 "${DIR}.new"
find "${DIR}.new" -type f -exec chmod 640 {} \;

# ─── Python venv и установка зависимостей ─────────────────────────────────────
log "Creating Python venv..."
python3 -m venv "${DIR}.new/.venv"
sudo -u "${USER_NAME}" "${DIR}.new/.venv/bin/pip" install --quiet --upgrade pip
sudo -u "${USER_NAME}" "${DIR}.new/.venv/bin/pip" install --quiet -r "${DIR}.new/requirements.txt"
log_ok "Python dependencies installed"

# ─── Атомарная замена директорий ──────────────────────────────────────────────
if [[ -d "${DIR}" ]]; then
  mv "${DIR}" "${DIR}.old"
fi
mv "${DIR}.new" "${DIR}"
chown -R "${USER_NAME}:${GROUP_NAME}" "${DIR}"
rm -rf "${DIR}.old" 2>/dev/null || true
log_ok "Directory swap completed: ${DIR}"

# ─── ENV-шаблон ───────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  tee "${ENV_FILE}" > /dev/null << 'ENVEOF'
# Marzban Bot — Environment Configuration
# Заполните все значения CHANGE_ME перед запуском

TOKEN=CHANGE_ME          # Telegram bot token from @BotFather, e.g. 1234567890:ABCdef...
OWNER_ID=CHANGE_ME       # Your Telegram user ID (integer), e.g. 123456789
PANEL_URL=CHANGE_ME      # Marzban panel URL, e.g. https://panel.example.com
PANEL_USER=CHANGE_ME     # Marzban admin username
PANEL_PASS=CHANGE_ME     # Marzban admin password
NODE_PREFIX=CHANGE_ME    # Optional node name prefix (leave empty to skip)
ENVEOF
  chmod 600 "${ENV_FILE}"
  log_ok "ENV template created: ${ENV_FILE} (fill in CHANGE_ME values before starting)"
else
  log "ENV file already exists: ${ENV_FILE}"
fi

# ─── Systemd unit ─────────────────────────────────────────────────────────────
tee "/etc/systemd/system/${SERVICE}.service" > /dev/null << UNITEOF
[Unit]
Description=Marzban Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${DIR}
ExecStart=${DIR}/.venv/bin/python ${DIR}/bot.py
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=300

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
ReadWritePaths=${DIR} /var/log

# Resource limits
MemoryMax=400M
CPUQuota=80%

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE}

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable "${SERVICE}"
log_ok "Systemd unit installed and enabled: ${SERVICE}"

# ─── Запуск (если env заполнен) ───────────────────────────────────────────────
if grep -q "CHANGE_ME" "${ENV_FILE}" 2>/dev/null; then
  log_warn "ENV file still contains CHANGE_ME — skipping service start"
  log_warn "Edit ${ENV_FILE} and run: systemctl start ${SERVICE}"
else
  systemctl start "${SERVICE}"
  log_ok "${SERVICE} started"
fi

DEPLOY_FAILED=0
log_ok "Deploy ${DEPLOY_VERSION} completed successfully"
