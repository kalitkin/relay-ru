#!/usr/bin/env bash
# setup-relay.sh v3.1 — RU-relay с VLESS+Reality+Fragment (обход МТС DPI)
#
# Схема:
#   Клиент (HAPP/incy + fragment) → VLESS+Reality → Relay (RU IP) → VLESS+Reality → VPS:8443 → инет
#
# Fragment фрагментирует TLS ClientHello → МТС DPI не успевает изменить session ID → Reality проходит
# На VPS НИЧЕГО менять не надо — relay подключается к существующему inbound.
#
# Использование:
#   sudo bash setup-relay.sh "vless://UUID@HOST:8443?security=reality&sni=...&pbk=...&sid=...&fp=chrome&flow=xtls-rprx-vision&type=tcp#NL"
#   sudo bash setup-relay.sh "vless://...NL" "vless://...FI"        # с failover
#   sudo bash setup-relay.sh "https://.../sub/..."                   # Marzban subscription URL
#   sudo bash setup-relay.sh --status
#   sudo bash setup-relay.sh --update "https://.../sub/..."          # обновить upstream UUID/хосты (inbound не трогает)
#   sudo bash setup-relay.sh --uninstall

set -euo pipefail

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_CONF="$XRAY_CONF_DIR/config.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly STATE_FILE="/etc/relay-state.json"
readonly SUB_DIR="/var/www/sub"
readonly SUB_PORT="8444"
readonly XRAY_VERSION="${XRAY_VERSION:-25.3.6}"
# dzen.ru — проверено: работает с МТС DPI + Reality + Fragment
readonly -a SNI_POOL=("dzen.ru" "mail.ru" "ya.ru")

CR='\033[0;31m'; CG='\033[0;32m'; CY='\033[1;33m'
CC='\033[0;36m'; CB='\033[1m'; NC='\033[0m'
info() { echo -e "${CC}[•]${NC} $*"; }
ok()   { echo -e "${CG}[✓]${NC} $*"; }
warn() { echo -e "${CY}[!]${NC} $*"; }
die()  { echo -e "${CR}[✗]${NC} $*" >&2; exit 1; }
hr()   { echo -e "${CC}$(printf '─%.0s' {1..60})${NC}"; }

# ══════════════════════════════════════════════════════════════════
# Парсер VLESS-ссылки → переменные UPi_*
# ══════════════════════════════════════════════════════════════════
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

expand_arg() {
    local arg=$1
    if [[ "$arg" =~ ^vless:// ]]; then
        EXPANDED_LINKS+=("$arg")
        return
    fi
    if [[ "$arg" =~ ^https?:// ]]; then
        info "Скачиваю подписку: $arg"
        local body
        body=$(curl -fsSL --max-time 10 -A "v2rayNG/1.8.0" "$arg") \
            || die "Не удалось скачать подписку: $arg"
        if ! grep -q "vless://" <<< "$body"; then
            local decoded
            decoded=$(echo "$body" | base64 -d 2>/dev/null || true)
            grep -q "vless://" <<< "$decoded" \
                && body="$decoded" \
                || die "В подписке нет VLESS-ссылок (формат не распознан)"
        fi
        local count=0
        while IFS= read -r line; do
            [[ "$line" =~ ^vless:// ]] || continue
            EXPANDED_LINKS+=("$line")
            count=$((count + 1))
        done <<< "$body"
        if (( count == 0 )); then die "Из подписки не извлечено ни одной VLESS-ссылки"; fi
        ok "Из подписки получено $count VLESS-ссылок"
        return
    fi
    die "Аргумент не VLESS и не URL подписки: $arg"
}

parse_vless() {
    local idx=$1 link=$2
    [[ "$link" =~ ^vless://(.+)$ ]] || die "Не VLESS-ссылка: $link"
    local rest="${BASH_REMATCH[1]}"

    local frag=""
    if [[ "$rest" == *"#"* ]]; then
        frag=$(urldecode "${rest##*#}")
        rest="${rest%%#*}"
    fi

    local query=""
    if [[ "$rest" == *"?"* ]]; then
        query="${rest#*\?}"
        rest="${rest%%\?*}"
    fi

    [[ "$rest" =~ ^([^@]+)@([^:]+):([0-9]+)$ ]] \
        || die "Ожидалось vless://UUID@HOST:PORT, получено: $rest"

    printf -v "UP${idx}_UUID" '%s' "${BASH_REMATCH[1]}"
    printf -v "UP${idx}_HOST" '%s' "${BASH_REMATCH[2]}"
    printf -v "UP${idx}_PORT" '%s' "${BASH_REMATCH[3]}"
    printf -v "UP${idx}_NAME" '%s' "$frag"

    printf -v "UP${idx}_TYPE"     '%s' "tcp"
    printf -v "UP${idx}_SECURITY" '%s' "reality"
    printf -v "UP${idx}_FP"       '%s' "chrome"
    printf -v "UP${idx}_FLOW"     '%s' ""
    printf -v "UP${idx}_SNI"      '%s' ""
    printf -v "UP${idx}_PBK"      '%s' ""
    printf -v "UP${idx}_SID"      '%s' ""

    local IFS='&'
    for kv in $query; do
        [[ "$kv" =~ ^([^=]+)=(.*)$ ]] || continue
        local k="${BASH_REMATCH[1]}" v
        v=$(urldecode "${BASH_REMATCH[2]}")
        case "$k" in
            type)     printf -v "UP${idx}_TYPE"     '%s' "$v" ;;
            security) printf -v "UP${idx}_SECURITY" '%s' "$v" ;;
            sni)      printf -v "UP${idx}_SNI"      '%s' "$v" ;;
            pbk)      printf -v "UP${idx}_PBK"      '%s' "$v" ;;
            sid)      printf -v "UP${idx}_SID"      '%s' "$v" ;;
            fp)       printf -v "UP${idx}_FP"       '%s' "$v" ;;
            flow)     printf -v "UP${idx}_FLOW"     '%s' "$v" ;;
        esac
    done

    local sec_var="UP${idx}_SECURITY" pbk_var="UP${idx}_PBK"
    local sec="${!sec_var}" pbk="${!pbk_var}"
    if [[ "$sec" == "reality" && -z "$pbk" ]]; then
        die "В VLESS-ссылке #$idx нет pbk — это не Reality?"
    fi
}

# ══════════════════════════════════════════════════════════════════
# Установка xray
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
# Outbound JSON для одного upstream
# ══════════════════════════════════════════════════════════════════
build_outbound() {
    local i=$1
    local uuid host port type security sni pbk sid fp flow
    eval "uuid=\$UP${i}_UUID"
    eval "host=\$UP${i}_HOST"
    eval "port=\$UP${i}_PORT"
    eval "type=\$UP${i}_TYPE"
    eval "security=\$UP${i}_SECURITY"
    eval "sni=\$UP${i}_SNI"
    eval "pbk=\$UP${i}_PBK"
    eval "sid=\$UP${i}_SID"
    eval "fp=\$UP${i}_FP"
    eval "flow=\$UP${i}_FLOW"

    local stream
    if [[ "$security" == "reality" ]]; then
        stream=$(cat <<JSON
        "network": "$type",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "$fp",
          "serverName": "$sni",
          "publicKey": "$pbk",
          "shortId": "$sid"
        }
JSON
)
    else
        stream=$(cat <<JSON
        "network": "$type",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$sni",
          "fingerprint": "$fp",
          "allowInsecure": false
        }
JSON
)
    fi

    cat <<JSON
    {
      "tag": "UP_$i",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$host",
          "port": $port,
          "users": [{
            "id": "$uuid",
            "encryption": "none",
            "flow": "$flow"
          }]
        }]
      },
      "streamSettings": {
$stream
      }
    }
JSON
}

# ══════════════════════════════════════════════════════════════════
# Генерация серверного конфига
# ══════════════════════════════════════════════════════════════════
generate_config() {
    info "Генерирую конфиг xray"

    local keys priv_key pub_key short_id
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv_key=$(awk '/Private/{print $3}' <<< "$keys")
    pub_key=$(awk '/Public/{print $3}'   <<< "$keys")
    short_id=$(openssl rand -hex 8)
    [[ -z "${RELAY_UUID:-}" ]] && RELAY_UUID=$("$XRAY_BIN" uuid 2>/dev/null)

    local outs="" sel=""
    for ((i=1; i<=UPCOUNT; i++)); do
        outs+="$(build_outbound "$i"),"$'\n'
        sel+="\"UP_$i\","
    done
    sel="${sel%,}"

    local routing
    if (( UPCOUNT > 1 )); then
        routing=$(cat <<JSON
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"], "outboundTag": "BLOCK"},
      {"type": "field", "inboundTag": ["CLIENT_IN"], "balancerTag": "up"}
    ],
    "balancers": [
      {"tag": "up", "selector": [$sel], "strategy": {"type": "leastPing"}}
    ]
  },
  "burstObservatory": {
    "subjectSelector": [$sel],
    "pingConfig": {
      "destination": "https://1.1.1.1/cdn-cgi/trace",
      "interval":    "30s",
      "timeout":     "5s",
      "samplingCount": 3
    }
  }
JSON
)
    else
        routing=$(cat <<JSON
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"], "outboundTag": "BLOCK"},
      {"type": "field", "inboundTag": ["CLIENT_IN"], "outboundTag": "UP_1"}
    ]
  }
JSON
)
    fi

    mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"

    # Inbound: без flow у клиентов — fragment-клиенты его не используют
    # shortIds включает "" для совместимости с incy/HAPP которые не передают sid
    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "policy": {
    "levels": {"0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5}}
  },
  "inbounds": [{
    "tag": "CLIENT_IN",
    "listen": "0.0.0.0",
    "port": $RELAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$RELAY_UUID", "email": "relay-client", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${RELAY_SNI}:443",
        "xver": 0,
        "serverNames": ["$RELAY_SNI"],
        "privateKey": "$priv_key",
        "shortIds": ["$short_id", ""]
      }
    }
  }],
  "outbounds": [
$outs    {"protocol": "freedom",   "tag": "DIRECT"},
    {"protocol": "blackhole", "tag": "BLOCK"}
  ],
$routing
}
EOF

    "$XRAY_BIN" run -test -config "$XRAY_CONF" 2>&1 | tail -5 || die "Конфиг не валиден"
    chmod 600 "$XRAY_CONF"
    ok "Конфиг $XRAY_CONF"

    local upstreams_json="["
    for ((i=1; i<=UPCOUNT; i++)); do
        local h p n
        eval "h=\$UP${i}_HOST"; eval "p=\$UP${i}_PORT"; eval "n=\$UP${i}_NAME"
        upstreams_json+="{\"name\":\"$n\",\"host\":\"$h\",\"port\":$p},"
    done
    upstreams_json="${upstreams_json%,}]"

    cat > "$STATE_FILE" <<EOF
{
  "relay_port":  $RELAY_PORT,
  "relay_sni":   "$RELAY_SNI",
  "uuid":        "$RELAY_UUID",
  "public_key":  "$pub_key",
  "short_id":    "$short_id",
  "upstreams":   $upstreams_json,
  "installed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 644 "$STATE_FILE"
}

# ══════════════════════════════════════════════════════════════════
# Обновление upstream (--update): UUID + хосты без смены inbound
# Нужно когда Marzban ротирует UUID у пользователя
# ══════════════════════════════════════════════════════════════════
update_upstream() {
    local sub_arg="${1:-}"
    [[ $EUID -ne 0 ]] && die "Нужен root"
    [[ ! -f "$XRAY_CONF" ]] && die "Relay не установлен (нет $XRAY_CONF)"

    if [[ -z "$sub_arg" ]]; then
        [[ -f "$STATE_FILE" ]] \
            && sub_arg=$(python3 -c "import json; s=json.load(open('$STATE_FILE')); print(s.get('sub_url',''))" 2>/dev/null) \
            || true
        [[ -z "$sub_arg" ]] && die "Укажи URL подписки: --update \"https://...\""
    fi

    info "Обновляю upstreams из: $sub_arg"
    EXPANDED_LINKS=()
    expand_arg "$sub_arg"

    UPCOUNT=${#EXPANDED_LINKS[@]}
    (( UPCOUNT == 0 )) && die "Нет VLESS-ссылок"

    local i=1
    for link in "${EXPANDED_LINKS[@]}"; do
        parse_vless "$i" "$link"
        i=$((i + 1))
    done

    local outs="" sel=""
    for ((i=1; i<=UPCOUNT; i++)); do
        outs+="$(build_outbound "$i"),"$'\n'
        sel+="\"UP_$i\","
    done
    sel="${sel%,}"

    python3 - <<PYEOF
import json

with open('$XRAY_CONF') as f:
    c = json.load(f)

# Удалить старые vless outbounds, оставить freedom/blackhole
c['outbounds'] = [o for o in c['outbounds'] if o.get('protocol') != 'vless']

# Вставить новые перед DIRECT
ins = next((i for i,o in enumerate(c['outbounds']) if o.get('tag') == 'DIRECT'), 0)
PYEOF

    python3 << PYEOF
import json, subprocess

with open('$XRAY_CONF') as f:
    c = json.load(f)

c['outbounds'] = [o for o in c['outbounds'] if o.get('protocol') != 'vless']
ins = next((i for i,o in enumerate(c['outbounds']) if o.get('tag') == 'DIRECT'), 0)

new_obs = []
PYEOF

    # Строим новые outbounds через build_outbound и вставляем через python
    local outs_json="["
    for ((i=1; i<=UPCOUNT; i++)); do
        outs_json+="$(build_outbound "$i"),"
    done
    outs_json="${outs_json%,}]"

    python3 - "$outs_json" "$sel" "$UPCOUNT" <<'PYEOF'
import json, sys

outs_json = sys.argv[1]
sel_str   = sys.argv[2]   # "UP_1","UP_2","UP_3"
upcount   = int(sys.argv[3])

with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)

c['outbounds'] = [o for o in c['outbounds'] if o.get('protocol') != 'vless']
ins = next((i for i,o in enumerate(c['outbounds']) if o.get('tag') == 'DIRECT'), 0)

new_obs = json.loads(outs_json)
for ob in reversed(new_obs):
    c['outbounds'].insert(ins, ob)

tags = [f"UP_{i}" for i in range(1, upcount + 1)]
if upcount > 1:
    c['routing'] = {
        "domainStrategy": "AsIs",
        "rules": [
            {"type": "field", "ip": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"], "outboundTag": "BLOCK"},
            {"type": "field", "inboundTag": ["CLIENT_IN"], "balancerTag": "up"}
        ],
        "balancers": [
            {"tag": "up", "selector": tags, "strategy": {"type": "leastPing"}}
        ]
    }
    c['burstObservatory'] = {
        "subjectSelector": tags,
        "pingConfig": {
            "destination": "https://1.1.1.1/cdn-cgi/trace",
            "interval": "30s",
            "timeout": "5s",
            "samplingCount": 3
        }
    }
else:
    c['routing'] = {
        "domainStrategy": "AsIs",
        "rules": [
            {"type": "field", "ip": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"], "outboundTag": "BLOCK"},
            {"type": "field", "inboundTag": ["CLIENT_IN"], "outboundTag": "UP_1"}
        ]
    }
    c.pop('burstObservatory', None)

with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(c, f, indent=2)

print(f"Обновлено {upcount} upstream(s):")
for ob in new_obs:
    vnext = ob['settings']['vnext'][0]
    print(f"  {ob['tag']}: {vnext['address']}:{vnext['port']}  uuid={vnext['users'][0]['id'][:8]}...")
PYEOF

    # Сохранить sub_url в state
    python3 - "$sub_arg" <<'PYEOF'
import json, sys
sub_url = sys.argv[1]
with open('/etc/relay-state.json') as f:
    s = json.load(f)
s['sub_url'] = sub_url
with open('/etc/relay-state.json', 'w') as f:
    json.dump(s, f, indent=2)
PYEOF

    "$XRAY_BIN" run -test -config "$XRAY_CONF" 2>&1 | tail -3 || die "Конфиг не валиден после update"
    systemctl restart xray-relay
    sleep 1
    systemctl is-active --quiet xray-relay && ok "xray-relay перезапущен" || die "xray-relay не стартует"
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# HTTPS subscription endpoint с клиентским конфигом (fragment)
# ══════════════════════════════════════════════════════════════════
setup_subscription() {
    info "Настраиваю subscription endpoint (HTTPS :$SUB_PORT)"

    local relay_ip pub_key short_id uuid
    relay_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
             || die "Не удалось определить внешний IP")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")

    # LE cert через sslip.io (не нужна регистрация домена)
    local sslip_domain
    sslip_domain="$(echo "$relay_ip" | tr '.' '-').sslip.io"
    local cert_dir="/etc/letsencrypt/live/${sslip_domain}"

    if [[ ! -f "${cert_dir}/fullchain.pem" ]]; then
        info "Получаю LE cert для $sslip_domain"
        apt-get install -y -qq certbot 2>/dev/null || warn "certbot не установился"
        if command -v certbot &>/dev/null; then
            certbot certonly --standalone \
                -d "$sslip_domain" \
                --non-interactive --agree-tos \
                -m "${CERTBOT_EMAIL:-kalitkinas@gmail.com}" \
                --http-01-port 80 2>&1 | tail -5 \
                && ok "LE cert: $sslip_domain" \
                || warn "certbot не смог получить cert — subscription только HTTP"
        fi
    else
        ok "LE cert уже есть: $sslip_domain"
    fi

    mkdir -p "$SUB_DIR"

    # Клиентский конфиг с fragment — рабочий паттерн для МТС DPI
    cat > "$SUB_DIR/relay.json" <<EOF
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$relay_ip",
          "port": $RELAY_PORT,
          "users": [{"encryption": "none", "id": "$uuid", "level": 8, "security": "auto"}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "realitySettings": {
          "fingerprint": "chrome",
          "publicKey": "$pub_key",
          "serverName": "$RELAY_SNI",
          "shortId": "$short_id",
          "show": false,
          "spiderX": ""
        },
        "security": "reality",
        "sockopt": {"dialerProxy": "fragment"},
        "tcpSettings": {"header": {"type": "none"}}
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
          "interval": "10-20",
          "length": "1400",
          "maxSplit": "100-200",
          "packets": "tlshello"
        },
        "userLevel": 0
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "sockopt": {"mark": 255, "TcpNoDelay": true}
      },
      "tag": "fragment"
    }
  ],
  "policy": {
    "levels": {"8": {"bufferSize": 3, "connIdle": 300, "downlinkOnly": 4, "handshake": 3, "uplinkOnly": 2}}
  },
  "remarks": "Relay-RU-${relay_ip}"
}
EOF

    cat > "$SUB_DIR/https_server.py" <<'PYEOF'
import http.server, ssl, os, glob
os.chdir('/var/www/sub')
httpd = http.server.HTTPServer(('0.0.0.0', 8444), http.server.SimpleHTTPRequestHandler)
cert_dir = next((d.rstrip('/') for d in glob.glob('/etc/letsencrypt/live/*/') if 'sslip.io' in d), None)
if cert_dir:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert_dir + '/fullchain.pem', cert_dir + '/privkey.pem')
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF

    cat > /etc/systemd/system/relay-sub.service <<EOF
[Unit]
Description=Relay Subscription Server
After=network.target
[Service]
ExecStart=/usr/bin/python3 $SUB_DIR/https_server.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    iptables -C INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --quiet relay-sub
    systemctl restart relay-sub
    sleep 1

    local proto="https"
    [[ ! -f "${cert_dir:-/nonexistent}/fullchain.pem" ]] && proto="http"
    local sub_url="${proto}://${sslip_domain}:${SUB_PORT}/relay.json"

    python3 - "$sub_url" "$sslip_domain" <<'PYEOF'
import json, sys
sub_url, sslip = sys.argv[1], sys.argv[2]
with open('/etc/relay-state.json') as f:
    s = json.load(f)
s['subscription_url'] = sub_url
s['sslip_domain'] = sslip
with open('/etc/relay-state.json', 'w') as f:
    json.dump(s, f, indent=2)
PYEOF

    ok "Subscription: $sub_url"
}

# ══════════════════════════════════════════════════════════════════
# systemd + healthcheck
# ══════════════════════════════════════════════════════════════════
setup_systemd() {
    info "systemd"

    cat > /etc/systemd/system/xray-relay.service <<'EOF'
[Unit]
Description=Xray Relay Node
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
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/bin/relay-healthcheck <<'CHKEOF'
#!/usr/bin/env bash
STATE="/etc/relay-state.json"
LOG="/var/log/xray/healthcheck.log"
[[ ! -f "$STATE" ]] && { echo "State not found"; exit 1; }
TS=$(date '+%Y-%m-%d %H:%M:%S')
RPORT=$(python3 -c "import json; print(json.load(open('$STATE'))['relay_port'])")
SVC=$(systemctl is-active xray-relay 2>/dev/null || echo "inactive")
PORT_OK=$(ss -tlnp 2>/dev/null | grep -q ":$RPORT " && echo "LISTEN" || echo "CLOSED")

UPS=""
COUNT=$(python3 -c "import json; print(len(json.load(open('$STATE'))['upstreams']))")
for ((i=0; i<COUNT; i++)); do
    H=$(python3 -c "import json; print(json.load(open('$STATE'))['upstreams'][$i]['host'])")
    P=$(python3 -c "import json; print(json.load(open('$STATE'))['upstreams'][$i]['port'])")
    if (echo >/dev/tcp/"$H"/"$P") 2>/dev/null; then
        UPS+="$H:$P=UP "
    else
        UPS+="$H:$P=DOWN "
    fi
done

MSG="$TS  svc=$SVC  port=$RPORT($PORT_OK)  $UPS"
echo "$MSG" | tee -a "$LOG" >/dev/null

if [[ "$SVC" != "active" ]]; then
    echo "$TS  [WARN] xray-relay down — restarting" | tee -a "$LOG" >/dev/null
    systemctl restart xray-relay
fi

if [[ -f "$LOG" ]] && (( $(stat -c%s "$LOG" 2>/dev/null || echo 0) > 10485760 )); then
    mv "$LOG" "${LOG}.1"
    touch "$LOG"
fi
CHKEOF
    chmod +x /usr/local/bin/relay-healthcheck

    cat > /etc/systemd/system/relay-healthcheck.service <<'EOF'
[Unit]
Description=Relay Healthcheck (oneshot)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-healthcheck
EOF

    cat > /etc/systemd/system/relay-healthcheck.timer <<'EOF'
[Unit]
Description=Relay Healthcheck — каждые 5 минут

[Timer]
OnBootSec=60s
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --quiet xray-relay
    systemctl enable --quiet relay-healthcheck.timer
    systemctl restart xray-relay
    systemctl start  relay-healthcheck.timer
    sleep 2
    systemctl is-active --quiet xray-relay \
        || die "xray-relay не стартует. journalctl -u xray-relay -n 50"
    ok "xray-relay активен"
    ok "relay-healthcheck timer (каждые 5 мин)"
}

# ══════════════════════════════════════════════════════════════════
# Firewall
# ══════════════════════════════════════════════════════════════════
setup_firewall() {
    info "iptables"
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null  || iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -C INPUT -p tcp --dport "$RELAY_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$RELAY_PORT" -j ACCEPT
    local rule="-p tcp --dport $RELAY_PORT --syn -m connlimit --connlimit-above $CONN_LIMIT --connlimit-mask 32 -j REJECT --reject-with tcp-reset"
    # shellcheck disable=SC2086
    iptables -C INPUT $rule 2>/dev/null || iptables -A INPUT $rule
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "порт $RELAY_PORT/tcp открыт, лимит $CONN_LIMIT/IP"
}

# ══════════════════════════════════════════════════════════════════
# BBR + TCP tuning
# ══════════════════════════════════════════════════════════════════
setup_kernel() {
    grep -q 'rmem_max=67108864' /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.netfilter.nf_conntrack_max=262144
EOF
    sysctl -p > /dev/null 2>&1 || true
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && ok "BBR ON" || warn "BBR: ядро не поддерживает"
    ok "TCP tuning применён (буферы 64MB, keepalive 60s)"
}

# ══════════════════════════════════════════════════════════════════
# Swap + Logrotate
# ══════════════════════════════════════════════════════════════════
setup_extras() {
    # Swap 512MB (защита от OOM)
    if ! swapon --show | grep -q swap 2>/dev/null; then
        fallocate -l 512M /swapfile 2>/dev/null && \
        chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile && \
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap 512MB создан"
    else
        ok "Swap уже есть"
    fi

    # Logrotate
    cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    ok "Logrotate: daily, 7 дней"
}

# ══════════════════════════════════════════════════════════════════
# Финальный вывод
# ══════════════════════════════════════════════════════════════════
print_output() {
    local relay_ip pub_key short_id uuid sub_url
    relay_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
             || echo "UNKNOWN")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")
    sub_url=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('subscription_url','не настроен'))")

    echo ""
    hr
    echo -e "${CB}${CG}  Relay готов!  IP: $relay_ip${NC}"
    hr

    echo -e "\n${CB}Subscription URL для HAPP / incy (добавить как подписку):${NC}"
    echo -e "${CY}$sub_url${NC}"

    echo -e "\n${CB}VLESS-ссылка (запасной вариант — без fragment):${NC}"
    echo -e "${CY}vless://${uuid}@${relay_ip}:${RELAY_PORT}?encryption=none&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#Relay-RU-${relay_ip}${NC}"

    echo -e "\n${CB}Upstream:${NC}"
    for ((i=1; i<=UPCOUNT; i++)); do
        local h p n
        eval "h=\$UP${i}_HOST"; eval "p=\$UP${i}_PORT"; eval "n=\$UP${i}_NAME"
        printf "  #%d  %s  %s:%d\n" "$i" "${n:-no-name}" "$h" "$p"
    done
    if (( UPCOUNT > 1 )); then echo "  Failover: leastPing (probe 30s)"; fi

    echo -e "\n${CB}Yandex Cloud Security Group — открой входящие порты (CIDR 0.0.0.0/0):${NC}"
    echo "  TCP $RELAY_PORT  — клиентские подключения (Reality)"
    echo "  TCP $SUB_PORT   — скачивание subscription"
    echo "  TCP 80          — certbot LE renewal"

    echo -e "\n${CB}Команды:${NC}"
    echo "  sudo bash $0 --status                       — состояние relay"
    echo "  sudo bash $0 --update \"https://sub-url\"     — обновить upstream UUID (после ротации Marzban)"
    echo "  journalctl -u xray-relay -f                 — live логи"
    echo "  sudo bash $0 --uninstall                    — снести всё"
    hr
    echo ""
}

# ══════════════════════════════════════════════════════════════════
# Uninstall
# ══════════════════════════════════════════════════════════════════
uninstall() {
    info "Удаляю xray-relay"
    systemctl disable --now xray-relay              2>/dev/null || true
    systemctl disable --now relay-healthcheck.timer 2>/dev/null || true
    systemctl disable --now relay-sub               2>/dev/null || true
    rm -f /etc/systemd/system/xray-relay.service
    rm -f /etc/systemd/system/relay-healthcheck.service
    rm -f /etc/systemd/system/relay-healthcheck.timer
    rm -f /etc/systemd/system/relay-sub.service
    rm -f /usr/local/bin/relay-healthcheck
    systemctl daemon-reload
    rm -rf "$XRAY_CONF_DIR" "$XRAY_LOG_DIR" "$STATE_FILE" "$SUB_DIR"
    rm -f /etc/logrotate.d/xray
    iptables -D INPUT -p tcp --dport "${RELAY_PORT:-443}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT            2>/dev/null || true
    ok "Готово. xray бинарь $XRAY_BIN не трогал — снеси вручную если надо."
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Status
# ══════════════════════════════════════════════════════════════════
status() {
    [[ ! -f "$STATE_FILE" ]] && die "State не найден ($STATE_FILE) — relay не установлен"

    local rport rsni uuid pub_key short_id installed sub_url
    rport=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['relay_port'])")
    rsni=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['relay_sni'])")
    uuid=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['uuid'])")
    pub_key=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['public_key'])")
    short_id=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['short_id'])")
    installed=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['installed_at'])")
    sub_url=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('subscription_url','не настроен'))")

    local svc port_state ext_ip
    svc=$(systemctl is-active xray-relay 2>/dev/null || echo "inactive")
    ss -tlnp 2>/dev/null | grep -q ":$rport " && port_state="LISTEN" || port_state="CLOSED"
    ext_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "?")

    hr
    echo -e "${CB}  RELAY STATUS  ${NC}"
    hr
    [[ "$svc" == "active" ]] && ok "xray-relay: active" || warn "xray-relay: $svc"
    [[ "$port_state" == "LISTEN" ]] && ok "Порт $rport: LISTEN" || warn "Порт $rport: $port_state"
    info "IP: $ext_ip  |  SNI: $rsni  |  Установлен: $installed"

    echo ""
    echo -e "${CB}Upstreams:${NC}"
    local count
    count=$(python3 -c "import json; print(len(json.load(open('$STATE_FILE'))['upstreams']))")
    for ((i=0; i<count; i++)); do
        local h p n
        h=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['upstreams'][$i]['host'])")
        p=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['upstreams'][$i]['port'])")
        n=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['upstreams'][$i]['name'])")
        if (echo >/dev/tcp/"$h"/"$p") 2>/dev/null; then
            ok "  #$((i+1)) $n  $h:$p"
        else
            warn "  #$((i+1)) $n  $h:$p — недоступен"
        fi
    done

    local hc_log="/var/log/xray/healthcheck.log"
    if [[ -f "$hc_log" ]]; then
        echo ""
        echo -e "${CB}Healthcheck (последние 5):${NC}"
        tail -5 "$hc_log" | sed 's/^/  /'
    fi

    echo ""
    echo -e "${CB}Subscription URL:${NC}"
    echo -e "${CY}$sub_url${NC}"
    echo ""
    echo -e "${CB}VLESS-ссылка (без fragment):${NC}"
    echo -e "${CY}vless://${uuid}@${ext_ip}:${rport}?encryption=none&security=reality&sni=${rsni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#Relay-RU-${ext_ip}${NC}"
    hr
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════
main() {
    echo -e "\n${CB}${CC}  setup-relay.sh v3.1 (Reality+Fragment)${NC}\n"

    [[ "${1:-}" == "--status"    || "${1:-}" == "-s" ]] && status
    [[ "${1:-}" == "--update"    || "${1:-}" == "-U" ]] && update_upstream "${2:-}"

    [[ $EUID -ne 0 ]] && die "Нужен root"
    [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]] && uninstall

    [[ $# -eq 0 ]] && cat <<USAGE && exit 1
Использование:
  sudo bash $0 "vless://..."                             # одна VLESS-ссылка
  sudo bash $0 "vless://NL" "vless://FI"                 # с failover
  sudo bash $0 "https://.../sub/..."                     # Marzban subscription URL
  sudo bash $0 --status                                  # текущее состояние
  sudo bash $0 --update "https://.../sub/..."            # обновить upstream UUID
  sudo bash $0 --uninstall                               # снести relay

ENV (необязательно):
  RELAY_PORT=443                — порт куда подключается клиент
  RELAY_SNI=dzen.ru             — SNI для Reality (RU домен для обхода МТС)
  RELAY_UUID=<uuid>             — фиксированный UUID клиента relay
  CONN_LIMIT=2048               — лимит соединений с одного IP (CGNAT)
  CERTBOT_EMAIL=your@email.com  — email для Let's Encrypt
  LOG_LEVEL=warning             — xray loglevel
USAGE

    RELAY_PORT="${RELAY_PORT:-443}"
    RELAY_SNI="${RELAY_SNI:-${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}}"
    CONN_LIMIT="${CONN_LIMIT:-2048}"

    info "OS: $(lsb_release -ds 2>/dev/null || uname -rs)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    for pkg in curl python3 iptables-persistent; do
        command -v "${pkg%%-*}" &>/dev/null && continue
        apt-get install -y -qq "$pkg" 2>/dev/null || warn "Не поставил $pkg"
    done

    EXPANDED_LINKS=()
    for arg in "$@"; do
        expand_arg "$arg"
    done

    UPCOUNT=${#EXPANDED_LINKS[@]}
    if (( UPCOUNT == 0 )); then die "Не получено ни одной VLESS-ссылки"; fi
    info "Парсинг $UPCOUNT VLESS-ссылок..."

    local i=1
    for link in "${EXPANDED_LINKS[@]}"; do
        parse_vless "$i" "$link"
        local h p n
        eval "h=\$UP${i}_HOST"; eval "p=\$UP${i}_PORT"; eval "n=\$UP${i}_NAME"
        if (echo >/dev/tcp/"$h"/"$p") 2>/dev/null; then
            ok "Upstream #$i ${n:-} → $h:$p — доступен"
        else
            warn "Upstream #$i ${n:-} → $h:$p — недоступен"
        fi
        i=$((i + 1))
    done

    install_xray
    generate_config
    setup_systemd
    setup_firewall
    setup_kernel
    setup_extras
    setup_subscription
    print_output
}

main "$@"
