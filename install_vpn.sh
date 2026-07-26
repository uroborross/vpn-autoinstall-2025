#!/usr/bin/env bash
# Установщик VPN-стека на чистую Ubuntu: 3x-ui + wg-easy + Portainer,
# опционально AmneziaWG (обфусцированный WireGuard) на ядерном модуле.
#
# Запускать только на новом сервере от root. Повторный запуск пропускает
# установку, если /opt/saved_config уже существует.
set -euo pipefail

# ── Параметры (можно переопределить через окружение) ─────────────────────────
SSH_PORT="${SSH_PORT:-30022}"
XUI_PORT="${XUI_PORT:-$(( (RANDOM % 10000) + 30000 ))}"
AWG_PORT="${AWG_PORT:-51822}"
AWG_SUBNET="${AWG_SUBNET:-10.9.0}"
XUI_VERSION="${XUI_VERSION:-v3.5.0}"        # пин: latest ломается без предупреждения
WGEASY_VERSION="${WGEASY_VERSION:-15}"      # v15 сменила схему настройки
PUBLIC_IP="${PUBLIC_IP:-}"
WITH_AWG=0
KEEP_RSYSLOG=1

SAVED_CONFIG="/opt/saved_config"
XUI_DIR="/opt/3x-ui"
AWG_DIR="/etc/amnezia/amneziawg"

usage() {
    cat <<'EOF'
Использование: install_vpn.sh [опции]

  --with-awg          дополнительно поднять AmneziaWG (ядерный модуль, DKMS)
  --awg-port PORT     UDP-порт AmneziaWG (по умолчанию 51822)
  --ssh-port PORT     новый SSH-порт (по умолчанию 30022)
  --disable-rsyslog   отключить системное логирование (по умолчанию оставляем)
  -h, --help          эта справка

Переменные окружения: PUBLIC_IP, XUI_PORT, XUI_VERSION, WGEASY_VERSION, AWG_SUBNET.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-awg) WITH_AWG=1 ;;
        --awg-port) AWG_PORT="$2"; shift ;;
        --ssh-port) SSH_PORT="$2"; shift ;;
        --disable-rsyslog) KEEP_RSYSLOG=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

log() { echo "==> $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# ── Предполётные проверки ────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "нужны права root"
[ -f /etc/os-release ] || die "не Ubuntu/Debian"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) : ;;
    *) die "поддерживается только Ubuntu/Debian, обнаружено: ${ID:-неизвестно}" ;;
esac

if [ -f "$SAVED_CONFIG" ]; then
    log "$SAVED_CONFIG уже существует — установка пропущена."
    log "Параметры: cat $SAVED_CONFIG"
    exit 0
fi

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
fi
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')"
fi
[ -n "$PUBLIC_IP" ] || die "не удалось определить публичный IP (задайте PUBLIC_IP=...)"

WAN_IF="$(ip -o route get to 8.8.8.8 | sed -n 's/.*dev \([^ ]\+\).*/\1/p')"
[ -n "$WAN_IF" ] || die "не удалось определить внешний интерфейс"

XUI_PATH="panel$(tr -dc a-z0-9 </dev/urandom | head -c 10)"
XUI_USER="admin$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
XUI_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

log "публичный IP: $PUBLIC_IP, внешний интерфейс: $WAN_IF"

# ── Базовые пакеты и Docker ──────────────────────────────────────────────────
log "устанавливаю пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl git ufw sqlite3 jq

if ! command -v docker >/dev/null 2>&1; then
    log "устанавливаю Docker"
    curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin

if [ "$KEEP_RSYSLOG" -eq 0 ]; then
    log "отключаю rsyslog по запросу"
    systemctl disable --now rsyslog 2>/dev/null || true
fi

# ── SSH на нестандартном порту ───────────────────────────────────────────────
log "переношу SSH на порт $SSH_PORT"
if grep -qE '^\s*#?\s*Port\s+' /etc/ssh/sshd_config; then
    sed -i -E "s/^\s*#?\s*Port\s+.*/Port $SSH_PORT/" /etc/ssh/sshd_config
else
    echo "Port $SSH_PORT" >>/etc/ssh/sshd_config
fi
sshd -t || die "sshd_config не проходит проверку — SSH не тронут"
systemctl reload ssh 2>/dev/null || systemctl reload sshd

# ── IP forwarding ────────────────────────────────────────────────────────────
if ! sysctl -n net.ipv4.ip_forward | grep -q '^1$'; then
    echo "net.ipv4.ip_forward = 1" >>/etc/sysctl.conf
    sysctl -p >/dev/null
fi

# ── Firewall: наружу только SSH, панель 3x-ui и VPN-порты ────────────────────
# Панели Portainer и wg-easy наружу НЕ открываются — они слушают только
# localhost, доступ через SSH-туннель: ssh -L 9000:127.0.0.1:9000 ...
log "настраиваю UFW"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH (старый порт, убрать после проверки нового)' >/dev/null
ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null
ufw allow "$XUI_PORT"/tcp comment '3x-ui panel' >/dev/null
ufw allow 37000:39000/tcp comment 'inbounds' >/dev/null
ufw allow 51820/udp comment 'wg-easy' >/dev/null
[ "$WITH_AWG" -eq 1 ] && ufw allow "$AWG_PORT"/udp comment 'AmneziaWG' >/dev/null
ufw --force enable >/dev/null

# ── 3x-ui ────────────────────────────────────────────────────────────────────
log "разворачиваю 3x-ui $XUI_VERSION"
if [ ! -d "$XUI_DIR" ]; then
    git clone --quiet --depth 1 --branch "$XUI_VERSION" https://github.com/MHSanaei/3x-ui.git "$XUI_DIR"
fi
(cd "$XUI_DIR" && docker compose up -d --quiet-pull)

# Ждём инициализации БД, затем настраиваем штатным CLI (надёжнее правки SQLite)
for _ in $(seq 1 30); do
    docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null && break
    sleep 2
done
docker exec 3x-ui /app/x-ui setting -username "$XUI_USER" -password "$XUI_PASS" \
    -port "$XUI_PORT" -webBasePath "/$XUI_PATH/" >/dev/null
(cd "$XUI_DIR" && docker compose restart >/dev/null)

# ── Portainer (только localhost) ─────────────────────────────────────────────
log "разворачиваю Portainer на 127.0.0.1:9000"
docker volume create portainer_data >/dev/null
docker run -d --restart=always --name portainer \
    -p 127.0.0.1:8000:8000 \
    -p 127.0.0.1:9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest >/dev/null

# ── wg-easy v15 (web-панель только на localhost) ─────────────────────────────
# В v15 переменная PASSWORD_HASH больше не поддерживается: администратор
# создаётся при первом входе в web-интерфейс.
log "разворачиваю wg-easy $WGEASY_VERSION"
docker volume create wg_data >/dev/null
docker run -d --name wg-easy --restart=unless-stopped \
    -e "INSECURE=true" \
    -v wg_data:/etc/wireguard \
    -v /lib/modules:/lib/modules:ro \
    -p 51820:51820/udp \
    -p 127.0.0.1:51821:51821/tcp \
    --cap-add NET_ADMIN --cap-add SYS_MODULE \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    "ghcr.io/wg-easy/wg-easy:$WGEASY_VERSION" >/dev/null

# ── AmneziaWG (опционально) ──────────────────────────────────────────────────
awg_summary=""
if [ "$WITH_AWG" -eq 1 ]; then
    log "устанавливаю AmneziaWG (ядерный модуль)"
    apt-get install -y -qq software-properties-common
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    apt-get update -qq
    apt-get install -y -qq amneziawg amneziawg-tools
    modprobe amneziawg || die "модуль amneziawg не загрузился (нужны linux-headers)"

    mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
    (
        umask 077
        cd "$AWG_DIR"
        awg genkey >server.key && awg pubkey <server.key >server.pub
        awg genkey >client.key && awg pubkey <client.key >client.pub

        # Заголовки H1-H4 должны быть различны и больше 4
        h=()
        while [ "${#h[@]}" -lt 4 ]; do
            v=$(( ($(od -An -N4 -tu4 /dev/urandom) % 2000000000) + 100000 ))
            case " ${h[*]} " in *" $v "*) continue ;; esac
            h+=("$v")
        done

        cat >awg0.conf <<EOF
[Interface]
Address = ${AWG_SUBNET}.1/24
ListenPort = ${AWG_PORT}
PrivateKey = $(cat server.key)
Jc = 4
Jmin = 40
Jmax = 70
S1 = 60
S2 = 80
H1 = ${h[0]}
H2 = ${h[1]}
H3 = ${h[2]}
H4 = ${h[3]}
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -I FORWARD 1 -i awg0 -j ACCEPT; iptables -I FORWARD 1 -o awg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT

[Peer]
PublicKey = $(cat client.pub)
AllowedIPs = ${AWG_SUBNET}.2/32
EOF

        cat >client.conf <<EOF
[Interface]
Address = ${AWG_SUBNET}.2/32
PrivateKey = $(cat client.key)
Jc = 4
Jmin = 40
Jmax = 70
S1 = 60
S2 = 80
H1 = ${h[0]}
H2 = ${h[1]}
H3 = ${h[2]}
H4 = ${h[3]}

[Peer]
PublicKey = $(cat server.pub)
Endpoint = ${PUBLIC_IP}:${AWG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
        chmod 600 awg0.conf client.conf
    )
    systemctl enable --now awg-quick@awg0 >/dev/null 2>&1
    sleep 2
    awg show awg0 >/dev/null 2>&1 || die "интерфейс awg0 не поднялся"
    awg_summary="$AWG_DIR/client.conf (порт ${AWG_PORT}/udp, сеть ${AWG_SUBNET}.0/24)"
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
umask 077
{
    echo "=============== 3x-ui ==============="
    echo "URL:      http://$PUBLIC_IP:$XUI_PORT/$XUI_PATH/"
    echo "Логин:    $XUI_USER"
    echo "Пароль:   $XUI_PASS"
    echo "Версия:   $XUI_VERSION"
    echo
    echo "=============== Portainer ==============="
    echo "Только localhost. Туннель:"
    echo "  ssh -p $SSH_PORT -L 9000:127.0.0.1:9000 root@$PUBLIC_IP"
    echo "  затем http://127.0.0.1:9000 (учётка создаётся при первом входе)"
    echo
    echo "=============== wg-easy (WireGuard) ==============="
    echo "Версия:   $WGEASY_VERSION — админ создаётся при первом входе в UI."
    echo "Панель только localhost. Туннель:"
    echo "  ssh -p $SSH_PORT -L 51821:127.0.0.1:51821 root@$PUBLIC_IP"
    echo "  затем http://127.0.0.1:51821"
    echo "UDP-порт 51820 открыт наружу."
    if [ -n "$awg_summary" ]; then
        echo
        echo "=============== AmneziaWG ==============="
        echo "Конфиг клиента: $awg_summary"
        echo "Скачать: scp -P $SSH_PORT root@$PUBLIC_IP:$AWG_DIR/client.conf ."
    fi
    echo
    echo "=============== Дальше ==============="
    echo "1) Проверьте новый SSH-порт:  ssh -p $SSH_PORT root@$PUBLIC_IP"
    echo "2) Затем закройте старый:      ufw delete allow 22/tcp"
    echo "3) Рекомендуется перезагрузка: reboot"
    echo "Повторный просмотр: cat $SAVED_CONFIG"
} | tee "$SAVED_CONFIG"
chmod 600 "$SAVED_CONFIG"

log "готово. Параметры сохранены в $SAVED_CONFIG (режим 600)."
