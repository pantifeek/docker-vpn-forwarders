#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pairs=(
  "ikev2:portainer/stacks/ikev2.yml:portainer/env/ikev2.env.example"
  "l2tp-ipsec:portainer/stacks/l2tp-ipsec.yml:portainer/env/l2tp-ipsec.env.example"
  "openvpn:portainer/stacks/openvpn.yml:portainer/env/openvpn.env.example"
  "wireguard:portainer/stacks/wireguard.yml:portainer/env/wireguard.env.example"
  "fortigate:portainer/stacks/fortigate.yml:portainer/env/fortigate.env.example"
  "kerio:portainer/stacks/kerio.yml:portainer/env/kerio.env.example"
)

for item in "${pairs[@]}"; do
  IFS=: read -r name stack envfile <<< "$item"
  [[ -r "$stack" ]] || { echo "Missing stack: $stack" >&2; exit 1; }
  [[ -r "$envfile" ]] || { echo "Missing env example: $envfile" >&2; exit 1; }

  if grep -Eq '^[[:space:]]+ports:' "$stack"; then
    echo "ERROR: $stack publishes host ports" >&2
    exit 1
  fi

  if grep -Eq 'privileged:[[:space:]]*true' "$stack"; then
    echo "ERROR: $stack uses privileged=true" >&2
    exit 1
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Validating $name with docker compose config"
    docker compose --env-file "$envfile" -f "$stack" config >/dev/null
  else
    echo "Static check only for $name (docker compose unavailable)"
  fi
done

printf 'Portainer template checks passed.\n'
