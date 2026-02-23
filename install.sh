#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Cloudflare Scanner v17.1 — installer
###############################################################################

INSTALL_DIR="${CFSCANNER_INSTALL_DIR:-/opt/cfscanner}"
SERVICE_NAME="cfscanner"
GO_VERSION="1.22.5"
VERSION="17.1"
GEOIP_URL="https://raw.githubusercontent.com/sapics/ip-location-db/main/geo-whois-asn-country/geo-whois-asn-country-ipv4.csv"
MASSCAN_REPO="https://github.com/robertdavidgraham/masscan"

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m' CYAN='\033[0;36m' NC='\033[0m'

# ─── banner ──────────────────────────────────────────────────────────────────
show_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
   ___  _____   ____
  / __\/ ____\ / ___|  ___ __ _ _ __  _ __   ___ _ __
 / /  |  _|   \___ \ / __/ _` | '_ \| '_ \ / _ \ '__|
/ /___| |___   ___) | (_| (_| | | | | | | |  __/ |
\____/|_____| |____/ \___\__,_|_| |_|_| |_|\___|_|

          v17.1  —  Cloudflare IP Range Scanner
BANNER
    echo -e "${NC}"
}

# ─── root check ──────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERR] Run as root (sudo bash install.sh)${NC}" >&2
        exit 1
    fi
}

# ─── architecture detection ──────────────────────────────────────────────────
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv6l)  ARCH="armv6l" ;;
        *)
            echo -e "${RED}[ERR] Unsupported architecture: $machine${NC}" >&2
            exit 1
            ;;
    esac
    echo -e "${GREEN}[OK]${NC} Architecture: ${ARCH}"
}

# ─── OS check ────────────────────────────────────────────────────────────────
check_os() {
    if ! command -v apt-get &>/dev/null; then
        echo -e "${RED}[ERR] Only Debian/Ubuntu are supported${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} OS: $(lsb_release -ds 2>/dev/null || grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
}

# ─── system info / auto-tune ─────────────────────────────────────────────────
get_system_info() {
    local total_kb cores
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    cores=$(nproc)
    local ram_gb=$(( total_kb / 1024 / 1024 ))

    if   (( total_kb < 1048576 )); then
        WORKERS=100;  RATE=10000
    elif (( total_kb < 2097152 )); then
        WORKERS=250;  RATE=20000
    elif (( total_kb < 4194304 )); then
        WORKERS=500;  RATE=50000
    else
        WORKERS=$(( cores * 200 ))
        RATE=$(( cores * 25000 ))
    fi

    (( WORKERS > 2000  )) && WORKERS=2000
    (( RATE    > 500000)) && RATE=500000

    MEM_LIMIT=$(( total_kb * 80 / 100 / 1024 ))   # 80 % of RAM in MiB
    echo -e "${GREEN}[OK]${NC} RAM: ${ram_gb}GB  Cores: ${cores}  Workers: ${WORKERS}  Rate: ${RATE}"
}

# ─── input validation ────────────────────────────────────────────────────────
validate_token() {
    local t="$1"
    [[ "$t" =~ ^[0-9]{8,10}:[A-Za-z0-9_-]{35,}$ ]]
}

validate_admin_id() {
    local id="$1"
    [[ "$id" =~ ^[0-9]{5,12}$ ]]
}

# ─── interactive credentials prompt ──────────────────────────────────────────
get_credentials() {
    echo -e "\n${YELLOW}=== Конфигурация бота ===${NC}"

    while true; do
        read -rp "Telegram Bot Token: " SCANNER_TOKEN
        validate_token "$SCANNER_TOKEN" && break
        echo -e "${RED}[ERR] Неверный формат токена${NC}"
    done

    while true; do
        read -rp "Admin Telegram ID: " ADMIN_ID
        validate_admin_id "$ADMIN_ID" && break
        echo -e "${RED}[ERR] Неверный формат ID${NC}"
    done

    read -rp "VLESS Config (vless://... или пусто): " VLESS_CONFIG
    VLESS_CONFIG="${VLESS_CONFIG:-}"
}

# ─── stop old service, preserve GeoIP ────────────────────────────────────────
cleanup_old() {
    echo -e "${BLUE}[>>]${NC} Очистка старой установки..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    if [[ -d "$INSTALL_DIR/data" ]]; then
        mkdir -p /tmp/cfscanner_cache
        cp -a "$INSTALL_DIR/data/." /tmp/cfscanner_cache/ 2>/dev/null || true
    fi

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"/{data,tmp}

    if [[ -d /tmp/cfscanner_cache ]]; then
        cp -a /tmp/cfscanner_cache/. "$INSTALL_DIR/data/" 2>/dev/null || true
        rm -rf /tmp/cfscanner_cache
    fi
}

# ─── apt dependencies + masscan ──────────────────────────────────────────────
install_dependencies() {
    echo -e "${BLUE}[>>]${NC} Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq \
        curl wget git build-essential libpcap-dev \
        unzip ca-certificates gnupg lsb-release \
        >/dev/null 2>&1

    if ! command -v masscan &>/dev/null; then
        echo -e "${BLUE}[>>]${NC} Сборка masscan из исходников..."
        local tmpdir
        tmpdir=$(mktemp -d)
        git clone --depth 1 "$MASSCAN_REPO" "$tmpdir/masscan" >/dev/null 2>&1
        make -C "$tmpdir/masscan" -j"$(nproc)" >/dev/null 2>&1
        cp "$tmpdir/masscan/bin/masscan" /usr/local/bin/masscan
        rm -rf "$tmpdir"
    fi
    echo -e "${GREEN}[OK]${NC} masscan: $(masscan --version 2>&1 | head -1)"
}

# ─── Go installation ─────────────────────────────────────────────────────────
install_go() {
    if command -v go &>/dev/null; then
        local current
        current=$(go version | awk '{print $3}' | tr -d 'go')
        if [[ "$current" == "$GO_VERSION" ]]; then
            echo -e "${GREEN}[OK]${NC} Go ${GO_VERSION} уже установлен"
            return
        fi
    fi

    echo -e "${BLUE}[>>]${NC} Установка Go ${GO_VERSION}..."
    local go_arch="$ARCH"
    [[ "$ARCH" == "armv6l" ]] && go_arch="armv6l"

    local tarball="go${GO_VERSION}.linux-${go_arch}.tar.gz"
    wget -q "https://go.dev/dl/${tarball}" -O "/tmp/${tarball}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"

    export PATH="/usr/local/go/bin:$PATH"
    echo -e "${GREEN}[OK]${NC} Go $(go version)"
}

# ─── sysctl tuning ───────────────────────────────────────────────────────────
optimize_system() {
    echo -e "${BLUE}[>>]${NC} Оптимизация сетевых параметров..."
    sysctl -w net.core.rmem_max=134217728        >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=134217728        >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" >/dev/null 2>&1 || true
    sysctl -w net.core.somaxconn=65535           >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fin_timeout=15        >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_tw_reuse=1            >/dev/null 2>&1 || true
    ulimit -n 1048576 2>/dev/null || true

    cat > /etc/sysctl.d/99-cfscanner.conf << SYSCTL
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.somaxconn=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
SYSCTL
    sysctl --system >/dev/null 2>&1 || true
}

# ─── GeoIP download (7-day cache) ────────────────────────────────────────────
download_geoip() {
    local dest="$INSTALL_DIR/data/geoip.csv"
    if [[ -f "$dest" ]]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$dest") ))
        if (( age < 604800 )); then
            echo -e "${GREEN}[OK]${NC} GeoIP кэш актуален ($(( age/3600 ))ч)"
            return
        fi
    fi
    echo -e "${BLUE}[>>]${NC} Загрузка GeoIP базы..."
    wget -q "$GEOIP_URL" -O "$dest"
    echo -e "${GREEN}[OK]${NC} GeoIP загружен: $(wc -l < "$dest") записей"
}

# ─── generate go.mod + main.go ───────────────────────────────────────────────
generate_code() {
    echo -e "${BLUE}[>>]${NC} Генерация Go кода..."
    cd "$INSTALL_DIR"

    cat << 'GOMOD' > go.mod
module cfscanner

go 1.22

require (
	golang.org/x/net v0.26.0
	gopkg.in/telebot.v3 v3.3.6
)
GOMOD

    cat << 'GOCODE' > main.go
package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/http2"
	tele "gopkg.in/telebot.v3"
)

var Version = "17.1"

// ─── Config ──────────────────────────────────────────────────────────────────

type Config struct {
	BotToken     string
	AdminID      int64
	VLESSConfig  string
	MasscanRate  int
	MasscanPorts string
	Workers      int
	TCPTimeout   time.Duration
	HTTPTimeout  time.Duration
	VLESSTimeout time.Duration
	DataDir      string
	TmpDir       string
	TLSSkipVerify bool
}

var cfg Config

// ─── VLESS config ─────────────────────────────────────────────────────────────

type vlessConfig struct {
	UUID         string
	SNI          string
	Host         string
	Path         string
	Type         string
	Security     string
	Fingerprint  string
	ALPN         string
	OriginalIP   string
	OriginalPort int
	Enabled      bool
}

var vless vlessConfig

// ─── Regions ─────────────────────────────────────────────────────────────────

var regions = map[string][]string{
	"EU": {
		"DE", "FR", "GB", "NL", "PL", "SE", "NO", "FI", "DK", "AT",
		"BE", "CH", "CZ", "SK", "HU", "RO", "BG", "HR", "SI", "RS",
		"PT", "ES", "IT", "GR", "IE", "LT", "LV", "EE",
	},
	"CIS": {
		"RU", "UA", "BY", "KZ", "UZ", "AZ", "GE", "AM", "MD", "KG",
		"TJ", "TM",
	},
	"ASIA": {
		"CN", "JP", "KR", "IN", "SG", "HK", "TW", "TH", "VN", "MY",
		"ID", "PH", "PK", "BD", "MM", "KH", "LA", "MN",
	},
	"AMERICAS": {
		"US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "VE",
	},
	"FAST": {
		"DE", "NL", "FR", "GB", "SE", "NO", "FI", "CH",
		"SG", "JP", "KR", "HK",
		"US", "CA",
	},
}

// ─── Types ───────────────────────────────────────────────────────────────────

type OpenPort struct {
	IP   string
	Port int
}

type Result struct {
	IP        string
	Country   string
	Config    string
	Error     string
	Port      int
	CFLatency int64
	VLESSLat  int64
	VLESSWork bool
}

// ─── ScanState ───────────────────────────────────────────────────────────────

type ScanState struct {
	mu          sync.Mutex
	results     []Result
	openPorts   []OpenPort
	stopped     int32
	resultsSent int32
	total       int64
	checked     int64
	found       int64
	startTime   time.Time
	msgID       int
	chatID      int64
	targetDesc  string
	countries   []string
	withVLESS   bool
}

var scan = ScanState{stopped: 1}

var (
	bot       *tele.Bot
	transport *http.Transport
)

// ─── init ────────────────────────────────────────────────────────────────────

func init() {
	cfg = Config{
		MasscanRate:  30000,
		MasscanPorts: "443,2053,2083,2087,2096,8443",
		Workers:      300,
		TCPTimeout:   500 * time.Millisecond,
		HTTPTimeout:  3 * time.Second,
		VLESSTimeout: 8 * time.Second,
		DataDir:      "/opt/cfscanner/data",
		TmpDir:       "/opt/cfscanner/tmp",
		TLSSkipVerify: true,
	}

	cfg.BotToken = os.Getenv("SCANNER_TOKEN")
	cfg.AdminID, _ = strconv.ParseInt(os.Getenv("ADMIN_ID"), 10, 64)
	cfg.VLESSConfig = os.Getenv("VLESS_CONFIG")

	if os.Getenv("TLS_SKIP_VERIFY") == "false" {
		cfg.TLSSkipVerify = false
	}

	if v := os.Getenv("MASSCAN_RATE"); v != "" {
		if r, err := strconv.Atoi(v); err == nil {
			cfg.MasscanRate = r
		}
	}
	if v := os.Getenv("WORKERS"); v != "" {
		if w, err := strconv.Atoi(v); err == nil {
			cfg.Workers = w
		}
	}

	parseVLESSConfig()
}

// ─── parseVLESSConfig ────────────────────────────────────────────────────────

func parseVLESSConfig() {
	raw := strings.TrimSpace(cfg.VLESSConfig)
	if raw == "" || !strings.HasPrefix(raw, "vless://") {
		return
	}

	u, err := url.Parse(raw)
	if err != nil {
		log.Printf("VLESS parse error: %v", err)
		return
	}

	vless.UUID = u.User.Username()
	vless.OriginalIP = u.Hostname()
	if p, err2 := strconv.Atoi(u.Port()); err2 == nil {
		vless.OriginalPort = p
	}

	q := u.Query()
	vless.Type = q.Get("type")
	vless.Security = q.Get("security")
	vless.SNI = q.Get("sni")
	vless.Fingerprint = q.Get("fp")
	vless.ALPN = q.Get("alpn")

	if h, err2 := url.QueryUnescape(q.Get("host")); err2 == nil && h != "" {
		vless.Host = h
	} else {
		vless.Host = q.Get("host")
	}
	if p, err2 := url.QueryUnescape(q.Get("path")); err2 == nil && p != "" {
		vless.Path = p
	} else {
		vless.Path = q.Get("path")
		if vless.Path == "" {
			vless.Path = "/"
		}
	}

	vless.Enabled = vless.UUID != "" && vless.OriginalIP != ""
}

// ─── main ────────────────────────────────────────────────────────────────────

func main() {
	debug.SetGCPercent(30)
	memLimit := int64(1800 << 20)
	if v := os.Getenv("MEM_LIMIT_MB"); v != "" {
		if mb, err := strconv.Atoi(v); err == nil && mb > 0 {
			memLimit = int64(mb) << 20
		}
	}
	debug.SetMemoryLimit(memLimit)

	log.Printf("CF Scanner v%s starting...", Version)

	if err := loadGeoIP(); err != nil {
		log.Printf("GeoIP load warning: %v", err)
	}

	initTransport()

	if cfg.BotToken == "" {
		log.Fatal("SCANNER_TOKEN not set")
	}

	var err error
	bot, err = tele.NewBot(tele.Settings{
		Token:  cfg.BotToken,
		Poller: &tele.LongPoller{Timeout: 10 * time.Second},
	})
	if err != nil {
		log.Fatalf("Bot init error: %v", err)
	}

	bot.Handle("/start", cmdStart)
	bot.Handle("/help", cmdStart)
	bot.Handle("/stop", cmdStop)
	bot.Handle("/status", cmdStatus)
	bot.Handle("/test", cmdTest)
	bot.Handle("/config", cmdConfig)
	bot.Handle(tele.OnText, handleText)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		bot.Stop()
		os.Exit(0)
	}()

	log.Printf("Bot started (admin=%d)", cfg.AdminID)
	bot.Start()
}

// ─── initTransport ───────────────────────────────────────────────────────────

func initTransport() {
	transport = &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: cfg.TLSSkipVerify}, // #nosec G402
		MaxIdleConns:    1000,
		MaxIdleConnsPerHost: 100,
		DisableKeepAlives:   false,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: 5 * time.Second,
		DialContext: (&net.Dialer{
			Timeout:   cfg.TCPTimeout,
			KeepAlive: 0,
		}).DialContext,
	}
	_ = http2.ConfigureTransport(transport)
}

// ─── isAdmin ─────────────────────────────────────────────────────────────────

func isAdmin(c tele.Context) bool {
	return c.Sender().ID == cfg.AdminID
}

// ─── cmdStart ────────────────────────────────────────────────────────────────

func cmdStart(c tele.Context) error {
	if !isAdmin(c) {
		return c.Send("⛔ Доступ запрещён")
	}
	vlessStatus := "❌ не настроен"
	if vless.Enabled {
		vlessStatus = fmt.Sprintf("✅ %s:%d", vless.OriginalIP, vless.OriginalPort)
	}
	msg := fmt.Sprintf(`🔍 <b>CF Scanner v%s</b>

⚙️ <b>Настройки:</b>
• Workers: <code>%d</code>
• Rate: <code>%d</code> pps
• Ports: <code>%s</code>
• VLESS: %s

📡 <b>Регионы:</b>
• <code>EU</code> — Европа (28 стран)
• <code>CIS</code> — СНГ (12 стран)
• <code>ASIA</code> — Азия (18 стран)
• <code>AMERICAS</code> — Америка (9 стран)
• <code>FAST</code> — Быстрые ноды

📝 <b>Примеры:</b>
• <code>AS13335</code> — скан ASN
• <code>AS13335 +vless</code> — с проверкой VLESS
• <code>1.1.1.0/24</code> — скан CIDR
• <code>EU DE FR</code> — регион + страны
• <code>FAST +vless</code> — быстрые + VLESS

ℹ️ Команды: /status /stop /test /config`,
		Version, cfg.Workers, cfg.MasscanRate, cfg.MasscanPorts, vlessStatus)
	return c.Send(msg, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

// ─── cmdConfig ───────────────────────────────────────────────────────────────

func cmdConfig(c tele.Context) error {
	if !isAdmin(c) {
		return c.Send("⛔ Доступ запрещён")
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	msg := fmt.Sprintf(`⚙️ <b>Конфигурация</b>

• Version: <code>%s</code>
• Workers: <code>%d</code>
• Rate: <code>%d</code>
• Ports: <code>%s</code>
• TCP timeout: <code>%v</code>
• HTTP timeout: <code>%v</code>
• VLESS timeout: <code>%v</code>
• VLESS: <code>%v</code>
• Data dir: <code>%s</code>

💾 <b>Память:</b>
• Alloc: <code>%s</code>
• Sys: <code>%s</code>
• GC cycles: <code>%d</code>`,
		Version,
		cfg.Workers, cfg.MasscanRate, cfg.MasscanPorts,
		cfg.TCPTimeout, cfg.HTTPTimeout, cfg.VLESSTimeout,
		vless.Enabled,
		cfg.DataDir,
		formatBytes(ms.Alloc), formatBytes(ms.Sys), ms.NumGC)
	return c.Send(msg, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

func formatBytes(b uint64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(b)/(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(b)/(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

// ─── cmdTest ─────────────────────────────────────────────────────────────────

func cmdTest(c tele.Context) error {
	if !isAdmin(c) {
		return c.Send("⛔ Доступ запрещён")
	}
	if !vless.Enabled {
		return c.Send("❌ VLESS не настроен")
	}
	_ = c.Send("🔄 Тестирование VLESS соединения...")
	start := time.Now()
	err := checkVLESS(vless.OriginalIP, vless.OriginalPort)
	latency := time.Since(start)
	if err != nil {
		return c.Send(fmt.Sprintf("❌ VLESS тест провален: %v\nВремя: %v", err, latency))
	}
	return c.Send(fmt.Sprintf("✅ VLESS работает!\nЛатентность: %v", latency))
}

// ─── cmdStop ─────────────────────────────────────────────────────────────────

func cmdStop(c tele.Context) error {
	if !isAdmin(c) {
		return c.Send("⛔ Доступ запрещён")
	}
	if atomic.LoadInt32(&scan.stopped) == 1 {
		return c.Send("ℹ️ Сканирование не активно")
	}
	_ = c.Send("⏹ Останавливаем сканирование...")
	forceStop()
	return nil
}

// ─── cmdStatus ───────────────────────────────────────────────────────────────

func cmdStatus(c tele.Context) error {
	if !isAdmin(c) {
		return c.Send("⛔ Доступ запрещён")
	}
	if atomic.LoadInt32(&scan.stopped) == 1 {
		return c.Send("💤 Сканирование не активно")
	}
	checked := atomic.LoadInt64(&scan.checked)
	total := atomic.LoadInt64(&scan.total)
	found := atomic.LoadInt64(&scan.found)
	elapsed := time.Since(scan.startTime)
	speed := float64(checked) / elapsed.Seconds()

	msg := fmt.Sprintf(`📊 <b>Статус сканирования</b>

🎯 Цель: <code>%s</code>
📈 Прогресс: <code>%s/%s</code> (%.1f%%)
✅ Найдено CF: <code>%s</code>
⚡ Скорость: <code>%.0f IP/s</code>
⏱ Время: <code>%v</code>`,
		scan.targetDesc,
		formatNumber(checked), formatNumber(total),
		progressPct(checked, total),
		formatNumber(found),
		speed,
		elapsed.Round(time.Second))
	return c.Send(msg, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

func progressPct(done, total int64) float64 {
	if total == 0 {
		return 0
	}
	return float64(done) / float64(total) * 100
}

// ─── handleText ──────────────────────────────────────────────────────────────

func handleText(c tele.Context) error {
	if !isAdmin(c) {
		return nil
	}
	text := strings.TrimSpace(c.Text())
	if text == "" {
		return nil
	}

	if atomic.LoadInt32(&scan.stopped) == 0 {
		return c.Send("⚠️ Сканирование уже запущено. Используйте /stop для остановки.")
	}

	parts := strings.Fields(text)
	withVLESS := false
	var targets []string
	var countries []string

	for _, p := range parts {
		if p == "+vless" {
			withVLESS = true
			continue
		}
		up := strings.ToUpper(p)
		if _, ok := regions[up]; ok {
			for _, cc := range regions[up] {
				countries = append(countries, cc)
			}
			targets = append(targets, up)
			continue
		}
		if len(p) == 2 && isUpperAlpha(p) {
			countries = append(countries, up)
			targets = append(targets, up)
			continue
		}
		targets = append(targets, p)
	}

	countries = uniqueStrings(countries)

	if len(targets) == 0 {
		return c.Send("❌ Укажите цель: ASN (AS13335), CIDR (1.1.1.0/24) или регион (EU, CIS, ASIA, AMERICAS, FAST)")
	}

	targetDesc := strings.Join(targets, " ")
	if withVLESS {
		targetDesc += " +vless"
	}

	msg, err := c.Bot().Send(c.Recipient(),
		fmt.Sprintf("🚀 Запуск сканирования: <code>%s</code>", targetDesc),
		&tele.SendOptions{ParseMode: tele.ModeHTML})
	if err != nil {
		return err
	}

	scan = ScanState{
		stopped:    0,
		startTime:  time.Now(),
		chatID:     c.Chat().ID,
		msgID:      msg.ID,
		targetDesc: targetDesc,
		countries:  countries,
		withVLESS:  withVLESS,
	}

	go runScan(targets, countries, withVLESS)
	return nil
}

func isUpperAlpha(s string) bool {
	for _, r := range s {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

// ─── runScan ─────────────────────────────────────────────────────────────────

func runScan(targets, countries []string, withVLESS bool) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("runScan panic: %v", r)
		}
		atomic.StoreInt32(&scan.stopped, 1)
	}()

	// Resolve CIDRs
	var cidrs []string
	for _, t := range targets {
		if strings.HasPrefix(strings.ToUpper(t), "AS") {
			fetched, err := fetchASN(t)
			if err != nil {
				log.Printf("ASN fetch error %s: %v", t, err)
				continue
			}
			cidrs = append(cidrs, fetched...)
		} else if strings.Contains(t, "/") {
			cidrs = append(cidrs, t)
		} else if _, ok := regions[strings.ToUpper(t)]; ok {
			continue
		} else if len(t) == 2 {
			continue
		} else {
			cidrs = append(cidrs, t+"/32")
		}
	}

	if len(cidrs) == 0 {
		// country/region only scan — use known Cloudflare ranges
		cidrs = []string{
			"103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
			"104.16.0.0/13", "104.24.0.0/14", "108.162.192.0/18",
			"131.0.72.0/22", "141.101.64.0/18", "162.158.0.0/15",
			"172.64.0.0/13", "173.245.48.0/20", "188.114.96.0/20",
			"190.93.240.0/20", "197.234.240.0/22", "198.41.128.0/17",
		}
	}

	total := countCIDRIPs(cidrs)
	atomic.StoreInt64(&scan.total, total)

	if total == 0 {
		sendMsg("❌ Нет IP адресов для сканирования")
		return
	}

	// Write targets file
	targetsFile := filepath.Join(cfg.TmpDir, "targets.txt")
	f, err := os.Create(targetsFile)
	if err != nil {
		log.Printf("targets file error: %v", err)
		return
	}
	for _, cidr := range cidrs {
		fmt.Fprintln(f, cidr)
	}
	f.Close()

	// Run masscan
	outputFile := filepath.Join(cfg.TmpDir, "masscan.json")
	os.Remove(outputFile)

	masscanArgs := []string{
		"--rate", strconv.Itoa(cfg.MasscanRate),
		"-p", cfg.MasscanPorts,
		"-iL", targetsFile,
		"-oJ", outputFile,
		"--open",
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, "masscan", masscanArgs...)
	if err := cmd.Start(); err != nil {
		log.Printf("masscan start error: %v", err)
		sendMsg("❌ Ошибка запуска masscan: " + err.Error())
		return
	}

	// Show progress immediately on scan start
	updateProgress()

	// Progress ticker
	ticker := time.NewTicker(12 * time.Second)
	defer ticker.Stop()
	done := make(chan struct{})

	var cmdErr error
	go func() {
		defer close(done)
		cmdErr = cmd.Wait()
	}()

	waitLoop:
	for {
		select {
		case <-done:
			break waitLoop
		case <-ticker.C:
			if atomic.LoadInt32(&scan.stopped) == 1 {
				cancel()
				break waitLoop
			}
			updateProgress()
		}
	}

	if cmdErr != nil && atomic.LoadInt32(&scan.stopped) == 0 {
		log.Printf("masscan error: %v", cmdErr)
		sendMsg("⚠️ masscan завершился с ошибкой: " + cmdErr.Error())
	}

	if atomic.LoadInt32(&scan.stopped) == 1 {
		_ = exec.Command("pkill", "-f", "masscan").Run()
		sendResults()
		return
	}

	// Parse masscan results
	scan.openPorts = parseMasscan(outputFile, countries)

	// Reset counters for worker-phase progress
	atomic.StoreInt64(&scan.total, int64(len(scan.openPorts)))
	atomic.StoreInt64(&scan.checked, 0)
	updateProgress()

	// Check workers
	wc := cfg.Workers
	if withVLESS && vless.Enabled {
		wc /= 3
	}
	if wc < 1 {
		wc = 1
	}

	semaphore := make(chan struct{}, wc)
	resultsCh := make(chan Result, len(scan.openPorts)+1)

	// Ticker for progress updates during worker phase
	workerTicker := time.NewTicker(5 * time.Second)
	workerDone := make(chan struct{})
	go func() {
		defer workerTicker.Stop()
		for {
			select {
			case <-workerTicker.C:
				if atomic.LoadInt32(&scan.stopped) == 1 {
					return
				}
				updateProgress()
			case <-workerDone:
				return
			}
		}
	}()

	var wg sync.WaitGroup
	defer close(workerDone)
	for _, op := range scan.openPorts {
		if atomic.LoadInt32(&scan.stopped) == 1 {
			break
		}
		semaphore <- struct{}{}
		wg.Add(1)
		go func(op OpenPort) {
			defer wg.Done()
			defer func() { <-semaphore }()
			r := checkWorker(op, withVLESS)
			atomic.AddInt64(&scan.checked, 1)
			if r != nil {
				atomic.AddInt64(&scan.found, 1)
				resultsCh <- *r
			}
		}(op)
	}

	wg.Wait()
	close(resultsCh)

	for r := range resultsCh {
		scan.mu.Lock()
		scan.results = append(scan.results, r)
		scan.mu.Unlock()
	}

	sort.Slice(scan.results, func(i, j int) bool {
		return scan.results[i].CFLatency < scan.results[j].CFLatency
	})

	sendResults()
}

// ─── checkWorker ─────────────────────────────────────────────────────────────

func checkWorker(op OpenPort, withVLESS bool) *Result {
	client := &http.Client{
		Transport: transport,
		Timeout:   cfg.HTTPTimeout,
		// No CheckRedirect — allow default redirect behavior
	}

	addr := fmt.Sprintf("%s:%d", op.IP, op.Port)
	reqURL := fmt.Sprintf("https://%s/cdn-cgi/trace", addr)
	req, err := http.NewRequest("GET", reqURL, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Host", "cloudflare.com")
	req.Host = "cloudflare.com"

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	cfLatency := time.Since(start).Milliseconds()
	defer resp.Body.Close()

	limited := io.LimitReader(resp.Body, 4096)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil
	}
	bodyStr := string(body)

	if !strings.Contains(bodyStr, "cloudflare") {
		return nil
	}

	country := getCountry(op.IP)

	r := &Result{
		IP:        op.IP,
		Country:   country,
		Port:      op.Port,
		CFLatency: cfLatency,
	}

	if withVLESS && vless.Enabled {
		vStart := time.Now()
		err := checkVLESS(op.IP, op.Port)
		r.VLESSLat = time.Since(vStart).Milliseconds()
		r.VLESSWork = err == nil
		if err == nil {
			r.Config = genVLESSConfig(op.IP, op.Port)
		}
	}

	return r
}

// ─── checkVLESS ──────────────────────────────────────────────────────────────

func checkVLESS(ip string, port int) error {
	addr := fmt.Sprintf("%s:%d", ip, port)
	tlsCfg := &tls.Config{
		ServerName:         vless.SNI,
		InsecureSkipVerify: true, // #nosec G402
		MinVersion:         tls.VersionTLS12,
	}
	if vless.ALPN != "" {
		tlsCfg.NextProtos = strings.Split(vless.ALPN, ",")
	}

	dialer := &net.Dialer{Timeout: cfg.VLESSTimeout}
	conn, err := tls.DialWithDialer(dialer, "tcp", addr, tlsCfg)
	if err != nil {
		return fmt.Errorf("TLS dial: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(cfg.VLESSTimeout))

	// WebSocket upgrade
	wsKey := make([]byte, 16)
	_, _ = rand.Read(wsKey)
	wsKeyB64 := base64.StdEncoding.EncodeToString(wsKey)

	host := vless.Host
	if host == "" {
		host = vless.SNI
	}
	path := vless.Path
	if path == "" {
		path = "/"
	}

	wsReq := fmt.Sprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path, host, wsKeyB64)

	_, err = conn.Write([]byte(wsReq))
	if err != nil {
		return fmt.Errorf("WS upgrade write: %w", err)
	}

	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil {
		return fmt.Errorf("WS upgrade read: %w", err)
	}
	if !strings.Contains(string(buf[:n]), "101") {
		return fmt.Errorf("WS upgrade failed: %s", string(buf[:n])[:min(100, n)])
	}

	// VLESS request
	vlessReq, err := buildVLESSRequest("google.com", 80)
	if err != nil {
		return fmt.Errorf("build VLESS: %w", err)
	}

	frame, err := writeWSFrame(vlessReq)
	if err != nil {
		return fmt.Errorf("WS frame: %w", err)
	}

	_, err = conn.Write(frame)
	if err != nil {
		return fmt.Errorf("VLESS send: %w", err)
	}

	// HTTP GET through tunnel
	httpReq := "GET /generate_204 HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n"
	httpFrame, _ := writeWSFrame([]byte(httpReq))
	_, err = conn.Write(httpFrame)
	if err != nil {
		return fmt.Errorf("HTTP send: %w", err)
	}

	resp := make([]byte, 4096)
	n, err = conn.Read(resp)
	if err != nil {
		return fmt.Errorf("VLESS recv: %w", err)
	}

	// Parse WebSocket frame header
	payload := resp[:n]
	if len(payload) < 2 {
		return fmt.Errorf("response too short")
	}
	payloadLen := int(payload[1] & 0x7F)
	headerLen := 2
	if payloadLen == 126 {
		if len(payload) < 4 {
			return fmt.Errorf("response too short for extended payload length")
		}
		headerLen = 4
	} else if payloadLen == 127 {
		if len(payload) < 10 {
			return fmt.Errorf("response too short for extended payload length")
		}
		headerLen = 10
	}
	if payload[1]&0x80 != 0 {
		headerLen += 4
	}
	if len(payload) < headerLen {
		return fmt.Errorf("response too short for frame header")
	}
	if len(payload) > headerLen {
		payload = payload[headerLen:]
	}
	if !strings.Contains(string(payload), "204") && !strings.Contains(string(payload), "HTTP") {
		return fmt.Errorf("unexpected response")
	}

	return nil
}

// ─── parseUUID ───────────────────────────────────────────────────────────────

func parseUUID(uuidStr string) ([16]byte, error) {
	var u [16]byte
	clean := strings.ReplaceAll(uuidStr, "-", "")
	if len(clean) != 32 {
		return u, fmt.Errorf("invalid UUID length")
	}
	b, err := hex.DecodeString(clean)
	if err != nil {
		return u, err
	}
	copy(u[:], b)
	return u, nil
}

// ─── buildVLESSRequest ───────────────────────────────────────────────────────

func buildVLESSRequest(destHost string, destPort uint16) ([]byte, error) {
	uuid, err := parseUUID(vless.UUID)
	if err != nil {
		return nil, err
	}

	var buf bytes.Buffer
	buf.WriteByte(0)          // version
	buf.Write(uuid[:])        // UUID
	buf.WriteByte(0)          // addons length
	buf.WriteByte(1)          // command: TCP
	binary.Write(&buf, binary.BigEndian, destPort) // #nosec G104
	buf.WriteByte(2)          // address type: domain
	buf.WriteByte(byte(len(destHost)))
	buf.WriteString(destHost)

	return buf.Bytes(), nil
}

// ─── writeWSFrame ────────────────────────────────────────────────────────────

func writeWSFrame(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte(0x82) // binary, FIN

	maskKey := make([]byte, 4)
	_, _ = rand.Read(maskKey)

	l := len(data)
	switch {
	case l < 126:
		buf.WriteByte(byte(l) | 0x80)
	case l < 65536:
		buf.WriteByte(126 | 0x80)
		b := make([]byte, 2)
		binary.BigEndian.PutUint16(b, uint16(l))
		buf.Write(b)
	default:
		buf.WriteByte(127 | 0x80)
		b := make([]byte, 8)
		binary.BigEndian.PutUint64(b, uint64(l))
		buf.Write(b)
	}

	buf.Write(maskKey)
	masked := make([]byte, l)
	for i, b := range data {
		masked[i] = b ^ maskKey[i%4]
	}
	buf.Write(masked)
	return buf.Bytes(), nil
}

// ─── genVLESSConfig ──────────────────────────────────────────────────────────

func genVLESSConfig(ip string, port int) string {
	params := url.Values{}
	params.Set("type", vless.Type)
	params.Set("security", vless.Security)
	if vless.SNI != "" {
		params.Set("sni", vless.SNI)
	}
	if vless.Fingerprint != "" {
		params.Set("fp", vless.Fingerprint)
	}
	if vless.Host != "" {
		params.Set("host", vless.Host)
	}
	if vless.Path != "" {
		params.Set("path", vless.Path)
	}
	if vless.ALPN != "" {
		params.Set("alpn", vless.ALPN)
	}

	return fmt.Sprintf("vless://%s@%s:%d?%s#CF-%s-%d",
		vless.UUID, ip, port, params.Encode(), ip, port)
}

// ─── formatProgress ──────────────────────────────────────────────────────────

func formatProgress() string {
	checked := atomic.LoadInt64(&scan.checked)
	total := atomic.LoadInt64(&scan.total)
	found := atomic.LoadInt64(&scan.found)
	elapsed := time.Since(scan.startTime)
	speed := float64(0)
	if elapsed.Seconds() > 0 {
		speed = float64(checked) / elapsed.Seconds()
	}
	var eta string
	if speed > 0 && total > checked {
		remaining := float64(total-checked) / speed
		eta = time.Duration(remaining * float64(time.Second)).Round(time.Second).String()
	} else {
		eta = "—"
	}

	bar := progressBar(checked, total, 20)

	return fmt.Sprintf(`🔄 <b>Сканирование</b>

🎯 Цель: <code>%s</code>
%s

📊 <code>%s / %s</code> (%.1f%%)
✅ Найдено CF: <code>%s</code>
⚡ Скорость: <code>%.0f IP/s</code>
⏱ Прошло: <code>%v</code>
⏳ Осталось: <code>%s</code>`,
		scan.targetDesc,
		bar,
		formatNumber(checked), formatNumber(total),
		progressPct(checked, total),
		formatNumber(found),
		speed,
		elapsed.Round(time.Second),
		eta)
}

// ─── progressBar ─────────────────────────────────────────────────────────────

func progressBar(done, total int64, width int) string {
	if total == 0 {
		return "[" + strings.Repeat("░", width) + "]"
	}
	filled := int(float64(done) / float64(total) * float64(width))
	if filled > width {
		filled = width
	}
	return "[" + strings.Repeat("█", filled) + strings.Repeat("░", width-filled) + "]"
}

// ─── formatNumber ────────────────────────────────────────────────────────────

func formatNumber(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fK", float64(n)/1_000)
	default:
		return strconv.FormatInt(n, 10)
	}
}

// ─── boolEmoji ───────────────────────────────────────────────────────────────

func boolEmoji(b bool) string {
	if b {
		return "✅"
	}
	return "❌"
}

// ─── safeEdit ────────────────────────────────────────────────────────────────

func safeEdit(chatID int64, msgID int, text string) {
	if bot == nil {
		return
	}
	msg := &tele.Message{ID: msgID, Chat: &tele.Chat{ID: chatID}}
	_, _ = bot.Edit(msg, text, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

func sendMsg(text string) {
	if bot == nil {
		return
	}
	recipient := tele.ChatID(scan.chatID)
	_, _ = bot.Send(recipient, text, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

// ─── updateProgress ──────────────────────────────────────────────────────────

func updateProgress() {
	safeEdit(scan.chatID, scan.msgID, formatProgress())
}

// ─── sendResults ─────────────────────────────────────────────────────────────

func sendResults() {
	if !atomic.CompareAndSwapInt32(&scan.resultsSent, 0, 1) {
		return
	}

	scan.mu.Lock()
	results := make([]Result, len(scan.results))
	copy(results, scan.results)
	scan.mu.Unlock()

	if len(results) == 0 {
		sendMsg("🔍 Сканирование завершено. Cloudflare IP не найдено.")
		return
	}

	// Build message with top 10
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("✅ <b>Сканирование завершено</b>\n\nНайдено: <code>%d</code> IP\n\n", len(results)))
	sb.WriteString("<b>Топ-10:</b>\n")
	limit := 10
	if len(results) < limit {
		limit = len(results)
	}
	for i, r := range results[:limit] {
		line := fmt.Sprintf("%d. <code>%s:%d</code> %s %dms",
			i+1, r.IP, r.Port, r.Country, r.CFLatency)
		if r.VLESSWork {
			line += " ✅VLESS"
		}
		sb.WriteString(line + "\n")
	}

	// Build ZIP
	zipPath := filepath.Join(cfg.TmpDir, "results.zip")
	if err := buildResultsZip(zipPath, results); err != nil {
		log.Printf("ZIP error: %v", err)
		sendMsg(sb.String())
		return
	}
	defer os.Remove(zipPath)

	recipient := tele.ChatID(scan.chatID)
	doc := &tele.Document{
		File:     tele.FromDisk(zipPath),
		FileName: "cf_results.zip",
		Caption:  sb.String(),
	}
	_, _ = bot.Send(recipient, doc, &tele.SendOptions{ParseMode: tele.ModeHTML})
}

func buildResultsZip(zipPath string, results []Result) error {
	zf, err := os.Create(zipPath)
	if err != nil {
		return err
	}
	defer zf.Close()

	zw := zip.NewWriter(zf)
	defer zw.Close()

	// report.txt
	if w, err := zw.Create("report.txt"); err == nil {
		fmt.Fprintf(w, "CF Scanner v%s — Report\n", Version)
		fmt.Fprintf(w, "Generated: %s\n", time.Now().Format(time.RFC3339))
		fmt.Fprintf(w, "Total: %d\n\n", len(results))
		for i, r := range results {
			fmt.Fprintf(w, "%d. %s:%d [%s] CF:%dms", i+1, r.IP, r.Port, r.Country, r.CFLatency)
			if r.VLESSWork {
				fmt.Fprintf(w, " VLESS:%dms", r.VLESSLat)
			}
			fmt.Fprintln(w)
		}
	}

	// vless_configs.txt
	if w, err := zw.Create("vless_configs.txt"); err == nil {
		for _, r := range results {
			if r.Config != "" {
				fmt.Fprintln(w, r.Config)
			}
		}
	}

	// results.csv
	if w, err := zw.Create("results.csv"); err == nil {
		fmt.Fprintln(w, "ip,port,country,cf_latency_ms,vless_latency_ms,vless_ok,config")
		for _, r := range results {
			fmt.Fprintf(w, "%s,%d,%s,%d,%d,%v,%s\n",
				r.IP, r.Port, r.Country, r.CFLatency, r.VLESSLat,
				r.VLESSWork, r.Config)
		}
	}

	return nil
}

// ─── parseMasscan ────────────────────────────────────────────────────────────

func parseMasscan(path string, countries []string) []OpenPort {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var ports []OpenPort
	seen := make(map[string]bool)

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.Contains(line, `"ip"`) {
			continue
		}

		var entry struct {
			IP    string `json:"ip"`
			Ports []struct {
				Port  int    `json:"port"`
				Proto string `json:"proto"`
			} `json:"ports"`
		}
		if err := json.Unmarshal([]byte(strings.TrimRight(line, ",")), &entry); err != nil {
			continue
		}

		if len(countries) > 0 {
			cc := getCountry(entry.IP)
			if !inSlice(cc, countries) {
				continue
			}
		}

		for _, p := range entry.Ports {
			key := fmt.Sprintf("%s:%d", entry.IP, p.Port)
			if seen[key] {
				continue
			}
			seen[key] = true
			ports = append(ports, OpenPort{IP: entry.IP, Port: p.Port})
		}
	}
	return ports
}

// ─── countCIDRIPs ────────────────────────────────────────────────────────────

func countCIDRIPs(cidrs []string) int64 {
	var total int64
	for _, cidr := range cidrs {
		if !strings.Contains(cidr, "/") {
			total++
			continue
		}
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			continue
		}
		ones, bits := network.Mask.Size()
		total += 1 << uint(bits-ones)
	}
	return total
}

// ─── fetchASN ────────────────────────────────────────────────────────────────

func fetchASN(asn string) ([]string, error) {
	asn = strings.TrimPrefix(strings.ToUpper(asn), "AS")

	apiURL := fmt.Sprintf("https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS%s", asn)
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(apiURL) // #nosec G107
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Data struct {
			Prefixes []struct {
				Prefix string `json:"prefix"`
			} `json:"prefixes"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	var cidrs []string
	for _, p := range result.Data.Prefixes {
		if !strings.Contains(p.Prefix, ":") { // skip IPv6
			cidrs = append(cidrs, p.Prefix)
		}
	}
	return cidrs, nil
}

// ─── GeoIP ───────────────────────────────────────────────────────────────────

type geoEntry struct {
	start uint32
	end   uint32
	cc    string
}

var (
	geoMu      sync.RWMutex
	geoEntries []geoEntry
)

func loadGeoIP() error {
	path := filepath.Join(cfg.DataDir, "geoip.csv")
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	var entries []geoEntry
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, ",")
		if len(parts) < 3 {
			continue
		}
		start, err1 := strconv.ParseUint(strings.TrimSpace(parts[0]), 10, 32)
		end, err2 := strconv.ParseUint(strings.TrimSpace(parts[1]), 10, 32)
		cc := strings.TrimSpace(parts[2])
		if err1 != nil || err2 != nil || cc == "" {
			continue
		}
		entries = append(entries, geoEntry{uint32(start), uint32(end), cc})
	}

	geoMu.Lock()
	geoEntries = entries
	geoMu.Unlock()
	log.Printf("GeoIP loaded: %d entries", len(entries))
	return nil
}

func getCountry(ipStr string) string {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return "??"
	}
	ip = ip.To4()
	if ip == nil {
		return "??"
	}
	n := ip2int(ip)

	geoMu.RLock()
	entries := geoEntries
	geoMu.RUnlock()

	lo, hi := 0, len(entries)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		e := entries[mid]
		if n < e.start {
			hi = mid - 1
		} else if n > e.end {
			lo = mid + 1
		} else {
			return e.cc
		}
	}
	return "??"
}

func ip2int(ip net.IP) uint32 {
	return binary.BigEndian.Uint32(ip.To4())
}

// ─── helpers ─────────────────────────────────────────────────────────────────

func inSlice(s string, list []string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}

func uniqueStrings(ss []string) []string {
	seen := make(map[string]bool, len(ss))
	out := make([]string, 0, len(ss))
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// ─── forceStop ───────────────────────────────────────────────────────────────

func forceStop() {
	if !atomic.CompareAndSwapInt32(&scan.stopped, 0, 1) {
		return
	}
	_ = exec.Command("pkill", "-f", "masscan").Run()
	sendResults()
}

GOCODE

}

# ─── build ───────────────────────────────────────────────────────────────────
build_scanner() {
    echo -e "${BLUE}[>>]${NC} Сборка сканера..."
    export PATH="/usr/local/go/bin:$PATH"
    cd "$INSTALL_DIR"

    if ! go mod tidy 2>&1; then
        echo -e "${RED}[ERR] go mod tidy failed${NC}" >&2
        exit 1
    fi

    CGO_ENABLED=0 go build \
        -ldflags="-s -w -X main.Version=${VERSION}" \
        -o cfscanner \
        . 2>&1

    echo -e "${GREEN}[OK]${NC} Сборка успешна: $(du -sh cfscanner | cut -f1)"
}

# ─── systemd service ─────────────────────────────────────────────────────────
create_service() {
    echo -e "${BLUE}[>>]${NC} Создание systemd сервиса..."

    cat > "$INSTALL_DIR/.env" << ENV
SCANNER_TOKEN=${SCANNER_TOKEN}
ADMIN_ID=${ADMIN_ID}
VLESS_CONFIG=${VLESS_CONFIG:-}
MASSCAN_RATE=${RATE}
WORKERS=${WORKERS}
TLS_SKIP_VERIFY=true
MEM_LIMIT_MB=${MEM_LIMIT}
ENV
    chmod 600 "$INSTALL_DIR/.env"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE
[Unit]
Description=Cloudflare Scanner v17.1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/cfscanner
Restart=always
RestartSec=5
User=root
LimitNOFILE=1048576
MemoryMax=${MEM_LIMIT}M
CPUAccounting=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cfscanner
KillMode=mixed
TimeoutStopSec=30
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start  "$SERVICE_NAME"
    sleep 2
    systemctl is-active --quiet "$SERVICE_NAME" && \
        echo -e "${GREEN}[OK]${NC} Сервис запущен" || \
        echo -e "${RED}[WARN]${NC} Сервис не запустился, проверьте: journalctl -u ${SERVICE_NAME} -n 50"
}

# ─── final summary ───────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  CF Scanner v17.1 успешно установлен!   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Управление сервисом:${NC}"
    echo -e "    systemctl status  ${SERVICE_NAME}"
    echo -e "    systemctl restart ${SERVICE_NAME}"
    echo -e "    systemctl stop    ${SERVICE_NAME}"
    echo -e "    journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "  ${CYAN}Установка:${NC}  ${INSTALL_DIR}"
    echo -e "  ${CYAN}Логи:${NC}       journalctl -u ${SERVICE_NAME}"
    echo -e "  ${CYAN}Версия:${NC}     v17.1"
    echo ""
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
    show_banner
    check_root
    detect_arch
    check_os
    get_system_info
    get_credentials
    cleanup_old
    install_dependencies
    install_go
    optimize_system
    download_geoip
    generate_code
    build_scanner
    create_service
    show_summary
}

main "$@"
