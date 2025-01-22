exthostip=`ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
extsshport=30022

# Случайный порт для x-ui
cport=`shuf -i 30000-40000 -n 1`
cpath="mysecpath$cport"

# Имя пользователя для x-ui
mainuser1="mainuser1"
username="$cport$mainuser1"

# Генерируем пароль (20 символов)
passwrd=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20 ; echo ''`

# Токен = пароль (x-ui)
token="$passwrd"

saved_config="/opt/saved_config"
d3xui_dir="/opt/3x-ui"

# Порт для inbound (VLESS+REALITY), случайно 37000–39000
inboundport=`shuf -i 37000-39000 -n 1`

# Пример JSON (копируем из вашей выборки, адаптируйте при необходимости)
inbound_settings='{
  "clients": [
    {
      "comment": "",
      "email": "test1",
      "enable": true,
      "expiryTime": 0,
      "flow": "",
      "id": "141798c3-1297-4423-8e78-2087702e42f3",
      "limitIp": 0,
      "reset": 0,
      "subId": "3yos4wehxu0wk1qc",
      "tgId": "",
      "totalGB": 0
    },
    {
      "comment": "",
      "email": "test2",
      "enable": true,
      "expiryTime": 0,
      "flow": "xtls-rprx-vision",
      "id": "3b8b9fa4-0db8-4d19-8d7f-10915ca9ce75",
      "limitIp": 0,
      "reset": 0,
      "subId": "xjyx2twpr13puw8h",
      "tgId": "",
      "totalGB": 0
    }
  ],
  "decryption": "none",
  "fallbacks": []
}'

inbound_stream='{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "dest": "gmail.com:443",
    "serverNames": [
      "gmail.com",
      "www.gmail.com"
    ],
    "privateKey": "2FMRl2Wd1vwpn_3z8FtVg9lq_Vbg-MTQ_fXnVKSrEgM",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "4ca1ce8afce1",
      "69d66d64969ec84a",
      "6dc2",
      "4b",
      "9a0db8",
      "38cc06cdd00d5e",
      "9fc786a6",
      "dcd6802715"
    ],
    "settings": {
      "publicKey": "r2W5QniqCslTCmQG7r8d-OMN1uaBRu1O2O3nmZwx7zU",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": false,
    "header": {
      "type": "none"
    }
  }
}'

inbound_sniff='{
  "enabled": true,
  "destOverride": ["http","tls","quic","fakedns"],
  "metadataOnly": false,
  "routeOnly": false
}'

inbound_allocate='{
  "strategy": "always",
  "refresh": 5,
  "concurrency": 3
}'

# Обновление системы и установка необходимых пакетов
apt update && apt upgrade -y && apt install -y mc git sqlite3 apache2-utils

# Установка Docker
curl -fsSL get.docker.com | sh

# Отключение системного логирования (по желанию)
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

    # Первый запуск для инициализации базы
    docker compose up -d
    sleep 5
    docker compose down

    # Настраиваем x-ui (админ-панель)
    sqlite3 "$d3xui_dir/db/x-ui.db" 'DELETE FROM users WHERE id=1'
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(2,'webPort','$cport');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(3,'webBasePath','/$cpath/');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'users' VALUES(1,'$username','$passwrd','$passwrd');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(4,'secretEnable','true');"

    # >>> Добавляем 1 inbound (vless+reality) на порт inboundport <<<
    # id=2 — поменяйте, если уже занято.
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

    # Запуск x-ui
    docker compose up -d

    # Установка Portainer (без лишних переменных)
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

    # Установка wg-easy (WireGuard)
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

    {
      echo "----------------- ADMIN PANEL (x-ui) -----------------"
      echo "URL: http://$exthostip:$cport/$cpath/panel"
      echo "Username: $username"
      echo "Password: $passwrd"
      echo "Token: $passwrd"
      echo ""
      echo "+++ Внимание: автоматически добавлен inbound +++"
      echo "  Порт для inbound: $inboundport"
      echo "  Протокол: vless + reality"
      echo "-----------------------------------------------"
      echo "Portainer: http://$exthostip:9000"
      echo "-----------------------------------------------"
      echo "wg-easy (WireGuard) по адресу: http://$exthostip:51821"
      echo "Пароль (plain) = $passwrd"
      echo "bcrypt-хэш: $hashedpass"
      echo "-----------------------------------------------"
      echo "Пожалуйста, перезагрузите сервер (reboot)."
      echo "-----------------------------------------------"
      echo "После перезагрузки, чтобы снова увидеть эти настройки,"
      echo "выполните: cat /opt/saved_config"
      echo "-----------------------------------------------"
    } | tee "$saved_config"
fi
