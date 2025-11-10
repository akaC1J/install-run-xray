#!/bin/bash
# Скрипт для идемпотентной установки/обновления Xray (VLESS + Reality)
# При каждом запуске генерируются новые UUID, приватный и публичный ключи,
# обновляется конфигурация Xray и перезапускается служба.
# По завершении выводятся новые параметры и VLESS-ссылка для клиента.

set -e

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

echo "Генерируем новую пару ключей (X25519)..."
KEYS_OUTPUT=$(xray x25519)
# Ожидается вывод вида:
#   Private key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   Public key:  yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Public key:" | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "Ошибка: не удалось сгенерировать ключи."
    exit 1
fi

echo "Сгенерирован новый приватный ключ"
echo "Сгенерирован новый публичный ключ"

# Генерация нового UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "Сгенерирован новый UUID"

# Определяем путь к конфигурационному файлу
CONFIG_PATH="/usr/local/etc/xray/config.json"

# Если файл конфигурации существует, делаем его резервную копию
if [ -f "$CONFIG_PATH" ]; then
    echo "Найдена существующая конфигурация. Создаём резервную копию..."
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak_$(date +%s)"
fi

echo "Создаём новый конфигурационный файл Xray: $CONFIG_PATH"
cat > "$CONFIG_PATH" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "www.google.com:443",
                    "xver": 0,
                    "serverNames": [
                        "www.google.com"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [""]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF

echo "Проверяем корректность JSON-конфига..."
jq . "$CONFIG_PATH" >/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: конфигурационный файл невалидный."
    exit 1
fi

# Устанавливаем права доступа к конфигурационному файлу
chown nobody:nogroup "$CONFIG_PATH"
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

# Получаем внешний IP сервера
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo "Не удалось определить внешний IP сервера."
    SERVER_IP="YOUR_SERVER_IP"
fi

# Формируем VLESS-ссылку для клиента
VLESS_LINK="vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google.com&fp=chrome&pbk=$PUBLIC_KEY&sid=&type=tcp&headerType=none#MyGoogleProxy"

echo "==========================================="
echo "Xray установлен/обновлён успешно!"
echo ""
echo "Новые параметры:"
echo "UUID:         $UUID"
echo "Private Key:  $PRIVATE_KEY"
echo "Public Key:   $PUBLIC_KEY"
echo ""
echo "VLESS-ссылка для клиента:"
echo "$VLESS_LINK"
echo "==========================================="
