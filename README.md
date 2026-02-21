
# install-run-xray

Скрипт для **установки и запуска Xray-сервера** (VLESS + Reality).
При запуске автоматически:

* устанавливает Xray (если не установлен),
* генерирует новую пару X25519 ключей,
* создаёт новый UUID,
* формирует конфигурацию,
* перезапускает службу,
* выводит готовую VLESS-ссылку для клиента.

Предназначено для учебных и ознакомительных целей.

---

## 🚀 Установка и запуск сервера

```bash
wget https://raw.githubusercontent.com/akaC1J/install-run-xray/main/install-run-xray.sh && \
chmod +x install-run-xray.sh && \
sudo ./install-run-xray.sh
```

После выполнения скрипта вы получите:

* UUID
* Private Key
* Public Key
* Готовую VLESS-ссылку

Пример ссылки:

```
vless://UUID@SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google.com&fp=chrome&pbk=PUBLIC_KEY&type=tcp#MyGoogleProxy
```

---

## 📋 Требования

* Права `sudo`
* Установленный `wget`
* Протестировано на:

  * Ubuntu 22.04
  * Ubuntu 24.04
  * Debian 12
  * Debian 13

---

# 🖥 Установка клиента Xray

Репозиторий содержит отдельный скрипт для установки клиента.

Клиент:

* принимает VLESS-ссылку
* автоматически устанавливает Xray
* создаёт конфигурацию:

  * inbound **Shadowsocks → VLESS Reality**
  * inbound **SOCKS5 (auth) → Direct**
* перезапускает службу
* выводит данные для подключения

---

## 🚀 Установка и запуск клиента

```bash
wget https://raw.githubusercontent.com/akaC1J/install-run-xray/main/install-client-xray.sh && \
chmod +x install-client-xray.sh && \
sudo ./install-client-xray.sh "vless://..."
```

В аргумент передаётся VLESS-ссылка, полученная на сервере.

---

## ⚙ Как работает клиент

После запуска автоматически создаются:

### 1️⃣ Shadowsocks inbound (весь трафик → сервер)

* Случайный порт
* Метод: `chacha20-ietf-poly1305`
* Случайный пароль

Этот inbound пересылает весь трафик в `vless-out`.

Подходит для:

* телефонов
* приложений
* прокси-клиентов
* роутеров

---

### 2️⃣ SOCKS5 inbound (auth → direct)

* Отдельный порт
* Логин/пароль
* Трафик идёт напрямую (без сервера)

Используется как:

* локальный SOCKS-прокси
* fallback-доступ
* тестовый канал

---

## 📌 Что вы получите после запуска клиента

Скрипт выведет:

```
[ Shadowsocks → VLESS Reality ]
Port:
Method:
Password:

[ SOCKS5 (auth) → DIRECT ]
Port:
Username:
Password:

[ VLESS Reality Outbound ]
Server:
SNI:
Fingerprint:
```

---

## 🔧 Как подключиться к клиенту

### Подключение через Shadowsocks

Используйте:

* Host: IP машины с клиентом
* Port: выведенный порт
* Method: `chacha20-ietf-poly1305`
* Password: выведенный пароль

Пример строки:

```
ss://BASE64(method:password)@CLIENT_IP:PORT
```

---

### Подключение через SOCKS5

```
socks5://user:password@CLIENT_IP:PORT
```

---

## 🔄 Идемпотентность

Оба скрипта:

* безопасно перезаписывают конфиг
* создают резервную копию предыдущего
* валидируют JSON через `jq`
* проверяют конфиг через `xray -test`
* перезапускают systemd-службу

--
