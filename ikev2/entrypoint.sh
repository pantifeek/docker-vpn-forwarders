#!/usr/bin/env bash
set -Eeuo pipefail

CONN_NAME="ikev2-client"
STATE_DIR="/run/ikev2-forwarder"
HEALTH_FILE="${STATE_DIR}/healthy"
VPN_RESOLV_FILE="${STATE_DIR}/vpn-resolv.conf"
DOCKER_RESOLV_BACKUP="${STATE_DIR}/docker-resolv.conf"

mkdir -p "${STATE_DIR}"
rm -f "${HEALTH_FILE}"

# Сохраняем DNS, который Docker выдал контейнеру. Этот resolver нужен,
# чтобы VPN_SERVER продолжал разрешаться даже при упавшем VPN.
if [[ -s /etc/resolv.conf ]]; then
    cat /etc/resolv.conf > "${DOCKER_RESOLV_BACKUP}"
else
    printf 'nameserver 127.0.0.11\noptions ndots:0\n' \
        > "${DOCKER_RESOLV_BACKUP}"
fi

# strongSwan resolve plugin будет писать DNS, полученные через IKEv2,
# сюда, а не в /etc/resolv.conf.
: > "${VPN_RESOLV_FILE}"
chmod 0644 "${VPN_RESOLV_FILE}" "${DOCKER_RESOLV_BACKUP}"

log() {
    printf '%s [ikev2-forwarder] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

load_secret() {
    local name="$1"
    local file_var="${name}_FILE"
    local file="${!file_var:-}"

    if [[ -n "${file}" ]]; then
        [[ -r "${file}" ]] || {
            log "ERROR: cannot read ${file_var}"
            exit 1
        }

        printf -v "${name}" '%s' "$(cat "${file}")"
    fi
}

normalize_rules() {
    printf '%s\n' "$1" \
        | tr ';' '\n' \
        | sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e '/^$/d' \
            -e '/^#/d'
}

escape_secret() {
    printf '%s' "$1" |
        sed 's/\\/\\\\/g; s/"/\\"/g'
}

is_ipv4() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

restore_docker_resolver() {
    if [[ -s "${DOCKER_RESOLV_BACKUP}" ]]; then
        cat "${DOCKER_RESOLV_BACKUP}" > /etc/resolv.conf
    else
        printf 'nameserver 127.0.0.11\noptions ndots:0\n' \
            > /etc/resolv.conf
    fi
}

ensure_vpn_server_resolution() {
    if is_ipv4 "${VPN_SERVER}"; then
        return 0
    fi

    if getent ahostsv4 "${VPN_SERVER}" >/dev/null 2>&1; then
        return 0
    fi

    log "VPN server DNS resolution failed, restoring Docker resolver"
    restore_docker_resolver

    if getent ahostsv4 "${VPN_SERVER}" >/dev/null 2>&1; then
        log "VPN server DNS resolution recovered"
        return 0
    fi

    log "ERROR: cannot resolve VPN_SERVER ${VPN_SERVER}"
    return 1
}

load_secret VPN_USERNAME
load_secret VPN_PASSWORD

: "${VPN_SERVER:?VPN_SERVER is required}"
: "${VPN_SERVER_ID:?VPN_SERVER_ID is required}"
: "${VPN_USERNAME:?VPN_USERNAME_FILE is required}"
: "${VPN_PASSWORD:?VPN_PASSWORD_FILE is required}"
: "${PORT_FORWARDS:?PORT_FORWARDS is required}"

VPN_EAP_IDENTITY="${VPN_EAP_IDENTITY:-${VPN_USERNAME}}"

# Optional split-DNS configuration.
# If VPN_DNS_SERVERS is empty, DNS servers received from the IKEv2 gateway
# are read from VPN_RESOLV_FILE.
VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-}"
VPN_DNS_SUFFIX="${VPN_DNS_SUFFIX:-}"
VPN_DNS_TIMEOUT="${VPN_DNS_TIMEOUT:-3}"

HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
HEALTH_MODE="${HEALTH_MODE:-any}"

RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
VPN_CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-45}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"
FORWARDER_START_RETRIES="${FORWARDER_START_RETRIES:-6}"
FORWARDER_RETRY_INTERVAL="${FORWARDER_RETRY_INTERVAL:-5}"

USER_ESC="$(escape_secret "${VPN_USERNAME}")"
PASS_ESC="$(escape_secret "${VPN_PASSWORD}")"
EAP_ESC="$(escape_secret "${VPN_EAP_IDENTITY}")"

derive_remote_ts() {
    local result=""
    local line listen target port extra cidr

    while IFS= read -r line; do
        IFS=: read -r listen target port extra <<< "${line}"

        [[ -z "${extra:-}" ]] || {
            log "ERROR: invalid PORT_FORWARDS rule: ${line}"
            exit 1
        }

        [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            log "ERROR: VPN_REMOTE_TS must be specified for DNS targets"
            exit 1
        }

        cidr="${target}/32"

        if [[ ",${result}," != *",${cidr},"* ]]; then
            [[ -z "${result}" ]] \
                && result="${cidr}" \
                || result="${result},${cidr}"
        fi
    done < <(normalize_rules "${PORT_FORWARDS}")

    printf '%s' "${result}"
}

VPN_REMOTE_TS="${VPN_REMOTE_TS:-$(derive_remote_ts)}"

cat > /etc/ipsec.conf <<EOF2
config setup
    uniqueids=no

conn ${CONN_NAME}
    keyexchange=ikev2
    type=tunnel
    auto=add

    keyingtries=1
    fragmentation=yes

    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s

    left=%defaultroute
    leftauth=eap-mschapv2
    leftsourceip=%config4
    eap_identity="${EAP_ESC}"

    right=${VPN_SERVER}
    rightid="${VPN_SERVER_ID}"
    rightauth=pubkey
    rightsubnet=${VPN_REMOTE_TS}
EOF2

if [[ -n "${VPN_LOCAL_ID:-}" ]]; then
    printf '    leftid="%s"\n' "${VPN_LOCAL_ID}" \
        >> /etc/ipsec.conf
fi

if [[ -n "${VPN_IKE:-}" ]]; then
    printf '    ike=%s\n' "${VPN_IKE}" \
        >> /etc/ipsec.conf
fi

if [[ -n "${VPN_ESP:-}" ]]; then
    printf '    esp=%s\n' "${VPN_ESP}" \
        >> /etc/ipsec.conf
fi

printf '"%s" : EAP "%s"\n' \
    "${EAP_ESC}" \
    "${PASS_ESC}" \
    > /etc/ipsec.secrets

chmod 0600 /etc/ipsec.secrets

# Дополнительные CA, если они переданы.
if compgen -G '/config/ca/*' >/dev/null 2>&1; then
    cp -L /config/ca/* /etc/ipsec.d/cacerts/
fi

# В v1.2 resolve plugin больше не меняет /etc/resolv.conf.
# DNS, выданные VPN-шлюзом, сохраняются в отдельный runtime-файл.
cat > /etc/strongswan.d/charon-forwarder.conf <<EOF2
charon {
    filelog {
        forwarder {
            path = /var/log/charon.log
            append = yes
            default = 1
            flush_line = yes
            ike_name = yes
        }
    }

    plugins {
        resolve {
            file = ${VPN_RESOLV_FILE}
        }
    }
}
EOF2

touch /var/log/charon.log

is_vpn_up() {
    ipsec statusall 2>/dev/null |
        grep -qE "${CONN_NAME}\\[[0-9]+\\]: ESTABLISHED"
}

connect_vpn() {
    rm -f "${HEALTH_FILE}"

    ensure_vpn_server_resolution || return 1

    log "Connecting to ${VPN_SERVER}"

    timeout "${VPN_CONNECT_TIMEOUT}" \
        ipsec up "${CONN_NAME}" \
        >/tmp/ipsec-up.log 2>&1 || true

    local i

    for i in $(seq 1 "${VPN_CONNECT_TIMEOUT}"); do
        if is_vpn_up; then
            log "IKEv2 tunnel established"
            return 0
        fi
        sleep 1
    done

    log "IKEv2 connection failed"
    return 1
}

get_vpn_dns_servers() {
    if [[ -n "${VPN_DNS_SERVERS}" ]]; then
        printf '%s\n' "${VPN_DNS_SERVERS}" \
            | tr ',; ' '\n\n\n' \
            | sed '/^[[:space:]]*$/d' \
            | awk '!seen[$0]++'
        return
    fi

    [[ -r "${VPN_RESOLV_FILE}" ]] || return 0

    awk '
        $1 == "nameserver" && NF >= 2 {
            if (!seen[$2]++) {
                print $2
            }
        }
    ' "${VPN_RESOLV_FILE}"
}

qualify_dns_name() {
    local target="$1"
    local suffix="${VPN_DNS_SUFFIX#.}"

    if [[ "${target}" == *.* ]] || [[ -z "${suffix}" ]]; then
        printf '%s\n' "${target}"
    else
        printf '%s.%s\n' "${target}" "${suffix}"
    fi
}

resolve_with_vpn_dns() {
    local hostname="$1"
    local dns
    local result
    local have_dns=0

    while IFS= read -r dns; do
        [[ -n "${dns}" ]] || continue
        have_dns=1

        result="$(
            dig \
                +time="${VPN_DNS_TIMEOUT}" \
                +tries=1 \
                +short \
                A "${hostname}" \
                @"${dns}" \
                2>/dev/null \
                | awk '
                    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                        print
                        exit
                    }
                '
        )"

        if [[ -n "${result}" ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
    done < <(get_vpn_dns_servers)

    [[ "${have_dns}" -eq 1 ]] || return 1
    return 1
}

resolve_target() {
    local target="$1"
    local hostname
    local result

    if is_ipv4 "${target}"; then
        printf '%s\n' "${target}"
        return 0
    fi

    hostname="$(qualify_dns_name "${target}")"

    # Для внутренних имён сначала используем DNS, полученные через IKEv2
    # (или явно заданные VPN_DNS_SERVERS).
    if is_vpn_up; then
        result="$(resolve_with_vpn_dns "${hostname}" || true)"

        if [[ -n "${result}" ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
    fi

    # Fallback на обычный Docker/system resolver. Это полезно для публичных
    # имён и не влияет на split-DNS для внутренних зон.
    result="$(
        getent ahostsv4 "${hostname}" 2>/dev/null |
            awk 'NR == 1 {print $1; exit}'
    )"

    if [[ -n "${result}" ]]; then
        printf '%s\n' "${result}"
        return 0
    fi

    log "ERROR: cannot resolve target ${hostname}" >&2
    return 1
}

FORWARDER_PIDS=()
FORWARDER_PORTS=()

stop_forwarders() {
    local pid

    for pid in "${FORWARDER_PIDS[@]:-}"; do
        [[ -n "${pid}" ]] || continue
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done

    FORWARDER_PIDS=()
    FORWARDER_PORTS=()
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
    local i pid port

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

    local line listen target port extra target_ip pid
    local count=0

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue

        IFS=: read -r listen target port extra <<< "${line}"

        if [[ -n "${extra:-}" ]] \
            || [[ ! "${listen}" =~ ^[0-9]+$ ]] \
            || [[ ! "${port}" =~ ^[0-9]+$ ]] \
            || [[ -z "${target}" ]]; then

            log "ERROR: invalid forwarding rule: ${line}"
            stop_forwarders
            return 1
        fi

        target_ip="$(resolve_target "${target}")" || {
            stop_forwarders
            return 1
        }

        log "Forward TCP ${listen} -> ${target} (${target_ip}):${port}"

        socat \
            "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" \
            "TCP4:${target_ip}:${port}" \
            >>/var/log/forwarder.log 2>&1 &

        pid="$!"
        FORWARDER_PIDS+=("${pid}")
        FORWARDER_PORTS+=("${listen}")
        count=$((count + 1))
    done < <(normalize_rules "${PORT_FORWARDS}")

    if [[ "${count}" -eq 0 ]]; then
        log "ERROR: PORT_FORWARDS contains no usable rules"
        return 1
    fi

    sleep 1

    if ! forwarders_ok; then
        log "ERROR: one or more TCP forwarders failed to start"
        stop_forwarders
        return 1
    fi

    return 0
}

start_forwarders_with_retry() {
    local i

    for i in $(seq 1 "${FORWARDER_START_RETRIES}"); do
        if start_forwarders; then
            return 0
        fi

        log "Retry TCP forwarders in ${FORWARDER_RETRY_INTERVAL} seconds"
        sleep "${FORWARDER_RETRY_INTERVAL}"
    done

    return 1
}

get_health_targets() {
    if [[ -n "${HEALTH_TARGETS:-}" ]]; then
        printf '%s\n' "${HEALTH_TARGETS}" |
            tr ';' '\n' |
            sed '/^[[:space:]]*$/d'
        return
    fi

    local line listen target port extra

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        IFS=: read -r listen target port extra <<< "${line}"
        printf '%s:%s\n' "${target}" "${port}"
    done < <(normalize_rules "${PORT_FORWARDS}")
}

probe_target() {
    local target="$1"
    local host port extra target_ip

    IFS=: read -r host port extra <<< "${target}"

    [[ -z "${extra:-}" ]] || return 1
    [[ -n "${host}" ]] || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1

    target_ip="$(resolve_target "${host}")" || return 1

    nc \
        -4 \
        -z \
        -w "${HEALTH_TIMEOUT}" \
        "${target_ip}" "${port}" \
        >/dev/null 2>&1
}

targets_ok() {
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

    [[ "${total}" -gt 0 ]] || return 1

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

health_ok() {
    is_vpn_up || return 1
    targets_ok || return 1
    forwarders_ok || return 1
}


recover_vpn() {
    log "Recovering IKEv2 tunnel"

    rm -f "${HEALTH_FILE}"
    stop_forwarders

    # На всякий случай восстанавливаем внешний Docker DNS перед reconnect.
    restore_docker_resolver

    timeout 15 ipsec down "${CONN_NAME}" \
        >/dev/null 2>&1 || true

    sleep 2

    if connect_vpn; then
        if start_forwarders_with_retry; then
            return 0
        fi

        log "Soft reconnect succeeded, but TCP forwarders failed"
    else
        log "Soft reconnect failed, restarting strongSwan"
    fi

    ipsec restart >/dev/null 2>&1 || true
    sleep 3

    restore_docker_resolver

    if connect_vpn; then
        if start_forwarders_with_retry; then
            return 0
        fi

        log "strongSwan restarted, but TCP forwarders failed"
    fi

    log "VPN recovery failed"
    return 1
}

cleanup() {
    rm -f "${HEALTH_FILE}"
    stop_forwarders
    ipsec stop >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

# Внешний resolver должен быть рабочим ещё до первого запуска strongSwan.
restore_docker_resolver

ipsec start

tail -n 0 -F /var/log/charon.log &

until connect_vpn; do
    log "Retry in 10 seconds"
    sleep 10
done

until start_forwarders_with_retry; do
    log "VPN is up, but TCP forwarders are not ready; retry in 10 seconds"
    sleep 10
done

failures=0
last_recovery=0
recovery_failures=0

while true; do
    sleep "${HEALTH_INTERVAL}"

    if health_ok; then
        failures=0
        touch "${HEALTH_FILE}"
        continue
    fi

    rm -f "${HEALTH_FILE}"

    if is_vpn_up && targets_ok && ! forwarders_ok; then
        log "TCP forwarder health failed; restarting forwarders only"
        if start_forwarders_with_retry; then
            failures=0
            touch "${HEALTH_FILE}"
            continue
        fi
    fi

    failures=$((failures + 1))

    log "Health check failed (${failures}/${HEALTH_FAIL_THRESHOLD})"

    if [[ "${failures}" -lt "${HEALTH_FAIL_THRESHOLD}" ]]; then
        continue
    fi

    failures=0

    now="$(date +%s)"

    if (( now - last_recovery < RECOVERY_COOLDOWN )); then
        log "Recovery suppressed by cooldown"
        continue
    fi

    last_recovery="${now}"

    if recover_vpn; then
        recovery_failures=0
    else
        recovery_failures=$((recovery_failures + 1))
        log "VPN recovery failed (${recovery_failures}/${MAX_RECOVERY_FAILURES})"
    fi

    if [[ "${recovery_failures}" -ge "${MAX_RECOVERY_FAILURES}" ]]; then
        log "ERROR: repeated recovery failures; exiting for Docker restart"
        exit 1
    fi
done
