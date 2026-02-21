#!/bin/bash
# Скрипт для идемпотентной установки/обновления Xray и настройки клиента VLESS Reality
# Принимает:
# 1. Строку подключения VLESS
# 2. (Опционально) login:pass для HTTP прокси

set -e

# Проверка наличия аргументов
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Использование: $0 'vless://...' ['login:pass']"
    exit 1
fi

CONNECTION_STRING="$1"
PROXY_AUTH_RAW="$2"
LISTEN_IP="0.0.0.0" # Изменил на локальный IP для безопасности, теперь совпадает везде
LISTEN_PORT=${3:-$((RANDOM % 20000 + 20000))}

# Проверка формата VLESS
if [[ ! "$CONNECTION_STRING" =~ ^vless:// ]]; then
    echo "Ошибка: строка должна начинаться с vless://"
    exit 1
fi

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then 
    echo "Пожалуйста, запустите скрипт от имени root."
    exit 1
fi

echo "Обновляем систему и устанавливаем зависимости..."
apt update && apt upgrade -y
apt install -y curl unzip jq

# Установка Xray
if [ ! -f /usr/local/bin/xray ]; then
    echo "Xray не найден. Устанавливаем Xray..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install --version v24.9.7
else
    echo "Xray уже установлен, пропускаем установку."
fi

# --- Парсинг строки подключения ---
echo "Разбираем строку подключения..."
uri="${CONNECTION_STRING#vless://}"
before_query="${uri%%\?*}"
query="${uri#*\?}"

if [[ "$before_query" == *"@"* ]]; then
    uuid="${before_query%%@*}"
    hostport="${before_query#*@}"
else
    echo "Ошибка: не удалось найти uuid@host в строке"
    exit 1
fi

hostport="${hostport%/}"
if [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"
    port="${hostport#*:}"
else
    host="$hostport"
    port="443"
fi

# Инициализация параметров Reality
encryption="none"; network="tcp"; sni=""; fingerprint="chrome"; security=""; alpn=""; flow=""; publicKey=""; shortId=""; packetEncoding=""

IFS='&' read -ra params <<< "$query"
for param in "${params[@]}"; do
    key="${param%%=*}"
    value="${param#*=}"
    case "$key" in
        encryption) encryption="$value" ;;
        type) network="$value" ;;
        sni) sni="$value" ;;
        fp) fingerprint="$value" ;;
        security) security="$value" ;;
        alpn) alpn="$value" ;;
        flow) flow="$value" ;;
        pbk) publicKey="$value" ;;
        sid) shortId="$value" ;;
        packetEncoding) packetEncoding="$value" ;;
    esac
done

if [ "$security" != "reality" ]; then echo "Ошибка: только security=reality"; exit 1; fi

# --- Настройка авторизации прокси ---
HTTP_SETTINGS="{}"
if [ -n "$PROXY_AUTH_RAW" ]; then
    # Разделяем login:pass
    PROXY_USER="${PROXY_AUTH_RAW%%:*}"
    PROXY_PASS="${PROXY_AUTH_RAW#*:}"
    HTTP_SETTINGS="{ \"accounts\": [ { \"user\": \"$PROXY_USER\", \"pass\": \"$PROXY_PASS\" } ] }"
    AUTH_LOG="Авторизация: $PROXY_USER:$PROXY_PASS"
else
    AUTH_LOG="Авторизация: отключена"
fi

# --- Генерация конфига ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
[ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "${CONFIG_PATH}.bak_$(date +%s)"

# Подготовка ALPN и Reality Settings
[ -n "$alpn" ] && alpn_json="\"alpn\": [$(echo "$alpn" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd ',' -)]" || alpn_json=""
reality_settings="\"realitySettings\": { \"show\": false, \"fingerprint\": \"$fingerprint\", \"serverName\": \"$sni\", \"publicKey\": \"$publicKey\", \"shortId\": \"$shortId\" ${alpn_json:+, $alpn_json} }"
stream_settings="\"streamSettings\": { \"network\": \"$network\", \"security\": \"$security\", $reality_settings ${packetEncoding:+, \"packetEncoding\": \"$packetEncoding\"} }"

cat > "$CONFIG_PATH" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "listen": "$LISTEN_IP",
            "port": $LISTEN_PORT,
            "protocol": "http",
            "settings": $HTTP_SETTINGS,
            "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": "$host",
                    "port": $port,
                    "users": [{ "id": "$uuid", "encryption": "$encryption", "flow": "$flow" }]
                }]
            },
            $stream_settings
        }
    ]
}
EOF

# Проверка и перезапуск
jq . "$CONFIG_PATH" >/dev/null
systemctl restart xray
sleep 2

if [ "$(systemctl is-active xray)" = "active" ]; then
    echo "==========================================="
    echo "Xray успешно настроен как HTTP-клиент!"
    echo ""
    echo "Адрес прокси:  $LISTEN_IP:$LISTEN_PORT"
    echo "$AUTH_LOG"
    echo "Протокол:      HTTP"
    echo ""
    echo "Пример использования (Linux):"
    if [ -n "$PROXY_AUTH_RAW" ]; then
        echo "export http_proxy=\"http://$PROXY_USER:$PROXY_PASS@$LISTEN_IP:$LISTEN_PORT\""
    else
        echo "export http_proxy=\"http://$LISTEN_IP:$LISTEN_PORT\""
    fi
    echo "==========================================="
else
    echo "Ошибка запуска. Проверьте: journalctl -u xray"
    exit 1
fi
