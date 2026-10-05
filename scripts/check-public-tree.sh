#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failed=0

printf 'Checking for files that should normally stay out of a public repository...\n'

while IFS= read -r -d '' file; do
    case "$file" in
        ./.git/*) continue ;;
    esac

    printf 'SUSPICIOUS FILE: %s\n' "$file"
    failed=1
done < <(
    find . -type f \
        \( -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' \
           -o -name '*.ovpn' -o -name '*.pcap' -o -name '*.pcapng' \) \
        -print0
)

printf 'Checking for private-key material...\n'
if grep -RIlE --exclude-dir=.git -- \
    '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----' . >/tmp/vpn-forwarder-private-key-hits 2>/dev/null; then
    cat /tmp/vpn-forwarder-private-key-hits
    failed=1
fi
rm -f /tmp/vpn-forwarder-private-key-hits

printf 'Checking shell syntax...\n'
while IFS= read -r -d '' file; do
    bash -n "$file"
done < <(find . -type f -name '*.sh' -print0)

if (( failed != 0 )); then
    printf '\nPublic-tree check FAILED. Review the findings before committing.\n' >&2
    exit 1
fi

printf 'Public-tree check passed. Manual git diff review is still required.\n'
