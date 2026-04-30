#!/usr/bin/env bash
# setup-relay.sh v2 — Lightweight RU-relay через существующий VLESS+Reality
#
# Схема:
#   Клиент → VLESS+Reality → [этот relay (RU)] → VLESS+Reality → твой VPS:8443 → инет
#
# На VPS НИЧЕГО менять не надо — relay подключается к существующему inbound
# (тому же что использует обычный клиент).
#
# Использование:
#   sudo bash setup-relay.sh "vless://UUID@HOST:8443?security=reality&sni=...&pbk=...&sid=...&fp=chrome&flow=xtls-rprx-vision&type=tcp#NL"
#   sudo bash setup-relay.sh "vless://...NL" "vless://...FI"        # с failover
#   sudo RELAY_PORT=8443 bash setup-relay.sh "vless://..."          # порт relay

set -euo pipefail

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_CONF="$XRAY_CONF_DIR/config.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly STATE_FILE="/etc/relay-state.json"
readonly XRAY_VERSION="${XRAY_VERSION:-25.3.6}"
readonly -a SNI_POOL=("ya.ru" "cloudflare.com" "microsoft.com")

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

# Раскрывает аргумент в массив VLESS-ссылок:
# - "vless://..."           → как есть
# - "http(s)://.../sub/..." → скачивает, base64-декодит при необходимости, режет по строкам
# Результат пишет в EXPANDED_LINKS (глобальный массив).
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
        # base64?
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

    # дефолты
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
# Генерация конфига
# ══════════════════════════════════════════════════════════════════
generate_config() {
    info "Генерирую конфиг xray"

    local keys priv_key pub_key short_id
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv_key=$(awk '/Private/{print $3}' <<< "$keys")
    pub_key=$(awk '/Public/{print $3}'   <<< "$keys")
    short_id=$(openssl rand -hex 8)
    [[ -z "${RELAY_UUID:-}" ]] && RELAY_UUID=$("$XRAY_BIN" uuid 2>/dev/null)

    # outbounds
    local outs="" sel=""
    for ((i=1; i<=UPCOUNT; i++)); do
        outs+="$(build_outbound "$i"),"$'\n'
        sel+="\"UP_$i\","
    done
    sel="${sel%,}"

    # routing — balancer если несколько, иначе прямой outboundTag
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

    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "policy": {
    "levels": {"0": {"handshake": 4, "connIdle": 120, "uplinkOnly": 2, "downlinkOnly": 5}}
  },
  "inbounds": [{
    "tag": "CLIENT_IN",
    "listen": "0.0.0.0",
    "port": $RELAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$RELAY_UUID", "flow": "xtls-rprx-vision", "email": "relay-client", "level": 0}],
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
        "shortIds": ["$short_id"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
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

    # state
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
# systemd
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

    # Healthcheck скрипт
    cat > /usr/local/bin/relay-healthcheck <<'CHKEOF'
#!/usr/bin/env bash
STATE="/etc/relay-state.json"
LOG="/var/log/xray/healthcheck.log"
[[ ! -f "$STATE" ]] && { echo "State not found"; exit 1; }
TS=$(date '+%Y-%m-%d %H:%M:%S')
RPORT=$(jq -r .relay_port "$STATE")
SVC=$(systemctl is-active xray-relay 2>/dev/null || echo "inactive")
PORT_OK=$(ss -tlnp 2>/dev/null | grep -q ":$RPORT " && echo "LISTEN" || echo "CLOSED")

# upstream availability
UPS=""
COUNT=$(jq -r '.upstreams | length' "$STATE")
for ((i=0; i<COUNT; i++)); do
    H=$(jq -r ".upstreams[$i].host" "$STATE")
    P=$(jq -r ".upstreams[$i].port" "$STATE")
    if (echo >/dev/tcp/"$H"/"$P") 2>/dev/null; then
        UPS+="$H:$P=UP "
    else
        UPS+="$H:$P=DOWN "
    fi
done

MSG="$TS  svc=$SVC  port=$RPORT($PORT_OK)  $UPS"
echo "$MSG" | tee -a "$LOG" >/dev/null

# auto-restart если сервис упал
if [[ "$SVC" != "active" ]]; then
    echo "$TS  [WARN] xray-relay down — restarting" | tee -a "$LOG" >/dev/null
    systemctl restart xray-relay
fi

# rotate если > 10 МБ
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
# BBR
# ══════════════════════════════════════════════════════════════════
setup_bbr() {
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && { ok "BBR ON"; return; }
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null \
        || printf '\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1 || true
    ok "BBR включён"
}

# ══════════════════════════════════════════════════════════════════
# Финальный вывод
# ══════════════════════════════════════════════════════════════════
print_output() {
    local relay_ip
    relay_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
             || echo "UNKNOWN")

    local pub_key short_id uuid
    pub_key=$(jq -r .public_key "$STATE_FILE")
    short_id=$(jq -r .short_id  "$STATE_FILE")
    uuid=$(jq -r .uuid          "$STATE_FILE")

    local link="vless://${uuid}@${relay_ip}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#Relay-RU-${relay_ip}"

    echo ""
    hr
    echo -e "${CB}${CG}  Relay готов!  IP: $relay_ip${NC}"
    hr

    echo -e "\n${CB}VLESS-ссылка для клиента (импорт в v2rayNG / Hiddify / Marzban):${NC}"
    echo -e "${CY}$link${NC}"

    echo -e "\n${CB}Upstream:${NC}"
    for ((i=1; i<=UPCOUNT; i++)); do
        local h p n
        eval "h=\$UP${i}_HOST"; eval "p=\$UP${i}_PORT"; eval "n=\$UP${i}_NAME"
        printf "  #%d  %s  %s:%d\n" "$i" "${n:-no-name}" "$h" "$p"
    done
    if (( UPCOUNT > 1 )); then echo "  Failover: leastPing (probe 30s)"; fi

    echo -e "\n${CB}Команды:${NC}"
    echo "  bash $0 --status                — состояние relay (сервис/порт/upstream'ы)"
    echo "  systemctl status xray-relay     — статус сервиса"
    echo "  journalctl -u xray-relay -f     — live логи xray"
    echo "  tail -f /var/log/xray/healthcheck.log — лог healthcheck"
    echo "  cat $STATE_FILE | jq .          — параметры"
    echo "  bash $0 --uninstall             — снести всё"
    hr
    echo ""
}

# ══════════════════════════════════════════════════════════════════
# Uninstall — для быстрого перебора VM
# ══════════════════════════════════════════════════════════════════
uninstall() {
    info "Удаляю xray-relay"
    systemctl disable --now xray-relay 2>/dev/null || true
    systemctl disable --now relay-healthcheck.timer 2>/dev/null || true
    rm -f /etc/systemd/system/xray-relay.service
    rm -f /etc/systemd/system/relay-healthcheck.service
    rm -f /etc/systemd/system/relay-healthcheck.timer
    rm -f /usr/local/bin/relay-healthcheck
    systemctl daemon-reload
    rm -rf "$XRAY_CONF_DIR" "$XRAY_LOG_DIR" "$STATE_FILE"
    iptables -D INPUT -p tcp --dport "${RELAY_PORT:-443}" -j ACCEPT 2>/dev/null || true
    ok "Готово. xray бинарь $XRAY_BIN не трогал — снеси вручную если надо."
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Status — on-demand проверка без модификации системы
# ══════════════════════════════════════════════════════════════════
status() {
    local STATE="/etc/relay-state.json"
    [[ ! -f "$STATE" ]] && die "State не найден ($STATE) — relay не установлен"

    local rport rsni uuid pub_key short_id installed
    rport=$(jq -r .relay_port   "$STATE")
    rsni=$(jq -r  .relay_sni    "$STATE")
    uuid=$(jq -r  .uuid         "$STATE")
    pub_key=$(jq -r .public_key "$STATE")
    short_id=$(jq -r .short_id  "$STATE")
    installed=$(jq -r .installed_at "$STATE")

    local svc port_state ext_ip
    svc=$(systemctl is-active xray-relay 2>/dev/null || echo "inactive")
    ss -tlnp 2>/dev/null | grep -q ":$rport " && port_state="LISTEN" || port_state="CLOSED"
    ext_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "?")

    hr
    echo -e "${CB}  RELAY STATUS  ${NC}"
    hr
    [[ "$svc" == "active" ]] && ok "Сервис xray-relay: active" || warn "Сервис xray-relay: $svc"
    [[ "$port_state" == "LISTEN" ]] && ok "Порт $rport: LISTEN" || warn "Порт $rport: $port_state"
    info "Внешний IP: $ext_ip"
    info "SNI: $rsni"
    info "Установлен: $installed"

    echo ""
    echo -e "${CB}Upstreams:${NC}"
    local count
    count=$(jq -r '.upstreams | length' "$STATE")
    for ((i=0; i<count; i++)); do
        local h p n
        h=$(jq -r ".upstreams[$i].host" "$STATE")
        p=$(jq -r ".upstreams[$i].port" "$STATE")
        n=$(jq -r ".upstreams[$i].name" "$STATE")
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
    echo -e "${CB}VLESS-ссылка для клиента:${NC}"
    echo -e "${CY}vless://${uuid}@${ext_ip}:${rport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${rsni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#Relay-RU-${ext_ip}${NC}"
    hr
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════
main() {
    echo -e "\n${CB}${CC}  setup-relay.sh v2${NC}\n"

    # --status работает без root (только чтение)
    [[ "${1:-}" == "--status"    || "${1:-}" == "-s" ]] && status

    [[ $EUID -ne 0 ]] && die "Нужен root"

    [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]] && uninstall

    [[ $# -eq 0 ]] && cat <<USAGE && exit 1
Использование:
  sudo bash $0 "vless://..."                       # одна VLESS-ссылка
  sudo bash $0 "vless://NL" "vless://FI"           # с failover
  sudo bash $0 "https://.../sub/..."               # подписка (Marzban subscription URL)
  sudo bash $0 --status                            # текущее состояние relay
  sudo bash $0 --uninstall                         # снести relay

ENV (необязательно):
  RELAY_PORT=443           — порт куда подключается клиент
  RELAY_SNI=cloudflare.com — SNI для Reality на relay
  RELAY_UUID=<uuid>        — фиксированный UUID клиента
  CONN_LIMIT=64            — лимит соединений с одного IP
  LOG_LEVEL=warning        — xray loglevel (warning/info/debug)
USAGE

    RELAY_PORT="${RELAY_PORT:-443}"
    RELAY_SNI="${RELAY_SNI:-${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}}"
    CONN_LIMIT="${CONN_LIMIT:-64}"

    info "OS: $(lsb_release -ds 2>/dev/null || uname -rs)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    for pkg in curl jq iptables-persistent; do
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
            warn "Upstream #$i ${n:-} → $h:$p — недоступен (relay поднимется, но трафик не пройдёт)"
        fi
        i=$((i + 1))
    done

    install_xray
    generate_config
    setup_systemd
    setup_firewall
    setup_bbr
    print_output
}

main "$@"
