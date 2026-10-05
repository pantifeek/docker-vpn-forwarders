#!/usr/bin/env bash
set -Eeuo pipefail


#
# ============================================================
# L2TP/IPsec forwarder
# ============================================================
#

CONN_NAME="l2tp-psk"
L2TP_NAME="vpn"

STATE_DIR="/run/l2tp-ipsec-forwarder"
HEALTH_FILE="${STATE_DIR}/healthy"

mkdir -p "${STATE_DIR}"
rm -f "${HEALTH_FILE}"


#
# ============================================================
# Logging
# ============================================================
#

log() {
    printf '%s [l2tp-ipsec-forwarder] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*"
}


#
# ============================================================
# Secrets
# ============================================================
#

load_secret() {
    local name="$1"
    local file_var="${name}_FILE"
    local file="${!file_var:-}"

    if [[ -n "${file}" ]]; then

        if [[ ! -r "${file}" ]]; then
            log "ERROR: cannot read ${file_var}"
            exit 1
        fi

        printf -v "${name}" '%s' "$(cat "${file}")"
    fi
}


escape_value() {
    printf '%s' "$1" |
        sed \
            -e 's/\\/\\\\/g' \
            -e 's/"/\\"/g'
}


#
# ============================================================
# PORT_FORWARDS parser
#
# Supported:
#
#   3389:10.10.10.10:3389
#
#   3389:rdp01.corp.local:3389
#
#   3389:rdp01.corp.local:3389;
#   3390:rdp02.corp.local:3389
#
# IPv6 target addresses are intentionally not supported here.
# ============================================================
#

normalize_rules() {
    printf '%s\n' "$1" |
        tr ';' '\n' |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e '/^$/d' \
            -e '/^#/d'
}


#
# ============================================================
# Load credentials
# ============================================================
#

load_secret VPN_USERNAME
load_secret VPN_PASSWORD
load_secret VPN_PSK


: "${VPN_SERVER:?VPN_SERVER is required}"
: "${VPN_USERNAME:?VPN_USERNAME or VPN_USERNAME_FILE is required}"
: "${VPN_PASSWORD:?VPN_PASSWORD or VPN_PASSWORD_FILE is required}"
: "${VPN_PSK:?VPN_PSK or VPN_PSK_FILE is required}"
: "${PORT_FORWARDS:?PORT_FORWARDS is required}"


#
# ============================================================
# Defaults
# ============================================================
#

HEALTH_INTERVAL="${HEALTH_INTERVAL:-20}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-3}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
HEALTH_MODE="${HEALTH_MODE:-all}"

RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-60}"
VPN_CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-45}"
MAX_RECOVERY_FAILURES="${MAX_RECOVERY_FAILURES:-3}"

VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-}"
VPN_DNS_SUFFIX="${VPN_DNS_SUFFIX:-}"

VPN_IKE="${VPN_IKE:-aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024}"

VPN_ESP="${VPN_ESP:-aes256-sha1,aes128-sha1,3des-sha1}"


USER_ESC="$(escape_value "${VPN_USERNAME}")"
PASS_ESC="$(escape_value "${VPN_PASSWORD}")"
PSK_ESC="$(escape_value "${VPN_PSK}")"


#
# ============================================================
# strongSwan / IPsec
# ============================================================
#

cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=no

conn ${CONN_NAME}
    keyexchange=ikev1
    authby=secret
    type=transport

    auto=add
    keyingtries=1

    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s

    left=%defaultroute
    leftprotoport=17/1701

    right=${VPN_SERVER}
    rightprotoport=17/1701

    ike=${VPN_IKE}
    esp=${VPN_ESP}
EOF


if [[ -n "${IPSEC_LOCAL_ID:-}" ]]; then

    printf '    leftid="%s"\n' \
        "${IPSEC_LOCAL_ID}" \
        >> /etc/ipsec.conf
fi


if [[ -n "${IPSEC_REMOTE_ID:-}" ]]; then

    printf '    rightid="%s"\n' \
        "${IPSEC_REMOTE_ID}" \
        >> /etc/ipsec.conf

else

    printf '    rightid=%%any\n' \
        >> /etc/ipsec.conf
fi


if [[ "${IPSEC_FORCE_ENCAPS:-false}" == "true" ]]; then

    printf '    forceencaps=yes\n' \
        >> /etc/ipsec.conf
fi


printf '%%any %%any : PSK "%s"\n' \
    "${PSK_ESC}" \
    > /etc/ipsec.secrets

chmod 0600 /etc/ipsec.secrets


#
# ============================================================
# strongSwan logging
# ============================================================
#

cat > /etc/strongswan.d/charon-forwarder.conf <<'EOF'
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
}
EOF

touch /var/log/charon.log


#
# ============================================================
# PPP authentication
# ============================================================
#

printf '"%s" * "%s" *\n' \
    "${USER_ESC}" \
    "${PASS_ESC}" \
    > /etc/ppp/chap-secrets


printf '"%s" * "%s" *\n' \
    "${USER_ESC}" \
    "${PASS_ESC}" \
    > /etc/ppp/pap-secrets


chmod 0600 \
    /etc/ppp/chap-secrets \
    /etc/ppp/pap-secrets


#
# ============================================================
# PPP
#
# Important:
# - do NOT install PPP default route
# - do NOT replace Docker /etc/resolv.conf
# - ask VPN server for its DNS with usepeerdns
# ============================================================
#

cat > /etc/ppp/options.l2tpd <<EOF
name "${USER_ESC}"

noauth
refuse-eap

noipdefault
ipcp-accept-local
ipcp-accept-remote

usepeerdns

mtu 1400
mru 1400

noccp
connect-delay 3000
EOF


#
# ============================================================
# xl2tpd
# ============================================================
#

cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lac ${L2TP_NAME}]
lns = ${VPN_SERVER}
pppoptfile = /etc/ppp/options.l2tpd
length bit = yes
redial = no
autodial = no
EOF


#
# ============================================================
# PPP interface helpers
# ============================================================
#

get_ppp_interface() {

    ip -o link show |
        awk -F': ' '
            $2 ~ /^ppp[0-9]+$/ {
                print $2
                exit
            }
        '
}


get_vpn_ip() {

    local iface

    iface="$(get_ppp_interface || true)"

    [[ -n "${iface}" ]] || return 1

    ip -4 -o addr show dev "${iface}" |
        awk '
            NR == 1 {
                split($4,a,"/")
                print a[1]
            }
        '
}


is_ipsec_up() {

    ipsec statusall 2>/dev/null |
        grep -qE "${CONN_NAME}\\[[0-9]+\\]: ESTABLISHED"
}


is_ppp_up() {

    local iface

    iface="$(get_ppp_interface || true)"

    [[ -n "${iface}" ]] || return 1

    ip -4 addr show dev "${iface}" |
        grep -q 'inet '
}


#
# ============================================================
# VPN DNS
#
# Priority:
#
# 1. VPN_DNS_SERVERS explicitly configured
# 2. DNS received from PPP peer
#
# Example:
#
# VPN_DNS_SERVERS=10.10.0.10;10.10.0.11
# ============================================================
#

get_vpn_dns_servers() {

    if [[ -n "${VPN_DNS_SERVERS}" ]]; then

        printf '%s\n' "${VPN_DNS_SERVERS}" |
            tr ',;' '\n' |
            sed \
                -e 's/^[[:space:]]*//' \
                -e 's/[[:space:]]*$//' \
                -e '/^$/d' |
            awk '!seen[$0]++'

        return
    fi


    if [[ -f /etc/ppp/resolv.conf ]]; then

        awk '
            $1 == "nameserver" {
                print $2
            }
        ' /etc/ppp/resolv.conf |
            awk '!seen[$0]++'
    fi
}


#
# ============================================================
# Routing through PPP
# ============================================================
#

ensure_vpn_route() {

    local target_ip="$1"

    local iface
    local vpn_ip

    iface="$(get_ppp_interface || true)"
    vpn_ip="$(get_vpn_ip || true)"

    [[ -n "${iface}" ]] || return 1
    [[ -n "${vpn_ip}" ]] || return 1

    ip route replace \
        "${target_ip}/32" \
        dev "${iface}" \
        src "${vpn_ip}"
}


#
# ============================================================
# DNS resolver
#
# For IP target:
#   simply returns IP and creates PPP route.
#
# For hostname:
#   first queries VPN DNS directly.
#
# If VPN DNS does not return an address,
#   system/Docker DNS is tried as fallback.
#
# Output on stdout is ONLY resolved IP.
# Logs go to stderr because this function is used in
# command substitutions.
# ============================================================
#

resolve_target() {

    local target="$1"

    #
    # Already IPv4.
    #
    if [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

        ensure_vpn_route "${target}" || return 1

        printf '%s\n' "${target}"
        return 0
    fi


    local query_name="${target}"

    #
    # Optional suffix for short hostnames:
    #
    # target = rdp01
    # VPN_DNS_SUFFIX = corp.local
    #
    # becomes:
    # rdp01.corp.local
    #
    if [[ "${target}" != *.* ]] \
        && [[ -n "${VPN_DNS_SUFFIX}" ]]; then

        query_name="${target}.${VPN_DNS_SUFFIX}"
    fi


    local vpn_ip
    vpn_ip="$(get_vpn_ip || true)"

    [[ -n "${vpn_ip}" ]] || return 1


    local dns
    local target_ip=""


    #
    # First try VPN DNS servers.
    #
    while IFS= read -r dns; do

        [[ -n "${dns}" ]] || continue

        #
        # DNS itself must be reachable over PPP.
        #
        ensure_vpn_route "${dns}" || continue


        target_ip="$(
            dig \
                -4 \
                +time=2 \
                +tries=1 \
                +short \
                A \
                @"${dns}" \
                "${query_name}" \
                -b "${vpn_ip}" \
            2>/dev/null |
            awk '
                /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                    print
                    exit
                }
            '
        )"


        if [[ -n "${target_ip}" ]]; then

            ensure_vpn_route "${target_ip}" || return 1

            log \
                "Resolved ${target} -> ${target_ip} using VPN DNS ${dns}" \
                >&2

            printf '%s\n' "${target_ip}"
            return 0
        fi

    done < <(get_vpn_dns_servers)


    #
    # Fallback to normal Docker/system DNS.
    #
    target_ip="$(
        getent ahostsv4 "${query_name}" 2>/dev/null |
            awk '
                NR == 1 {
                    print $1
                    exit
                }
            '
    )"


    if [[ -n "${target_ip}" ]]; then

        ensure_vpn_route "${target_ip}" || return 1

        log \
            "Resolved ${target} -> ${target_ip} using system DNS" \
            >&2

        printf '%s\n' "${target_ip}"
        return 0
    fi


    log "ERROR: cannot resolve VPN hostname ${target}" >&2

    return 1
}


#
# ============================================================
# xl2tpd
# ============================================================
#

start_xl2tpd() {

    pkill -TERM xl2tpd 2>/dev/null || true
    pkill -TERM pppd 2>/dev/null || true

    sleep 1

    rm -f /run/xl2tpd/l2tp-control
    touch /run/xl2tpd/l2tp-control

    xl2tpd -D \
        >> /var/log/xl2tpd.log \
        2>&1 &

    XL2TPD_PID=$!

    sleep 1

    return 0
}


#
# ============================================================
# Install routes to all configured targets.
# DNS names are resolved here after PPP is established.
# ============================================================
#

install_target_routes() {

    local line
    local listen
    local target
    local port
    local extra
    local target_ip


    while IFS= read -r line; do

        IFS=: read -r listen target port extra <<< "${line}"


        if [[ -n "${extra:-}" ]] \
            || [[ ! "${listen}" =~ ^[0-9]+$ ]] \
            || [[ ! "${port}" =~ ^[0-9]+$ ]]; then

            log "ERROR: invalid PORT_FORWARDS rule: ${line}"
            return 1
        fi


        target_ip="$(resolve_target "${target}")" || {

            log "ERROR: unable to resolve ${target}"
            return 1
        }


        log "VPN route ${target} (${target_ip}) installed"

    done < <(normalize_rules "${PORT_FORWARDS}")
}


#
# ============================================================
# Connect VPN
# ============================================================
#

connect_vpn() {

    rm -f "${HEALTH_FILE}"


    log "Connecting IPsec to ${VPN_SERVER}"


    timeout "${VPN_CONNECT_TIMEOUT}" \
        ipsec up "${CONN_NAME}" \
        >/tmp/ipsec-up.log \
        2>&1 || true


    local i


    for i in $(seq 1 "${VPN_CONNECT_TIMEOUT}"); do

        if is_ipsec_up; then
            break
        fi

        sleep 1
    done


    if ! is_ipsec_up; then

        log "IPsec connection failed"
        return 1
    fi


    log "IPsec established, starting L2TP"


    start_xl2tpd

    sleep 1


    printf 'c %s\n' "${L2TP_NAME}" \
        > /run/xl2tpd/l2tp-control


    for i in $(seq 1 "${VPN_CONNECT_TIMEOUT}"); do

        if is_ppp_up; then

            local vpn_ip
            vpn_ip="$(get_vpn_ip)"


            log "L2TP/PPP established, VPN IP ${vpn_ip}"


            #
            # Give usepeerdns a moment to write
            # /etc/ppp/resolv.conf.
            #
            sleep 1


            if ! install_target_routes; then

                log "Target/DNS configuration failed"
                return 1
            fi


            return 0
        fi


        sleep 1
    done


    log "L2TP/PPP connection failed"

    return 1
}


#
# ============================================================
# TCP forwarders
# ============================================================
#

FORWARDER_PIDS=()
FORWARDER_PORTS=()


stop_forwarders() {

    local pid


    for pid in "${FORWARDER_PIDS[@]:-}"; do

        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done


    FORWARDER_PIDS=()
    FORWARDER_PORTS=()


    #
    # Only our container contains socat processes.
    #
    pkill -TERM socat 2>/dev/null || true
}


start_forwarders() {

    stop_forwarders


    local vpn_ip
    vpn_ip="$(get_vpn_ip)"


    local line
    local listen
    local target
    local port
    local extra
    local target_ip


    while IFS= read -r line; do

        IFS=: read -r listen target port extra <<< "${line}"


        if [[ -n "${extra:-}" ]] \
            || [[ ! "${listen}" =~ ^[0-9]+$ ]] \
            || [[ ! "${port}" =~ ^[0-9]+$ ]]; then

            log "ERROR: invalid forwarding rule: ${line}"
            exit 1
        fi


        target_ip="$(resolve_target "${target}")" || {

            log "ERROR: unable to resolve ${target}"
            return 1
        }


        log \
            "Forward TCP ${listen} -> ${target} (${target_ip}):${port} via ${vpn_ip}"


        socat \
            "TCP4-LISTEN:${listen},reuseaddr,fork,keepalive" \
            "TCP4:${target_ip}:${port},bind=${vpn_ip}" \
            >> /var/log/forwarder.log \
            2>&1 &


        FORWARDER_PIDS+=("$!")
        FORWARDER_PORTS+=("${listen}")


    done < <(normalize_rules "${PORT_FORWARDS}")

    [[ "${#FORWARDER_PIDS[@]}" -gt 0 ]] || return 1
    sleep 1
    forwarders_ok
}


port_is_listening() {
    local port="$1"
    ss -H -lnt 2>/dev/null |
        awk -v port="${port}" '
            $4 ~ (":" port "$") { found=1 }
            END { exit(found ? 0 : 1) }
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
}


#
# ============================================================
# Health targets
#
# If HEALTH_TARGETS is empty,
# destinations from PORT_FORWARDS are used.
#
# Example:
#
# HEALTH_TARGETS=
# rdp01.domain.local:3389;
# rdp02.domain.local:3389
# ============================================================
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

        IFS=: read -r listen target port extra <<< "${line}"

        printf '%s:%s\n' \
            "${target}" \
            "${port}"

    done < <(normalize_rules "${PORT_FORWARDS}")
}


probe_target() {

    local target="$1"

    local host
    local port
    local extra
    local vpn_ip
    local target_ip


    IFS=: read -r host port extra <<< "${target}"


    [[ -z "${extra:-}" ]] || return 1


    vpn_ip="$(get_vpn_ip || true)"

    [[ -n "${vpn_ip}" ]] || return 1


    target_ip="$(resolve_target "${host}")" || return 1


    nc \
        -4 \
        -z \
        -w "${HEALTH_TIMEOUT}" \
        -s "${vpn_ip}" \
        "${target_ip}" \
        "${port}" \
        >/dev/null \
        2>&1
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


    if [[ "${total}" -eq 0 ]]; then
        return 0
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


health_ok() {
    is_ipsec_up || return 1
    is_ppp_up || return 1
    targets_ok || return 1
    forwarders_ok || return 1
}


#
# ============================================================
# VPN recovery
# ============================================================
#

recover_vpn() {

    log "Restarting L2TP/IPsec connection"


    rm -f "${HEALTH_FILE}"


    stop_forwarders


    printf 'd %s\n' "${L2TP_NAME}" \
        > /run/xl2tpd/l2tp-control \
        2>/dev/null || true


    pkill -TERM pppd 2>/dev/null || true
    pkill -TERM xl2tpd 2>/dev/null || true


    timeout 10 \
        ipsec down "${CONN_NAME}" \
        >/dev/null \
        2>&1 || true


    sleep 2


    #
    # First attempt: normal reconnect.
    #
    if connect_vpn; then

        start_forwarders
        return 0
    fi


    #
    # Second attempt: restart strongSwan completely.
    #
    log "Normal reconnect failed, restarting strongSwan"


    ipsec restart \
        >/dev/null \
        2>&1 || true


    sleep 3


    if connect_vpn; then

        start_forwarders
        return 0
    fi


    log "VPN recovery failed"

    return 1
}


#
# ============================================================
# Cleanup
# ============================================================
#

cleanup() {

    rm -f "${HEALTH_FILE}"


    stop_forwarders


    pkill -TERM pppd 2>/dev/null || true
    pkill -TERM xl2tpd 2>/dev/null || true


    ipsec stop \
        >/dev/null \
        2>&1 || true
}


trap cleanup EXIT INT TERM


#
# ============================================================
# Start services
# ============================================================
#

log "Starting strongSwan"


ipsec start


#
# Make VPN logs visible in Docker / Portainer.
#
touch \
    /var/log/charon.log \
    /var/log/xl2tpd.log


tail -n 0 -F \
    /var/log/charon.log \
    /var/log/xl2tpd.log &


#
# ============================================================
# Initial connection
# ============================================================
#

until connect_vpn; do

    log "Retry in 10 seconds"

    sleep 10


    ipsec restart \
        >/dev/null \
        2>&1 || true


    sleep 2
done


until start_forwarders; do
    log "Forwarder startup failed; retry in 5 seconds"
    sleep 5
done


#
# ============================================================
# Monitoring loop
# ============================================================
#

failures=0
last_recovery=0
recovery_failures=0


while true; do

    sleep "${HEALTH_INTERVAL}"


    if health_ok; then

        if [[ "${failures}" -gt 0 ]]; then

            log "VPN health check recovered"
        fi


        failures=0

        touch "${HEALTH_FILE}"

        continue
    fi


    rm -f "${HEALTH_FILE}"

    if is_ipsec_up && is_ppp_up && targets_ok && ! forwarders_ok; then
        log "TCP forwarder health failed; restarting forwarders only"
        if start_forwarders; then
            failures=0
            touch "${HEALTH_FILE}"
            continue
        fi
    fi

    failures=$((failures + 1))


    log \
        "VPN health check failed (${failures}/${HEALTH_FAIL_THRESHOLD})"


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
