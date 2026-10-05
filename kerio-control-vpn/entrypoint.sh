#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/run/kerio-forwarder"
HEALTH_FILE="${STATE_DIR}/healthy"
VPN_RESOLV_FILE="${STATE_DIR}/vpn-resolv.conf"
DOCKER_RESOLV_BACKUP="${STATE_DIR}/docker-resolv.conf"

mkdir -p "${STATE_DIR}" /var/log/kerio-kvc /var/log
rm -f "${HEALTH_FILE}"

log() { printf '%s [kerio-forwarder] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
load_secret() { local n="$1" fv="${n}_FILE" f="${!fv:-}"; if [[ -n "$f" ]]; then [[ -r "$f" ]] || { log "ERROR: cannot read ${fv}"; exit 1; }; printf -v "$n" '%s' "$(cat "$f")"; fi; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
encode_password() { local v="$1" r="" b; for b in $(printf '%s' "$v" | od -An -t u1); do printf -v r '%s%02x' "$r" "$((b ^ 85))"; done; printf '%s' "$r"; }
normalize_rules() { printf '%s\n' "$1" | tr ';' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d'; }
is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

load_secret VPN_USERNAME
load_secret VPN_PASSWORD
: "${VPN_SERVER:?VPN_SERVER is required}"
: "${VPN_USERNAME:?VPN_USERNAME or VPN_USERNAME_FILE is required}"
: "${VPN_PASSWORD:?VPN_PASSWORD or VPN_PASSWORD_FILE is required}"
: "${PORT_FORWARDS:?PORT_FORWARDS is required}"

VPN_PORT="${VPN_PORT:-4090}"
VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-}"
VPN_DNS_SUFFIX="${VPN_DNS_SUFFIX:-}"
VPN_DNS_TIMEOUT="${VPN_DNS_TIMEOUT:-3}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
HEALTH_MODE="${HEALTH_MODE:-all}"
RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
VPN_CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-45}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"

if [[ -s /etc/resolv.conf ]]; then cp /etc/resolv.conf "$DOCKER_RESOLV_BACKUP"; else printf 'nameserver 127.0.0.11\noptions ndots:0\n' > "$DOCKER_RESOLV_BACKUP"; fi
: > "$VPN_RESOLV_FILE"

restore_docker_resolver() { [[ -s "$DOCKER_RESOLV_BACKUP" ]] && cat "$DOCKER_RESOLV_BACKUP" > /etc/resolv.conf; }
capture_kerio_dns() {
    # Kerio may alter /etc/resolv.conf. Preserve non-Docker nameservers as VPN DNS,
    # then restore Docker DNS so VPN_SERVER resolution remains independent of the tunnel.
    if [[ -r /etc/resolv.conf ]]; then
        awk '$1=="nameserver" && $2!="127.0.0.11" {print $2}' /etc/resolv.conf | awk '!seen[$0]++' > "$VPN_RESOLV_FILE" || true
    fi
    restore_docker_resolver
}

if [[ -z "${VPN_FINGERPRINT:-}" ]]; then
    log "VPN_FINGERPRINT is not set; attempting TLS fingerprint discovery"
    if ! nc -4 -z -w 5 "$VPN_SERVER" "$VPN_PORT" >/dev/null 2>&1; then
        log "ERROR: ${VPN_SERVER}:${VPN_PORT} is not reachable from this container; fingerprint discovery cannot start"
        exit 1
    fi
    VPN_FINGERPRINT="$(timeout 12 openssl s_client -connect "${VPN_SERVER}:${VPN_PORT}" -servername "${VPN_SERVER}" </dev/null 2>/dev/null | openssl x509 -fingerprint -md5 -noout 2>/dev/null | sed 's/^.*=//' || true)"
    if [[ -z "$VPN_FINGERPRINT" ]]; then
        log "ERROR: automatic fingerprint discovery failed; set VPN_FINGERPRINT to a value verified out-of-band"
        exit 1
    fi
    log "Kerio server fingerprint detected automatically"
fi

SERVER_ESC="$(xml_escape "$VPN_SERVER")"
USER_ESC="$(xml_escape "$VPN_USERNAME")"
PASSWORD_XOR="$(encode_password "$VPN_PASSWORD")"
cat > /etc/kerio-kvc.conf <<EOF2
<config>
  <connections>
    <connection type="persistent">
      <server>${SERVER_ESC}</server>
      <port>${VPN_PORT}</port>
      <username>${USER_ESC}</username>
      <password>XOR:${PASSWORD_XOR}</password>
      <fingerprint>${VPN_FINGERPRINT}</fingerprint>
      <active>1</active>
    </connection>
  </connections>
</config>
EOF2
chmod 0600 /etc/kerio-kvc.conf
unset VPN_PASSWORD PASSWORD_XOR

kerio_up() { ip -4 addr show dev kvnet 2>/dev/null | grep -q 'inet '; }
get_vpn_ip() { ip -4 -o addr show dev kvnet 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'; }
wait_for_kerio() {
    local i
    for i in $(seq 1 "$VPN_CONNECT_TIMEOUT"); do
        if kerio_up; then capture_kerio_dns; log "Kerio VPN established"; return 0; fi
        sleep 1
    done
    return 1
}
start_kerio() { rm -f "$HEALTH_FILE"; restore_docker_resolver; log "Starting Kerio VPN client"; /etc/init.d/kerio-kvc stop >/dev/null 2>&1 || true; sleep 1; /etc/init.d/kerio-kvc start; wait_for_kerio; }
stop_kerio() { /etc/init.d/kerio-kvc stop >/dev/null 2>&1 || true; restore_docker_resolver; }

get_vpn_dns_servers() {
    if [[ -n "$VPN_DNS_SERVERS" ]]; then printf '%s\n' "$VPN_DNS_SERVERS" | tr ',; ' '\n\n\n' | sed '/^$/d' | awk '!seen[$0]++'; return; fi
    [[ -r "$VPN_RESOLV_FILE" ]] && awk 'NF {print}' "$VPN_RESOLV_FILE" | awk '!seen[$0]++'
}
qualify_dns_name() { local t="$1" s="${VPN_DNS_SUFFIX#.}"; if [[ "$t" == *.* || -z "$s" ]]; then printf '%s\n' "$t"; else printf '%s.%s\n' "$t" "$s"; fi; }
resolve_target() {
    local t="$1" h dns result
    if is_ipv4 "$t"; then printf '%s\n' "$t"; return 0; fi
    h="$(qualify_dns_name "$t")"
    if kerio_up; then
        capture_kerio_dns
        while IFS= read -r dns; do
            [[ -n "$dns" ]] || continue
            result="$(dig +time="$VPN_DNS_TIMEOUT" +tries=1 +short A "$h" @"$dns" 2>/dev/null | awk '/^[0-9]+\./ {print; exit}')"
            [[ -z "$result" ]] || { printf '%s\n' "$result"; return 0; }
        done < <(get_vpn_dns_servers)
    fi
    result="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1 {print $1; exit}')"
    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}
route_uses_kerio() { local ip="$1"; ip -4 route get "$ip" 2>/dev/null | grep -qE 'dev kvnet([[:space:]]|$)'; }

FORWARDER_PIDS=(); FORWARDER_PORTS=()
stop_forwarders() { local p; for p in "${FORWARDER_PIDS[@]:-}"; do [[ -n "$p" ]] || continue; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; FORWARDER_PIDS=(); FORWARDER_PORTS=(); pkill -TERM socat 2>/dev/null || true; }
port_is_listening() { local p="$1"; ss -H -lnt 2>/dev/null | awk -v port="$p" '$4 ~ (":" port "$") {f=1} END {exit(f?0:1)}'; }
forwarders_ok() { local c="${#FORWARDER_PIDS[@]}" i; ((c>0)) || return 1; [[ "${#FORWARDER_PORTS[@]}" -eq "$c" ]] || return 1; for ((i=0;i<c;i++)); do kill -0 "${FORWARDER_PIDS[$i]}" 2>/dev/null || return 1; port_is_listening "${FORWARDER_PORTS[$i]}" || return 1; done; }
start_forwarders() {
    stop_forwarders
    local line listen target port extra ip count=0 vpn_ip
    vpn_ip="$(get_vpn_ip)" || return 1
    while IFS= read -r line; do
        IFS=: read -r listen target port extra <<< "$line"
        [[ -z "${extra:-}" && "$listen" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] || { log "ERROR: invalid PORT_FORWARDS rule: $line"; return 1; }
        ip="$(resolve_target "$target")" || { log "ERROR: unable to resolve $target"; return 1; }
        route_uses_kerio "$ip" || { log "ERROR: route to $ip does not use kvnet"; return 1; }
        log "Forward TCP ${listen} -> ${target} (${ip}):${port}"
        socat "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" "TCP4:${ip}:${port},bind=${vpn_ip}" >>/var/log/forwarder.log 2>&1 &
        FORWARDER_PIDS+=("$!"); FORWARDER_PORTS+=("$listen"); count=$((count+1))
    done < <(normalize_rules "$PORT_FORWARDS")
    ((count>0)) || return 1; sleep 1; forwarders_ok
}

get_health_targets() { if [[ -n "${HEALTH_TARGETS:-}" ]]; then normalize_rules "$HEALTH_TARGETS"; return; fi; local l a t p x; while IFS= read -r l; do IFS=: read -r a t p x <<< "$l"; printf '%s:%s\n' "$t" "$p"; done < <(normalize_rules "$PORT_FORWARDS"); }
probe_target() { local v="$1" h p x ip vpn_ip; IFS=: read -r h p x <<< "$v"; [[ -z "${x:-}" ]] || return 1; ip="$(resolve_target "$h")" || return 1; route_uses_kerio "$ip" || return 1; vpn_ip="$(get_vpn_ip)" || return 1; nc -4 -z -w "$HEALTH_TIMEOUT" -s "$vpn_ip" "$ip" "$p" >/dev/null 2>&1; }
targets_ok() { local total=0 ok=0 t; while IFS= read -r t; do [[ -n "$t" ]] || continue; total=$((total+1)); probe_target "$t" && ok=$((ok+1)); done < <(get_health_targets); ((total>0)) || return 1; case "$HEALTH_MODE" in any) ((ok>0));; all) ((ok==total));; *) log "ERROR: HEALTH_MODE must be any or all"; return 1;; esac; }
health_ok() { kerio_up && targets_ok && forwarders_ok; }

recover_vpn() { rm -f "$HEALTH_FILE"; stop_forwarders; stop_kerio; sleep 2; start_kerio && start_forwarders; }
cleanup() { rm -f "$HEALTH_FILE"; stop_forwarders; stop_kerio; }
trap cleanup EXIT INT TERM

touch /var/log/kerio-kvc/error.log /var/log/kerio-kvc/debug.log /var/log/forwarder.log
tail -n 0 -F /var/log/kerio-kvc/error.log /var/log/kerio-kvc/debug.log /var/log/forwarder.log &

until start_kerio; do log "Kerio startup failed; retry in 10 seconds"; sleep 10; done
until start_forwarders; do log "Forwarder startup failed; retry in 5 seconds"; sleep 5; done

failures=0; last_recovery=0; recovery_failures=0
while true; do
    sleep "$HEALTH_INTERVAL"
    if health_ok; then failures=0; recovery_failures=0; touch "$HEALTH_FILE"; continue; fi
    rm -f "$HEALTH_FILE"
    if kerio_up && targets_ok && ! forwarders_ok; then
        log "TCP forwarder health failed; restarting forwarders only"
        if start_forwarders; then failures=0; touch "$HEALTH_FILE"; continue; fi
    fi
    failures=$((failures+1)); log "Health check failed (${failures}/${HEALTH_FAIL_THRESHOLD})"
    ((failures>=HEALTH_FAIL_THRESHOLD)) || continue
    failures=0; now="$(date +%s)"
    if ((now-last_recovery<RECOVERY_COOLDOWN)); then log "Recovery suppressed by cooldown"; continue; fi
    last_recovery="$now"
    if recover_vpn; then recovery_failures=0; else recovery_failures=$((recovery_failures+1)); log "Kerio recovery failed (${recovery_failures}/${MAX_RECOVERY_FAILURES})"; fi
    if ((recovery_failures>=MAX_RECOVERY_FAILURES)); then log "ERROR: repeated recovery failures; exiting for Docker restart"; exit 1; fi
done
