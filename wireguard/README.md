# WireGuard forwarder

WireGuard через kernel + `wg-quick`, TCP forwarding через `socat`.

## Обязательные параметры

- `WG_CONFIG_FILE` — read-only `wg0.conf`, default `/config/wg0.conf`;
- `PORT_FORWARDS`.

PrivateKey хранится только в mounted-конфигурации и никогда не коммитится.

## DNS

Поддерживаются:

```text
VPN_DNS_SERVERS=10.20.30.53;10.20.30.54
VPN_DNS_SUFFIX=corp.local
```

Если `VPN_DNS_SERVERS` не задан, wrapper читает `DNS=` из `[Interface]` `wg0.conf`. Эта строка удаляется из runtime-копии, чтобы `wg-quick` не менял Docker `/etc/resolv.conf`; внутренние имена разрешаются явными DNS-query.

DNS server должен маршрутизироваться через WireGuard (`AllowedIPs`).

## Health/recovery

Проверяются WireGuard interface, route-to-target через `wg0`, target TCP и все `socat` listeners. Если упал только forwarder — перезапускается только `socat`. После повторяющихся неудачных full-recovery контейнер завершается для Docker restart.
