# Архитектура

Проект решает одну задачу: дать Apache Guacamole/`guacd` или другому контейнеру доступ к TCP-сервисам, которые доступны только через отдельные клиентские VPN, не публикуя эти сервисы на Docker host.

```text
                         external Docker network
+-------------+          guac-vpn-transit          +--------------------+
|   guacd     | ---------------------------------> | vpn-customer-a     |
|             |       vpn-customer-a:3389          | socat :3389        |
+-------------+                                     +----------+---------+
                                                               |
                                                               | VPN tunnel
                                                               v
                                                        private network
                                                        RDP/SSH/etc.
```

## Один VPN = один контейнер

Для каждого независимого VPN создаётся отдельный Stack/container. Это разделяет:

- credentials;
- routes;
- tunnel state;
- DNS;
- health/recovery;
- логи и диагностику.

Не рекомендуется запускать несколько VPN-клиентов в одном контейнере.

## Почему используется TCP forwarder

`guacd` всегда подключается к стабильному Docker DNS name (`VPN_CONTAINER_NAME`) и локальному listen-port. Внутри VPN-forwarder `socat` соединяет этот порт с конечным target через VPN.

Преимущества:

- не нужно публиковать RDP/SSH на host;
- Guacamole не обязан знать маршруты всех customer networks;
- можно дать одному VPN несколько локальных портов;
- health/recovery остаётся локальным для конкретного VPN.

## Общая Docker-сеть

По умолчанию используется external bridge:

```text
guac-vpn-transit
```

Подключайте к ней только контейнеры, которым нужен доступ к forwarders.

Критично: subnet Docker-сети не должен пересекаться с удалёнными VPN-сетями. Иначе Linux может выбрать Docker route вместо VPN route.

## PORT_FORWARDS

```text
3389:rdp01.corp.local:3389;3390:10.20.30.41:3389
```

Один VPN-контейнер может обслуживать несколько TCP destinations. Для каждого target используется отдельный listen-port.

## Split DNS

Основной принцип: публичное имя VPN gateway должно продолжать разрешаться через обычный Docker resolver даже при проблемах VPN. Внутренние target names при этом могут разрешаться через VPN DNS.

Поддержка:

- **IKEv2** — VPN DNS от strongSwan resolve plugin или `VPN_DNS_SERVERS`, Docker resolver сохраняется отдельно;
- **L2TP/IPsec** — peer DNS от PPP или `VPN_DNS_SERVERS`;
- **WireGuard** — `VPN_DNS_SERVERS` либо `DNS=` из `wg0.conf`, без замены Docker resolver;
- **FortiGate** — peer DNS от PPP best-effort либо явный `VPN_DNS_SERVERS`;
- **Kerio** — предпочтительно явный `VPN_DNS_SERVERS`; wrapper также пытается перехватить DNS, установленный Kerio, и восстановить Docker resolver;
- **OpenVPN** — DNS зависит от профиля/client directives; текущая реализация прежде всего контролирует tunnel/route/target/forwarder.

VPN DNS server сам должен быть маршрутизируем через соответствующий tunnel.

## Health model

Целевая модель одинакова для всех forwarder:

```text
VPN process/interface up
        ↓
route to target through VPN
        ↓
target TCP reachable
        ↓
socat PID alive + listen-port exists
        ↓
container healthy
```

Если падает только `socat`, VPN reconnect не нужен. Если падает tunnel/route/target — выполняется protocol-specific recovery. Если full-recovery многократно не помогает, PID 1 завершается, после чего Docker `restart: unless-stopped` запускает контейнер заново.
