# Развёртывание через Portainer

## Рекомендуемая модель

Один VPN-клиент = один Stack/service = один набор секретов.

Не объединяйте несколько независимых VPN-подключений в один контейнер. Если нужно 10 VPN — создайте 10 Stack-экземпляров из одного и того же шаблона с разными переменными.

## Git Stack

Для публикационного репозитория рекомендуется использовать Portainer **Git repository Stack**. В репозитории уже есть готовые Compose-файлы:

```text
portainer/stacks/ikev2.yml
portainer/stacks/l2tp-ipsec.yml
portainer/stacks/openvpn.yml
portainer/stacks/wireguard.yml
portainer/stacks/fortigate.yml
portainer/stacks/kerio.yml
```

Каждый Stack использует `build.context` на соответствующий каталог репозитория и не требует заранее опубликованного Docker image registry.

## Environment variables

Рядом лежат примеры переменных:

```text
portainer/env/ikev2.env.example
portainer/env/l2tp-ipsec.env.example
...
```

В Portainer значения задаются в секции **Environment variables** самого Stack. Реальные секреты туда по возможности не помещайте — передавайте пути к файлам на Docker host (`SECRET_DIR`).

## Секреты на Docker host

Пример:

```text
/opt/vpn-forwarders/secrets/customer-a/
├── username
├── password
├── psk
├── client.ovpn
├── key_password
├── wg0.conf
└── ca/
```

Stack bind-mount'ит только нужные файлы как read-only. Это подходит для обычного Docker endpoint в Portainer и не требует Docker Swarm Secrets.

## Общая Docker-сеть

По умолчанию шаблоны ожидают external network:

```text
guac-vpn-transit
```

Создать один раз:

```bash
docker network create guac-vpn-transit
```

И `guacd`, и все VPN-forwarder должны быть подключены к ней.

## Имена сервисов

Шаблоны используют:

```yaml
container_name: ${VPN_CONTAINER_NAME}
```

Поэтому в Guacamole можно использовать то же значение как hostname. Имя должно быть уникальным на Docker host.

## Обновление из Git

После изменения репозитория Portainer может повторно pull'нуть Git и redeploy Stack. Если менялся Dockerfile/entrypoint, включайте пересборку image при redeploy.

## Что не делать

- Не добавляйте `ports:` только ради Guacamole — это откроет forward-порт на Docker host.
- Не храните secrets рядом с Compose в Git.
- Не используйте `privileged: true`, если конкретный VPN не требует этого доказуемо.
- Не используйте одну и ту же WireGuard private key одновременно в нескольких активных контейнерах.
