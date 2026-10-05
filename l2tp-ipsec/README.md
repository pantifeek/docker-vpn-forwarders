# L2TP/IPsec forwarder

strongSwan IKEv1/IPsec transport + `xl2tpd` + PPP + `socat`.

## Обязательные параметры

- `VPN_SERVER`;
- `VPN_USERNAME_FILE` (или `VPN_USERNAME`);
- `VPN_PASSWORD_FILE` (или `VPN_PASSWORD`);
- `VPN_PSK_FILE` (или `VPN_PSK`);
- `PORT_FORWARDS`.

Docker host должен предоставлять `/dev/ppp` и PPP kernel support.

## Split DNS

PPP запрашивает peer DNS (`usepeerdns`). Можно задать DNS явно:

```text
VPN_DNS_SERVERS=10.20.30.53;10.20.30.54
VPN_DNS_SUFFIX=corp.local
```

Внутренние target-hostnames разрешаются отдельно, без намеренной замены Docker `/etc/resolv.conf`.

## Health/recovery

Проверяются IPsec, PPP, target TCP и все `socat` listeners. Если VPN и targets исправны, но умер `socat`, перезапускаются только forwarders. После повторных неудачных full-recovery контейнер завершается для Docker restart.

## Compatibility proposals

Defaults содержат SHA-1/3DES/DH group 2 для legacy gateway. Для новых инсталляций переопределите `VPN_IKE`/`VPN_ESP` более сильными предложениями, поддерживаемыми сервером.
