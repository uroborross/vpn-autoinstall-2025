# VPN-autoinstall 2025 RU
## Подключитесь к новому серверу на Ubuntu 22 (от root)

```
ssh root@"ip-address"
```

"введите ваш пароль"

## Начните установку

```
git clone https://github.com/uroborross/vpn-autoinstall-2025.git /opt/vpn-autoinstall-2025
bash /opt/vpn-autoinstall-2025/install_vpn.sh
```

## После выполнения установки SSH порт изменился (по умолчанию 30022)

```
ssh -p 30022 root@"ip-address"
```

"введите ваш пароль"

## Где посмотреть параметры после установки

```
cat /opt/saved_config
```

## Примечания
- Используется публичный IP (можно переопределить переменной `PUBLIC_IP`)
- Скрипт применяет новый SSH-порт сразу (делает reload sshd)
- Рекомендуется перезагрузить сервер после завершения установки

---

# VPN-autoinstall 2025 EN
## Connect to the new server on Ubuntu 22 (as root)

```
ssh root@"ip-address"
```

"enter your password"

## Start the installation

```
git clone https://github.com/uroborross/vpn-autoinstall-2025.git /opt/vpn-autoinstall-2025
bash /opt/vpn-autoinstall-2025/install_vpn.sh
```

## After installation, the SSH port has changed (default 30022)

```
ssh -p 30022 root@"ip-address"
```

"enter your password"

## Where to view settings after install

```
cat /opt/saved_config
```

## Notes
- Uses public IP (override with `PUBLIC_IP`)
- Applies new SSH port immediately (reloads sshd)
- Reboot is recommended after install
