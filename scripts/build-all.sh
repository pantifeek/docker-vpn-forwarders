#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build() {
    local tag="$1"
    local dir="$2"

    printf '\n==> Building %s from %s\n' "$tag" "$dir"
    docker build -t "$tag" "$ROOT/$dir"
}

build local/ikev2-forwarder:1.2 ikev2
build local/l2tp-ipsec-forwarder:1.2 l2tp-ipsec
build local/openvpn-forwarder:1.1 openvpn
build local/wireguard-forwarder:1.1 wireguard
build local/fortivpn-forwarder:1.1 fortigate-ssl-vpn

cat <<'MSG'

Kerio was not built automatically.
Build it explicitly after reviewing the third-party client URL and vendor terms:
  docker build -t local/kerio-vpn-forwarder:1.1 ./kerio-control-vpn
MSG
