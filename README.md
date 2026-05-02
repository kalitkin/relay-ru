# relay-ru — обход МТС DPI через RU-облако

Автоматическая установка VLESS+Reality+Fragment relay-ноды в российском облаке (Yandex Cloud) для обхода блокировок мобильного оператора МТС.

---

## Как это работает

```
Телефон (МТС mobile)
    │  VLESS + Reality + Fragment(tlshello)
    ▼
Relay VM (Yandex Cloud, Москва)  ← этот репозиторий
    │  VLESS + Reality
    ▼
Upstream VPS (NL / FI / TR)  ← твой Marzban
    │
    ▼
Интернет
```

**Почему нужен relay в российском облаке?**

МТС (и другие мобильные операторы РФ) пропускают TCP-трафик только к нескольким «доверенным» российским провайдерам — Yandex Cloud, VK Cloud, Aeza, Selectel, Timeweb. К любому зарубежному IP TCP SYN дропается ещё на уровне оператора. Поэтому нельзя подключиться к VPS в Нидерландах напрямую — нужен промежуточный relay в RU.

**Почему Fragment?**

Даже к whitelisted IP МТС DPI активен. Он модифицирует байты TLS session ID в ClientHello — это ломает Reality authentication (Xray 25.x использует session ID для auth). Fragment дробит TLS ClientHello на несколько TCP-пакетов (`packets: tlshello`), и DPI не успевает собрать и модифицировать session ID. Reality handshake проходит.

**Почему SNI dzen.ru?**

Российский домен, находится в whitelist МТС. SNI не используется для реального подключения (Reality camouflage), но DPI смотрит на него при решении — пропускать или нет.

---

## Что умеет скрипт

- Устанавливает xray-core на чистую Ubuntu VM за ~3 минуты
- Генерирует Reality ключи и UUID автоматически
- Получает Let's Encrypt сертификат через sslip.io (без регистрации домена)
- Поднимает HTTPS subscription endpoint — добавляешь ссылку в HAPP/incy и получаешь рабочий конфиг с fragment
- Настраивает failover между NL/FI/TR upstream (leastPing балансировка)
- Настраивает kernel (BBR, TCP буферы 64MB, keepalive), swap, logrotate, iptables, healthcheck timer
- `--update` — обновляет UUID upstream без пересоздания inbound (нужно после ротации Marzban)

---

## Быстрый старт

### 1. Создай VM в Yandex Cloud

- Регион: **ru-central1** (Москва) — обязательно, МТС whitelist по ASN
- OS: Ubuntu 24.04
- RAM: 2 GB, 2 vCPU
- Публичный IP: да

В Security Group открой входящий трафик (CIDR `0.0.0.0/0`):

| Протокол | Порт | Назначение |
|----------|------|-----------|
| TCP | 443 | клиенты (Reality) |
| TCP | 8444 | subscription |
| TCP | 80 | Let's Encrypt renewal |
| TCP | 22 | SSH |

### 2. Установи relay

```bash
curl -fsSL https://raw.githubusercontent.com/kalitkin/relay-ru/main/setup-relay.sh -o /tmp/sr.sh
sudo bash /tmp/sr.sh "https://your-marzban.domain/sub/TOKEN"
```

Вместо Marzban subscription URL можно передать VLESS-ссылки напрямую:

```bash
# Одна нода
sudo bash /tmp/sr.sh "vless://UUID@144.31.123.202:8443?security=reality&sni=self-music.online&pbk=KEY&sid=SID&fp=chrome&flow=xtls-rprx-vision&type=tcp#NL"

# Несколько нод (failover)
sudo bash /tmp/sr.sh "vless://...#NL" "vless://...#FI" "vless://...#TR"
```

### 3. Добавь subscription в HAPP

После установки скрипт выведет:

```
Subscription URL: https://130-193-50-141.sslip.io:8444/relay.json
```

Добавь эту ссылку в HAPP (iOS) как подписку. Всё — подключение настроено.

---

## Команды управления

```bash
# Состояние (upstreams, порт, subscription URL, healthcheck лог)
sudo bash sr.sh --status

# Обновить UUID upstream после ротации Marzban
sudo bash sr.sh --update "https://your-marzban.domain/sub/TOKEN"

# Живые логи
journalctl -u xray-relay -f

# Удалить всё
sudo bash sr.sh --uninstall
```

---

## Переменные окружения

```bash
RELAY_PORT=443            # порт для клиентов (по умолчанию 443)
RELAY_SNI=dzen.ru         # SNI для Reality camouflage (по умолчанию случайный из пула)
RELAY_UUID=<uuid>         # зафиксировать UUID inbound (по умолчанию генерируется)
CONN_LIMIT=2048           # лимит соединений с одного IP (МТС CGNAT — много юзеров за одним IP)
CERTBOT_EMAIL=a@b.com     # email для LE cert
LOG_LEVEL=warning         # xray loglevel (info для отладки)
```

---

## Клиентский конфиг (fragment-паттерн)

Subscription endpoint отдаёт этот JSON. Ключевое — `dialerProxy: "fragment"` и outbound `fragment` с `packets: tlshello`:

```json
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [{"address": "RELAY_IP", "port": 443,
          "users": [{"encryption": "none", "id": "RELAY_UUID", "level": 8}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "publicKey": "RELAY_PUBKEY",
          "serverName": "dzen.ru",
          "shortId": "RELAY_SHORTID"
        },
        "sockopt": {"dialerProxy": "fragment"}
      },
      "tag": "proxy"
    },
    {
      "protocol": "freedom",
      "settings": {
        "fragment": {
          "packets": "tlshello",
          "length": "1400",
          "interval": "10-20",
          "maxSplit": "100-200"
        }
      },
      "streamSettings": {"network": "tcp", "security": "none",
        "sockopt": {"mark": 255, "TcpNoDelay": true}},
      "tag": "fragment"
    }
  ]
}
```

---

## Как мы пришли к этому решению

### Этап 1 — Выбор облака

Первая попытка создать VM дала IP из Пакистана (пакет VPS в непонятном облаке). МТС whitelist работает по ASN — проверяешь командой:

```bash
curl -s "https://ipinfo.io/130.193.50.141" | grep -E "org|country"
```

Нужно AS200350 (Yandex Cloud) или AS47764 (VK Cloud) или Aeza/Selectel/Timeweb. Пересоздали VM в ru-central1 Москва.

### Этап 2 — Reality без Fragment не работает

Поставили стандартный VLESS+Reality. С WiFi работало. С мобильной сети МТС — нет. Логи показывали:

```
REALITY: processed invalid connection
```

Через `tcpdump` сравнили пакеты:

| | WiFi (работает) | МТС mobile (не работает) |
|--|--|--|
| Размер ClientHello | 517 байт | 367 байт |
| session ID | оригинальный | **изменён DPI** |

**Вывод:** МТС DPI на мобильной сети модифицирует байты TLS session ID. Xray 25.x использует session ID для Reality authentication → auth ломается.

### Этап 3 — TLS с самоподписанным сертификатом

Перешли с Reality на обычный TLS (самоподписанный серт). Ошибка изменилась:

```
failed to read request version > i/o timeout
```

TCP+TLS соединение устанавливается, но данные не приходят. **Диагноз:** МТС делает TLS MITM — принимает TLS от клиента, устанавливает своё TLS с нашим сервером, расшифровывает, видит VLESS внутри, дропает. `allowInsecure=1` позволяло DPI MITM работать.

### Этап 4 — Let's Encrypt сертификат

С настоящим LE cert клиент отклоняет поддельный серт от DPI → MITM не проходит. Использовали sslip.io — бесплатный DNS без регистрации (`130-193-50-141.sslip.io` → `130.193.50.141`).

Но tcpdump показал: клиент шлёт Reality ClientHello (расширение `fe0d`) даже при `security=tls` в URL. Некоторые приложения (v2rayNG/incy) игнорируют параметр и используют Reality если видят `flow=xtls-rprx-vision`. Несовместимость с нашим TLS сервером.

### Этап 5 — Fragment (РЕШЕНИЕ)

Fragment фрагментирует сам TLS ClientHello на несколько TCP-пакетов. DPI получает первый фрагмент — это неполный ClientHello — и не успевает собрать полный пакет для модификации session ID. Reality handshake проходит без изменений.

Подтверждено: **179 соединений с 91.78.233.86 (МТС CGNAT mobile)** в access.log через несколько часов работы.

### Этап 6 — Subscription endpoint для HAPP

HAPP (iOS) требует HTTPS subscription URL — нельзя вставить JSON вручную. Поставили Python HTTPS сервер на порту 8444 с LE сертификатом. Subscription отдаёт готовый fragment-конфиг.

incy (другое iOS приложение) генерирует пустой shortId в Reality — добавили `""` в список `shortIds` на сервере для совместимости.

### Этап 7 — Нестабильность и UUID ротация

После нескольких дней работа стала нестабильной. Диагностика показала:

- UUID в Marzban сменился (`39d0b44d` → `d20b9d3f`) — relay подключался к upstream с устаревшим UUID → все соединения отклонялись
- TCP буферы дефолтные 208 KB — узкое место под нагрузкой
- Один upstream NL — если он падает, всё

**Исправлено:**
- Добавили команду `--update` для синхронизации UUID без пересоздания inbound
- Добавили FI и TR как failover с leastPing балансировкой
- TCP буферы 64 MB, keepalive 60s, swap 512MB, conntrack max 262144, logrotate

---

## Поведение МТС DPI (выводы)

| Атака | Симптом | Решение |
|-------|---------|---------|
| Модификация TLS session ID | `REALITY: processed invalid connection` | Fragment (tlshello) |
| TLS MITM | `failed to read request version` | LE cert (клиент отклоняет поддельный) |
| Silent payload drop | TCP handshake ок, данные не идут | — (обходится через Fragment+Reality) |
| UDP/QUIC drop | Hysteria/QUIC не работает | Не обходится — только TCP |
| Whitelist по ASN | TCP SYN drop к зарубежным IP | Relay в Yandex Cloud |

**На WiFi DPI не активен.** Тестировать только на мобильной сети.

---

## Файлы на VM после установки

```
/usr/local/bin/xray                   — xray-core бинарь
/usr/local/etc/xray/config.json       — конфиг (600, только root)
/etc/relay-state.json                 — UUID, ключи, subscription URL
/var/www/sub/relay.json               — клиентский конфиг с fragment
/var/www/sub/https_server.py          — HTTPS subscription сервер
/usr/local/bin/relay-healthcheck      — скрипт проверки
/var/log/xray/access.log              — логи соединений
/var/log/xray/error.log               — логи ошибок
/var/log/xray/healthcheck.log         — история healthcheck
```

**Systemd сервисы:**

```
xray-relay.service          — основной процесс xray
relay-sub.service           — HTTPS subscription сервер
relay-healthcheck.timer     — проверка каждые 5 минут
```

---

## Troubleshooting

**Клиент не подключается с мобильной сети (WiFi работает)**
```bash
# Проверить что xray слушает порт
ss -tlnp | grep 443

# Смотреть логи в реальном времени
sudo journalctl -u xray-relay -f

# Включить verbose логи
sudo LOG_LEVEL=info systemctl restart xray-relay
```

**`REALITY: processed invalid connection` в error.log**

Это нормальный шум — боты и сканеры стучатся на порт 443. Если таких ошибок много и клиент не работает — проверь fragment в клиентском конфиге.

**Subscription недоступна**
```bash
systemctl status relay-sub
journalctl -u relay-sub -n 20
```

**UUID устарел (Marzban ротировал)**
```bash
sudo bash sr.sh --update "https://your-marzban.domain/sub/TOKEN"
```

**Проверить что upstream отвечает**
```bash
sudo bash sr.sh --status
```
