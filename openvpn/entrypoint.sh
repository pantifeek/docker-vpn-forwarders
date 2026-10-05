#!/usr/bin/env bash
set -Eeuo pipefail


#
# ------------------------------------------------------------
# Runtime configuration
# ------------------------------------------------------------
#

RUNTIME_DIR="/run/openvpn-forwarder"
HEALTH_FILE="${RUNTIME_DIR}/healthy"

OVPN_CONFIG_FILE="${OVPN_CONFIG_FILE:-/config/client.ovpn}"
OVPN_KEY_PASSWORD_FILE="${OVPN_KEY_PASSWORD_FILE:-/run/secrets/key_password}"

OVPN_RUNTIME_DIR="/run/openvpn"
OVPN_RUNTIME_FILE="${OVPN_RUNTIME_DIR}/client.ovpn"

HEALTH_TARGETS="${HEALTH_TARGETS:-}"
HEALTH_MODE="${HEALTH_MODE:-any}"

HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"

OPENVPN_CONNECT_TIMEOUT="${OPENVPN_CONNECT_TIMEOUT:-45}"
OPENVPN_VERB="${OPENVPN_VERB:-3}"


mkdir -p \
    "${RUNTIME_DIR}" \
    "${OVPN_RUNTIME_DIR}" \
    /var/log


log() {
    printf '%s [openvpn-forwarder] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*"
}


normalize_rules() {

    printf '%s\n' "$1" |
        tr ';' '\n' |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e '/^$/d' \
            -e '/^#/d'
}


: "${PORT_FORWARDS:?PORT_FORWARDS is required}"


#
# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------
#

if [[ ! -r "${OVPN_CONFIG_FILE}" ]]; then
    log "ERROR: OpenVPN configuration is not readable: ${OVPN_CONFIG_FILE}"
    exit 1
fi


if [[ ! -r "${OVPN_KEY_PASSWORD_FILE}" ]]; then
    log "ERROR: OpenVPN private key password file is not readable"
    exit 1
fi


#
# A daemonized OpenVPN process would escape our supervision.
#
if grep -Eq \
    '^[[:space:]]*daemon([[:space:]]|$)' \
    "${OVPN_CONFIG_FILE}"; then

    log "ERROR: OpenVPN config contains daemon directive"
    exit 1
fi


install \
    -o root \
    -g root \
    -m 0600 \
    "${OVPN_CONFIG_FILE}" \
    "${OVPN_RUNTIME_FILE}"


#
# ------------------------------------------------------------
# OpenVPN process
# ------------------------------------------------------------
#

OPENVPN_PID=""


is_openvpn_running() {

    [[ -n "${OPENVPN_PID:-}" ]] \
        && kill -0 "${OPENVPN_PID}" 2>/dev/null
}


get_tun_interface() {

    ip -o link show |
        awk -F': ' '
            $2 ~ /^(tun|tap)[0-9]+(@.*)?$/ {
                iface=$2
                sub(/@.*/, "", iface)
                print iface
                exit
            }
        '
}


is_vpn_up() {

    is_openvpn_running || return 1

    local iface
    iface="$(get_tun_interface || true)"

    [[ -n "${iface}" ]] || return 1

    ip -4 addr show dev "${iface}" 2>/dev/null |
        grep -q '[[:space:]]inet[[:space:]]'
}


stop_openvpn() {

    if is_openvpn_running; then

        log "Stopping OpenVPN"

        kill "${OPENVPN_PID}" 2>/dev/null || true
        wait "${OPENVPN_PID}" 2>/dev/null || true
    fi

    OPENVPN_PID=""
}


start_openvpn() {

    rm -f "${HEALTH_FILE}"

    stop_openvpn

    log "Starting OpenVPN"

    openvpn \
        --config "${OVPN_RUNTIME_FILE}" \
        --askpass "${OVPN_KEY_PASSWORD_FILE}" \
        --auth-retry nointeract \
        --verb "${OPENVPN_VERB}" &

    OPENVPN_PID=$!

    local i
    local iface

    for ((i=1; i<=OPENVPN_CONNECT_TIMEOUT; i++)); do

        if ! is_openvpn_running; then
            log "ERROR: OpenVPN process exited during connection"
            return 1
        fi

        iface="$(get_tun_interface || true)"

        if [[ -n "${iface}" ]]; then

            #
            # Give OpenVPN time to install pushed routes.
            #
            sleep 2

            if ip -4 addr show dev "${iface}" 2>/dev/null |
                grep -q '[[:space:]]inet[[:space:]]'; then

                log "OpenVPN tunnel ${iface} is up"
                return 0
            fi
        fi

        sleep 1
    done

    log "ERROR: OpenVPN tunnel did not appear"
    return 1
}


#
# ------------------------------------------------------------
# Destination resolving
# ------------------------------------------------------------
#

resolve_target() {

    local target="$1"

    if [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "${target}"
        return 0
    fi

    local result

    result="$(
        getent ahostsv4 "${target}" 2>/dev/null |
            awk '
                NR == 1 {
                    print $1
                    exit
                }
            '
    )"

    if [[ -n "${result}" ]]; then
        printf '%s\n' "${result}"
        return 0
    fi

    log "ERROR: cannot resolve target ${target}" >&2
    return 1
}


#
# ------------------------------------------------------------
# Verify that destination is routed through VPN
# ------------------------------------------------------------
#

route_uses_vpn() {

    local target_ip="$1"
    local iface
    local route

    iface="$(get_tun_interface || true)"
    [[ -n "${iface}" ]] || return 1

    route="$(ip -4 route get "${target_ip}" 2>/dev/null || true)"
    [[ -n "${route}" ]] || return 1

    grep -Eq "(^|[[:space:]])dev[[:space:]]+${iface}([[:space:]]|$)" \
        <<< "${route}"
}


#
# ------------------------------------------------------------
# TCP forwarders
# ------------------------------------------------------------
#

FORWARDER_PIDS=()
FORWARDER_PORTS=()


stop_forwarders() {

    local pid

    for pid in "${FORWARDER_PIDS[@]:-}"; do

        if [[ -n "${pid}" ]]; then
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done

    FORWARDER_PIDS=()
    FORWARDER_PORTS=()

    #
    # Safety cleanup for orphaned socat processes inside
    # this dedicated container.
    #
    pkill -TERM socat 2>/dev/null || true
}


port_is_listening() {

    local port="$1"

    ss -H -lnt 2>/dev/null |
        awk -v port="${port}" '
            $4 ~ (":" port "$") {
                found=1
            }

            END {
                exit(found ? 0 : 1)
            }
        '
}


forwarders_ok() {

    local count="${#FORWARDER_PIDS[@]}"
    local i
    local pid
    local port

    [[ "${count}" -gt 0 ]] || return 1

    [[ "${#FORWARDER_PORTS[@]}" -eq "${count}" ]] || return 1

    for ((i=0; i<count; i++)); do

        pid="${FORWARDER_PIDS[$i]}"
        port="${FORWARDER_PORTS[$i]}"

        kill -0 "${pid}" 2>/dev/null || return 1
        port_is_listening "${port}" || return 1
    done

    return 0
}


start_forwarders() {

    stop_forwarders

    local line
    local listen
    local target
    local port
    local extra
    local target_ip
    local pid
    local count=0

    while IFS= read -r line; do

        [[ -n "${line}" ]] || continue

        IFS=: read -r listen target port extra <<< "${line}"

        if [[ -n "${extra:-}" ]] \
            || [[ ! "${listen}" =~ ^[0-9]+$ ]] \
            || [[ ! "${port}" =~ ^[0-9]+$ ]] \
            || [[ -z "${target}" ]]; then

            log "ERROR: invalid PORT_FORWARDS rule: ${line}"
            stop_forwarders
            return 1
        fi

        target_ip="$(resolve_target "${target}")" || {
            stop_forwarders
            return 1
        }

        log \
            "Forward TCP ${listen} -> ${target} (${target_ip}):${port}"

        socat \
            "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" \
            "TCP4:${target_ip}:${port}" \
            >> /var/log/forwarder.log \
            2>&1 &

        pid=$!

        FORWARDER_PIDS+=("${pid}")
        FORWARDER_PORTS+=("${listen}")

        count=$((count + 1))

    done < <(normalize_rules "${PORT_FORWARDS}")

    if [[ "${count}" -eq 0 ]]; then
        log "ERROR: PORT_FORWARDS contains no usable rules"
        return 1
    fi

    #
    # Give socat a moment to bind its listening sockets.
    #
    sleep 1

    if ! forwarders_ok; then
        log "ERROR: one or more TCP forwarders failed to start"
        stop_forwarders
        return 1
    fi

    return 0
}


restart_forwarders() {

    log "Restarting TCP forwarders only"

    if start_forwarders; then
        log "TCP forwarders recovered"
        return 0
    fi

    log "ERROR: TCP forwarder recovery failed"
    return 1
}


#
# ------------------------------------------------------------
# Health targets
# ------------------------------------------------------------
#

get_health_targets() {

    if [[ -n "${HEALTH_TARGETS:-}" ]]; then
        normalize_rules "${HEALTH_TARGETS}"
        return
    fi

    local line
    local listen
    local target
    local port
    local extra

    while IFS= read -r line; do

        [[ -n "${line}" ]] || continue

        IFS=: read -r listen target port extra <<< "${line}"

        if [[ -n "${extra:-}" ]] \
            || [[ -z "${target}" ]] \
            || [[ ! "${port}" =~ ^[0-9]+$ ]]; then

            continue
        fi

        printf '%s:%s\n' \
            "${target}" \
            "${port}"

    done < <(normalize_rules "${PORT_FORWARDS}")
}


probe_target() {

    local value="$1"

    local host
    local port
    local extra
    local target_ip

    IFS=: read -r host port extra <<< "${value}"

    [[ -z "${extra:-}" ]] || return 1
    [[ -n "${host}" ]] || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1

    target_ip="$(resolve_target "${host}")" || return 1

    #
    # v1.1: successful health target must actually be routed
    # through the current OpenVPN interface.
    #
    route_uses_vpn "${target_ip}" || return 1

    nc \
        -4 \
        -z \
        -w "${HEALTH_TIMEOUT}" \
        "${target_ip}" \
        "${port}" \
        >/dev/null \
        2>&1
}


health_targets_ok() {

    local total=0
    local successful=0
    local target

    while IFS= read -r target; do

        [[ -n "${target}" ]] || continue

        total=$((total + 1))

        if probe_target "${target}"; then
            successful=$((successful + 1))
        fi

    done < <(get_health_targets)

    #
    # v1.0 treated zero targets as healthy.
    # That masked broken PORT_FORWARDS configuration.
    #
    if [[ "${total}" -eq 0 ]]; then
        log "ERROR: no health targets were generated"
        return 1
    fi

    case "${HEALTH_MODE}" in

        any)
            [[ "${successful}" -gt 0 ]]
            ;;

        all)
            [[ "${successful}" -eq "${total}" ]]
            ;;

        *)
            log "ERROR: HEALTH_MODE must be any or all"
            return 1
            ;;
    esac
}


complete_health_ok() {

    is_vpn_up || return 1
    forwarders_ok || return 1
    health_targets_ok || return 1

    return 0
}


#
# ------------------------------------------------------------
# Full OpenVPN recovery
# ------------------------------------------------------------
#

recover_openvpn() {

    log "Restarting OpenVPN connection"

    rm -f "${HEALTH_FILE}"

    stop_forwarders
    stop_openvpn

    sleep 2

    if ! start_openvpn; then
        log "ERROR: OpenVPN recovery failed"
        return 1
    fi

    if ! start_forwarders; then
        log "ERROR: OpenVPN recovered, but TCP forwarders failed"
        return 1
    fi

    return 0
}


attempt_openvpn_recovery() {
    if recover_openvpn; then
        recovery_failures=0
        return 0
    fi

    recovery_failures=$((recovery_failures + 1))
    log "OpenVPN recovery failed (${recovery_failures}/${MAX_RECOVERY_FAILURES})"

    if [[ "${recovery_failures}" -ge "${MAX_RECOVERY_FAILURES}" ]]; then
        log "ERROR: repeated recovery failures; exiting for Docker restart"
        exit 1
    fi

    return 1
}


#
# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
#

cleanup() {

    rm -f "${HEALTH_FILE}"

    stop_forwarders
    stop_openvpn
}


trap cleanup EXIT
trap 'exit 0' INT TERM


#
# ------------------------------------------------------------
# Initial connection
# ------------------------------------------------------------
#

until start_openvpn; do

    log "Retry OpenVPN in 10 seconds"
    sleep 10
done


until start_forwarders; do

    log "Retry TCP forwarders in 5 seconds"
    sleep 5
done


#
# Initial health is not assumed.
# It must be proven by the monitor loop.
#
rm -f "${HEALTH_FILE}"


#
# ------------------------------------------------------------
# Monitoring
# ------------------------------------------------------------
#

failures=0
last_recovery=0
recovery_failures=0


while true; do

    #
    # 1. VPN process/interface itself.
    #
    if ! is_vpn_up; then

        rm -f "${HEALTH_FILE}"

        failures=$((failures + 1))

        log \
            "OpenVPN tunnel health check failed " \
            "(${failures}/${HEALTH_FAIL_THRESHOLD})"

        if [[ "${failures}" -ge "${HEALTH_FAIL_THRESHOLD}" ]]; then

            now="$(date +%s)"

            if (( now - last_recovery >= RECOVERY_COOLDOWN )); then

                attempt_openvpn_recovery || true

                last_recovery="${now}"
                failures=0
            fi
        fi

        sleep "${HEALTH_INTERVAL}"
        continue
    fi


    #
    # 2. Local socat forwarders.
    #
    # If only socat died, do NOT restart OpenVPN.
    #
    if ! forwarders_ok; then

        rm -f "${HEALTH_FILE}"

        log "TCP forwarder health check failed"

        restart_forwarders || true

        if ! forwarders_ok; then
            sleep "${HEALTH_INTERVAL}"
            continue
        fi
    fi


    #
    # 3. Real destination through the VPN.
    #
    if health_targets_ok; then

        if [[ "${failures}" -gt 0 ]]; then
            log "VPN destination health check recovered"
        fi

        failures=0
        recovery_failures=0
        touch "${HEALTH_FILE}"

    else

        rm -f "${HEALTH_FILE}"

        failures=$((failures + 1))

        log \
            "VPN destination health check failed " \
            "(${failures}/${HEALTH_FAIL_THRESHOLD})"

        if [[ "${failures}" -ge "${HEALTH_FAIL_THRESHOLD}" ]]; then

            now="$(date +%s)"

            if (( now - last_recovery >= RECOVERY_COOLDOWN )); then

                attempt_openvpn_recovery || true

                last_recovery="${now}"
                failures=0
            fi
        fi
    fi


    sleep "${HEALTH_INTERVAL}"
done
