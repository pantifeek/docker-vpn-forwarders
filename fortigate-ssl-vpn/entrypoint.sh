#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_DIR="/run/fortivpn-forwarder"
HEALTH_FILE="${RUNTIME_DIR}/healthy"
CONFIG_FILE="/run/openfortivpn/config"
VPN_RESOLV_FILE="${RUNTIME_DIR}/vpn-resolv.conf"

mkdir -p "${RUNTIME_DIR}" /run/openfortivpn /var/log
chmod 0700 /run/openfortivpn
rm -f "${HEALTH_FILE}"
: > "${VPN_RESOLV_FILE}"

log() { printf '%s [fortivpn-forwarder] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
read_secret() { local f="$1"; [[ -r "$f" ]] || fail "Secret file is not readable: $f"; tr -d '\r\n' < "$f"; }
normalize_rules() { printf '%s\n' "$1" | tr ';' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d'; }
is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

: "${FORTI_HOST:?FORTI_HOST is required}"
FORTI_PORT="${FORTI_PORT:-443}"
: "${FORTI_USERNAME_FILE:?FORTI_USERNAME_FILE is required}"
: "${FORTI_PASSWORD_FILE:?FORTI_PASSWORD_FILE is required}"
: "${PORT_FORWARDS:?PORT_FORWARDS is required}"

FORTI_REALM="${FORTI_REALM:-}"
VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-}"
VPN_DNS_SUFFIX="${VPN_DNS_SUFFIX:-}"
VPN_DNS_TIMEOUT="${VPN_DNS_TIMEOUT:-3}"
HEALTH_TARGETS="${HEALTH_TARGETS:-}"
HEALTH_MODE="${HEALTH_MODE:-all}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
FORTI_CONNECT_TIMEOUT="${FORTI_CONNECT_TIMEOUT:-60}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"

USERNAME="$(read_secret "$FORTI_USERNAME_FILE")"
PASSWORD="$(read_secret "$FORTI_PASSWORD_FILE")"
[[ -n "$USERNAME" ]] || fail "VPN username is empty"
[[ -n "$PASSWORD" ]] || fail "VPN password is empty"

FORTI_PID=""
FORWARDER_PIDS=()
FORWARDER_PORTS=()

write_config() {
    umask 077
    cat > "$CONFIG_FILE" <<EOF2
host = ${FORTI_HOST}
port = ${FORTI_PORT}
username = ${USERNAME}
password = ${PASSWORD}
set-dns = 0
pppd-use-peerdns = 1
EOF2
    [[ -z "$FORTI_REALM" ]] || printf 'realm = %s\n' "$FORTI_REALM" >> "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

find_ppp_interface() { ip -o link show | awk -F': ' '$2 ~ /^ppp[0-9]+$/ {print $2; exit}'; }
get_vpn_ip() { local i; i="$(find_ppp_interface || true)"; [[ -n "$i" ]] || return 1; ip -4 -o addr show dev "$i" | awk 'NR==1 {split($4,a,"/"); print a[1]}'; }
is_vpn_up() { local i; [[ -n "${FORTI_PID}" ]] && kill -0 "${FORTI_PID}" 2>/dev/null || return 1; i="$(find_ppp_interface || true)"; [[ -n "$i" ]] && ip -4 addr show dev "$i" | grep -q 'inet '; }

capture_peer_dns() {
    local src=""
    for src in /etc/ppp/resolv.conf /var/run/ppp/resolv.conf; do
        [[ -r "$src" ]] || continue
        awk '$1=="nameserver" {print $2}' "$src" | awk '!seen[$0]++' > "$VPN_RESOLV_FILE" || true
        [[ -s "$VPN_RESOLV_FILE" ]] && return 0
    done
    return 0
}

wait_for_vpn() {
    local elapsed=0 iface
    while (( elapsed < FORTI_CONNECT_TIMEOUT )); do
        [[ -n "${FORTI_PID}" ]] && kill -0 "$FORTI_PID" 2>/dev/null || return 1
        iface="$(find_ppp_interface || true)"
        if [[ -n "$iface" ]] && ip -4 addr show dev "$iface" | grep -q 'inet '; then
            capture_peer_dns
            log "VPN established, interface ${iface}"
            return 0
        fi
        sleep 1; elapsed=$((elapsed+1))
    done
    return 1
}

get_vpn_dns_servers() {
    if [[ -n "$VPN_DNS_SERVERS" ]]; then printf '%s\n' "$VPN_DNS_SERVERS" | tr ',; ' '\n\n\n' | sed '/^$/d' | awk '!seen[$0]++'; return; fi
    [[ -r "$VPN_RESOLV_FILE" ]] && awk 'NF {print}' "$VPN_RESOLV_FILE" | awk '!seen[$0]++'
}

qualify_dns_name() { local t="$1" s="${VPN_DNS_SUFFIX#.}"; if [[ "$t" == *.* || -z "$s" ]]; then printf '%s\n' "$t"; else printf '%s.%s\n' "$t" "$s"; fi; }

resolve_target() {
    local target="$1" host dns result
    if is_ipv4 "$target"; then printf '%s\n' "$target"; return 0; fi
    host="$(qualify_dns_name "$target")"
    if is_vpn_up; then
        while IFS= read -r dns; do
            [[ -n "$dns" ]] || continue
            result="$(dig +time="$VPN_DNS_TIMEOUT" +tries=1 +short A "$host" @"$dns" 2>/dev/null | awk '/^[0-9]+\./ {print; exit}')"
            [[ -z "$result" ]] || { printf '%s\n' "$result"; return 0; }
        done < <(get_vpn_dns_servers)
    fi
    result="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1; exit}')"
    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}

route_uses_ppp() {
    local ip="$1" iface
    iface="$(find_ppp_interface || true)"; [[ -n "$iface" ]] || return 1
    ip -4 route get "$ip" 2>/dev/null | grep -qE "dev ${iface}([[:space:]]|$)"
}

stop_forwarders() {
    local p
    for p in "${FORWARDER_PIDS[@]:-}"; do [[ -n "$p" ]] || continue; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
    FORWARDER_PIDS=(); FORWARDER_PORTS=(); pkill -TERM socat 2>/dev/null || true
}
port_is_listening() { local p="$1"; ss -H -lnt 2>/dev/null | awk -v port="$p" '$4 ~ (":" port "$") {f=1} END {exit(f?0:1)}'; }
forwarders_ok() { local c="${#FORWARDER_PIDS[@]}" i; (( c > 0 )) || return 1; [[ "${#FORWARDER_PORTS[@]}" -eq "$c" ]] || return 1; for ((i=0;i<c;i++)); do kill -0 "${FORWARDER_PIDS[$i]}" 2>/dev/null || return 1; port_is_listening "${FORWARDER_PORTS[$i]}" || return 1; done; }

start_forwarders() {
    stop_forwarders
    local rule listen target port extra ip count=0 vpn_ip
    vpn_ip="$(get_vpn_ip)" || return 1
    while IFS= read -r rule; do
        IFS=: read -r listen target port extra <<< "$rule"
        [[ -z "${extra:-}" && "$listen" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] || { log "ERROR: invalid PORT_FORWARDS rule: $rule"; return 1; }
        ip="$(resolve_target "$target")" || { log "ERROR: unable to resolve target $target"; return 1; }
        route_uses_ppp "$ip" || { log "ERROR: route to $ip does not use VPN PPP interface"; return 1; }
        log "Forward TCP ${listen} -> ${target} (${ip}):${port}"
        socat "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" "TCP4:${ip}:${port},bind=${vpn_ip}" >>/var/log/forwarder.log 2>&1 &
        FORWARDER_PIDS+=("$!"); FORWARDER_PORTS+=("$listen"); count=$((count+1))
    done < <(normalize_rules "$PORT_FORWARDS")
    (( count > 0 )) || return 1
    sleep 1; forwarders_ok
}

get_health_targets() {
    if [[ -n "$HEALTH_TARGETS" ]]; then normalize_rules "$HEALTH_TARGETS"; return; fi
    local r l t p x; while IFS= read -r r; do IFS=: read -r l t p x <<< "$r"; printf '%s:%s\n' "$t" "$p"; done < <(normalize_rules "$PORT_FORWARDS")
}

probe_target() {
    local item="$1" host port extra ip vpn_ip
    IFS=: read -r host port extra <<< "$item"; [[ -z "${extra:-}" ]] || return 1
    ip="$(resolve_target "$host")" || return 1; route_uses_ppp "$ip" || return 1; vpn_ip="$(get_vpn_ip)" || return 1
    nc -4 -z -w "$HEALTH_TIMEOUT" -s "$vpn_ip" "$ip" "$port" >/dev/null 2>&1
}

targets_ok() {
    local total=0 ok=0 t; while IFS= read -r t; do [[ -n "$t" ]] || continue; total=$((total+1)); probe_target "$t" && ok=$((ok+1)); done < <(get_health_targets)
    (( total > 0 )) || return 1
    case "$HEALTH_MODE" in any) ((ok>0));; all) ((ok==total));; *) log "ERROR: HEALTH_MODE must be any or all"; return 1;; esac
}
health_ok() { is_vpn_up && targets_ok && forwarders_ok; }

stop_vpn() {
    if [[ -n "${FORTI_PID:-}" ]] && kill -0 "$FORTI_PID" 2>/dev/null; then log "Stopping openfortivpn"; kill "$FORTI_PID" 2>/dev/null || true; wait "$FORTI_PID" 2>/dev/null || true; fi
    FORTI_PID=""
}

start_vpn() {
    rm -f "$HEALTH_FILE"; : > "$VPN_RESOLV_FILE"; write_config
    log "Connecting SSL-VPN to ${FORTI_HOST}:${FORTI_PORT}"
    openfortivpn -c "$CONFIG_FILE" >>/var/log/openfortivpn.log 2>&1 & FORTI_PID="$!"
    if ! wait_for_vpn; then log "ERROR: VPN tunnel did not become ready"; return 1; fi
    return 0
}

recover_vpn() { rm -f "$HEALTH_FILE"; stop_forwarders; stop_vpn; sleep 3; start_vpn && start_forwarders; }
cleanup() { rm -f "$HEALTH_FILE"; stop_forwarders; stop_vpn; }
trap cleanup EXIT INT TERM

touch /var/log/openfortivpn.log /var/log/forwarder.log
tail -n 0 -F /var/log/openfortivpn.log /var/log/forwarder.log &

until start_vpn; do log "VPN startup failed; retry in 10 seconds"; stop_vpn; sleep 10; done
until start_forwarders; do log "Forwarder startup failed; retry in 5 seconds"; sleep 5; done

failures=0; last_recovery=0; recovery_failures=0
while true; do
    sleep "$HEALTH_INTERVAL"
    if health_ok; then failures=0; recovery_failures=0; touch "$HEALTH_FILE"; continue; fi
    rm -f "$HEALTH_FILE"
    if is_vpn_up && targets_ok && ! forwarders_ok; then
        log "TCP forwarder health failed; restarting forwarders only"
        if start_forwarders; then failures=0; touch "$HEALTH_FILE"; continue; fi
    fi
    failures=$((failures+1)); log "VPN health check failed (${failures}/${HEALTH_FAIL_THRESHOLD})"
    (( failures >= HEALTH_FAIL_THRESHOLD )) || continue
    failures=0; now="$(date +%s)"
    if (( now - last_recovery < RECOVERY_COOLDOWN )); then log "Recovery suppressed by cooldown"; continue; fi
    last_recovery="$now"
    if recover_vpn; then recovery_failures=0; else recovery_failures=$((recovery_failures+1)); log "VPN recovery failed (${recovery_failures}/${MAX_RECOVERY_FAILURES})"; fi
    if (( recovery_failures >= MAX_RECOVERY_FAILURES )); then log "ERROR: repeated recovery failures; exiting for Docker restart"; exit 1; fi
done
