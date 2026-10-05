# Portainer templates

`stacks/` — Compose-файлы для **Stacks → Git repository**.

`env/` — примеры переменных. Скопируйте значения в Environment variables Portainer; файлы `.env.example` не содержат секретов.

Все Stack-файлы:

- собирают image из исходников этого же Git-репозитория;
- подключают service к external network `${TRANSIT_NETWORK:-guac-vpn-transit}`;
- не публикуют host ports;
- читают секреты из `${SECRET_DIR}` на Docker host.

Подробности: [`../docs/portainer.md`](../docs/portainer.md).
