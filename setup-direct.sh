#!/usr/bin/env bash
# setup-direct.sh v1 — прямой выход в интернет через RU VM
#
# Схема:
#   Клиент (HAPP/incy) → VLESS + Reality + XHTTP + Fragment → RU VM → Интернет
#
# Технологии:
#   Reality   — TLS camouflage, DPI видит легитимный TLS к dzen.ru
#   XHTTP     — HTTP-based transport, post-handshake трафик выглядит как HTTP
#   Fragment  — дробит TLS ClientHello, защита от операторов модифицирующих session ID
#
# Не требует европейских VPS. Трафик выходит прямо из Yandex Cloud.
#
# Использование:
#   sudo bash setup-direct.sh              # установить
#   sudo bash setup-direct.sh --status     # статус
#   sudo bash setup-direct.sh --uninstall  # удалить

set -euo pipefail

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly DIRECT_CONF="$XRAY_CONF_DIR/direct.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly STATE_FILE="/etc/direct-state.json"
readonly SUB_DIR="/var/www/sub"
readonly SUB_FILE="$SUB_DIR/direct.json"
readonly XRAY_VERSION="${XRAY_VERSION:-25.3.6}"
readonly -a SNI_POOL=("dzen.ru" "mail.ru" "ya.ru")

CR='\033[0;31m'; CG='\033[0;32m'; CY='\033[1;33m'
CC='\033[0;36m'; CB='\033[1m'; NC='\033[0m'
info() { echo -e "${CC}[•]${NC} $*"; }
ok()   { echo -e "${CG}[✓]${NC} $*"; }
warn() { echo -e "${CY}[!]${NC} $*"; }
die()  { echo -e "${CR}[✗]${NC} $*" >&2; exit 1; }
hr()   { echo -e "${CC}$(printf '─%.0s' {1..60})${NC}"; }

# ══════════════════════════════════════════════════════════════════
# Установка / проверка xray
# ══════════════════════════════════════════════════════════════════
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        local ver
        ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
        [[ "$ver" == "$XRAY_VERSION" ]] && { ok "xray $XRAY_VERSION уже стоит"; return; }
        warn "Обновляю xray $ver → $XRAY_VERSION"
    fi

    info "Ставлю xray-core $XRAY_VERSION"
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *) die "Архитектура не поддерживается: $(uname -m)" ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch}.zip"
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    curl -fsSL "$url" -o "$tmp/x.zip"
    mkdir -p "$tmp/x"
    if command -v unzip &>/dev/null; then
        unzip -q "$tmp/x.zip" -d "$tmp/x"
    elif command -v python3 &>/dev/null; then
        python3 -c "import zipfile; zipfile.ZipFile('$tmp/x.zip').extractall('$tmp/x')"
    else
        apt-get install -y -qq unzip 2>/dev/null && unzip -q "$tmp/x.zip" -d "$tmp/x" \
            || die "Нет unzip и python3"
    fi
    install -m 755 "$tmp/x/xray" "$XRAY_BIN"
    mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"
    ok "xray $($XRAY_BIN version | awk 'NR==1{print $2}') установлен"
}

# ══════════════════════════════════════════════════════════════════
# Генерация конфига
# ══════════════════════════════════════════════════════════════════
generate_config() {
    info "Генерирую конфиг (Reality + XHTTP)"

    local keys priv_key pub_key short_id uuid
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv_key=$(awk '/Private/{print $3}' <<< "$keys")
    pub_key=$(awk '/Public/{print $3}'   <<< "$keys")
    short_id=$(openssl rand -hex 8)
    uuid=$("$XRAY_BIN" uuid 2>/dev/null)

    mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"

    cat > "$DIRECT_CONF" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}",
    "access": "${XRAY_LOG_DIR}/direct-access.log",
    "error":  "${XRAY_LOG_DIR}/direct-error.log"
  },
  "policy": {
    "levels": {"0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5}}
  },
  "inbounds": [{
    "tag": "DIRECT_IN",
    "listen": "0.0.0.0",
    "port": $DIRECT_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "email": "direct-client", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${DIRECT_SNI}:443",
        "xver": 0,
        "serverNames": ["$DIRECT_SNI"],
        "privateKey": "$priv_key",
        "shortIds": ["$short_id", ""]
      },
      "xhttpSettings": {
        "path": "/dl",
        "host": "$DIRECT_SNI",
        "mode": "auto",
        "extra": {
          "scMaxEachPostBytes": 1000000,
          "scMaxConcurrentPosts": 100,
          "scMinPostsIntervalMs": 30,
          "xPaddingBytes": "100-1000"
        }
      }
    }
  }],
  "outbounds": [
    {"protocol": "freedom",   "tag": "DIRECT", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "blackhole", "tag": "BLOCK"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"], "outboundTag": "BLOCK"},
      {"type": "field", "inboundTag": ["DIRECT_IN"], "outboundTag": "DIRECT"}
    ]
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1", "77.88.8.8"]
  }
}
EOF

    "$XRAY_BIN" run -test -config "$DIRECT_CONF" 2>&1 | tail -3 || die "Конфиг не валиден"
    chmod 600 "$DIRECT_CONF"
    ok "Конфиг $DIRECT_CONF"

    cat > "$STATE_FILE" <<EOF
{
  "direct_port":  $DIRECT_PORT,
  "direct_sni":   "$DIRECT_SNI",
  "uuid":         "$uuid",
  "public_key":   "$pub_key",
  "private_key":  "$priv_key",
  "short_id":     "$short_id",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 644 "$STATE_FILE"
}

# ══════════════════════════════════════════════════════════════════
# HTTPS subscription endpoint — клиентский конфиг
# Технологии: Reality + XHTTP + Fragment (все вместе)
# ══════════════════════════════════════════════════════════════════
setup_subscription() {
    info "Создаю subscription endpoint"

    local relay_ip pub_key short_id uuid
    relay_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
             || die "Не удалось определить внешний IP")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")

    # LE cert — переиспользуем если уже есть (от relay)
    local sslip_domain cert_dir
    sslip_domain="$(echo "$relay_ip" | tr '.' '-').sslip.io"
    cert_dir="/etc/letsencrypt/live/${sslip_domain}"

    if [[ ! -f "${cert_dir}/fullchain.pem" ]]; then
        info "Получаю LE cert для $sslip_domain"
        apt-get install -y -qq certbot 2>/dev/null || true
        if command -v certbot &>/dev/null; then
            certbot certonly --standalone \
                -d "$sslip_domain" \
                --non-interactive --agree-tos \
                -m "${CERTBOT_EMAIL:-kalitkinas@gmail.com}" \
                --http-01-port 80 2>&1 | tail -5 \
                && ok "LE cert: $sslip_domain" \
                || warn "certbot не смог — subscription только HTTP"
        fi
    else
        ok "LE cert уже есть: $sslip_domain"
    fi

    mkdir -p "$SUB_DIR"

    # Клиентский конфиг: Reality + XHTTP + Fragment
    # - dialerProxy: fragment  →  фрагментирует TLS ClientHello (против session-ID атаки)
    # - network: xhttp         →  HTTP-based transport после хендшейка (против payload inspection)
    # - security: reality      →  TLS camouflage под dzen.ru
    cat > "$SUB_FILE" <<EOF
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$relay_ip",
          "port": $DIRECT_PORT,
          "users": [{"encryption": "none", "id": "$uuid", "level": 8}]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "publicKey": "$pub_key",
          "serverName": "$DIRECT_SNI",
          "shortId": "$short_id",
          "show": false,
          "spiderX": ""
        },
        "xhttpSettings": {
          "path": "/dl",
          "host": "$DIRECT_SNI",
          "mode": "auto",
          "extra": {
            "scMaxEachPostBytes": 1000000,
            "scMaxConcurrentPosts": 100,
            "scMinPostsIntervalMs": 30,
            "xPaddingBytes": "100-1000"
          }
        },
        "sockopt": {"dialerProxy": "fragment"}
      },
      "tag": "proxy"
    },
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"},
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs",
        "fragment": {
          "packets": "tlshello",
          "length": "1400",
          "interval": "10-20",
          "maxSplit": "100-200"
        }
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "sockopt": {"TcpNoDelay": true}
      },
      "tag": "fragment"
    }
  ],
  "policy": {
    "levels": {"8": {"bufferSize": 3, "connIdle": 300, "downlinkOnly": 4, "handshake": 3, "uplinkOnly": 2}}
  },
  "remarks": "Direct-RU-${relay_ip}"
}
EOF

    # Subscription сервер: переиспользуем если уже запущен relay-sub,
    # иначе запускаем новый
    if systemctl is-active --quiet relay-sub 2>/dev/null; then
        ok "relay-sub уже запущен — direct.json доступен там же"
    else
        cat > "$SUB_DIR/https_server.py" <<'PYEOF'
import http.server, ssl, os, glob
from socketserver import ThreadingMixIn

class ThreadingHTTPServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 64

os.chdir('/var/www/sub')
httpd = ThreadingHTTPServer(('0.0.0.0', 8444), http.server.SimpleHTTPRequestHandler)
cert_dir = next((d.rstrip('/') for d in glob.glob('/etc/letsencrypt/live/*/') if 'sslip.io' in d), None)
if cert_dir:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert_dir + '/fullchain.pem', cert_dir + '/privkey.pem')
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF

        cat > /etc/systemd/system/relay-sub.service <<'EOF'
[Unit]
Description=Relay Subscription Server
After=network.target
[Service]
ExecStart=/usr/bin/python3 /var/www/sub/https_server.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        iptables -C INPUT -p tcp --dport 8444 -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport 8444 -j ACCEPT
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable --quiet relay-sub
        systemctl restart relay-sub
    fi

    local proto="https"
    [[ ! -f "${cert_dir}/fullchain.pem" ]] && proto="http"
    local sub_url="${proto}://${sslip_domain}:8444/direct.json"

    python3 - "$sub_url" "$sslip_domain" <<'PYEOF'
import json, sys
sub_url, sslip = sys.argv[1], sys.argv[2]
with open('/etc/direct-state.json') as f:
    s = json.load(f)
s['subscription_url'] = sub_url
s['sslip_domain'] = sslip
with open('/etc/direct-state.json', 'w') as f:
    json.dump(s, f, indent=2)
PYEOF

    ok "Subscription: $sub_url"
}

# ══════════════════════════════════════════════════════════════════
# systemd сервис
# ══════════════════════════════════════════════════════════════════
setup_systemd() {
    info "systemd"

    cat > /etc/systemd/system/xray-direct.service <<'EOF'
[Unit]
Description=Xray Direct Node (XHTTP)
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/direct.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --quiet xray-direct
    systemctl restart xray-direct
    sleep 2
    systemctl is-active --quiet xray-direct \
        || die "xray-direct не стартует. journalctl -u xray-direct -n 50"
    ok "xray-direct активен"
}

# ══════════════════════════════════════════════════════════════════
# Firewall
# ══════════════════════════════════════════════════════════════════
setup_firewall() {
    info "iptables"
    iptables -C INPUT -p tcp --dport "$DIRECT_PORT" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$DIRECT_PORT" -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "порт $DIRECT_PORT/tcp открыт"
}

# ══════════════════════════════════════════════════════════════════
# Kernel + swap + logrotate (только если ещё не настроено)
# ══════════════════════════════════════════════════════════════════
setup_system() {
    grep -q 'rmem_max=67108864' /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.netfilter.nf_conntrack_max=262144
EOF
    sysctl -p > /dev/null 2>&1 || true
    ok "Kernel tuning OK"

    if ! swapon --show | grep -q swap 2>/dev/null; then
        fallocate -l 512M /swapfile 2>/dev/null && chmod 600 /swapfile \
            && mkswap /swapfile > /dev/null && swapon /swapfile \
            && (grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab)
        ok "Swap 512MB создан"
    else
        ok "Swap уже есть"
    fi

    [[ -f /etc/logrotate.d/xray ]] || cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    ok "Logrotate OK"
}

# ══════════════════════════════════════════════════════════════════
# Финальный вывод
# ══════════════════════════════════════════════════════════════════
print_output() {
    local relay_ip pub_key short_id uuid sub_url
    relay_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "UNKNOWN")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")
    sub_url=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('subscription_url','не настроен'))")

    echo ""
    hr
    echo -e "${CB}${CG}  Direct node готов!  IP: $relay_ip${NC}"
    hr
    echo -e "\n${CB}Transport:${NC} VLESS + Reality + XHTTP + Fragment"
    echo -e "${CB}Выход в интернет:${NC} напрямую из Yandex Cloud (без relay в Европу)"

    echo -e "\n${CB}Subscription URL для HAPP / incy:${NC}"
    echo -e "${CY}$sub_url${NC}"

    echo -e "\n${CB}VLESS URI (запасной):${NC}"
    echo -e "${CY}vless://${uuid}@${relay_ip}:${DIRECT_PORT}?encryption=none&security=reality&sni=${DIRECT_SNI}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=xhttp&path=%2Fdl&host=${DIRECT_SNI}#Direct-RU-${relay_ip}${NC}"

    echo -e "\n${CB}Yandex Cloud Security Group — добавь входящие (CIDR 0.0.0.0/0):${NC}"
    echo "  TCP $DIRECT_PORT  — клиентские подключения (XHTTP+Reality)"
    echo "  TCP 8444         — subscription (если relay-sub ещё не открыт)"

    echo -e "\n${CB}Команды:${NC}"
    echo "  sudo bash $0 --status     — состояние"
    echo "  journalctl -u xray-direct -f  — логи"
    echo "  sudo bash $0 --uninstall  — удалить"
    hr
    echo ""
}

# ══════════════════════════════════════════════════════════════════
# Status
# ══════════════════════════════════════════════════════════════════
status() {
    [[ ! -f "$STATE_FILE" ]] && die "State не найден — direct node не установлен"

    local dport dsni uuid pub_key short_id sub_url
    dport=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['direct_port'])")
    dsni=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['direct_sni'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    sub_url=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('subscription_url','не настроен'))")
    local svc ext_ip
    svc=$(systemctl is-active xray-direct 2>/dev/null || echo "inactive")
    ext_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "?")

    hr
    echo -e "${CB}  DIRECT NODE STATUS  ${NC}"
    hr
    [[ "$svc" == "active" ]] && ok "xray-direct: active" || warn "xray-direct: $svc"
    ss -tlnp 2>/dev/null | grep -q ":$dport " && ok "Порт $dport: LISTEN" || warn "Порт $dport: CLOSED"
    info "IP: $ext_ip  |  SNI: $dsni  |  Transport: XHTTP"
    echo ""
    echo -e "${CB}Subscription URL:${NC}"
    echo -e "${CY}$sub_url${NC}"
    echo ""
    echo -e "${CB}VLESS URI:${NC}"
    echo -e "${CY}vless://${uuid}@${ext_ip}:${dport}?encryption=none&security=reality&sni=${dsni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=xhttp&path=%2Fdl&host=${dsni}#Direct-RU-${ext_ip}${NC}"
    echo ""
    echo -e "${CB}Последние соединения:${NC}"
    tail -10 /var/log/xray/direct-access.log 2>/dev/null | sed 's/^/  /' || echo "  (нет логов)"
    hr
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Uninstall
# ══════════════════════════════════════════════════════════════════
uninstall() {
    info "Удаляю xray-direct"
    systemctl disable --now xray-direct 2>/dev/null || true
    rm -f /etc/systemd/system/xray-direct.service
    systemctl daemon-reload
    rm -f "$DIRECT_CONF" "$STATE_FILE" "$SUB_FILE"
    iptables -D INPUT -p tcp --dport "${DIRECT_PORT:-2096}" -j ACCEPT 2>/dev/null || true
    ok "xray-direct удалён"
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════
main() {
    echo -e "\n${CB}${CC}  setup-direct.sh v1 (Reality + XHTTP + Fragment)${NC}\n"

    [[ "${1:-}" == "--status"    || "${1:-}" == "-s" ]] && status
    [[ $EUID -ne 0 ]] && die "Нужен root"
    [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]] && uninstall

    DIRECT_PORT="${DIRECT_PORT:-2096}"
    DIRECT_SNI="${DIRECT_SNI:-${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}}"

    # Проверить конфликт портов
    if ss -tlnp 2>/dev/null | grep -q ":${DIRECT_PORT} "; then
        warn "Порт $DIRECT_PORT занят — пробую 2087"
        DIRECT_PORT="2087"
        if ss -tlnp 2>/dev/null | grep -q ":${DIRECT_PORT} "; then
            die "Порты 2096 и 2087 заняты. Укажи: DIRECT_PORT=XXXX sudo bash $0"
        fi
    fi
    info "Порт: $DIRECT_PORT | SNI: $DIRECT_SNI"

    info "OS: $(lsb_release -ds 2>/dev/null || uname -rs)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    for pkg in curl python3 iptables-persistent; do
        command -v "${pkg%%-*}" &>/dev/null && continue
        apt-get install -y -qq "$pkg" 2>/dev/null || warn "Не поставил $pkg"
    done

    install_xray
    generate_config
    setup_systemd
    setup_firewall
    setup_system
    setup_subscription
    print_output
}

main "$@"
