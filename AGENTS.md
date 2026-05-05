# AGENTS.md

## Контекст проекта

Bash installer для свежего Ubuntu server. Он устанавливает и настраивает Docker, 3x-ui, Portainer, wg-easy, UFW rules, IP forwarding и меняет SSH port.

Главный файл:
- `install_vpn.sh` — destructive server installer, рассчитанный на запуск от root на Ubuntu.
- `README.md` — RU/EN инструкция.

## Безопасность

- Не запускать `install_vpn.sh` на локальной машине.
- Не запускать remote SSH/install commands без явного запроса пользователя.
- Считать output `/opt/saved_config` секретным, потому что он содержит generated credentials.
- Аккуратно работать с SSH и firewall changes: скрипт reloads `sshd`, меняет port на `30022` и включает UFW.
- Сохранять idempotency вокруг guard `/opt/saved_config`, если задача не меняет install semantics.

## Проверки

```bash
bash -n install_vpn.sh
shellcheck install_vpn.sh
```

`shellcheck` может быть не установлен; baseline check — `bash -n`.
