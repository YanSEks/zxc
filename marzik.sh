#!/usr/bin/env bash
# ==============================================================================
# Marzban Telegram Bot Deploy Script v4.0.2 (fully fixed)
# Generates and deploys a fully-featured Marzban VPN panel management bot.
#
# Changelog vs v4.0.0 / v4.0.1:
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
VERSION="4.0.2"
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

dry_run_exec() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    "$@"
  fi
}

# ==== CLI: --migrate ====
do_migrate() {
  local src="$1"
  [[ -f "$src" ]] || { error "File not found: $src"; exit 1; }
  info "Migrating config from: $src"
  # shellcheck source=/dev/null
  source "$src"
  success "Migration source loaded."
}

# ==== Argument parsing (fix #1: while/shift) ====
MIGRATE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --migrate)
      [[ $# -ge 2 ]] || { error "--migrate requires a filename argument"; exit 1; }
      MIGRATE_FILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--migrate <env-file>]"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--migrate <env-file>]"
      exit 1
      ;;
  esac
done

if [[ -n "$MIGRATE_FILE" ]]; then
  do_migrate "$MIGRATE_FILE"
fi

# ==== Banner ====
echo ""
echo "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${BLUE}║   Marzban Bot Deployer  v${VERSION}            ║${RESET}"
echo "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${RESET}"
echo ""

# ==== Root check (fix #12: use $0) ====
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Try: sudo $0 $*"
  exit 1
fi

# ==== Python version check (fix #15) ====
check_python_version() {
  local py_bin="$1"
  local ver
  ver=$("$py_bin" -c 'import sys; print(sys.version_info[:2])' 2>/dev/null) || return 1
  local major minor
  major=$("$py_bin" -c 'import sys; print(sys.version_info.major)' 2>/dev/null)
  minor=$("$py_bin" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)
  if [[ "$major" -gt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -ge 10 ]]; }; then
    return 0
  fi
  return 1
}

PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" &>/dev/null && check_python_version "$candidate"; then
    PYTHON_BIN="$candidate"
    break
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  error "Python 3.10+ is required but not found. Please install Python 3.10 or newer."
  exit 1
fi
success "Using Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

# ==== System packages ====
info "Updating package lists..."
dry_run_exec apt-get update -qq

PACKAGES=(python3-venv python3-pip git curl)
for pkg in "${PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    info "Installing $pkg..."
    dry_run_exec apt-get install -y -qq "$pkg"
  else
    success "$pkg already installed"
  fi
done

# ==== Stop existing service ====
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  info "Stopping existing service $SERVICE..."
  dry_run_exec systemctl stop "$SERVICE"
fi

# ==== User / directory setup ====
if ! id "$APP_USER" &>/dev/null; then
  info "Creating system user: $APP_USER"
  dry_run_exec useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi

info "Creating app directory: $DIR"
dry_run_exec mkdir -p "$DIR"
dry_run_exec chown "$APP_USER:$APP_USER" "$DIR"

# ==== Configuration collection ====
read_value() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local value

  if [[ -n "${!var_name:-}" ]]; then
    info "$prompt [using migrated value]"
    return
  fi

  if [[ -n "$default" ]]; then
    read -rp "${BLUE}${prompt}${RESET} [${default}]: " value
    value="${value:-$default}"
  else
    read -rp "${BLUE}${prompt}${RESET}: " value
    while [[ -z "$value" ]]; do
      warn "This field is required."
      read -rp "${BLUE}${prompt}${RESET}: " value
    done
  fi
  printf -v "$var_name" '%s' "$value"
}

read_value BOT_TOKEN  "Telegram Bot Token"
read_value ADMIN_IDS  "Admin Telegram IDs (comma-separated)"
read_value MARZBAN_URL "Marzban Panel URL (e.g. https://panel.example.com)"
read_value MARZBAN_USER "Marzban Admin Username"
read_value MARZBAN_PASS "Marzban Admin Password"
read_value INBOUND_TAGS "Default inbound tags (comma-separated, e.g. vless,vmess)" "vless"

# ==== .env creation (fix #2: umask subshell, fix #3: printf) ====
info "Writing .env file..."
if [[ "$DRY_RUN" != "true" ]]; then
  (
    umask 077
    {
      printf 'BOT_TOKEN=%s\n'     "$BOT_TOKEN"
      printf 'ADMIN_IDS=%s\n'     "$ADMIN_IDS"
      printf 'MARZBAN_URL=%s\n'   "$MARZBAN_URL"
      printf 'MARZBAN_USER=%s\n'  "$MARZBAN_USER"
      printf 'MARZBAN_PASS=%s\n'  "$MARZBAN_PASS"
      printf 'INBOUND_TAGS=%s\n'  "$INBOUND_TAGS"
    } > "$DIR/.env"
  )
  chown "$APP_USER:$APP_USER" "$DIR/.env"
fi
success ".env written"

# ==== requirements.txt (fix #16: chmod 644) ====
info "Writing requirements.txt..."
cat > "$DIR/requirements.txt" << 'REQS'
python-telegram-bot==20.7
aiohttp==3.9.3
python-dotenv==1.0.1
REQS
chmod 644 "$DIR/requirements.txt"
chown "$APP_USER:$APP_USER" "$DIR/requirements.txt"
success "requirements.txt written"

# ==== config.py (fix #10: __future__, fix #16: chmod) ====
info "Writing config.py..."
cat > "$DIR/config.py" << 'PYEOF'
from __future__ import annotations
# ==== config.py ====
import os
from dotenv import load_dotenv

load_dotenv()

BOT_TOKEN: str = os.environ["BOT_TOKEN"]
ADMIN_IDS: list[int] = [int(x.strip()) for x in os.environ["ADMIN_IDS"].split(",") if x.strip()]
MARZBAN_URL: str = os.environ["MARZBAN_URL"].rstrip("/")
MARZBAN_USER: str = os.environ["MARZBAN_USER"]
MARZBAN_PASS: str = os.environ["MARZBAN_PASS"]
INBOUND_TAGS: list[str] = [t.strip() for t in os.environ.get("INBOUND_TAGS", "vless").split(",") if t.strip()]
PYEOF
chmod 640 "$DIR/config.py"
chown "$APP_USER:$APP_USER" "$DIR/config.py"
success "config.py written"

# ==== marzban.py (fix #4, #5, #8, #16) ====
info "Writing marzban.py..."
cat > "$DIR/marzban.py" << 'PYEOF'
from __future__ import annotations
# ==== marzban.py ====
import datetime
import aiohttp
from typing import Any, Optional

class MarzbanAPI:
    def __init__(self, base_url: str, username: str, password: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._username = username
        self._password = password
        self._token: Optional[str] = None
        # fix #5: single session reused across requests
        # fix #8: aiohttp timeouts
        self._timeout = aiohttp.ClientTimeout(total=30, connect=10)
        self._session: Optional[aiohttp.ClientSession] = None

    def _get_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=self._timeout)
        return self._session

    async def close(self) -> None:
        """Close the underlying aiohttp session."""
        if self._session and not self._session.closed:
            await self._session.close()
            self._session = None

    async def login(self) -> None:
        session = self._get_session()
        url = f"{self._base_url}/api/admin/token"
        data = {"username": self._username, "password": self._password}
        async with session.post(url, data=data) as resp:
            resp.raise_for_status()
            body = await resp.json()
        self._token = body["access_token"]

    async def _request(
        self,
        method: str,
        path: str,
        *,
        json: Any = None,
        params: Any = None,
        _retry: bool = True,
    ) -> Any:
        # fix #4: token auto-refresh on 401
        if self._token is None:
            await self.login()
        session = self._get_session()
        headers = {"Authorization": f"Bearer {self._token}"}
        url = f"{self._base_url}{path}"
        async with session.request(method, url, headers=headers, json=json, params=params) as resp:
            if resp.status == 401 and _retry:
                # Token expired — refresh and retry once
                self._token = None
                await self.login()
                return await self._request(method, path, json=json, params=params, _retry=False)
            resp.raise_for_status()
            if resp.content_type == "application/json":
                return await resp.json()
            return await resp.text()

    # ---- Public API methods ----

    async def get_inbounds(self) -> dict[str, Any]:
        return await self._request("GET", "/api/inbounds")

    async def get_user(self, username: str) -> dict[str, Any]:
        return await self._request("GET", f"/api/user/{username}")

    async def create_user(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("POST", "/api/user", json=payload)

    async def delete_user(self, username: str) -> Any:
        return await self._request("DELETE", f"/api/user/{username}")

    async def update_user(self, username: str, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("PUT", f"/api/user/{username}", json=payload)

    async def get_users(self, *, offset: int = 0, limit: int = 100) -> dict[str, Any]:
        return await self._request("GET", "/api/users", params={"offset": offset, "limit": limit})

    async def get_system_stats(self) -> dict[str, Any]:
        return await self._request("GET", "/api/system")
PYEOF
chmod 640 "$DIR/marzban.py"
chown "$APP_USER:$APP_USER" "$DIR/marzban.py"
success "marzban.py written"

# ==== bot.py (fix #6, #7, #9, #13, #14, #17, #16) ====
info "Writing bot.py..."
cat > "$DIR/bot.py" << 'PYEOF'
from __future__ import annotations
# ==== bot.py ====
import datetime
import re
import logging
from typing import Optional

from telegram import (
    Update,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
)
from telegram.ext import (
    Application,
    CommandHandler,
    CallbackQueryHandler,
    MessageHandler,
    ContextTypes,
    filters,
)

import config
from marzban import MarzbanAPI

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# fix #6: IP/host regex with port <= 65535 validated in _parse_host
_IP_RE = re.compile(
    r"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)"
    r"(?::\d{1,5})?\b"
    r"|"
    r"\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?::\d{1,5})?\b"
)

api = MarzbanAPI(config.MARZBAN_URL, config.MARZBAN_USER, config.MARZBAN_PASS)


def _is_admin(user_id: int) -> bool:
    return user_id in config.ADMIN_IDS


def _admin_only(func):
    import functools

    @functools.wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        if update.effective_user and not _is_admin(update.effective_user.id):
            await update.effective_message.reply_text("⛔ Access denied.")
            return
        return await func(update, context)

    return wrapper


# fix #14: _parse_host with try/except ValueError for port
def _parse_host(text: str) -> Optional[tuple[str, int]]:
    """Parse 'host:port' or 'host', returning (host, port) or None."""
    text = text.strip()
    if ":" in text:
        host, _, port_str = text.rpartition(":")
        try:
            port = int(port_str)
        except ValueError:
            return None
        # fix #6: port range validation
        if port < 1 or port > 65535:
            return None
        return host, port
    return text, 443


# fix #13: callback_data must be <= 64 bytes
def _cb(data: str) -> str:
    encoded = data.encode("utf-8")
    if len(encoded) > 64:
        return encoded[:64].decode("utf-8", errors="ignore")
    return data


@_admin_only
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    text = (
        "🤖 *Marzban Bot* ready.\n\n"
        "Commands:\n"
        "/new\\_user – Create user\n"
        "/del – Delete user\n"
        "/user\\_info – User details\n"
        "/extend – Extend expiry\n"
        "/disable – Disable user\n"
        "/enable – Enable user\n"
        "/inbounds – List inbounds\n"
        "/update\\_ips – Update user IPs\n"
        "/stats – System stats\n"
    )
    await update.effective_message.reply_text(text, parse_mode="Markdown")


@_admin_only
async def cmd_new_user(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /new_user <username> <days> <gb>"""
    args = context.args or []
    if len(args) < 3:
        await update.effective_message.reply_text("Usage: /new_user <username> <days> <gb>")
        return

    username = args[0]
    # fix #9: try/except ValueError for days/gb
    try:
        days = int(args[1])
        gb = float(args[2])
    except ValueError:
        await update.effective_message.reply_text("❌ <days> and <gb> must be numbers.")
        return

    # fix #17: timezone-aware datetime
    expire_ts = int(
        (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)).timestamp()
    )
    data_limit = int(gb * 1024 ** 3)

    proxies: dict = {}
    for tag in config.INBOUND_TAGS:
        proxies[tag] = {}

    payload = {
        "username": username,
        "proxies": proxies,
        "data_limit": data_limit,
        "expire": expire_ts,
        "data_limit_reset_strategy": "no_reset",
        "status": "active",
    }
    try:
        result = await api.create_user(payload)
        links = "\n".join(result.get("links", []))
        await update.effective_message.reply_text(
            f"✅ User *{username}* created.\n\n{links}", parse_mode="Markdown"
        )
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_del(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /del <username>"""
    args = context.args or []
    if not args:
        await update.effective_message.reply_text("Usage: /del <username>")
        return
    username = args[0]
    try:
        await api.delete_user(username)
        await update.effective_message.reply_text(f"🗑 User *{username}* deleted.", parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    pending = context.user_data.get("pending_delete")
    if not pending:
        await update.effective_message.reply_text("No pending action.")
        return
    username = pending
    context.user_data.pop("pending_delete", None)
    try:
        await api.delete_user(username)
        await update.effective_message.reply_text(f"🗑 User *{username}* deleted.", parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    context.user_data.clear()
    await update.effective_message.reply_text("❎ Cancelled.")


@_admin_only
async def cmd_inbounds(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        inbounds = await api.get_inbounds()
        lines = []
        for tag, entries in inbounds.items():
            lines.append(f"*{tag}*")
            for entry in entries if isinstance(entries, list) else [entries]:
                host = entry.get("host") or entry.get("address", "?")
                port = entry.get("port", "?")
                lines.append(f"  • {host}:{port}")
        text = "\n".join(lines) or "No inbounds found."
        await update.effective_message.reply_text(text, parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_update_ips(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Start flow to update IPs for an inbound tag."""
    args = context.args or []
    if not args:
        # Show tag selection keyboard
        buttons = [
            [InlineKeyboardButton(tag, callback_data=_cb(f"ip_sel:tag:{tag}"))]
            for tag in config.INBOUND_TAGS
        ]
        await update.effective_message.reply_text(
            "Select inbound tag to update IPs:",
            reply_markup=InlineKeyboardMarkup(buttons),
        )
        return
    tag = args[0]
    context.user_data["pending_ip_update_tag"] = tag
    await update.effective_message.reply_text(
        f"Send new IP/host list for *{tag}* (one per line, host:port):", parse_mode="Markdown"
    )


@_admin_only
async def cmd_user_info(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /user_info <username>"""
    args = context.args or []
    if not args:
        await update.effective_message.reply_text("Usage: /user_info <username>")
        return
    username = args[0]
    try:
        user = await api.get_user(username)
        # fix #17: timezone-aware
        expire = user.get("expire")
        if expire:
            expire_dt = datetime.datetime.fromtimestamp(expire, tz=datetime.timezone.utc)
            expire_str = expire_dt.strftime("%Y-%m-%d %H:%M UTC")
        else:
            expire_str = "Never"
        used = user.get("used_traffic", 0) or 0
        limit = user.get("data_limit", 0) or 0
        status = user.get("status", "?")
        text = (
            f"👤 *{username}*\n"
            f"Status: {status}\n"
            f"Expires: {expire_str}\n"
            f"Traffic: {used / 1024**3:.2f} GB / {limit / 1024**3:.2f} GB"
        )
        await update.effective_message.reply_text(text, parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_extend(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /extend <username> <days>"""
    args = context.args or []
    if len(args) < 2:
        await update.effective_message.reply_text("Usage: /extend <username> <days>")
        return
    username = args[0]
    try:
        days = int(args[1])
    except ValueError:
        await update.effective_message.reply_text("❌ <days> must be a number.")
        return
    try:
        user = await api.get_user(username)
        current_expire = user.get("expire") or 0
        # fix #17: timezone-aware base time
        now_ts = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
        base = max(current_expire, now_ts)
        new_expire = base + days * 86400
        await api.update_user(username, {"expire": new_expire})
        expire_dt = datetime.datetime.fromtimestamp(new_expire, tz=datetime.timezone.utc)
        await update.effective_message.reply_text(
            f"✅ *{username}* extended to {expire_dt.strftime('%Y-%m-%d %H:%M UTC')}.",
            parse_mode="Markdown",
        )
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_disable(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /disable <username>"""
    args = context.args or []
    if not args:
        await update.effective_message.reply_text("Usage: /disable <username>")
        return
    username = args[0]
    try:
        await api.update_user(username, {"status": "disabled"})
        await update.effective_message.reply_text(f"⏸ User *{username}* disabled.", parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_enable(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Usage: /enable <username>"""
    args = context.args or []
    if not args:
        await update.effective_message.reply_text("Usage: /enable <username>")
        return
    username = args[0]
    try:
        await api.update_user(username, {"status": "active"})
        await update.effective_message.reply_text(f"▶️ User *{username}* enabled.", parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


@_admin_only
async def cmd_stats(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        stats = await api.get_system_stats()
        mem_total = stats.get("mem_total", 0) or 0
        mem_used = stats.get("mem_used", 0) or 0
        cpu = stats.get("cpu_usage", 0) or 0
        users_active = stats.get("users_active", 0) or 0
        text = (
            f"📊 *System Stats*\n"
            f"CPU: {cpu:.1f}%\n"
            f"RAM: {mem_used / 1024**2:.0f} MB / {mem_total / 1024**2:.0f} MB\n"
            f"Active users: {users_active}"
        )
        await update.effective_message.reply_text(text, parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


# fix #7: handle_ip_list only fires when pending flow is active
async def handle_ip_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.effective_user or not _is_admin(update.effective_user.id):
        return
    # fix #7: gate on pending flow
    tag = context.user_data.get("pending_ip_update_tag")
    if not tag:
        return

    text = update.effective_message.text or ""
    hosts = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parsed = _parse_host(line)
        if parsed is None:
            await update.effective_message.reply_text(f"⚠️ Invalid host/port: {line!r}. Aborting.")
            return
        hosts.append(parsed)

    if not hosts:
        await update.effective_message.reply_text("No valid hosts found.")
        return

    context.user_data.pop("pending_ip_update_tag", None)
    try:
        inbounds = await api.get_inbounds()
        tag_inbounds = inbounds.get(tag, [])
        if not isinstance(tag_inbounds, list):
            tag_inbounds = [tag_inbounds]
        updated = 0
        for entry in tag_inbounds:
            if hosts:
                host, port = hosts[updated % len(hosts)]
                await api._request(
                    "PUT",
                    f"/api/inbound/{entry.get('id', '')}",
                    json={"host": host, "port": port},
                )
                updated += 1
        await update.effective_message.reply_text(f"✅ Updated {updated} inbound(s) for tag *{tag}*.", parse_mode="Markdown")
    except Exception as exc:
        await update.effective_message.reply_text(f"❌ Error: {exc}")


async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    data = query.data or ""
    if data.startswith("ip_sel:tag:"):
        tag = data[len("ip_sel:tag:"):]
        if not update.effective_user or not _is_admin(update.effective_user.id):
            return
        context.user_data["pending_ip_update_tag"] = tag
        await query.edit_message_text(
            f"Send new IP/host list for *{tag}* (one per line, host:port):", parse_mode="Markdown"
        )


async def post_init(application: Application) -> None:
    logger.info("Bot started, performing API login check...")
    try:
        await api.login()
        logger.info("Marzban API login OK.")
    except Exception as exc:
        logger.warning(f"Marzban API login failed at startup: {exc}")


async def post_shutdown(application: Application) -> None:
    logger.info("Bot shutting down, closing API session...")
    await api.close()


def main() -> None:
    app = (
        Application.builder()
        .token(config.BOT_TOKEN)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
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
    # fix #7: text handler only fires when pending flow is active (gated inside handle_ip_list)
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_ip_list))
    app.add_handler(CallbackQueryHandler(callback_handler))

    logger.info("Starting polling...")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
PYEOF
chmod 640 "$DIR/bot.py"
chown "$APP_USER:$APP_USER" "$DIR/bot.py"
success "bot.py written"

# ==== venv setup ====
info "Creating Python virtual environment..."
dry_run_exec "$PYTHON_BIN" -m venv "$VENV_DIR"
dry_run_exec chown -R "$APP_USER:$APP_USER" "$VENV_DIR"

info "Installing Python packages..."
dry_run_exec "$VENV_DIR/bin/pip" install --quiet --upgrade pip
dry_run_exec "$VENV_DIR/bin/pip" install --quiet -r "$DIR/requirements.txt"
success "Python packages installed"

# ==== Verify Python version in venv (fix #15: post-install check) ====
if [[ "$DRY_RUN" != "true" ]]; then
  venv_py="$VENV_DIR/bin/python"
  if ! check_python_version "$venv_py"; then
    error "Venv Python does not meet >= 3.10 requirement."
    exit 1
  fi
  success "Venv Python version OK: $($venv_py --version)"
fi

# ==== systemd service ====
info "Writing systemd service unit..."
cat > "/etc/systemd/system/${SERVICE}.service" << SVCEOF
[Unit]
Description=Marzban Telegram Bot
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${DIR}
EnvironmentFile=${DIR}/.env
ExecStart=${VENV_DIR}/bin/python ${DIR}/bot.py
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

dry_run_exec systemctl daemon-reload
dry_run_exec systemctl enable "$SERVICE"
success "systemd service configured"

# ==== Start service ====
info "Starting $SERVICE..."
dry_run_exec systemctl start "$SERVICE"

# fix #11: sleep gated by dry-run
if [[ "$DRY_RUN" != "true" ]]; then
  sleep 3
fi

# ==== Healthcheck ====
info "Checking service health..."
if [[ "$DRY_RUN" == "true" ]]; then
  warn "Dry-run mode: skipping healthcheck"
elif systemctl is-active --quiet "$SERVICE"; then
  success "Service $SERVICE is running."
else
  error "Service $SERVICE failed to start. Check logs: journalctl -u $SERVICE -n 50"
  exit 1
fi

# ==== Summary ====
echo ""
echo "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${GREEN}║     Deployment Complete! v${VERSION}        ║${RESET}"
echo "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
info "App directory : $DIR"
info "Service name  : $SERVICE"
info "Log file      : $LOG_FILE"
info "Manage with   : systemctl {start|stop|restart|status} $SERVICE"
info "View logs     : journalctl -u $SERVICE -f"
echo ""
success "All done! 🎉"
