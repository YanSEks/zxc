#!/usr/bin/env bash
# ==============================================================================
# Marzban Telegram Bot Deploy Script v4.0.0
# Generates and deploys a fully-featured Marzban VPN panel management bot.
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

LOG_FILE="/var/log/marzban-bot-deploy.log"
if [[ "$DRY_RUN" != "true" ]]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

RED=$(tput setaf 1 2>/dev/null || printf '\033[0;31m')
GREEN=$(tput setaf 2 2>/dev/null || printf '\033[0;32m')
YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[0;33m')
BLUE=$(tput setaf 4 2>/dev/null || printf '\033[0;34m')
BOLD=$(tput bold 2>/dev/null || printf '\033[1m')
RESET=$(tput sgr0 2>/dev/null || printf '\033[0m')

VERSION="4.0.0"
APP_USER="marzbot"
DIR="/opt/marzban_bot"
SERVICE="marzban-bot"
VENV_DIR="$DIR/venv"

# ==============================================================================
# Logging helpers
# ==============================================================================
info()    { printf "%s[INFO]%s  %s\n" "${BLUE}${BOLD}" "${RESET}" "$*"; }
success() { printf "%s[OK]%s    %s\n" "${GREEN}${BOLD}" "${RESET}" "$*"; }
warn()    { printf "%s[WARN]%s  %s\n" "${YELLOW}${BOLD}" "${RESET}" "$*"; }
error()   { printf "%s[ERROR]%s %s\n" "${RED}${BOLD}" "${RESET}" "$*" >&2; }
step()    { printf "\n%s==> %s%s\n" "${BOLD}" "$*" "${RESET}"; }

# ==============================================================================
# Argument parsing
# ==============================================================================
MIGRATE_FILE=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) shift ;;  # Already handled above
        --migrate)
            shift
            MIGRATE_FILE="${1:-}"
            shift || true
            ;;
        --help|-h)
            echo "Использование: $0 [--dry-run] [--migrate <json>]"
            exit 0
            ;;
        *)
            error "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# Preflight checks
# ==============================================================================
preflight() {
    step "Проверка зависимостей"
    local missing=()
    for cmd in python3 pip3 git curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Отсутствующие зависимости: ${missing[*]}"
        exit 1
    fi
    success "Все зависимости найдены"
}

# ==============================================================================
# Setup app user and directories
# ==============================================================================
setup_env() {
    step "Настройка окружения"
    if ! id "$APP_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --home "$DIR" "$APP_USER"
        info "Создан пользователь $APP_USER"
    fi
    mkdir -p "$DIR"
    chown "$APP_USER":"$APP_USER" "$DIR"

    if [[ ! -d "$VENV_DIR" ]]; then
        python3 -m venv "$VENV_DIR"
        info "Создано виртуальное окружение: $VENV_DIR"
    fi
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet aiogram aiohttp pyyaml
    success "Окружение настроено"
}

# ==============================================================================
# Generate marzban.py
# ==============================================================================
generate_marzban_py() {
    step "Генерация marzban.py"
    cat > "$DIR/marzban.py" << 'PYEOF'
"""Marzban API client."""
from __future__ import annotations

import asyncio
import time
from typing import Any

import aiohttp


class MarzbanAPI:
    _RATE_LIMIT = 0.2  # seconds between requests

    def __init__(self, url: str, username: str, password: str) -> None:
        self._url = url.rstrip("/")
        self._username = username
        self._password = password
        self._token: str | None = None
        self._last_request: float = 0.0

    async def _throttle(self) -> None:
        elapsed = time.monotonic() - self._last_request
        if elapsed < self._RATE_LIMIT:
            await asyncio.sleep(self._RATE_LIMIT - elapsed)
        self._last_request = time.monotonic()

    async def _headers(self) -> dict[str, str]:
        if not self._token:
            await self._authenticate()
        return {"Authorization": f"Bearer {self._token}"}

    async def _authenticate(self) -> None:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{self._url}/api/admin/token",
                data={"username": self._username, "password": self._password},
            ) as resp:
                resp.raise_for_status()
                data = await resp.json()
                self._token = data["access_token"]

    async def _request(
        self,
        method: str,
        path: str,
        params: dict | None = None,
        **kwargs: Any,
    ) -> Any:
        await self._throttle()
        for attempt in range(2):
            headers = await self._headers()
            async with aiohttp.ClientSession() as session:
                async with session.request(
                    method,
                    f"{self._url}{path}",
                    headers=headers,
                    params=params,
                    **kwargs,
                ) as resp:
                    if resp.status == 401 and attempt == 0:
                        self._token = None
                        continue
                    resp.raise_for_status()
                    if resp.content_type == "application/json":
                        return await resp.json()
                    return None
        return None

    async def get_users(self) -> list[dict[str, Any]]:
        all_users: list[dict[str, Any]] = []
        offset = 0
        limit = 100
        while True:
            data = await self._request(
                "GET",
                "/api/users",
                params={"offset": offset, "limit": limit},
            )
            users = data.get("users", []) if isinstance(data, dict) else []
            all_users.extend(users)
            if len(users) < limit:
                break
            offset += limit
        return all_users

    async def get_hosts(self) -> dict[str, list[dict[str, Any]]]:
        data = await self._request("GET", "/api/hosts")
        return data if isinstance(data, dict) else {}

    async def update_hosts(self, hosts: dict[str, list[dict[str, Any]]]) -> None:
        await self._request("PUT", "/api/hosts", json=hosts)

    async def get_user(self, username: str) -> dict[str, Any]:
        return await self._request("GET", f"/api/user/{username}")

    async def update_user(self, username: str, data: dict[str, Any]) -> dict[str, Any]:
        return await self._request("PUT", f"/api/user/{username}", json=data)

    async def delete_user(self, username: str) -> None:
        await self._request("DELETE", f"/api/user/{username}")

    async def get_inbounds(self) -> dict[str, Any]:
        data = await self._request("GET", "/api/inbounds")
        return data if isinstance(data, dict) else {}
PYEOF
    chown "$APP_USER":"$APP_USER" "$DIR/marzban.py"
    success "marzban.py создан"
}

# ==============================================================================
# Generate bot.py
# ==============================================================================
generate_bot_py() {
    step "Генерация bot.py"
    cat > "$DIR/bot.py" << 'PYEOF'
"""Marzban Telegram Bot v4.0.0."""
from __future__ import annotations

import asyncio
import json
import os
from typing import Any

from aiogram import Bot, Dispatcher, types
from aiogram.filters import Command

from marzban import MarzbanAPI

BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_IDS = set(map(int, os.environ.get("ADMIN_IDS", "").split(","))) if os.environ.get("ADMIN_IDS") else set()
MARZBAN_URL = os.environ["MARZBAN_URL"]
MARZBAN_USER = os.environ["MARZBAN_USERNAME"]
MARZBAN_PASS = os.environ["MARZBAN_PASSWORD"]

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
api = MarzbanAPI(MARZBAN_URL, MARZBAN_USER, MARZBAN_PASS)

# In-memory state for multi-step operations
_state: dict[int, dict[str, Any]] = {}


# ==============================================================================
# Helpers
# ==============================================================================

def _parse_host(raw: str) -> dict[str, Any]:
    """Parse an IP string into a Marzban host dictionary."""
    if ":" in raw:
        addr, port_str = raw.rsplit(":", 1)
        return {"address": addr, "port": int(port_str)}
    return {"address": raw, "port": 443}


async def _check_admin(update: types.Update) -> bool:
    if not ADMIN_IDS:
        return True
    message = getattr(update, "message", None) or getattr(update, "callback_query", None)
    if message is None:
        return False
    user = getattr(message, "from_user", None)
    if user is None:
        return False
    return user.id in ADMIN_IDS


# ==============================================================================
# Command handlers
# ==============================================================================

@dp.message(Command("start", "help"))
async def cmd_start(update: types.Message) -> None:
    if not await _check_admin(update):
        return
    if not update.message:
        return
    await update.message.answer(
        "🤖 <b>Marzban Bot v4.0.0</b>\n\n"
        "Команды:\n"
        "/users — список пользователей\n"
        "/setip &lt;tag&gt; &lt;ip:port&gt; — обновить IP для инбаунда\n"
        "/setip all &lt;ip:port&gt; — обновить IP для всех инбаундов\n"
        "/migrate &lt;json&gt; — импортировать пользователей из JSON",
        parse_mode="HTML",
    )


@dp.message(Command("users"))
async def cmd_users(update: types.Message) -> None:
    if not await _check_admin(update):
        return
    if not update.message:
        return
    users = await api.get_users()
    if not users:
        await update.message.answer("Пользователей нет.")
        return
    lines = [f"👥 Всего пользователей: {len(users)}\n"]
    for u in users[:20]:
        status = "✅" if u.get("status") == "active" else "❌"
        lines.append(f"{status} {u.get('username', '?')}")
    if len(users) > 20:
        lines.append(f"… и ещё {len(users) - 20}")
    await update.message.answer("\n".join(lines))


@dp.message(Command("setip"))
async def cmd_setip(update: types.Message) -> None:
    if not await _check_admin(update):
        return
    if not update.message:
        return
    args = (update.message.text or "").split()[1:]
    if len(args) < 2:
        await update.message.answer("Использование: /setip <tag|all> <ip[:port]>")
        return
    tag_arg, ip_raw = args[0], args[1]
    chat_id = update.message.chat.id
    _state[chat_id] = {"action": "ip_confirm", "tag": None if tag_arg == "all" else tag_arg, "ip": ip_raw}
    tag_display = "все инбаунды" if tag_arg == "all" else tag_arg
    kb = types.InlineKeyboardMarkup(
        inline_keyboard=[
            [
                types.InlineKeyboardButton(text="✅ Подтвердить", callback_data="ip_confirm"),
                types.InlineKeyboardButton(text="❌ Отмена", callback_data="ip_cancel"),
            ]
        ]
    )
    await update.message.answer(
        f"Установить <code>{ip_raw}</code> для <b>{tag_display}</b>?",
        reply_markup=kb,
        parse_mode="HTML",
    )


@dp.message(Command("migrate"))
async def cmd_migrate(update: types.Message) -> None:
    if not await _check_admin(update):
        return
    if not update.message:
        return
    args = (update.message.text or "").split(maxsplit=1)
    if len(args) < 2:
        await update.message.answer("Использование: /migrate <json>")
        return
    await _handle_migrate(update.message, args[1])


# ==============================================================================
# Callback handler
# ==============================================================================

@dp.callback_query()
async def callback_handler(query: types.CallbackQuery) -> None:
    if not query.message or not query.from_user:
        return
    chat_id = query.message.chat.id
    data = query.data or ""

    if data == "ip_cancel":
        _state.pop(chat_id, None)
        await query.message.edit_text("Отменено.")
        return

    if data == "ip_confirm":
        state = _state.pop(chat_id, None)
        if not state:
            await query.answer("Сессия истекла.")
            return
        tag = state.get("tag")
        ips = [state.get("ip", "")]

        if tag is None:
            # Update all inbounds, preserving existing host settings
            all_hosts = await api.get_hosts()
            for t in all_hosts:
                updated_list = []
                for i, ip in enumerate(ips):
                    host_entry = _parse_host(ip)
                    if i < len(all_hosts[t]):
                        existing = all_hosts[t][i].copy()
                        existing["address"] = host_entry["address"]
                        existing["port"] = host_entry.get("port", existing.get("port", 443))
                        updated_list.append(existing)
                    else:
                        updated_list.append({
                            "address": host_entry["address"],
                            "port": host_entry.get("port", 443),
                            "remark": "",
                        })
                all_hosts[t] = updated_list
            await api.update_hosts(all_hosts)
            await query.message.edit_text("✅ IP обновлён для всех инбаундов.")
        else:
            hosts = await api.get_hosts()
            tag_hosts = hosts.get(tag, [])
            updated_list = []
            for i, ip in enumerate(ips):
                host_entry = _parse_host(ip)
                if i < len(tag_hosts):
                    existing = tag_hosts[i].copy()
                    existing["address"] = host_entry["address"]
                    existing["port"] = host_entry.get("port", existing.get("port", 443))
                    updated_list.append(existing)
                else:
                    updated_list.append({
                        "address": host_entry["address"],
                        "port": host_entry.get("port", 443),
                        "remark": "",
                    })
            hosts[tag] = updated_list
            await api.update_hosts(hosts)
            await query.message.edit_text(f"✅ IP обновлён для инбаунда <b>{tag}</b>.", parse_mode="HTML")

    await query.answer()


# ==============================================================================
# Migration helper
# ==============================================================================

async def _handle_migrate(message: types.Message, json_str: str) -> None:
    try:
        users_data = json.loads(json_str)
    except json.JSONDecodeError as exc:
        await message.answer(f"❌ Невалидный JSON: {exc}")
        return
    if not isinstance(users_data, list):
        await message.answer("❌ JSON должен быть массивом пользователей.")
        return
    ok, fail = 0, 0
    for user in users_data:
        try:
            await api._request("POST", "/api/user", json=user)
            ok += 1
        except Exception:
            fail += 1
    await message.answer(f"✅ Импортировано: {ok}\n❌ Ошибок: {fail}")


# ==============================================================================
# CLI migrate (called from bash --migrate flag)
# ==============================================================================

async def _handle_cli_migrate_async(json_path: str) -> None:
    with open(json_path) as f:
        users_data = json.load(f)
    if not isinstance(users_data, list):
        raise ValueError("JSON должен быть массивом пользователей.")
    ok, fail = 0, 0
    for user in users_data:
        try:
            await api._request("POST", "/api/user", json=user)
            ok += 1
        except Exception:
            fail += 1
    print(f"Импортировано: {ok}, ошибок: {fail}")


# ==============================================================================
# Entry point
# ==============================================================================

async def main() -> None:
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
PYEOF
    chown "$APP_USER":"$APP_USER" "$DIR/bot.py"
    success "bot.py создан"
}

# ==============================================================================
# CLI migrate handler (called from bash before bot starts)
# ==============================================================================
_handle_cli_migrate() {
    local json_file="$1"
    if [[ ! -f "$json_file" ]]; then
        error "Файл не найден: $json_file"
        exit 1
    fi
    info "Запуск миграции из файла: $json_file"
    "$VENV_DIR/bin/python3" - "$json_file" << 'PYEOF'
import sys, asyncio, os
sys.path.insert(0, os.environ.get("BOT_DIR", "/opt/marzban_bot"))
from marzban import MarzbanAPI
import json

async def run(path):
    url  = os.environ["MARZBAN_URL"]
    user = os.environ["MARZBAN_USERNAME"]
    pw   = os.environ["MARZBAN_PASSWORD"]
    api  = MarzbanAPI(url, user, pw)
    with open(path) as f:
        users = json.load(f)
    if not isinstance(users, list):
        raise SystemExit("JSON должен быть массивом.")
    ok, fail = 0, 0
    for u in users:
        try:
            await api._request("POST", "/api/user", json=u)
            ok += 1
        except Exception as e:
            print(f"  FAIL {u.get('username','?')}: {e}", file=sys.stderr)
            fail += 1
    print(f"Импортировано: {ok}, ошибок: {fail}")

asyncio.run(run(sys.argv[1]))
PYEOF
}

# Process --migrate flag after functions are defined
if [[ -n "$MIGRATE_FILE" ]]; then
    _handle_cli_migrate "$MIGRATE_FILE"
    exit 0
fi

# ==============================================================================
# Generate systemd service
# ==============================================================================
generate_service() {
    step "Генерация systemd сервиса"
    cat > "/etc/systemd/system/${SERVICE}.service" << EOF
[Unit]
Description=Marzban Telegram Bot v${VERSION}
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${DIR}
EnvironmentFile=${DIR}/.env
ExecStart=${VENV_DIR}/bin/python3 ${DIR}/bot.py
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    success "Сервис ${SERVICE} зарегистрирован"
}

# ==============================================================================
# Configure environment file
# ==============================================================================
configure_env() {
    step "Настройка .env файла"
    local env_file="$DIR/.env"
    if [[ -f "$env_file" ]]; then
        warn ".env уже существует, пропускаем создание"
        return
    fi
    cat > "$env_file" << 'EOF'
BOT_TOKEN=your_telegram_bot_token_here
ADMIN_IDS=123456789
MARZBAN_URL=https://your-marzban-panel.example.com
MARZBAN_USERNAME=admin
MARZBAN_PASSWORD=your_password_here
EOF
    chmod 600 "$env_file"
    chown "$APP_USER":"$APP_USER" "$env_file"
    warn "Заполните $env_file перед запуском сервиса"
    success ".env создан"
}

# ==============================================================================
# Enable and start service
# ==============================================================================
enable_service() {
    step "Запуск сервиса ${SERVICE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Пропускаем запуск сервиса"
        return
    fi
    systemctl enable --now "$SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SERVICE"; then
        success "Сервис ${SERVICE} запущен успешно"
    else
        warn "Сервис не запустился. Проверьте: journalctl -u ${SERVICE} -n 50"
    fi
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo "${BOLD}${BLUE}Marzban Telegram Bot Deploy Script v${VERSION}${RESET}"
    echo "$(date)"
    echo ""

    if [[ "$EUID" -ne 0 ]] && [[ "$DRY_RUN" != "true" ]]; then
        error "Запустите скрипт от root или с sudo"
        exit 1
    fi

    preflight
    setup_env
    generate_marzban_py
    generate_bot_py
    configure_env
    generate_service
    enable_service

    echo ""
    success "Деплой завершён! Версия: ${VERSION}"
    info "Логи: journalctl -u ${SERVICE} -f"
    info "Конфигурация: ${DIR}/.env"
}

main
