# Kerio Control VPN forwarder

Оборачивает Linux Kerio Control VPN Client и проксирует TCP через `kvnet`.

## Third-party client

`.deb` Kerio не хранится в этом репозитории. Dockerfile скачивает официальный пакет по `KERIO_DEB_URL` во время build. Перед публикацией/перераспространением готового image проверьте условия лицензии вендора.

## Обязательные параметры

- `VPN_SERVER`;
- `VPN_PORT` (default `4090`);
- `VPN_USERNAME_FILE`;
- `VPN_PASSWORD_FILE`;
- `PORT_FORWARDS`.

Для production рекомендуется явно задать `VPN_FINGERPRINT`, предварительно проверив его вне контейнера. Если параметр пуст, wrapper сначала проверит TCP-доступность VPN-порта, затем попробует получить fingerprint через TLS probe. Такой auto-detection не гарантирован для всех версий Kerio/network path.

## Split DNS

Предпочтительно задать явно:

```text
VPN_DNS_SERVERS=10.20.30.53;10.20.30.54
VPN_DNS_SUFFIX=corp.local
```

Дополнительно wrapper пытается сохранить DNS, которые Kerio записал в `/etc/resolv.conf`, в отдельный runtime-файл и затем восстанавливает Docker resolver. Это защищает разрешение публичного `VPN_SERVER` от состояния VPN.

## Health/recovery

Проверяются `kvnet`, route-to-target через `kvnet`, target TCP и `socat` listeners. Forwarder-only failure не приводит к лишнему reconnect VPN. Повторяющиеся неудачные recovery завершают контейнер для Docker restart.

Kerio остаётся experimental из-за proprietary client и различий поведения между версиями.
