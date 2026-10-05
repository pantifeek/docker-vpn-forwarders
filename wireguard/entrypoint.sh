#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/run/wireguard-forwarder"
HEALTH_FILE="${STATE_DIR}/healthy"
WG_CONFIG_FILE="${WG_CONFIG_FILE:-/config/wg0.conf}"
WG_RUNTIME_CONFIG="/run/wireguard/wg0.conf"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-}"
VPN_DNS_SUFFIX="${VPN_DNS_SUFFIX:-}"
VPN_DNS_TIMEOUT="${VPN_DNS_TIMEOUT:-3}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
HEALTH_MODE="${HEALTH_MODE:-all}"
RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
WG_CONNECT_TIMEOUT="${WG_CONNECT_TIMEOUT:-20}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"

mkdir -p "${STATE_DIR}" /run/wireguard /var/log
rm -f "${HEALTH_FILE}"

log() { printf '%s [wireguard-forwarder] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
normalize_rules() { printf '%s\n' "$1" | tr ';' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d'; }
is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

: "${PORT_FORWARDS:?PORT_FORWARDS is required}"
[[ -r "${WG_CONFIG_FILE}" ]] || { log "ERROR: WireGuard config is not readable: ${WG_CONFIG_FILE}"; exit 1; }

# Capture DNS= from wg-quick config before removing it. We intentionally do not
# let wg-quick replace the container resolver; internal names are resolved explicitly.
CONFIG_DNS="$({ awk -F= 'tolower($1) ~ /^[[:space:]]*dns[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2}' "${WG_CONFIG_FILE}" || true; } | tr ',' '\n' | sed '/^$/d' | paste -sd';' -)"
if [[ -z "${VPN_DNS_SERVERS}" && -n "${CONFIG_DNS}" ]]; then
    VPN_DNS_SERVERS="${CONFIG_DNS}"
fi

awk 'tolower($0) !~ /^[[:space:]]*dns[[:space:]]*=/' "${WG_CONFIG_FILE}" > "${WG_RUNTIME_CONFIG}"
chmod 0600 "${WG_RUNTIME_CONFIG}"

is_wg_up() {
    ip link show "${WG_INTERFACE}" >/dev/null 2>&1 && wg show "${WG_INTERFACE}" >/dev/null 2>&1
}

start_wireguard() {
    rm -f "${HEALTH_FILE}"
    if is_wg_up; then wg-quick down "${WG_RUNTIME_CONFIG}" >/dev/null 2>&1 || true; fi
    log "Starting WireGuard interface ${WG_INTERFACE}"
    wg-quick up "${WG_RUNTIME_CONFIG}" || return 1
    local i
    for i in $(seq 1 "${WG_CONNECT_TIMEOUT}"); do
        if is_wg_up; then log "WireGuard interface ${WG_INTERFACE} is up"; return 0; fi
        sleep 1
    done
    log "ERROR: WireGuard interface did not appear"
    return 1
}

stop_wireguard() {
    if is_wg_up; then wg-quick down "${WG_RUNTIME_CONFIG}" >/dev/null 2>&1 || true; fi
}

get_vpn_dns_servers() {
    printf '%s\n' "${VPN_DNS_SERVERS}" | tr ',; ' '\n\n\n' | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

qualify_dns_name() {
    local target="$1" suffix="${VPN_DNS_SUFFIX#.}"
    if [[ "${target}" == *.* || -z "${suffix}" ]]; then printf '%s\n' "${target}"; else printf '%s.%s\n' "${target}" "${suffix}"; fi
}

resolve_target() {
    local target="$1" hostname dns result
    if is_ipv4 "${target}"; then printf '%s\n' "${target}"; return 0; fi
    hostname="$(qualify_dns_name "${target}")"
    if is_wg_up && [[ -n "${VPN_DNS_SERVERS}" ]]; then
        while IFS= read -r dns; do
            [[ -n "${dns}" ]] || continue
            result="$(dig +time="${VPN_DNS_TIMEOUT}" +tries=1 +short A "${hostname}" @"${dns}" 2>/dev/null | awk '/^[0-9]+\./ {print; exit}')"
            if [[ -n "${result}" ]]; then printf '%s\n' "${result}"; return 0; fi
        done < <(get_vpn_dns_servers)
    fi
    result="$(getent ahostsv4 "${hostname}" 2>/dev/null | awk 'NR==1 {print $1; exit}')"
    [[ -n "${result}" ]] || { log "ERROR: cannot resolve target ${hostname}" >&2; return 1; }
    printf '%s\n' "${result}"
}

route_uses_wg() {
    local ip="$1"
    ip -4 route get "${ip}" 2>/dev/null | grep -qE "dev ${WG_INTERFACE}([[:space:]]|$)"
}

FORWARDER_PIDS=()
FORWARDER_PORTS=()

stop_forwarders() {
    local pid
    for pid in "${FORWARDER_PIDS[@]:-}"; do [[ -n "${pid}" ]] || continue; kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; done
    FORWARDER_PIDS=(); FORWARDER_PORTS=(); pkill -TERM socat 2>/dev/null || true
}

port_is_listening() {
    local port="$1"
    ss -H -lnt 2>/dev/null | awk -v port="${port}" '$4 ~ (":" port "$") {found=1} END {exit(found ? 0 : 1)}'
}

forwarders_ok() {
    local count="${#FORWARDER_PIDS[@]}" i
    (( count > 0 )) || return 1
    [[ "${#FORWARDER_PORTS[@]}" -eq "${count}" ]] || return 1
    for ((i=0;i<count;i++)); do kill -0 "${FORWARDER_PIDS[$i]}" 2>/dev/null || return 1; port_is_listening "${FORWARDER_PORTS[$i]}" || return 1; done
}

start_forwarders() {
    stop_forwarders
    local line listen target port extra target_ip count=0
    while IFS= read -r line; do
        IFS=: read -r listen target port extra <<< "${line}"
        [[ -z "${extra:-}" && "${listen}" =~ ^[0-9]+$ && "${port}" =~ ^[0-9]+$ ]] || { log "ERROR: invalid PORT_FORWARDS rule: ${line}"; return 1; }
        target_ip="$(resolve_target "${target}")" || return 1
        route_uses_wg "${target_ip}" || { log "ERROR: route to ${target_ip} does not use ${WG_INTERFACE}"; return 1; }
        log "Forward TCP ${listen} -> ${target} (${target_ip}):${port}"
        socat "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" "TCP4:${target_ip}:${port}" >>/var/log/forwarder.log 2>&1 &
        FORWARDER_PIDS+=("$!"); FORWARDER_PORTS+=("${listen}"); count=$((count+1))
    done < <(normalize_rules "${PORT_FORWARDS}")
    (( count > 0 )) || return 1
    sleep 1
    forwarders_ok
}

get_health_targets() {
    if [[ -n "${HEALTH_TARGETS:-}" ]]; then normalize_rules "${HEALTH_TARGETS}"; return; fi
    local line listen target port extra
    while IFS= read -r line; do IFS=: read -r listen target port extra <<< "${line}"; printf '%s:%s\n' "${target}" "${port}"; done < <(normalize_rules "${PORT_FORWARDS}")
}

probe_target() {
    local value="$1" host port extra ip
    IFS=: read -r host port extra <<< "${value}"; [[ -z "${extra:-}" ]] || return 1
    ip="$(resolve_target "${host}")" || return 1
    route_uses_wg "${ip}" || return 1
    nc -4 -z -w "${HEALTH_TIMEOUT}" "${ip}" "${port}" >/dev/null 2>&1
}

targets_ok() {
    local total=0 ok=0 t
    while IFS= read -r t; do [[ -n "${t}" ]] || continue; total=$((total+1)); probe_target "${t}" && ok=$((ok+1)); done < <(get_health_targets)
    (( total > 0 )) || return 1
    case "${HEALTH_MODE}" in any) (( ok > 0 ));; all) (( ok == total ));; *) log "ERROR: HEALTH_MODE must be any or all"; return 1;; esac
}

health_ok() { is_wg_up && targets_ok && forwarders_ok; }

recover_wireguard() {
    rm -f "${HEALTH_FILE}"; stop_forwarders; stop_wireguard; sleep 2
    start_wireguard && start_forwarders
}

cleanup() { rm -f "${HEALTH_FILE}"; stop_forwarders; stop_wireguard; }
trap cleanup EXIT INT TERM

until start_wireguard; do log "Retry in 10 seconds"; sleep 10; done
until start_forwarders; do log "Forwarder startup failed; retry in 5 seconds"; sleep 5; done

failures=0; last_recovery=0; recovery_failures=0
while true; do
    sleep "${HEALTH_INTERVAL}"
    if health_ok; then failures=0; recovery_failures=0; touch "${HEALTH_FILE}"; continue; fi
    rm -f "${HEALTH_FILE}"
    # If tunnel and targets are good, repair only socat.
    if is_wg_up && targets_ok && ! forwarders_ok; then
        log "TCP forwarder health failed; restarting forwarders only"
        if start_forwarders; then failures=0; touch "${HEALTH_FILE}"; continue; fi
    fi
    failures=$((failures+1)); log "WireGuard health check failed (${failures}/${HEALTH_FAIL_THRESHOLD})"
    (( failures >= HEALTH_FAIL_THRESHOLD )) || continue
    failures=0; now="$(date +%s)"
    if (( now - last_recovery < RECOVERY_COOLDOWN )); then log "Recovery suppressed by cooldown"; continue; fi
    last_recovery="${now}"
    if recover_wireguard; then recovery_failures=0; else recovery_failures=$((recovery_failures+1)); log "WireGuard recovery failed (${recovery_failures}/${MAX_RECOVERY_FAILURES})"; fi
    if (( recovery_failures >= MAX_RECOVERY_FAILURES )); then log "ERROR: repeated recovery failures; exiting for Docker restart"; exit 1; fi
done
