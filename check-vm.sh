#!/usr/bin/env bash
# check-vm.sh — Проверяет подходит ли VM для relay в белых списках РФ
#
# Использование:
#   bash check-vm.sh               — проверка IP/ASN/сети
#   bash check-vm.sh 1.2.3.4      — + проверка выхода к твоему VPS (NL/FI)
#   VERBOSE=1 bash check-vm.sh    — показывает raw API ответы

UPSTREAM_VPS="${1:-}"
VERBOSE="${VERBOSE:-0}"

set -euo pipefail

# ══════════════════════════════════════════════════════════════
# Вывод
# ══════════════════════════════════════════════════════════════
GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

ok()       { echo -e "  ${GRN}[✓]${NC} $*"; }
fail_msg() { echo -e "  ${RED}[✗]${NC} $*"; }
warn_msg() { echo -e "  ${YLW}[~]${NC} $*"; }
info()     { echo -e "  ${CYN}[·]${NC} $*"; }
hr()       { echo -e "${CYN}$(printf '═%.0s' {1..48})${NC}"; }

PASS=0; FAIL=0; WARN=0

# (( ++N )) безопасен с set -e: всегда >= 1 → exit code 0
pass()      { (( ++PASS )); ok       "$@"; }
flunk()     { (( ++FAIL )); fail_msg "$@"; }
warn_only() { (( ++WARN )); warn_msg "$@"; }

# ══════════════════════════════════════════════════════════════
# Зависимости
# ══════════════════════════════════════════════════════════════
check_deps() {
    local missing=()
    for cmd in curl jq ping; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${RED}Ошибка: не найдены команды: ${missing[*]}${NC}"
        echo "  apt-get install -y ${missing[*]}"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════
# curl-хелпер — все запросы через одни флаги
# ══════════════════════════════════════════════════════════════
c() { curl --fail --silent --show-error --max-time 5 "$@" 2>/dev/null || true; }

# ══════════════════════════════════════════════════════════════
# CIDR-проверка (чистый bash, без python)
# ══════════════════════════════════════════════════════════════
ip_to_int() {
    local a b c d; IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

in_cidr() {
    local net=${2%/*} pfx=${2#*/}
    local ip_int net_int mask
    ip_int=$(ip_to_int "$1")
    net_int=$(ip_to_int "$net")
    mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    # return 0 = match (true), return 1 = no match (false)
    return $(( (ip_int & mask) != (net_int & mask) ))
}

# ══════════════════════════════════════════════════════════════
# Globals (заполняются в get_ip / get_geo)
# ══════════════════════════════════════════════════════════════
MY_IP="" CC="" ASN_FULL="" ASN_NUM="" ISP="" ORG=""

# ══════════════════════════════════════════════════════════════
# 1. Публичный IP
# ══════════════════════════════════════════════════════════════
get_ip() {
    info "Определяю публичный IP..."
    MY_IP=$(
        c https://api.ipify.org ||
        c https://icanhazip.com ||
        echo ""
    )
    MY_IP="${MY_IP//[$'\t\r\n ']}"  # trim whitespace
}

# ══════════════════════════════════════════════════════════════
# 2. Геолокация + ASN (HTTPS, с fallback)
# ══════════════════════════════════════════════════════════════
get_geo() {
    info "Запрашиваю геолокацию..."
    local raw="" src=""

    # Попытка 1: ipapi.co
    raw=$(c "https://ipapi.co/${MY_IP}/json/")
    src="ipapi.co"
    CC=$(echo "$raw" | jq -r '.country_code // ""' 2>/dev/null || echo "")

    # Fallback: ipwho.is
    if [[ -z "$CC" || "$CC" == "null" ]]; then
        raw=$(c "https://ipwho.is/${MY_IP}")
        src="ipwho.is"
        CC=$(echo "$raw"      | jq -r '.country_code           // ""' 2>/dev/null || echo "")
        ASN_FULL=$(echo "$raw" | jq -r '"AS"+(.connection.asn|tostring)' 2>/dev/null || echo "")
        ISP=$(echo "$raw"      | jq -r '.connection.isp        // ""' 2>/dev/null || echo "")
        ORG=$(echo "$raw"      | jq -r '.connection.org        // ""' 2>/dev/null || echo "")
    else
        ASN_FULL=$(echo "$raw" | jq -r '.asn // ""' 2>/dev/null || echo "")
        ISP=$(echo "$raw"      | jq -r '.org // ""' 2>/dev/null || echo "")
        ORG="$ISP"
    fi

    # Нормализуем ASN: "AS200350 YANDEX" → "AS200350"
    ASN_NUM=$(echo "$ASN_FULL" | grep -oE 'AS[0-9]+' | head -1 || echo "")

    if [[ "$VERBOSE" == "1" ]]; then
        echo ""
        echo -e "  ${CYN}[VERBOSE] источник: $src${NC}"
        echo "$raw" | jq . 2>/dev/null || echo "$raw"
        echo ""
    fi
}

# ══════════════════════════════════════════════════════════════
# 3. Страна — warn если не RU (не fail: ASN важнее)
# ══════════════════════════════════════════════════════════════
check_country() {
    case "$CC" in
        RU)   pass      "Страна: Россия (RU)" ;;
        "")   warn_only "Страна не определена" ;;
        *)    warn_only "Страна: $CC — не RU, но ASN важнее" ;;
    esac
}

# ══════════════════════════════════════════════════════════════
# 4. ASN — PASS если известный, WARN если нет, FAIL если пустой
# ══════════════════════════════════════════════════════════════
declare -A KNOWN_WL=(
    ["AS200350"]="Yandex Cloud"
    ["AS13238"]="Yandex"
    ["AS47764"]="VK Cloud / Mail.ru"
    ["AS57629"]="VK Cloud"
    ["AS210644"]="Aeza"
    ["AS49505"]="Selectel"
    ["AS196954"]="MTS Cloud"
    ["AS8359"]="MTS"
    ["AS31133"]="Megafon"
    ["AS9123"]="Timeweb"
    ["AS8334"]="Beeline"
    ["AS12389"]="Rostelecom"
    ["AS42610"]="Rostelecom Cloud"
    ["AS48666"]="Mastertel"
)

check_asn() {
    if [[ -z "$ASN_NUM" ]]; then
        flunk "ASN не определён — данные о провайдере получить не удалось"
        return
    fi

    local wl="${KNOWN_WL[$ASN_NUM]:-}"
    if [[ -n "$wl" ]]; then
        pass "ASN $ASN_NUM → $wl (есть в белых списках операторов)"
    elif [[ "$CC" == "RU" ]]; then
        # Страна RU, но ASN не в списке — может быть небольшой RU-провайдер
        warn_only "ASN $ASN_NUM (${ISP:-?}) — не в известном списке, но страна RU"
        warn_msg  "    Попробуй, но надёжнее: Yandex Cloud / Aeza / VK Cloud"
    else
        # Страна не RU И ASN не в списке — точно не подойдёт
        flunk "ASN $ASN_NUM (${ISP:-?}) — не RU-облако, белые списки операторов не пройдёт"
        fail_msg "    Нужен: Yandex Cloud / Aeza / VK Cloud / Selectel / Timeweb"
    fi
}

# ══════════════════════════════════════════════════════════════
# 5. CIDR — только info, не влияет на счётчики
# ══════════════════════════════════════════════════════════════
check_cidr() {
    local -a ranges=(
        "84.201.0.0/16"    "84.252.128.0/17"  "158.160.0.0/16"   # Yandex Cloud
        "51.250.0.0/16"    "62.84.112.0/20"   "89.249.160.0/21"  # Yandex Cloud
        "130.193.32.0/19"  "178.154.128.0/17" "93.158.128.0/18"  # Yandex Cloud
        "94.100.0.0/16"    "217.69.128.0/17"  "195.239.160.0/20" # VK / Mail.ru
        "185.30.176.0/22"  "194.67.0.0/16"                       # VK / Mail.ru
        "185.231.204.0/22" "185.233.116.0/22"                    # Aeza RU
        "185.159.128.0/19" "92.223.64.0/18"                      # Selectel
        "212.193.128.0/19" "31.130.224.0/20"                     # Timeweb
    )
    for cidr in "${ranges[@]}"; do
        if in_cidr "$MY_IP" "$cidr"; then
            info "CIDR: $MY_IP входит в $cidr"
            return
        fi
    done
    info "CIDR: IP не найден в захардкоженных диапазонах (ASN важнее)"
}

# ══════════════════════════════════════════════════════════════
# 6. Сеть — PASS если хотя бы один URL доступен
# ══════════════════════════════════════════════════════════════
check_network() {
    local urls=("https://ya.ru" "https://vk.com" "https://google.com")
    for url in "${urls[@]}"; do
        if c "$url" -o /dev/null; then
            pass "Интернет: $url доступен"
            return
        fi
    done
    flunk "Интернет недоступен (ya.ru + vk.com + google.com — все не отвечают)"
}

# ══════════════════════════════════════════════════════════════
# 7. Порт 443
# ══════════════════════════════════════════════════════════════
check_port() {
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        warn_only "Порт 443 занят — укажи другой через RELAY_PORT=8443"
    else
        pass "Порт 443 свободен"
    fi
}

# ══════════════════════════════════════════════════════════════
# 8. Пинг — только info, не влияет на счётчики
# ══════════════════════════════════════════════════════════════
check_ping() {
    local ms
    ms=$(ping -c2 -W3 ya.ru 2>/dev/null | awk -F'/' '/rtt/{print $5}' || echo "")
    if [[ -z "$ms" ]]; then
        info "Пинг ya.ru: нет ответа (ICMP закрыт — это нормально)"
        return
    fi
    local ms_int=${ms%.*}
    if   (( ms_int < 20  )); then info     "Пинг ya.ru: ${ms}ms — отлично (RU-сегмент)"
    elif (( ms_int < 60  )); then info     "Пинг ya.ru: ${ms}ms — норм"
    else                          warn_msg "  Пинг ya.ru: ${ms}ms — высокий, возможно VM не в RU"
    fi
}

# ══════════════════════════════════════════════════════════════
# 9. Выход к upstream VPS (опционально)
# ══════════════════════════════════════════════════════════════
tcp_check() {
    # Использует bash /dev/tcp — нет зависимости от nc
    (echo >/dev/tcp/"$1"/"$2") 2>/dev/null
}

check_upstream() {
    if [[ -z "$UPSTREAM_VPS" ]]; then
        info "Upstream VPS не указан (передай IP аргументом для проверки выхода)"
        return
    fi
    info "Проверяю TCP до VPS $UPSTREAM_VPS..."
    if tcp_check "$UPSTREAM_VPS" 443 || tcp_check "$UPSTREAM_VPS" 8443; then
        pass "Выход к $UPSTREAM_VPS — есть (443 или 8443)"
    else
        warn_only "Выход к $UPSTREAM_VPS — нет на 443/8443"
        warn_msg  "    OK если inbound ещё не добавлен в Marzban на VPS"
    fi
}

# ══════════════════════════════════════════════════════════════
# Итог
# ══════════════════════════════════════════════════════════════
print_verdict() {
    echo ""
    hr
    if (( FAIL > 0 )); then
        echo -e "${BLD}${RED}  РЕЗУЛЬТАТ: VM НЕ ПОДХОДИТ ✗${NC}"
        echo ""
        echo "  Критических ошибок: $FAIL — ищи другой VM."
        echo ""
        echo "  Где брать RU-VM с белым IP:"
        echo "    • Yandex Cloud  cloud.yandex.ru  (~400 ₽/мес preemptible)"
        echo "    • Aeza RU       aeza.net"
        echo "    • VK Cloud      cloud.vk.com"
        echo "    • Selectel      selectel.ru"
        echo "    • Timeweb       timeweb.cloud"
    elif (( WARN > 0 )); then
        echo -e "${BLD}${YLW}  РЕЗУЛЬТАТ: ВОЗМОЖНО ПОДОЙДЁТ ⚠${NC}"
        echo ""
        echo "  IP:  $MY_IP"
        echo "  ASN: ${ASN_NUM:-?}  ${ISP:-}"
        echo ""
        echo "  Предупреждений: $WARN. Если провайдер реально RU-облако — пробуй."
        echo "  Следующий шаг:  sudo bash setup-relay.sh"
    else
        echo -e "${BLD}${GRN}  РЕЗУЛЬТАТ: VM ПОДХОДИТ ✓${NC}"
        echo ""
        echo "  IP:  $MY_IP"
        echo "  ASN: $ASN_NUM  ${ISP}"
        echo ""
        echo "  Следующий шаг:  sudo bash setup-relay.sh"
    fi
    hr
    echo ""
}

# ══════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════
main() {
    hr
    echo -e "${BLD}${CYN}   check-vm.sh — проверка VM для RU relay${NC}"
    hr
    echo ""

    check_deps

    get_ip
    if [[ -z "$MY_IP" ]]; then
        flunk "Публичный IP не определён — нет интернета?"
        print_verdict; exit 1
    fi
    info "IP: $MY_IP"

    get_geo
    echo ""
    printf "  Страна: %s\n"  "${CC:-неизвестно}"
    printf "  ASN:    %s\n"  "${ASN_FULL:-неизвестно}"
    printf "  ISP:    %s\n"  "${ISP:-неизвестно}"
    echo ""

    echo -e "${CYN}── Проверки ──────────────────────────────────────${NC}"
    check_country
    check_asn
    check_cidr
    check_network
    check_port
    check_ping
    check_upstream

    print_verdict
}

main "$@"
