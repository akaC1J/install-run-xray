#!/bin/bash
# Идемпотентная установка/обновление Xray и настройка клиента VLESS Reality
# + inbound: Shadowsocks (весь трафик -> vless-out)
# + inbound: SOCKS5 (auth) -> direct-out

set -euo pipefail

# ---- args ----
if [ $# -ne 1 ]; then
  echo "Использование: $0 'vless://...'"
  exit 1
fi

CONNECTION_STRING="$1"

# ---- helpers ----
urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# ---- checks ----
if [[ ! "$CONNECTION_STRING" =~ ^vless:// ]]; then
  echo "Ошибка: строка должна начинаться с vless://"
  exit 1
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Запустите скрипт от root."
  exit 1
fi

# ---- packages ----
apt update -y
apt install -y curl unzip jq openssl

# ---- install xray ----
if [ ! -f /usr/local/bin/xray ]; then
  echo "Устанавливаем Xray..."
  bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
else
  echo "Xray уже установлен."
fi

# ---- random ports/password ----
SS_PORT="${SS_PORT:-$((RANDOM % 20000 + 20000))}"
SOCKS_PORT="${SOCKS_PORT:-$((RANDOM % 20000 + 10000))}"
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PASSWORD="${SS_PASSWORD:-$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)}"

SOCKS_USER="fuck_rkn"
SOCKS_PASS="$SS_PASSWORD"

# ---- parse VLESS ----
uri="${CONNECTION_STRING#vless://}"
uri="${uri%%#*}"

before_query="$uri"
query=""

if [[ "$uri" == *"?"* ]]; then
  before_query="${uri%%\?*}"
  query="${uri#*\?}"
fi

if [[ "$before_query" != *"@"* ]]; then
  echo "Неверная ссылка (нет uuid@host)"
  exit 1
fi

uuid="${before_query%%@*}"
hostport="${before_query#*@}"
hostport="${hostport%%/*}"

if [[ "$hostport" == *":"* ]]; then
  host="${hostport%:*}"
  port="${hostport#*:}"
else
  host="$hostport"
  port="443"
fi

# defaults
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

if [ -n "$query" ]; then
  IFS='&' read -ra params <<< "$query"
  for param in "${params[@]}"; do
    key="${param%%=*}"
    value="${param#*=}"
    value="$(urldecode "$value")"
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
fi

if [ "$security" != "reality" ]; then
  echo "Требуется security=reality"
  exit 1
fi

if [ -z "$sni" ] || [ -z "$publicKey" ]; then
  echo "В ссылке должны быть sni и pbk"
  exit 1
fi

CONFIG_PATH="/usr/local/etc/xray/config.json"
mkdir -p /usr/local/etc/xray
[ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "${CONFIG_PATH}.bak_$(date +%s)"

# ---- alpn array ----
ALPN_JSON="null"
if [ -n "$alpn" ]; then
  ALPN_JSON="$(printf '%s' "$alpn" | awk -F',' 'BEGIN{printf "["} {for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","}} END{printf "]"}')"
fi

# ---- build config ----
XRAY_CONFIG="$(jq -n \
  --arg ss_method "$SS_METHOD" \
  --arg ss_pass "$SS_PASSWORD" \
  --argjson ss_port "$SS_PORT" \
  --arg socks_user "$SOCKS_USER" \
  --arg socks_pass "$SOCKS_PASS" \
  --argjson socks_port "$SOCKS_PORT" \
  --arg host "$host" \
  --argjson port_num "$port" \
  --arg uuid "$uuid" \
  --arg enc "$encryption" \
  --arg flow "$flow" \
  --arg net "$network" \
  --arg fp "$fingerprint" \
  --arg sni "$sni" \
  --arg pbk "$publicKey" \
  --arg sid "$shortId" \
  --arg pe "$packetEncoding" \
  --argjson alpn_arr "$ALPN_JSON" '
{
  log: { loglevel: "warning" },

  inbounds: [
    {
      tag: "ss-in",
      port: $ss_port,
      protocol: "shadowsocks",
      settings: {
        method: $ss_method,
        password: $ss_pass,
        network: "tcp,udp"
      }
    },
    {
      tag: "socks-in",
      listen: "0.0.0.0",
      port: $socks_port,
      protocol: "socks",
      settings: {
        auth: "password",
        udp: true,
        accounts: [
          { user: $socks_user, pass: $socks_pass }
        ]
      }
    }
  ],

  outbounds: [
    {
      tag: "vless-out",
      protocol: "vless",
      settings: {
        vnext: [
          {
            address: $host,
            port: $port_num,
            users: [
              ({
                id: $uuid,
                encryption: $enc
              } + (if $flow != "" then {flow: $flow} else {} end))
            ]
          }
        ]
      },
      streamSettings:
        ({
          network: $net,
          security: "reality",
          realitySettings:
            ({
              show: false,
              fingerprint: $fp,
              serverName: $sni,
              publicKey: $pbk
            }
            + (if $sid != "" then {shortId: $sid} else {} end)
            + (if $alpn_arr != null then {alpn: $alpn_arr} else {} end))
        }
        + (if $pe != "" then {packetEncoding: $pe} else {} end))
    },
    {
      tag: "direct-out",
      protocol: "freedom"
    }
  ],

  routing: {
    rules: [
      {
        type: "field",
        inboundTag: ["ss-in"],
        outboundTag: "vless-out"
      },
      {
        type: "field",
        inboundTag: ["socks-in"],
        outboundTag: "direct-out"
      }
    ]
  }
}
')"

printf '%s\n' "$XRAY_CONFIG" > "$CONFIG_PATH"

# ---- validate ----
jq . "$CONFIG_PATH" >/dev/null
xray -test -config "$CONFIG_PATH"

systemctl restart xray
sleep 2

echo ""
echo "============================================================"
echo "                    XRAY CONFIGURATION                     "
echo "============================================================"
echo ""
printf "  %-20s %s\n" "STATUS:" "RUNNING"
echo ""
echo "  [ Shadowsocks → VLESS Reality ]"
printf "    %-18s %s\n" "Port:" "$SS_PORT"
printf "    %-18s %s\n" "Method:" "$SS_METHOD"
printf "    %-18s %s\n" "Password:" "$SS_PASSWORD"
echo ""
echo "  [ SOCKS5 (auth) → DIRECT ]"
printf "    %-18s %s\n" "Port:" "$SOCKS_PORT"
printf "    %-18s %s\n" "Username:" "$SOCKS_USER"
printf "    %-18s %s\n" "Password:" "$SOCKS_PASS"
echo ""
echo "  [ VLESS Reality Outbound ]"
printf "    %-18s %s\n" "Server:" "$host:$port"
printf "    %-18s %s\n" "SNI:" "$sni"
printf "    %-18s %s\n" "Fingerprint:" "$fingerprint"
printf "    %-18s %s\n" "ALPN:" "${alpn:-<empty>}"
printf "    %-18s %s\n" "ShortID:" "${shortId:-<empty>}"
echo ""
echo "============================================================"
echo ""
