#!/usr/bin/env bash
# setup-relay.sh — Production-lite Xray relay (RU segment → NL/FI VPS)
#
# Схема:
#   Client → VLESS+Reality → [этот relay] → VLESS+TLS|Reality → VPS (NL / FI)
#
# Использование:
#   cp .env.relay /etc/relay.env && nano /etc/relay.env
#   sudo bash setup-relay.sh
#
# Или через env-переменные:
#   UUID=xxx UPSTREAM_UUID=yyy UPSTREAM_1_IP=1.2.3.4 UPSTREAM_2_IP=5.6.7.8 sudo bash setup-relay.sh

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# Константы
# ══════════════════════════════════════════════════════════════════
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_CONF="$XRAY_CONF_DIR/config.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly STATE_FILE="/etc/relay-state.json"
readonly ENV_FILE="${ENV_FILE:-/etc/relay.env}"
readonly XRAY_VERSION="${XRAY_VERSION:-25.3.6}"
readonly -a SNI_POOL=("ya.ru" "cloudflare.com" "microsoft.com")

# ══════════════════════════════════════════════════════════════════
# Вывод
# ══════════════════════════════════════════════════════════════════
CR='\033[0;31m'; CG='\033[0;32m'; CY='\033[1;33m'
CC='\033[0;36m'; CB='\033[1m'; NC='\033[0m'
info() { echo -e "${CC}[•]${NC} $*"; }
ok()   { echo -e "${CG}[✓]${NC} $*"; }
warn() { echo -e "${CY}[!]${NC} $*"; }
die()  { echo -e "${CR}[✗]${NC} $*" >&2; exit 1; }
hr()   { echo -e "${CC}$(printf '─%.0s' {1..60})${NC}"; }

# ══════════════════════════════════════════════════════════════════
# Валидация env
# ══════════════════════════════════════════════════════════════════
validate_env() {
    [[ $EUID -ne 0 ]] && die "Нужен root: sudo bash $0"

    # Загружаем .env если есть
    if [[ -f "$ENV_FILE" ]]; then
        info "Загружаю $ENV_FILE"
        set -a; source "$ENV_FILE"; set +a
    fi

    # Применяем дефолты
    MODE="${MODE:-normal}"
    RELAY_PORT="${RELAY_PORT:-443}"
    UPSTREAM_PORT="${UPSTREAM_PORT:-7443}"
    CONN_LIMIT="${CONN_LIMIT:-64}"
    RELAY_SNI="${RELAY_SNI:-${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}}"
    UPSTREAM_1_TLS_SNI="${UPSTREAM_1_TLS_SNI:-${UPSTREAM_1_IP:-}}"
    UPSTREAM_2_TLS_SNI="${UPSTREAM_2_TLS_SNI:-${UPSTREAM_2_IP:-}}"
    UPSTREAM_ALLOW_INSECURE="${UPSTREAM_ALLOW_INSECURE:-true}"

    local err=0
    for v in UUID UPSTREAM_UUID UPSTREAM_1_IP UPSTREAM_2_IP; do
        [[ -z "${!v:-}" ]] && { warn "Обязательная переменная не задана: $v"; (( err++ )); }
    done

    if [[ "$MODE" == "secure" ]]; then
        for v in UPSTREAM_PUBLIC_KEY UPSTREAM_SHORT_ID; do
            [[ -z "${!v:-}" ]] && { warn "Нужно для MODE=secure: $v"; (( err++ )); }
        done
        UPSTREAM_REALITY_SNI="${UPSTREAM_REALITY_SNI:-$RELAY_SNI}"
    fi

    [[ "$MODE" != "normal" && "$MODE" != "secure" ]] && \
        die "MODE должен быть 'normal' или 'secure', получено: '$MODE'"

    (( err > 0 )) && die "$err обязательных переменных не задано. Заполни /etc/relay.env"

    ok "Переменные OK  (MODE=$MODE, SNI=$RELAY_SNI, PORT=$RELAY_PORT)"
}

# ══════════════════════════════════════════════════════════════════
# Зависимости
# ══════════════════════════════════════════════════════════════════
check_deps() {
    local missing=()
    for cmd in curl openssl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    (( ${#missing[@]} > 0 )) && die "Не хватает команд: ${missing[*]}"
    ok "Зависимости OK"
}

# ══════════════════════════════════════════════════════════════════
# Установка xray (идемпотентна)
# ══════════════════════════════════════════════════════════════════
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        local ver
        ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$ver" == "$XRAY_VERSION" ]]; then
            ok "xray $XRAY_VERSION уже установлен — пропускаю"
            return
        fi
        warn "Обновляю xray: $ver → $XRAY_VERSION"
    fi

    info "Устанавливаю xray-core $XRAY_VERSION..."
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *) die "Архитектура не поддерживается: $(uname -m)" ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch}.zip"
    local tmp; tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    curl -fsSL "$url" -o "$tmp/xray.zip"
    mkdir -p "$tmp/xray"
    if command -v unzip &>/dev/null; then
        unzip -q "$tmp/xray.zip" -d "$tmp/xray"
    elif command -v python3 &>/dev/null; then
        python3 -c "import zipfile; zipfile.ZipFile('$tmp/xray.zip').extractall('$tmp/xray')"
    else
        die "Нет ни unzip ни python3 для распаковки. Установи: apt-get install unzip"
    fi
    install -m 755 "$tmp/xray/xray" "$XRAY_BIN"

    mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"
    for f in geoip.dat geosite.dat; do
        [[ -f "$tmp/xray/$f" ]] && cp "$tmp/xray/$f" "$XRAY_CONF_DIR/"
    done

    ok "xray $("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}') установлен"
}

# ══════════════════════════════════════════════════════════════════
# Предварительная проверка upstream
# ══════════════════════════════════════════════════════════════════
healthcheck_upstream() {
    info "Проверяю доступность upstream серверов..."
    local reachable=0
    for n in 1 2; do
        local ip_var="UPSTREAM_${n}_IP"
        local ip="${!ip_var}"
        if (echo >/dev/tcp/"$ip"/"$UPSTREAM_PORT") 2>/dev/null; then
            ok "Upstream $n  ($ip:$UPSTREAM_PORT) — доступен"
            (( reachable++ ))
        else
            warn "Upstream $n  ($ip:$UPSTREAM_PORT) — недоступен"
            warn "  → Добавь inbound на VPS (см. вывод в конце скрипта)"
        fi
    done
    (( reachable == 0 )) && warn "Оба upstream недоступны — xray поднимется, но трафик не пройдёт"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Строители outbound-блоков (вызываются из generate_config)
# ══════════════════════════════════════════════════════════════════
_build_tls_outbound() {
    local tag=$1 ip=$2 sni=$3
    cat <<EOF
    {
      "tag": "$tag",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$ip",
          "port": $UPSTREAM_PORT,
          "users": [{"id": "$UPSTREAM_UUID", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$sni",
          "allowInsecure": $UPSTREAM_ALLOW_INSECURE,
          "fingerprint": "chrome"
        }
      }
    }
EOF
}

_build_reality_outbound() {
    local tag=$1 ip=$2
    cat <<EOF
    {
      "tag": "$tag",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$ip",
          "port": $UPSTREAM_PORT,
          "users": [{"id": "$UPSTREAM_UUID", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$UPSTREAM_REALITY_SNI",
          "publicKey": "$UPSTREAM_PUBLIC_KEY",
          "shortId": "$UPSTREAM_SHORT_ID"
        }
      }
    }
EOF
}

# ══════════════════════════════════════════════════════════════════
# Генерация конфига
# ══════════════════════════════════════════════════════════════════
generate_config() {
    info "Генерирую конфиг xray (MODE=$MODE)..."

    # Reality keypair для inbound (клиент → relay)
    local keys priv_key pub_key short_id
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv_key=$(awk '/Private/{print $3}' <<< "$keys")
    pub_key=$(awk '/Public/{print $3}'   <<< "$keys")
    short_id=$(openssl rand -hex 8)

    # Outbound-блоки в зависимости от режима
    local out1 out2
    if [[ "$MODE" == "secure" ]]; then
        out1=$(_build_reality_outbound "UPSTREAM_1" "$UPSTREAM_1_IP")
        out2=$(_build_reality_outbound "UPSTREAM_2" "$UPSTREAM_2_IP")
    else
        out1=$(_build_tls_outbound "UPSTREAM_1" "$UPSTREAM_1_IP" "$UPSTREAM_1_TLS_SNI")
        out2=$(_build_tls_outbound "UPSTREAM_2" "$UPSTREAM_2_IP" "$UPSTREAM_2_TLS_SNI")
    fi

    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake":    4,
        "connIdle":     120,
        "uplinkOnly":   2,
        "downlinkOnly": 5
      }
    }
  },
  "inbounds": [
    {
      "tag": "CLIENT_IN",
      "listen": "0.0.0.0",
      "port": $RELAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "relay-client",
            "level": 0
          }
        ],
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
$out1,
$out2,
    {"protocol": "freedom",   "tag": "DIRECT"},
    {"protocol": "blackhole", "tag": "BLOCK"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "inboundTag": ["CLIENT_IN"],
        "balancerTag": "upstream_balancer"
      }
    ],
    "balancers": [
      {
        "tag": "upstream_balancer",
        "selector": ["UPSTREAM_1", "UPSTREAM_2"],
        "strategy": {"type": "leastPing"}
      }
    ]
  },
  "burstObservatory": {
    "subjectSelector": ["UPSTREAM_1", "UPSTREAM_2"],
    "pingConfig": {
      "destination":    "https://1.1.1.1/cdn-cgi/trace",
      "interval":       "30s",
      "timeout":        "5s",
      "samplingCount":  3
    }
  }
}
EOF

    "$XRAY_BIN" run -test -config "$XRAY_CONF" &>/dev/null || die "Конфиг не прошёл валидацию xray"
    ok "Конфиг записан: $XRAY_CONF"

    # Сохраняем состояние (pub info только — без private key)
    chmod 600 "$XRAY_CONF"
    cat > "$STATE_FILE" <<EOF
{
  "mode":          "$MODE",
  "relay_port":    $RELAY_PORT,
  "relay_sni":     "$RELAY_SNI",
  "uuid":          "$UUID",
  "public_key":    "$pub_key",
  "short_id":      "$short_id",
  "upstream_1_ip": "$UPSTREAM_1_IP",
  "upstream_2_ip": "$UPSTREAM_2_IP",
  "upstream_port": $UPSTREAM_PORT,
  "upstream_uuid": "$UPSTREAM_UUID",
  "installed_at":  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$STATE_FILE"
}

# ══════════════════════════════════════════════════════════════════
# Systemd: сервис + таймер healthcheck
# ══════════════════════════════════════════════════════════════════
setup_systemd() {
    info "Настраиваю systemd..."

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

    # Скрипт healthcheck (работает независимо)
    cat > /usr/local/bin/check-relay.sh <<'CHKEOF'
#!/usr/bin/env bash
STATE="/etc/relay-state.json"
LOG="/var/log/xray/healthcheck.log"
[[ ! -f "$STATE" ]] && { echo "State not found: $STATE"; exit 1; }

UP1=$(jq -r .upstream_1_ip "$STATE")
UP2=$(jq -r .upstream_2_ip "$STATE")
PORT=$(jq -r .upstream_port "$STATE")
RPORT=$(jq -r .relay_port   "$STATE")
TS=$(date '+%Y-%m-%d %H:%M:%S')

tcp_check() { (echo >/dev/tcp/"$1"/"$2") 2>/dev/null && echo "UP" || echo "DOWN"; }

SVC=$(systemctl is-active xray-relay 2>/dev/null || echo "inactive")
PORT_OK=$(ss -tlnp | grep -q ":$RPORT " && echo "LISTEN" || echo "CLOSED")
U1=$(tcp_check "$UP1" "$PORT")
U2=$(tcp_check "$UP2" "$PORT")

MSG="$TS  svc=$SVC  port=$RPORT($PORT_OK)  up1=${UP1}:${U1}  up2=${UP2}:${U2}"
echo "$MSG" | tee -a "$LOG"

# Авто-рестарт если сервис упал
if [[ "$SVC" != "active" ]]; then
    echo "$TS  [WARN] xray-relay down — restarting" | tee -a "$LOG"
    systemctl restart xray-relay
fi

# Ротация лога если > 10 МБ
[[ -f "$LOG" ]] && (( $(stat -c%s "$LOG" 2>/dev/null || echo 0) > 10485760 )) && \
    mv "$LOG" "${LOG}.1" && touch "$LOG"
CHKEOF
    chmod +x /usr/local/bin/check-relay.sh

    cat > /etc/systemd/system/relay-healthcheck.service <<'EOF'
[Unit]
Description=Relay Upstream Healthcheck (oneshot)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-relay.sh
EOF

    cat > /etc/systemd/system/relay-healthcheck.timer <<'EOF'
[Unit]
Description=Relay Upstream Healthcheck — каждые 5 минут

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
    systemctl is-active --quiet xray-relay || \
        die "xray-relay не запустился. Диагностика: journalctl -u xray-relay -n 50"

    ok "xray-relay   запущен"
    ok "healthcheck  timer активен (каждые 5 мин)"
}

# ══════════════════════════════════════════════════════════════════
# Firewall + лимит подключений
# ══════════════════════════════════════════════════════════════════
setup_security() {
    info "Настраиваю firewall и ограничение подключений..."

    # UFW
    ufw allow ssh          > /dev/null
    ufw allow "$RELAY_PORT/tcp" > /dev/null
    echo "y" | ufw enable  > /dev/null 2>&1 || true

    # Лимит соединений на порт relay (per source IP)
    local ipt_rule="-p tcp --dport $RELAY_PORT --syn -m connlimit --connlimit-above $CONN_LIMIT --connlimit-mask 32 -j REJECT --reject-with tcp-reset"
    # shellcheck disable=SC2086
    iptables -C INPUT $ipt_rule 2>/dev/null || iptables -A INPUT $ipt_rule

    # Сохраняем правила
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    ok "UFW: порт $RELAY_PORT/tcp открыт"
    ok "iptables: conn limit $CONN_LIMIT/IP на порту $RELAY_PORT"
}

# ══════════════════════════════════════════════════════════════════
# BBR
# ══════════════════════════════════════════════════════════════════
setup_bbr() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR уже активен"
        return
    fi
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || \
        printf '\n# BBR\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
        >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1 || true
    ok "BBR включён"
}

# ══════════════════════════════════════════════════════════════════
# Проверка IP в белых списках RU-сегмента (pure bash, без python)
# ══════════════════════════════════════════════════════════════════
_ip_to_int() {
    local a b c d; IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

_in_cidr() {
    local net=${2%/*} pfx=${2#*/}
    local ip_int net_int mask
    ip_int=$(_ip_to_int "$1")
    net_int=$(_ip_to_int "$net")
    mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    return $(( (ip_int & mask) != (net_int & mask) ))
}

check_whitelist_ip() {
    local ip=$1
    local -a ranges=(
        "84.201.0.0/16"    "84.252.128.0/17"  "130.193.32.0/19"
        "158.160.0.0/16"   "51.250.0.0/16"    "89.249.160.0/21"
        "62.84.112.0/20"   "178.154.128.0/17" "93.158.128.0/18"
        "94.100.0.0/16"    "217.69.128.0/17"  "195.239.160.0/20"
        "185.30.176.0/22"  "194.67.0.0/16"
        "185.231.204.0/22" "185.233.116.0/22"
    )
    for cidr in "${ranges[@]}"; do
        if _in_cidr "$ip" "$cidr"; then
            echo "$cidr"
            return
        fi
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════
# Итоговый вывод
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

    local vless_link="vless://${uuid}@${relay_ip}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#Relay-RU-${relay_ip}"

    # Inbound JSON для Marzban на VPS
    local marzban_json
    if [[ "$MODE" == "normal" ]]; then
        marzban_json=$(cat <<EOF
{
  "tag": "RELAY-RU-${relay_ip}",
  "listen": "0.0.0.0",
  "port": $UPSTREAM_PORT,
  "protocol": "vless",
  "settings": {
    "clients": [
      {"id": "$UPSTREAM_UUID", "email": "relay-ru", "encryption": "none"}
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [{
        "certificateFile": "/etc/ssl/xray/relay.crt",
        "keyFile":         "/etc/ssl/xray/relay.key"
      }]
    }
  }
}
EOF
)
    else
        marzban_json=$(cat <<EOF
{
  "tag": "RELAY-RU-${relay_ip}",
  "listen": "0.0.0.0",
  "port": $UPSTREAM_PORT,
  "protocol": "vless",
  "settings": {
    "clients": [
      {"id": "$UPSTREAM_UUID", "email": "relay-ru", "encryption": "none"}
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "ya.ru:443",
      "xver": 0,
      "serverNames": ["ya.ru"],
      "privateKey": "<СГЕНЕРИРУЙ НА VPS: xray x25519>",
      "shortIds": ["$UPSTREAM_SHORT_ID"]
    }
  }
}
EOF
)
    fi

    # Проверка белых списков
    local wl_result
    wl_result=$(check_whitelist_ip "$relay_ip")

    echo ""
    hr
    echo -e "${CB}${CG}  Relay готов!  IP: ${relay_ip}${NC}"
    hr

    echo -e "\n${CB}1. VLESS-ссылка (добавить в Marzban или клиент):${NC}"
    echo -e "${CY}$vless_link${NC}"

    echo -e "\n${CB}2. Inbound для Marzban на VPS (оба NL и FI):${NC}"
    echo "   Marzban panel → Xray Settings → \"inbounds\" → добавить блок:"
    echo ""
    echo "$marzban_json" | jq . 2>/dev/null || echo "$marzban_json"

    if [[ "$MODE" == "normal" ]]; then
        echo ""
        echo -e "${CY}   ▶ MODE=normal: на VPS нужен TLS-сертификат.${NC}"
        echo "     Запусти на каждом VPS (NL и FI):"
        echo "     mkdir -p /etc/ssl/xray && openssl req -x509 -newkey rsa:2048 \\"
        echo "       -keyout /etc/ssl/xray/relay.key -out /etc/ssl/xray/relay.crt \\"
        echo "       -days 3650 -nodes -subj '/CN=relay'"
        echo "     Затем перезапусти xray на VPS."
    else
        echo ""
        echo -e "${CY}   ▶ MODE=secure: на VPS нужна своя Reality-пара для relay-inbound.${NC}"
        echo "     Запусти на VPS: xray x25519"
        echo "     Private key → в 'privateKey' выше"
        echo "     Public key  → UPSTREAM_PUBLIC_KEY в /etc/relay.env на relay"
        echo "     Потом: systemctl restart xray-relay  (на этой relay VM)"
    fi

    echo -e "\n${CB}3. Upstream серверы:${NC}"
    echo "   #1 NL  $UPSTREAM_1_IP:$UPSTREAM_PORT"
    echo "   #2 FI  $UPSTREAM_2_IP:$UPSTREAM_PORT"
    echo "   Failover: burstObservatory + leastPing (probe каждые 30 сек)"

    echo -e "\n${CB}4. Белые списки:${NC}"
    if [[ -n "$wl_result" ]]; then
        ok "IP $relay_ip → входит в белый список RU ($wl_result)"
    else
        warn "IP $relay_ip — не найден в известных RU-диапазонах"
        warn "Убедись что VM создана в Yandex Cloud / Aeza RU / VK Cloud"
    fi

    echo -e "\n${CB}Команды:${NC}"
    echo "  systemctl status xray-relay            — статус сервиса"
    echo "  journalctl -u xray-relay -f            — live логи"
    echo "  check-relay.sh                         — ручная проверка"
    echo "  tail -f /var/log/xray/healthcheck.log  — лог healthcheck"
    echo "  cat $STATE_FILE | jq .             — параметры"
    echo ""
    hr
    echo ""
}

# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════
main() {
    echo -e "\n${CB}${CC}  setup-relay.sh${NC}\n"

    validate_env
    check_deps

    info "ОС: $(lsb_release -ds 2>/dev/null || uname -rs)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    apt-get -f install -y -qq 2>/dev/null || true
    for pkg in curl unzip jq ufw iptables-persistent; do
        apt-get install -y -qq "$pkg" 2>/dev/null || warn "Не удалось установить $pkg — продолжаю"
    done

    install_xray
    healthcheck_upstream
    generate_config
    setup_systemd
    setup_security
    setup_bbr
    print_output
}

main "$@"
