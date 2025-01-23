# Скрипт без #!/usr/bin/env bash, по требованию.

exthostip=`ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
extsshport=30022

# Случайный порт для x-ui
cport=`shuf -i 30000-40000 -n 1`
cpath="mysecpath$cport"

# Задаём "mainuser1"
mainuser1="mainuser1"
username="$cport$mainuser1"

# Генерируем пароль (20 символов)
passwrd=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20 ; echo ''`

# Токен = пароль
token="$passwrd"

saved_config="/opt/saved_config"
d3xui_dir="/opt/3x-ui"

# Обновление системы и установка необходимых пакетов
apt update && apt upgrade -y && apt install -y mc git sqlite3 apache2-utils

# Установка Docker
curl -fsSL get.docker.com | sh

# Отключение системного логирования (по желанию)
systemctl disable rsyslog
systemctl stop rsyslog

# Проверка, не выполнен ли скрипт ранее
if [ ! -f "$saved_config" ]; then
    # Изменяем SSH-порт
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
    # Порты Portainer
    ufw allow 8000/tcp
    ufw allow 9000/tcp
    # Порты WireGuard
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

    # Настраиваем x-ui в базе SQLite
    sqlite3 "$d3xui_dir/db/x-ui.db" 'DELETE FROM users WHERE id=1'
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(2,'webPort','$cport');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(3,'webBasePath','/$cpath/');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'users' VALUES(1,'$username','$passwrd','$token');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(4,'secretEnable','true');"

    # Запуск x-ui
    docker compose up -d

    # Установка Portainer (без задания логина/пароля)
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

    # Установка wg-easy (WireGuard) с bcrypt-хэшем
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

    # Выводим информацию и сохраняем в /opt/saved_config
    {
      echo "----------------- ADMIN PANEL (x-ui) -----------------"
      echo "URL: http://$exthostip:$cport/$cpath/panel"
      echo "Username: $username"
      echo "Password: $passwrd"
      echo "Token: $token"
      echo "-----------------------------------------------"
      echo "Portainer установлен. Доступен по адресу:"
      echo "http://$exthostip:9000"
      echo "(При первом входе попросит создать учётку вручную)"
      echo "-----------------------------------------------"
      echo "wg-easy (WireGuard) доступен по адресу:"
      echo "http://$exthostip:51821"
      echo "Пароль (plain) = $passwrd"
      echo "bcrypt-хэш: $hashedpass"
      echo "-----------------------------------------------"
      echo "Пожалуйста, перезагрузите сервер (reboot)."
      echo "-----------------------------------------------"
    } | tee "$saved_config"
fi
