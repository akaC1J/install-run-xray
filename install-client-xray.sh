#!/bin/bash
# Скрипт для идемпотентной установки/обновления Xray и настройки клиента VLESS Reality
# Принимает один аргумент — строку подключения вида:
#   vless://uuid@host:port?param1=value1&param2=value2...
# Конфигурирует Xray как клиент с SOCKS5 прокси на 127.0.0.1:1080

set -e

# Проверка наличия аргумента
if [ $# -ne 1 ]; then
    echo "Ошибка: не указана строка подключения."
    echo "Использование: $0 'vless://...'"
    exit 1
fi

CONNECTION_STRING="$1"

# Проверка формата
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

# Проверка, установлен ли Xray
if [ ! -f /usr/local/bin/xray ]; then
    echo "Xray не найден. Устанавливаем Xray..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install --version v24.9.7
else
    echo "Xray уже установлен, пропускаем установку."
fi

# --- Парсинг строки подключения ---
echo "Разбираем строку подключения..."

# Удаляем префикс vless://
uri="${CONNECTION_STRING#vless://}"

# Разделяем на часть до ? и query
before_query="${uri%%\?*}"
query="${uri#*\?}"

# Если в before_query есть @, разделяем на uuid и hostport
if [[ "$before_query" == *"@"* ]]; then
    uuid="${before_query%%@*}"
    hostport="${before_query#*@}"
else
    echo "Ошибка: не удалось найти uuid@host в строке"
    exit 1
fi

# Удаляем возможный завершающий слеш
hostport="${hostport%/}"

# Разделяем hostport на host и port
if [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"
    port="${hostport#*:}"
else
    host="$hostport"
    port="443"   # порт по умолчанию
fi

# Проверка, что порт число
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: порт должен быть числом"
    exit 1
fi

# Инициализируем переменные для параметров
encryption="none"
network="tcp"
sni=""
fingerprint="chrome"
security=""
alpn=""
flow=""
publicKey=""
shortId=""
packetEncoding=""
headerType=""

# Разбираем query-параметры
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
        headerType) headerType="$value" ;;
        *) echo "Предупреждение: неизвестный параметр $key" ;;
    esac
done

# Проверка обязательных параметров для Reality
if [ "$security" != "reality" ]; then
    echo "Ошибка: данный скрипт поддерживает только security=reality"
    exit 1
fi
if [ -z "$publicKey" ]; then
    echo "Ошибка: не указан публичный ключ (pbk)"
    exit 1
fi
if [ -z "$sni" ]; then
    echo "Ошибка: не указан sni (serverName)"
    exit 1
fi
if [ -z "$uuid" ]; then
    echo "Ошибка: не удалось извлечь UUID"
    exit 1
fi

# Устанавливаем значение по умолчанию для shortId, если не задано
[ -z "$shortId" ] && shortId=""

# --- Формирование конфигурации Xray для клиента ---
CONFIG_PATH="/usr/local/etc/xray/config.json"

# Если файл конфигурации существует, делаем его резервную копию
if [ -f "$CONFIG_PATH" ]; then
    echo "Найдена существующая конфигурация. Создаём резервную копию..."
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak_$(date +%s)"
fi

echo "Создаём новый конфигурационный файл Xray (клиент): $CONFIG_PATH"

# Формируем JSON с помощью heredoc
# Обрабатываем alpn как массив, если содержит запятую
if [ -n "$alpn" ]; then
    if [[ "$alpn" == *","* ]]; then
        # Преобразуем в JSON массив
        alpn_array=$(echo "$alpn" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd ',' -)
        alpn_json="\"alpn\": [$alpn_array]"
    else
        alpn_json="\"alpn\": [\"$alpn\"]"
    fi
else
    alpn_json=""
fi

# Формируем realitySettings с alpn, если он задан
if [ -n "$alpn_json" ]; then
    reality_settings="\"realitySettings\": { \"show\": false, \"fingerprint\": \"$fingerprint\", \"serverName\": \"$sni\", \"publicKey\": \"$publicKey\", \"shortId\": \"$shortId\", $alpn_json }"
else
    reality_settings="\"realitySettings\": { \"show\": false, \"fingerprint\": \"$fingerprint\", \"serverName\": \"$sni\", \"publicKey\": \"$publicKey\", \"shortId\": \"$shortId\" }"
fi

# Добавляем packetEncoding, если задан
if [ -n "$packetEncoding" ]; then
    packet_encoding_json="\"packetEncoding\": \"$packetEncoding\""
    stream_settings_separator=", "
else
    packet_encoding_json=""
    stream_settings_separator=""
fi

# Собираем streamSettings
if [ -n "$packet_encoding_json" ]; then
    stream_settings="\"streamSettings\": { \"network\": \"$network\", \"security\": \"$security\", $reality_settings, $packet_encoding_json }"
else
    stream_settings="\"streamSettings\": { \"network\": \"$network\", \"security\": \"$security\", $reality_settings }"
fi

# Записываем конфиг
cat > "$CONFIG_PATH" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 1080,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true,
                "ip": "127.0.0.1"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "$host",
                        "port": $port,
                        "users": [
                            {
                                "id": "$uuid",
                                "encryption": "$encryption",
                                "flow": "$flow"
                            }
                        ]
                    }
                ]
            },
            $stream_settings
        }
    ]
}
EOF

# Проверка корректности JSON
echo "Проверяем корректность JSON-конфига..."
jq . "$CONFIG_PATH" >/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: конфигурационный файл невалидный."
    exit 1
fi

# Устанавливаем права доступа к конфигурационному файлу
chown nobody:nogroup "$CONFIG_PATH" 2>/dev/null || chown nobody:nobody "$CONFIG_PATH" 2>/dev/null || true
chmod 644 "$CONFIG_PATH"

echo "Перезапускаем службу Xray..."
systemctl restart xray
sleep 2

SERVICE_STATUS=$(systemctl is-active xray)
if [ "$SERVICE_STATUS" = "active" ]; then
    echo "Служба Xray успешно запущена!"
else
    echo "Ошибка: служба Xray не запущена. Статус:"
    systemctl status xray --no-pager
    exit 1
fi

echo "==========================================="
echo "Xray настроен как клиент VLESS Reality."
echo ""
echo "Локальный SOCKS5 прокси: 127.0.0.1:1080"
echo "UDP поддерживается."
echo ""
echo "Для использования выполните, например:"
echo "  export http_proxy=socks5://127.0.0.1:1080"
echo "  export https_proxy=socks5://127.0.0.1:1080"
echo "или настройте приложение на прокси 127.0.0.1:1080 (SOCKS5)."
echo ""
echo "Исходная строка подключения:"
echo "$CONNECTION_STRING"
echo "==========================================="
