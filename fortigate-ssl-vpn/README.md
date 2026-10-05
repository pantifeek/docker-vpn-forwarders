# FortiGate SSL-VPN forwarder

`openfortivpn` + PPP + `socat`.

## Обязательные параметры

- `FORTI_HOST`;
- `FORTI_PORT` (default `443`);
- `FORTI_USERNAME_FILE`;
- `FORTI_PASSWORD_FILE`;
- `PORT_FORWARDS`.

`FORTI_REALM` optional.

## Split DNS

Wrapper сохраняет Docker DNS и не разрешает openfortivpn напрямую менять `/etc/resolv.conf`:

```text
set-dns = 0
pppd-use-peerdns = 1
```

Peer DNS считывается из PPP runtime-файла. Надёжный вариант для известных внутренних DNS:

```text
VPN_DNS_SERVERS=10.20.30.53;10.20.30.54
VPN_DNS_SUFFIX=corp.local
```

## Health/recovery

Проверяются openfortivpn/PPP, route-to-target через PPP, target TCP и `socat` listeners. Если сломан только forwarder, VPN не переподключается. После повторяющихся неудачных recovery PID 1 завершается.
