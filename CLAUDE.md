# CLAUDE.md

## Память проекта

Это root-level Ubuntu VPN autoinstaller. Он настраивает system packages, Docker, 3x-ui, Portainer, wg-easy, firewall rules, IP forwarding и SSH port behavior.

Главный файл: `install_vpn.sh`.

## Как работать

- Никогда не запускать installer локально.
- Не выполнять remote install commands без прямого запроса пользователя.
- Считать generated credentials и output `/opt/saved_config` секретными.
- Быть осторожным с `sshd_config`, UFW, Docker containers и `/opt` paths.
- Сохранять текущий guard, который пропускает setup, если `/opt/saved_config` уже существует, если пользователь не попросил изменить это.

## Проверки

```bash
bash -n install_vpn.sh
shellcheck install_vpn.sh
```

Если `shellcheck` недоступен, использовать `bash -n`.
