# Docker VPN Forwarders

Набор Docker-образов для подключения контейнера к удалённой VPN-сети и публикации выбранных TCP-сервисов **только внутри Docker-сети**. Основной сценарий — Apache Guacamole/`guacd`, который подключается к RDP/SSH/другому TCP-сервису через отдельный VPN-forwarder.

```text
Guacamole / guacd
        │
        │ shared Docker network
        ▼
VPN forwarder container
        │
        │ VPN tunnel
        ▼
private target (RDP, SSH, ...)
```

Forwarder не публикует RDP-порты на Docker host. Если в Stack явно не добавить `ports:`, сервис доступен только контейнерам общей Docker-сети.

## Что есть в репозитории

| Каталог | VPN | Статус | DNS внутри VPN |
|---|---|---:|---|
| `ikev2/` | IKEv2 / strongSwan / EAP-MSCHAPv2 | candidate | split-DNS |
| `l2tp-ipsec/` | L2TP/IPsec PSK / strongSwan + xl2tpd | candidate | split-DNS |
| `openvpn/` | OpenVPN | candidate | зависит от `.ovpn`; forwarder контролирует маршрут/сервис |
| `wireguard/` | WireGuard | candidate | split-DNS через `VPN_DNS_SERVERS` или `DNS=` из `wg0.conf` |
| `fortigate-ssl-vpn/` | FortiGate SSL-VPN / openfortivpn | candidate/experimental | split-DNS, peer DNS best-effort |
| `kerio-control-vpn/` | Kerio Control VPN Client | experimental | split-DNS через `VPN_DNS_SERVERS` или DNS, полученный клиентом |
| `portainer/` | готовые Stack-файлы и env-примеры | — | — |
| `docs/` | архитектура, Portainer, статусы | — | — |

`candidate` означает, что реализация основана на рабочем варианте, но после публикационной переработки её всё равно нужно проверить на конкретном VPN-шлюзе. `experimental` — есть зависимость от поведения конкретного вендорского клиента/шлюза.

## Быстрый старт в Portainer

### 1. Создать общую Docker-сеть

Один раз на Docker host:

```bash
docker network create guac-vpn-transit
```

Если используется другое имя сети — задайте `TRANSIT_NETWORK` в переменных Stack.

### 2. Подготовить секреты на Docker host

Секреты **не должны храниться в Git**. Для каждого подключения рекомендуется отдельный каталог, например:

```text
/opt/vpn-forwarders/secrets/customer-a/
├── username
├── password
├── psk              # только L2TP/IPsec
├── client.ovpn      # только OpenVPN
├── key_password     # если приватный ключ OpenVPN зашифрован
├── wg0.conf         # только WireGuard
└── ca/              # при необходимости для IKEv2
```

Рекомендуемые права:

```bash
chmod 700 /opt/vpn-forwarders/secrets/customer-a
chmod 600 /opt/vpn-forwarders/secrets/customer-a/* 2>/dev/null || true
```

### 3. Создать Stack из Git repository

В Portainer:

1. **Stacks → Add stack → Git repository**.
2. Указать URL этого репозитория.
3. Для `Compose path` выбрать нужный файл, например:
   - `portainer/stacks/ikev2.yml`
   - `portainer/stacks/l2tp-ipsec.yml`
   - `portainer/stacks/openvpn.yml`
   - `portainer/stacks/wireguard.yml`
   - `portainer/stacks/fortigate.yml`
   - `portainer/stacks/kerio.yml`
4. Заполнить Environment variables по соответствующему примеру из `portainer/env/`.
5. Нажать **Deploy the stack**.

Stack сам собирает образ из каталога соответствующего VPN.

### 4. Настроить Guacamole

Если Stack называется/создаёт сервис `vpn-customer-a`, а задано:

```text
PORT_FORWARDS=3389:rdp01.corp.local:3389
```

то в Guacamole:

```text
Hostname: vpn-customer-a
Port:     3389
```

`guacd` и VPN-forwarder должны быть подключены к одной Docker-сети, например `guac-vpn-transit`.

## PORT_FORWARDS

Все forwarder-образы используют одинаковый формат:

```text
<listen-port>:<target-host-or-ip>:<target-port>[;<listen-port>:<target>:<target-port>...]
```

Примеры:

```text
3389:10.20.30.40:3389
3389:rdp01.corp.local:3389;3390:rdp02.corp.local:3389
```

Внутри Docker сервис будет слушать `listen-port`, а соединение уйдёт к `target:target-port` через VPN.

## Health/recovery

Цель проекта — одинаковая модель здоровья для всех VPN:

1. VPN-интерфейс/сессия подняты.
2. Целевой адрес доступен через VPN.
3. Целевой TCP-порт отвечает.
4. Все процессы `socat` живы и слушают нужные локальные порты.
5. Если сломан только TCP-forwarder — перезапускается только `socat`.
6. Если проблема в VPN/маршруте/target — выполняется reconnect VPN.
7. После повторяющихся неудачных recovery PID 1 завершается, и `restart: unless-stopped` позволяет Docker перезапустить контейнер.

Реализации постепенно приводятся к этой модели. Текущие различия описаны в [`docs/status.md`](docs/status.md).

## Split DNS

Для VPN, где внутренние DNS-имена не должны ломать Docker DNS, используется схема split-DNS:

- публичное имя VPN-шлюза разрешается обычным Docker resolver;
- внутренние target-hostnames разрешаются через `VPN_DNS_SERVERS` или DNS, полученный от VPN;
- `/etc/resolv.conf` контейнера не должен без необходимости заменяться VPN-клиентом.

Если автоматическое получение DNS конкретным клиентом ненадёжно, укажите явно:

```text
VPN_DNS_SERVERS=10.20.30.53;10.20.30.54
VPN_DNS_SUFFIX=corp.local
```

## Секреты и безопасность

Никогда не коммитьте:

- username/password/PSK;
- WireGuard `PrivateKey`;
- реальные `.ovpn`;
- клиентские сертификаты и private keys;
- production hostnames/IP, если они чувствительны;
- packet captures и диагностические дампы.

Перед публикацией изменений:

```bash
./scripts/check-public-tree.sh
```

Контейнеры получают только необходимые capabilities/devices; примеры не используют `privileged: true`.

## Сборка вручную

Например:

```bash
docker build -t local/ikev2-forwarder:1.2 ./ikev2
```

Или все свободно распространяемые образы:

```bash
./scripts/build-all.sh
```

Kerio по умолчанию исключён из массовой сборки, потому что во время build скачивает проприетарный клиент вендора. Сам `.deb` в репозитории не хранится.

## Документация

- [`docs/architecture.md`](docs/architecture.md) — схема и принципы.
- [`docs/portainer.md`](docs/portainer.md) — развёртывание через Portainer.
- [`docs/status.md`](docs/status.md) — зрелость и ограничения каждого VPN.
- README внутри каждого VPN-каталога — его параметры и особенности.

## Лицензирование

Код wrapper-скриптов можно лицензировать отдельно, но сами VPN-клиенты и библиотеки имеют собственные лицензии. Для Kerio особенно важно соблюдать условия распространения вендорского клиента: репозиторий содержит только Dockerfile/wrapper и загружает официальный пакет при build.
