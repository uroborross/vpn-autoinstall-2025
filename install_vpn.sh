# Убираем #!/usr/bin/env bash по вашему требованию
# Можно оставить пусто или указать другой шебанг

exthostip=`ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
extsshport=30022

# Случайный порт для x-ui
cport=`shuf -i 30000-40000 -n 1`
cpath="mysecpath$cport"

# Придумайте сами значение mainuser1, например "user"
mainuser1="user"
username="$cport$mainuser1"

# Генерируем пароль (20 символов)
passwrd=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20 ; echo ''`

# Токен = пароль
token="$passwrd"

saved_config="/opt/saved_config"
d3xui_dir="/opt/3x-ui"

# Обновление системы и установка необходимых пакетов
apt update && apt upgrade -y && apt install -y mc git sqlite3

# Установка Docker
curl -fsSL get.docker.com | sh

# Отключение системного логирования (по желанию)
systemctl disable rsyslog
systemctl stop rsyslog

# Проверяем, не выполнен ли скрипт ранее
if [ ! -f "$saved_config" ]; then
    # Меняем SSH-порт
    portstring=`cat /etc/ssh/sshd_config | egrep '^\#?Port'`
    sed -i "s/$portstring/Port $extsshport/" /etc/ssh/sshd_config

    # Включаем IP Forwarding
    (sysctl net.ipv4.ip_forward | grep 'forward = 1') || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf

    # Настраиваем ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow $extsshport/tcp
    ufw allow $cport/tcp
    # Диапазон 37000-39000 остаётся, если он нужен для других правил
    ufw allow 37000:39000/tcp

    # Порты для Portainer
    ufw allow 8000/tcp
    ufw allow 9000/tcp

    # Порты для wg-easy (по умолчанию 51820/udp для самого WG и 51821/tcp для веб-морды)
    # Меняйте при необходимости
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

    # -- Вносим ВСЁ за один блок в базу x-ui --
    # (webPort, webBasePath, user, password=token, secretEnable)

    sqlite3 "$d3xui_dir/db/x-ui.db" 'DELETE FROM users WHERE id=1'
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(2,'webPort','$cport');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(3,'webBasePath','/$cpath/');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'users' VALUES(1,'$username','$passwrd','$token');"
    sqlite3 "$d3xui_dir/db/x-ui.db" "INSERT INTO 'settings' VALUES(4,'secretEnable','true');"

    # Запускаем x-ui c уже обновлённой базой
    docker compose up -d

    # Установка Portainer: пытаемся задать тот же логин/пароль
    # В последних версиях логин = admin, ENV 'ADMIN_USERNAME' может быть проигнорирован.
    # Но ADMIN_PASSWORD точно сработает для initial setup.
    docker volume create portainer_data
    docker run -d --restart=always \
        --name portainer \
        -p 8000:8000 \
        -p 9000:9000 \
        -e ADMIN_USERNAME="$username" \
        -e ADMIN_PASSWORD="$passwrd" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest

    # Установка wg-easy (WireGuard) c тем же паролем
    # (wg-easy не имеет логина, только пароль веб-интерфейса)
    docker volume create wg_data
    docker run -d --name wg-easy \
        --restart=always \
        -e WG_HOST="$exthostip" \
        -e PASSWORD="$passwrd" \
        -v wg_data:/etc/wireguard \
        -p 51820:51820/udp \
        -p 51821:51821/tcp \
        --cap-add NET_ADMIN \
        ghcr.io/wg-easy/wg-easy:latest

    # Вывод данных
    echo "----------------- ADMIN PANEL (x-ui) -----------------"
    echo "URL: http://$exthostip:$cport/$cpath/panel"
    echo "URL: http://$exthostip:$cport/$cpath/panel" > "$saved_config"

    echo "Username: $username"
    echo "Username: $username" >> "$saved_config"

    echo "Password: $passwrd"
    echo "Password: $passwrd" >> "$saved_config"

    echo "Token: $token"
    echo "Token: $token" >> "$saved_config"
    echo "-----------------------------------------------------"

    echo "Portainer доступен по адресу:"
    echo "http://$exthostip:9000"
    echo "Логин (возможно будет проигнорирован) = $username"
    echo "Пароль = $passwrd"

    echo "-----------------------------------------------------"
    echo "wg-easy (WireGuard) доступен по адресу:"
    echo "http://$exthostip:51821"
    echo "Пароль веб-интерфейса = $passwrd"
    echo "-----------------------------------------------------"

    echo "Пожалуйста, перезагрузите сервер (reboot)."
    echo "-----------------------------------------------------"
fi
