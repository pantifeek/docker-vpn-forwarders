# Статус реализаций и известные ограничения

Статус относится к исходникам в этом репозитории после унификации health/recovery и подготовки к Portainer. Даже `candidate` нужно проверять против конкретного VPN-шлюза перед production.

## IKEv2 — candidate

- strongSwan / IKEv2 / EAP-MSCHAPv2;
- split-DNS: Docker resolver сохраняется для публичного VPN gateway, внутренние имена разрешаются через VPN DNS;
- контролируются `socat` PID/listeners и target TCP;
- при падении только `socat` перезапускаются forwarders, без лишнего reconnect VPN;
- после серии неудачных recovery PID 1 завершается, чтобы Docker `restart: unless-stopped` мог перезапустить контейнер.

Ограничение: для DNS-target необходимо явно задать `VPN_REMOTE_TS`, потому что IPsec traffic selector формируется до появления туннеля. Он должен покрывать target network и, при необходимости, VPN DNS.

## L2TP/IPsec — candidate

- strongSwan IKEv1/IPsec transport + xl2tpd + PPP;
- DNS-aware resolution через `VPN_DNS_SERVERS` или peer DNS;
- добавлен контроль `socat` PID/listeners;
- forwarder-only recovery и финальный Docker restart после повторяющихся неудач.

Важно: compatibility defaults содержат SHA-1/3DES/DH group 2 для старых L2TP/IPsec gateway. Для новых систем задавайте `VPN_IKE`/`VPN_ESP` явно более сильными наборами.

## OpenVPN — candidate

- контролируется OpenVPN process/interface;
- проверяется, что маршрут к target использует VPN interface;
- контролируются `socat` PID/listeners;
- при падении только forwarder VPN не перезапускается;
- повторные неудачные full-recovery приводят к завершению PID 1.

Текущий wrapper ожидает файл passphrase приватного ключа `OVPN_KEY_PASSWORD_FILE`. `.ovpn` должен быть неинтерактивным по остальным способам аутентификации.

## WireGuard — candidate

- kernel WireGuard через `wg-quick`;
- контролируются interface, route-to-target, target TCP и `socat` listeners;
- split-DNS через `VPN_DNS_SERVERS` либо `DNS=` из `wg0.conf`;
- `DNS=` удаляется из runtime-копии конфигурации, чтобы `wg-quick` не заменял Docker resolver;
- repeated recovery failure завершает PID 1.

Ограничение: DNS server должен входить в `AllowedIPs` соответствующего peer, иначе запросы к нему не пойдут через WireGuard.

## FortiGate SSL-VPN — candidate / experimental

- `openfortivpn` + PPP;
- Docker resolver не заменяется (`set-dns=0`);
- peer DNS запрашивается через PPP и сохраняется отдельно, также поддерживается явный `VPN_DNS_SERVERS`;
- проверяется PPP route-to-target, target TCP и `socat` listeners;
- forwarder-only recovery и финальный restart контейнера.

Автоматическое получение DNS зависит от конкретного FortiGate/openfortivpn/PPP. Если peer DNS не появляется, задайте `VPN_DNS_SERVERS` явно.

## Kerio Control VPN — experimental

- vendor Kerio Control VPN Client, пакет не хранится в Git;
- проверяется `kvnet`, route-to-target, target TCP и `socat` listeners;
- поддержан split-DNS через явный `VPN_DNS_SERVERS`; дополнительно wrapper пытается перехватить DNS, который Kerio записал в `/etc/resolv.conf`, после чего восстанавливает Docker resolver;
- если `VPN_FINGERPRINT` не задан, выполняется auto-detection. Перед TLS-probe отдельно проверяется TCP-доступность VPN-порта и выводится понятная ошибка;
- для production предпочтителен fingerprint, проверенный вне контейнера и переданный явно.

Kerio остаётся experimental, потому что поведение proprietary client (DNS, fingerprint/protocol handshake, package installation) может различаться между версиями gateway/client.
