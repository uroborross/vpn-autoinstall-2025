#!/usr/bin/env bash

exthostip=`ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
extsshport=30022
cport=`shuf -i 30000-40000 -n 1`
cpath="mysecpath$cport"
username="admin$cport"
passwrd=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20 ; echo ''`
token=`tr -dc A-Za-z0-9 </dev/urandom | head -c 64 ; echo ''`
saved_config="/opt/saved_config"
d3xui_dir="/opt/3x-ui"

# Обновление системы и установка необходимых пакетов
apt update && apt upgrade -y && apt install -y mc git sqlite

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
    ufw --force enable

    # Клонируем 3x-ui
    git clone https://github.com/MHSanaei/3x-ui.git "$d3xui_dir"
    cd "$d3xui_dir"
    docker compose up -d
    sleep 5
    docker compose down

    # Настраиваем 3x-ui
    sqlite3 "$d3xui_dir/db/x-ui.db" 'DELETE FROM users WHERE id=1'
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'users' VALUES(1,'$username','$passwrd','$token');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(2,'webPort','$cport');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(3,'webBasePath','/$cpath/');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(4,'secretEnable','true');"

    echo "----------------- ADMIN PANEL -----------------"
    echo "URL: http://$exthostip:$cport/$cpath/panel"
    echo "URL: http://$exthostip:$cport/$cpath/panel" > "$saved_config"
    echo "Username: $username"
    echo "Username: $username" >> "$saved_config"
    echo "Password: $passwrd"
    echo "Password: $passwrd" >> "$saved_config"
    echo "Token: $token"
    echo "Token: $token" >> "$saved_config"
    echo "-----------------------------------------------"

    # Запуск 3x-ui
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

    echo "-----------------------------------------------"
    echo "Portainer установлен. Доступен по адресу:"
    echo "http://$exthostip:9000"
    echo "-----------------------------------------------"
    echo "Пожалуйста, перезагрузите сервер (reboot)."
    echo "-----------------------------------------------"
fi
