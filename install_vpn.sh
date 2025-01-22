# (Шебанг убран, по вашему требованию)

exthostip=`ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
extsshport=30022

# Случайный порт для x-ui
cport=`shuf -i 30000-40000 -n 1`
cpath="mysecpath$cport"

# Основной юзер x-ui
mainuser1="mainuser1"
username="$cport$mainuser1"

# Генерируем пароль (20 символов)
passwrd=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20 ; echo ''`
token="$passwrd"   # в x-ui user/token одинаковы

saved_config="/opt/saved_config"
d3xui_dir="/opt/3x-ui"

# Порт inbound (для VLESS+Reality), случайно 37000–39000
inboundport=`shuf -i 37000-39000 -n 1`

# ---- 1) Генерация Reality ключей и shortIds через docker xray ----
# Установим Docker (ниже в скрипте он и так есть), но генерируем ДО вставки в SQLite.

# Генерируем приватный ключ
privateKey=$(docker run --rm teddysun/xray xray x25519 | awk '/Private key/ {print $NF; exit}')
# Получаем публичный ключ из приватного
publicKey=$(docker run --rm teddysun/xray xray x25519 --pub "$privateKey" | awk '/Public key/ {print $NF; exit}')

# Генерируем shortIds (массив из 1-2 случайных hex)
shortId=$(head /dev/urandom | tr -dc a-f0-9 | head -c 8)
# Можно сделать массив на несколько shortIds, если хотите
# shortIds='["4ca1ce8a","69d66d64","6dc2"]'
shortIds="[\"$shortId\"]"

# UUID для клиента (flow="xtls-rprx-vision")
# (Можно сделать 1 клиент, или несколько)
uuid1=$(cat /proc/sys/kernel/random/uuid)
email1="myclient1"

# Обратите внимание: если хотите flow="xtls-rprx-vision" у клиента, надо прописать flow в JSON.
# Если у других клиентов нужно flow="", то просто дублируйте массив клиентов.

clientsJson="[
  {
    \"email\": \"$email1\",
    \"enable\": true,
    \"expiryTime\": 0,
    \"flow\": \"xtls-rprx-vision\",
    \"id\": \"$uuid1\",
    \"limitIp\": 0,
    \"reset\": 0,
    \"subId\": \"$(head /dev/urandom | tr -dc a-z0-9 | head -c 16)\",
    \"tgId\": \"\",
    \"totalGB\": 0
  }
]"

# Собираем JSON: settings, stream, sniffing
# (clients и "decryption": "none" + "fallbacks": [])
inbound_settings=$(cat <<EOF
{
  "clients": $clientsJson,
  "decryption": "none",
  "fallbacks": []
}
EOF
)

# streamSettingsJson
inbound_stream=$(cat <<EOF
{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "dest": "gmail.com:443",
    "serverNames": ["gmail.com","www.gmail.com"],
    "privateKey": "$privateKey",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": $shortIds,
    "settings": {
      "publicKey": "$publicKey",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": false,
    "header": { "type": "none" }
  }
}
EOF
)

# sniffingSettingsJson
inbound_sniff=$(cat <<EOF
{
  "enabled": true,
  "destOverride": ["http","tls","quic","fakedns"],
  "metadataOnly": false,
  "routeOnly": false
}
EOF
)

# allocateJson (часто не меняется, можно оставить)
inbound_allocate=$(cat <<EOF
{
  "strategy": "always",
  "refresh": 5,
  "concurrency": 3
}
EOF
)

# --------------------- Начало установки  ---------------------
apt update && apt upgrade -y && apt install -y mc git sqlite3 apache2-utils

curl -fsSL get.docker.com | sh

systemctl disable rsyslog
systemctl stop rsyslog

if [ ! -f "$saved_config" ]; then
    # Меняем SSH-порт
    portstring=`cat /etc/ssh/sshd_config | egrep '^\#?Port'`
    sed -i "s/$portstring/Port $extsshport/" /etc/ssh/sshd_config

    # Включаем IP Forwarding
    (sysctl net.ipv4.ip_forward | grep 'forward = 1') || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf

    # Настройка ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow $extsshport/tcp
    ufw allow $cport/tcp
    ufw allow 37000:39000/tcp
    ufw allow 8000/tcp
    ufw allow 9000/tcp
    ufw allow 51820/udp
    ufw allow 51821/tcp
    ufw --force enable

    # Клонируем 3x-ui
    git clone https://github.com/MHSanaei/3x-ui.git "$d3xui_dir"
    cd "$d3xui_dir"

    # Первый запуск x-ui (инициализация базы)
    docker compose up -d
    sleep 5
    docker compose down

    # Настройка x-ui (пользователь админ-панели)
    sqlite3 "$d3xui_dir/db/x-ui.db" 'DELETE FROM users WHERE id=1'
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(2,'webPort','$cport');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(3,'webBasePath','/$cpath/');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'users' VALUES(1,'$username','$passwrd','$token');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(4,'secretEnable','true');"

    # Добавляем inbound (vless + reality)
    # id=2, remark='myInbound', enable=1
    # Можно менять "1760124" / "2407799102" если хотите,
    # это "createTime" и "updateTime" (x-ui обычно генерит).
    sqlite3 "$d3xui_dir/db/x-ui.db" "
    INSERT INTO inbounds
    VALUES(
      2,
      1,
      1760124,
      2407799102,
      0,
      'myInbound',
      1,
      0,
      '',
      $inboundport,
      'vless',
      '$inbound_settings',
      '$inbound_stream',
      'inbound-$inboundport',
      '$inbound_sniff',
      '$inbound_allocate'
    );"

    # Запуск x-ui со вставленным inbound
    docker compose up -d

    # Установка Portainer
    docker volume create portainer_data
    docker run -d --restart=always \
      --name portainer \
      -p 8000:8000 \
      -p 9000:9000 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest

    # Генерация bcrypt-хэша для wg-easy
    hashedpass=$(htpasswd -nbBC 10 "" "$passwrd" | cut -d ":" -f2)

    # Установка wg-easy
    docker volume create wg_data
    docker run -d --name wg-easy \
      --restart=always \
      -e WG_HOST="$exthostip" \
      -e PASSWORD_HASH="$hashedpass" \
      -v wg_data:/etc/wireguard \
      -p 51820:51820/udp \
      -p 51821:51821/tcp \
      --cap-add NET_ADMIN \
      ghcr.io/wg-easy/wg-easy:latest

    # Выводим итоги
    {
      echo "----------------- ADMIN PANEL (x-ui) -----------------"
      echo "URL: http://$exthostip:$cport/$cpath/panel"
      echo "Username: $username"
      echo "Password: $passwrd"
      echo "Token: $token"
      echo ""
      echo "+++ Inbound (vless + reality) +++"
      echo "Порт: $inboundport"
      echo "privateKey: $privateKey"
      echo "publicKey : $publicKey"
      echo "shortIds  : $shortId"
      echo "UUID      : $uuid1  (flow=xtls-rprx-vision)"
      echo "--------------------------------"
      echo "Portainer: http://$exthostip:9000"
      echo "wg-easy: http://$exthostip:51821 (пароль = $passwrd)"
      echo "--------------------------------"
      echo "Пожалуйста, перезагрузите сервер (reboot)."
      echo "После перезагрузки, чтобы снова увидеть эти настройки:"
      echo "  cat /opt/saved_config"
    } | tee "$saved_config"

fi
