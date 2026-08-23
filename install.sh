#!/usr/bin/env bash
# INTEGRITY_MARKER_EOF_CHECK
set -euo pipefail

_integrity() {
    local src="${BASH_SOURCE[0]:-$0}"
    if [ -f "$src" ] && [ -r "$src" ]; then
        if ! tail -n5 "$src" 2>/dev/null | grep -q '^# END_OF_SCRIPT$'; then
            printf '\033[48;5;124m\033[38;5;255m ✗ Script file is incomplete (download was truncated). Re-download and try again. \033[0m\n' >&2
            exit 99
        fi
    fi
}
_integrity

SCRIPT_VERSION="6.4.0"
SELF_SRC="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${0:-}")"

DB_PATH="${DB_PATH:-/etc/x-ui/x-ui.db}"
STATE_DIR="/etc/reality443"
STATE_FILE="${STATE_DIR}/state.json"
PORTS_FILE="${STATE_DIR}/original-ports.json"
ROUTED_FILE="${STATE_DIR}/routed-ports.json"
HOSTS_FILE="${STATE_DIR}/created-hosts.json"
BACKUP_ROOT="${STATE_DIR}/backups"
DISABLED_DIR="${STATE_DIR}/disabled-sites"
LOG_DIR="/var/log/reality443"
LOG_FILE="${LOG_DIR}/reality443.log"
LOCK_FILE="/run/reality443.lock"
PID_FILE="/run/reality443.pid"
INSTALL_PATH="/usr/local/bin/reality-443.sh"
WATCHDOG_PATH="/usr/local/bin/reality443-watchdog.sh"
GUARD_NAME="reality443-guard"
GUARD_UNIT="/etc/systemd/system/${GUARD_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-reality443.conf"
LIMITS_FILE="/etc/security/limits.d/99-reality443.conf"
NGINX_TUNE="/etc/nginx/conf.d/00-reality443-tune.conf"

NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_DIR="/etc/nginx"
STREAM_FILE="/etc/nginx/stream-reality443.conf"
SITE_CONF="/etc/nginx/conf.d/reality443-site.conf"
SITE_ROOT="/var/www/reality443"
SITE_PORT=8081

CERT_SEARCH_DIRS="/root /root/cert /root/certs /root/.acme.sh /etc/letsencrypt/live /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /etc/nginx/cert /etc/x-ui /opt/cert /opt/certs /usr/local/etc/xray /home"
XUI_SERVICE="x-ui"
NGINX_SERVICE="nginx"

MARK_BEGIN="# BEGIN reality443"
MARK_END="# END reality443"
MIN_PORT=10001
MAX_PORT=19999
DEFAULT_PANEL_PORT=2053
DEFAULT_SUB_PORT=2096
GUARD_INTERVAL=30
LOG_MAX_BYTES=5242880

DOMAIN=""
SITE_MODE="none"
SITE_TARGET=""
SITE_CERT=""
SITE_KEY=""
SITE_BIND_PORT=""
SITE_SRC_ARG=""
SUB_DOMAIN=""
SUB_CERT=""
SUB_KEY=""
SUB_BIND_PORT=""
PANEL_ON_SITE="no"
SUB_ON_SITE="no"

declare -a RI_ID=() RI_REMARK=() RI_LISTEN=() RI_PORT=() RI_PROTO=() RI_SNI=() RI_SNIS=() RI_NET=()
declare -A TAKEN_PORTS=()
declare -a SEL_IDX=()
declare -a PLAN_PORT=()
ALLOC_PORT=""
PROMPT_IDX=0
HOST_MECHANISM="external_proxy"
STREAM_SO_CACHE=""

R=$'\033[0m'
C_OLIVE=$'\033[38;5;107m'
C_PINK=$'\033[38;5;211m'
C_CHERRY=$'\033[38;5;168m'
C_CHOC=$'\033[38;5;173m'
C_PURPLE=$'\033[38;5;141m'
C_TURQ=$'\033[38;5;80m'
C_BLUE=$'\033[38;5;111m'
C_GOLD=$'\033[38;5;179m'
C_SLATE=$'\033[38;5;110m'
C_MINT=$'\033[38;5;115m'
C_LILAC=$'\033[38;5;183m'
C_SAND=$'\033[38;5;180m'
C_STEEL=$'\033[38;5;74m'
C_ROSE=$'\033[38;5;175m'
C_MOSS=$'\033[38;5;114m'

BG_OK=$'\033[48;5;28m'$'\033[38;5;255m'
BG_ERR=$'\033[48;5;124m'$'\033[38;5;255m'
BG_WARN=$'\033[48;5;136m'$'\033[38;5;255m'

PAL=("$C_OLIVE" "$C_PINK" "$C_CHERRY" "$C_CHOC" "$C_PURPLE" "$C_TURQ" "$C_BLUE" "$C_GOLD" "$C_SLATE" "$C_MINT" "$C_LILAC" "$C_SAND" "$C_STEEL" "$C_ROSE" "$C_MOSS")

line_c() { local i="$1"; shift; printf '%s%s%s\n' "${PAL[$((i % ${#PAL[@]}))]}" "$*" "$R"; }
next_c() { printf '%s' "${PAL[$((PROMPT_IDX % ${#PAL[@]}))]}"; PROMPT_IDX=$((PROMPT_IDX + 1)); }

log_write() {
    local lvl="$1"; shift
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -f "$LOG_FILE" ]; then
        local sz
        sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        [ "$sz" -gt "$LOG_MAX_BYTES" ] && mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
    { printf '%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$*" >> "$LOG_FILE"; } 2>/dev/null || true
}

ok()   { log_write OK "$*";    printf '%s ✓ %s %s\n' "$BG_OK" "$*" "$R" >&2; }
err()  { log_write ERROR "$*"; printf '%s ✗ %s %s\n' "$BG_ERR" "$*" "$R" >&2; }
warn() { log_write WARN "$*";  printf '%s ! %s %s\n' "$BG_WARN" "$*" "$R" >&2; }
info() { log_write INFO "$*";  printf '%s  %s%s\n' "$C_SLATE" "$*" "$R" >&2; }
step() { printf '\n%s%s%s\n' "$C_PURPLE" "$*" "$R" >&2; }
pause() { local _x; printf '%s\n  Press Enter to continue...%s' "$C_STEEL" "$R"; read -r _x || true; }

have() { command -v "$1" >/dev/null 2>&1; }

rand_str() {
    local n="${1:-6}" s=""
    s=$(head -c 512 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'a-z0-9' | cut -c1-"$n")
    [ -n "$s" ] || s="x$(date +%s%N | cut -c8-$((7 + n)))"
    printf '%s\n' "$s"
}

is_ancestor_pid() {
    local target="$1" cur="$$" guard=0
    while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
        [ "$cur" = "$target" ] && return 0
        cur=$(awk '{print $4}' "/proc/${cur}/stat" 2>/dev/null || echo "")
        guard=$((guard + 1))
        [ "$guard" -gt 20 ] && break
    done
    return 1
}

acquire_lock() {
    local oldpid cmd
    if [ -f "$PID_FILE" ]; then
        oldpid=$(head -n1 "$PID_FILE" 2>/dev/null | grep -oE '^[0-9]+' || true)
        if [ -n "$oldpid" ] && [ "$oldpid" != "$$" ] && kill -0 "$oldpid" 2>/dev/null \
           && ! is_ancestor_pid "$oldpid"; then
            cmd=$(tr '\0' ' ' < "/proc/${oldpid}/cmdline" 2>/dev/null || true)
            case "$cmd" in
                *reality-443.sh*|*reality443*)
                    err "Another instance is running (PID ${oldpid})."
                    info "Stop it:        kill ${oldpid}"
                    info "Or clear it:    rm -f ${PID_FILE}"
                    return 1 ;;
            esac
        fi
        rm -f "$PID_FILE"
    fi
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || true
    trap 'rm -f "$PID_FILE" 2>/dev/null || true' EXIT
    return 0
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Must run as root: sudo bash $0"
        exit 1
    fi
}

header() {
    clear
    local -a art=(
'  ████ ████  ██  █    ███ █████ █   █ █  █ █  █ ████'
'  █  █ █    █  █ █     █    █    █ █  █  █ █  █    █'
'  ████ ███  ████ █     █    █     █   ████ ████  ███'
'  █ █  █    █  █ █     █    █     █      █    █    █'
'  █  █ ████ █  █ ████ ███   █     █      █    █ ████'
    )
    local i=0 l
    for l in "${art[@]}"; do line_c "$i" "$l"; i=$((i + 1)); done
    printf '%s   SNI Router for 3x-ui Reality  ·  v%s%s\n\n' "$C_TURQ" "$SCRIPT_VERSION" "$R"
    banner
}

banner_row() {
    local label="$1" state="$2" note="${3:-}" bg text
    case "$state" in
        ok)   bg="$BG_OK";   text="ACTIVE" ;;
        warn) bg="$BG_WARN"; text="PARTIAL" ;;
        *)    bg="$BG_ERR";  text="INACTIVE" ;;
    esac
    printf '%s %-12s %-9s %s' "$bg" "$label" "$text" "$R"
    [ -n "$note" ] && printf ' %s%s%s' "$C_SLATE" "$note" "$R"
    printf '\n'
}

banner() {
    load_state 2>/dev/null || true
    local n_state="bad" n_note="" s_state="bad" s_note="" g_state="bad" g_note="not installed"
    local t_state="bad" t_note="defaults"
    if have nginx; then
        case "$(stream_state)" in
            static)  n_state="ok"; n_note="stream built-in" ;;
            dynamic) if find_stream_so >/dev/null 2>&1; then n_state="ok"; n_note="stream module"; else n_state="warn"; n_note="stream .so missing"; fi ;;
            *)       n_state="warn"; n_note="no stream module" ;;
        esac
    fi
    if [ -f "$STREAM_FILE" ] && grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null; then
        s_state="ok"; s_note="$(count_routed) SNI route(s)"
    fi
    if systemctl is-enabled --quiet "${GUARD_NAME}.service" 2>/dev/null; then
        if systemctl is-active --quiet "${GUARD_NAME}.service" 2>/dev/null; then
            g_state="ok"; g_note="auto-start + watchdog"
        else
            g_state="warn"; g_note="enabled but stopped"
        fi
    fi
    [ -f "$SYSCTL_FILE" ] && { t_state="ok"; t_note="bbr + tuned sockets"; }
    banner_row "NGINX" "$n_state" "$n_note"
    banner_row "443 ROUTER" "$s_state" "$s_note"
    banner_row "WATCHDOG" "$g_state" "$g_note"
    banner_row "TUNING" "$t_state" "$t_note"
    [ -n "$DOMAIN" ] && printf '%s DOMAIN       %-9s %s%s\n' "$C_GOLD" "SET" "$DOMAIN" "$R"
    echo
}

count_routed() {
    local n=0
    [ -f "$STREAM_FILE" ] || { printf '0\n'; return 0; }
    n=$(grep -cE '^[[:space:]]+"' "$STREAM_FILE" 2>/dev/null) || true
    [ -n "$n" ] || n=0
    printf '%s\n' "$n"
}

has_ipv6() {
    [ -s /proc/net/if_inet6 ] || return 1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' || return 1
    return 0
}

is_private_ip() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

backend_ip() {
    if is_private_ip "$1"; then printf '%s\n' "$1"; else printf '127.0.0.1\n'; fi
}

preflight_443() {
    local owner pp sp
    pp=$(panel_port); sp=$(sub_port)
    if [ "$pp" = "443" ]; then
        systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
        refresh_taken_ports
        alloc_port "" || return 1
        set_setting webPort "$ALLOC_PORT"
        warn "Panel was on port 443 - moved to ${ALLOC_PORT}"
        systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
        sleep 2
    fi
    if [ "$sp" = "443" ]; then
        systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
        refresh_taken_ports
        alloc_port "" || return 1
        set_setting subPort "$ALLOC_PORT"
        warn "Subscription was on port 443 - moved to ${ALLOC_PORT}"
        systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
        sleep 2
    fi
    if port_busy 443; then
        owner=$(port_owner 443)
        case "$owner" in
            nginx|"") ;;
            *)
                err "Port 443 is held by '${owner}', not nginx."
                info "Stop that service first, then run the installer again."
                info "Find it with:  ss -ltnp '( sport = :443 )'"
                return 1 ;;
        esac
    fi
    if http_binds_443; then
        warn "Another nginx site listens on 443 in the http block - moving it aside"
        disable_stock_default_site
    fi
    return 0
}

server_public_ip() {
    local ip=""
    ip=$(timeout 8 curl -4 -fsSL ifconfig.co 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    ip=$(timeout 8 curl -4 -fsSL icanhazip.com 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    ip=$(timeout 8 curl -4 -fsSL api.ipify.org 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    ip=$(timeout 8 curl -4 -fsSL ip.sb 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    return 1
}

server_ips() {
    local pub
    pub=$(server_public_ip)
    {
        [ -n "$pub" ] && printf '%s\n' "$pub"
        ip -4 route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}'
        ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    } | grep -E '^[0-9]+\.' | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)' | sort -u
    if [ -z "$pub" ]; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u
    fi
}

resolve_a() {
    local host="$1"
    if have dig; then
        dig +short +time=3 +tries=2 A "$host" 2>/dev/null | grep -E '^[0-9.]+$'
    else
        getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}

check_dns() {
    local -a mine=()
    mapfile -t mine < <(server_ips)
    if [ "${#mine[@]}" -eq 0 ]; then
        warn "Could not determine this server's public IP - skipping DNS check"
        return 0
    fi
    local d ips ip m match bad=0
    local pub
    pub=$(server_public_ip)
    local -a doms=("$DOMAIN")
    [ -n "$SUB_DOMAIN" ] && [ "$SUB_DOMAIN" != "$DOMAIN" ] && doms+=("$SUB_DOMAIN")
    for d in "${doms[@]}"; do
        [ -n "$d" ] || continue
        ips=$(resolve_a "$d")
        if [ -z "$ips" ]; then
            err "${d} has no A record - it does not resolve at all"
            info "create an A record:  ${d}  ->  ${mine[0]}"
            bad=$((bad + 1))
            continue
        fi
        match=0
        for ip in $ips; do
            for m in "${mine[@]}"; do
                [ "$ip" = "$m" ] && match=1
            done
        done
        if [ "$match" -eq 1 ]; then
            ok "${d} resolves to this server"
        else
            local resolved
            resolved=$(printf '%s' "$ips" | tr '\n' ' ' | sed 's/ *$//')
            local is_cdn=0
            for ip in $ips; do
                if timeout 8 curl -sk -o /dev/null -w '%{http_code}' --resolve "${d}:443:${ip}" "https://${d}/" 2>/dev/null | grep -qE '^(200|301|302|403)$'; then
                    is_cdn=1
                fi
            done
            if [ "$is_cdn" -eq 1 ]; then
                ok "${d} is behind a CDN/proxy (${resolved}) - this is fine if the origin is set to ${pub:-this server}"
            else
                err "${d} resolves to ${resolved} - NOT this server (${pub:-${mine[0]:-unknown}})"
                info "fix the A record:  ${d}  ->  ${pub:-${mine[0]:-<your-public-ip>}}"
                bad=$((bad + 1))
            fi
        fi
    done
    [ "$bad" -eq 0 ] && return 0
    return 1
}

check_reality_chain() {
    local i sni out subj bad=0 shown=0
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        is_routable_listen "${RI_LISTEN[$i]}" || continue
        sni="${RI_SNI[$i]}"
        [ -n "$sni" ] || continue
        grep -qF "\"${sni}\"" "$STREAM_FILE" 2>/dev/null || continue
        shown=1
        out=$(timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$sni" </dev/null 2>&1 || true)
        subj=$(printf '%s' "$out" | grep -m1 -oE 'subject=.*' | head -c 90)
        if [ -n "$subj" ]; then
            ok "${sni} -> Reality chain OK (${subj})"
        else
            err "${sni} -> no certificate returned through 443"
            info "xray is listening but the Reality handshake to its dest is failing"
            bad=$((bad + 1))
        fi
    done
    [ "$shown" -eq 0 ] && return 0
    [ "$bad" -eq 0 ] && return 0
    return 1
}

reality_dest_of() {
    local id="$1" d
    d=$(q "SELECT stream_settings FROM inbounds WHERE id=${id};" \
        | jq -r '.[0].stream_settings | fromjson | (.realitySettings.dest // .realitySettings.target // "")' 2>/dev/null)
    printf '%s' "$d"
}

check_reality_dests() {
    local i id dest host port out proto alpn bad=0
    step "Reality target (dest) validation"
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        is_routable_listen "${RI_LISTEN[$i]}" || continue
        id="${RI_ID[$i]}"
        dest=$(reality_dest_of "$id")
        [ -n "$dest" ] || continue
        host="${dest%%:*}"
        port="${dest##*:}"
        [ "$port" = "$host" ] && port=443
        out=$(timeout 12 openssl s_client -connect "${host}:${port}" -servername "$host" -tls1_3 -alpn h2 </dev/null 2>&1 || true)
        proto=$(printf '%s' "$out" | grep -m1 -oE 'New, TLSv[0-9.]+|Protocol version: TLSv[0-9.]+' | grep -oE 'TLSv[0-9.]+')
        alpn=$(printf '%s' "$out" | grep -m1 -oE 'ALPN protocol: [a-z0-9/.]+' | sed 's/.*: //')
        if [ -z "$proto" ]; then
            out=$(timeout 12 openssl s_client -connect "${host}:${port}" -servername "$host" -alpn h2 </dev/null 2>&1 || true)
            proto=$(printf '%s' "$out" | grep -m1 -oE 'New, TLSv[0-9.]+|Protocol version: TLSv[0-9.]+' | grep -oE 'TLSv[0-9.]+')
            alpn=$(printf '%s' "$out" | grep -m1 -oE 'ALPN protocol: [a-z0-9/.]+' | sed 's/.*: //')
        fi
        if [ "$proto" = "TLSv1.3" ] && [ "$alpn" = "h2" ]; then
            ok "${RI_REMARK[$i]:-inbound}: dest ${dest} supports TLS1.3 + h2"
        elif [ "$proto" = "TLSv1.3" ]; then
            warn "${RI_REMARK[$i]:-inbound}: dest ${dest} has TLS1.3 but ALPN='${alpn:-none}' (h2 expected)"
            bad=$((bad + 1))
        elif [ -n "$proto" ]; then
            err "${RI_REMARK[$i]:-inbound}: dest ${dest} only speaks ${proto} - Reality REQUIRES TLS 1.3"
            info "clients will fail to connect through this inbound"
            bad=$((bad + 1))
        else
            err "${RI_REMARK[$i]:-inbound}: dest ${dest} is unreachable from this server"
            bad=$((bad + 1))
        fi
        case "$host" in
            *.ir|*.ir:*) warn "${host} is an Iranian domain - a poor Reality target, prefer a foreign CDN host" ;;
        esac
    done
    [ "$bad" -eq 0 ] && return 0
    return 1
}

check_orphan_inbounds() {
    local json n i id rem lst prt sec snis sn found orphans=0
    json=$(q "SELECT id, remark, listen, port, stream_settings FROM inbounds WHERE enable=1 OR enable IS NULL;")
    n=$(printf '%s' "$json" | jq 'length')
    for ((i = 0; i < n; i++)); do
        id=$(printf '%s' "$json" | jq -r ".[$i].id")
        rem=$(printf '%s' "$json" | jq -r ".[$i].remark // \"\"")
        lst=$(printf '%s' "$json" | jq -r ".[$i].listen // \"\"")
        prt=$(printf '%s' "$json" | jq -r ".[$i].port")
        is_routable_listen "$lst" || continue
        sec=$(printf '%s' "$json" | jq -r ".[$i].stream_settings | fromjson? | .security // \"\"")
        if [ "$sec" != "reality" ]; then
            err "'${rem}' listens on ${lst}:${prt} but is not Reality - it is unreachable from outside"
            info "give it a public listen address in the panel, or delete it"
            orphans=$((orphans + 1))
            continue
        fi
        snis=$(printf '%s' "$json" | jq -r ".[$i].stream_settings | fromjson | (.realitySettings.serverNames // []) | join(\" \")")
        found=0
        for sn in $snis; do
            grep -qF "\"${sn}\"" "$STREAM_FILE" 2>/dev/null && { found=1; break; }
        done
        if [ "$found" -eq 0 ]; then
            err "'${rem}' listens on ${lst}:${prt} but NO SNI of it is routed on 443 - it is dead"
            info "run option 2 (Add New Inbounds) to route it, or give it a serverName in the panel"
            orphans=$((orphans + 1))
        fi
    done
    [ "$orphans" -eq 0 ] && return 0
    return 1
}

http_probe() {
    local host="$1" path="${2:-/}" c
    c=$(timeout 15 curl -sk -o /dev/null -w '%{http_code}' --resolve "${host}:443:127.0.0.1" "https://${host}${path}" 2>/dev/null)
    c=$(printf '%s' "$c" | head -n1 | grep -oE '^[0-9]{3}' | head -n1)
    printf '%s' "${c:-000}"
}

TEST_FAILS=0
post_install_test() {
    local fails=0 out code sni i
    step "Live self-test"

    if systemctl is-active --quiet "$NGINX_SERVICE"; then
        ok "nginx service is active"
    else
        err "nginx service is NOT active"
        systemctl status "$NGINX_SERVICE" --no-pager 2>&1 | tail -n 8 >&2
        fails=$((fails + 1))
    fi

    if port_busy 443; then
        out=$(port_owner 443)
        if [ "$out" = "nginx" ] || [ -z "$out" ]; then
            ok "port 443 is bound by nginx"
        else
            err "port 443 is bound by '${out}' instead of nginx"
            fails=$((fails + 1))
        fi
    else
        err "nothing is listening on port 443"
        info "check:  journalctl -u ${NGINX_SERVICE} -n 30 --no-pager"
        fails=$((fails + 1))
    fi

    if [ -n "$SITE_CERT" ] && [ -n "$DOMAIN" ]; then
        out=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | grep -m1 'subject=' || true)
        if [ -n "$out" ]; then
            ok "TLS handshake for ${DOMAIN} succeeded"
        else
            err "TLS handshake for ${DOMAIN} FAILED on 127.0.0.1:443"
            fails=$((fails + 1))
        fi
        if have curl; then
            code=$(http_probe "$DOMAIN" "/")
            if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
                ok "camouflage site answers on https://${DOMAIN}/ (HTTP ${code})"
            else
                err "site on https://${DOMAIN}/ returned HTTP ${code}"
                fails=$((fails + 1))
            fi
        fi
    fi

    if sub_is_separate && have curl; then
        out=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$SUB_DOMAIN" </dev/null 2>/dev/null | grep -m1 'subject=' || true)
        if [ -n "$out" ]; then
            ok "TLS handshake for ${SUB_DOMAIN} succeeded"
        else
            err "TLS handshake for ${SUB_DOMAIN} FAILED"
            fails=$((fails + 1))
        fi
        code=$(http_probe "$SUB_DOMAIN" "/")
        if [ "$code" = "200" ]; then
            ok "camouflage site answers on https://${SUB_DOMAIN}/ (HTTP 200)"
        else
            err "site on https://${SUB_DOMAIN}/ returned HTTP ${code}"
            fails=$((fails + 1))
        fi
    fi

    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        is_routable_listen "${RI_LISTEN[$i]}" || continue
        sni="${RI_SNI[$i]}"
        [ -n "$sni" ] || continue
        if port_busy "${RI_PORT[$i]}"; then
            ok "${RI_REMARK[$i]:-inbound} listening on ${RI_PORT[$i]}"
        else
            err "${RI_REMARK[$i]:-inbound} is NOT listening on ${RI_PORT[$i]}"
            info "check:  journalctl -u ${XUI_SERVICE} -n 30 --no-pager"
            fails=$((fails + 1))
        fi
    done

    if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        if ufw status 2>/dev/null | grep -qE '^443/tcp'; then
            ok "firewall allows 443/tcp"
        else
            err "firewall is active but 443/tcp is NOT allowed"
            fails=$((fails + 1))
        fi
    else
        warn "ufw is not active - the server relies on the provider firewall only"
    fi

    check_orphan_inbounds || fails=$((fails + 1))
    step "DNS"
    check_dns || fails=$((fails + 1))
    step "Reality end-to-end probe through 443"
    check_reality_chain || fails=$((fails + 1))
    check_reality_dests || fails=$((fails + 1))

    echo
    TEST_FAILS="$fails"
    if [ "$fails" -eq 0 ]; then
        ok "Self-test passed - the server answers on 443"
        return 0
    fi
    err "Self-test found ${fails} problem(s) - see the lines marked with a cross above"
    return 1
}

is_installed() {
    [ -f "$STREAM_FILE" ] || return 1
    grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null || return 1
    return 0
}

is_routable_listen() {
    [ "$1" = "127.0.0.1" ] && return 0
    is_private_ip "$1" && return 0
    return 1
}

pkg_mgr() {
    if have apt-get; then echo apt
    elif have dnf; then echo dnf
    elif have yum; then echo yum
    else echo none; fi
}

install_pkgs() {
    case "$(pkg_mgr)" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
             DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
        yum) yum install -y "$@" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

ensure_deps() {
    local missing=()
    have sqlite3 || missing+=(sqlite3)
    have jq || missing+=(jq)
    have ss || missing+=(iproute2)
    have openssl || missing+=(openssl)
    have curl || missing+=(curl)
    have dig || missing+=(dnsutils)
    have flock || missing+=(util-linux)
    if [ "${#missing[@]}" -gt 0 ]; then
        info "Installing dependencies: ${missing[*]}"
        install_pkgs "${missing[@]}" || true
    fi
    local fatal=0
    have sqlite3 || { err "sqlite3 is required and could not be installed."; fatal=1; }
    have jq || { err "jq is required and could not be installed."; fatal=1; }
    [ "$fatal" -eq 0 ] || exit 1
}

esc() { printf '%s' "$1" | sed "s/'/''/g"; }
q() { sqlite3 -cmd ".timeout 8000" -json "$DB_PATH" "$1" 2>/dev/null || printf '[]'; }
xval() { sqlite3 -cmd ".timeout 8000" "$DB_PATH" "$1" 2>/dev/null || true; }
xsql() {
    sqlite3 -cmd ".timeout 8000" "$DB_PATH" "$1" >/dev/null 2>&1 || return 1
    sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    return 0
}

db_ready() {
    [ -f "$DB_PATH" ] || { err "Database not found at ${DB_PATH}"; return 1; }
    sqlite3 "$DB_PATH" "SELECT 1 FROM inbounds LIMIT 1;" >/dev/null 2>&1 || {
        err "Cannot read the inbounds table in ${DB_PATH}"; return 1; }
    return 0
}

detect_host_mechanism() {
    if xval "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts';" | grep -q '^hosts$'; then
        HOST_MECHANISM="hosts_table"
    else
        HOST_MECHANISM="external_proxy"
    fi
}

get_setting() {
    local k; k=$(esc "$1")
    q "SELECT value FROM settings WHERE key='${k}';" | jq -r '.[0].value // empty'
}

set_setting() {
    local k v ek ev exists
    k="$1"; v="$2"; ek=$(esc "$k"); ev=$(esc "$v")
    exists=$(xval "SELECT COUNT(*) FROM settings WHERE key='${ek}';")
    [ -n "$exists" ] || exists=0
    if [ "$exists" -gt 0 ]; then
        xsql "UPDATE settings SET value='${ev}' WHERE key='${ek}';"
    else
        xsql "INSERT INTO settings (key, value) VALUES ('${ek}', '${ev}');"
    fi
}

panel_port() { local p; p=$(get_setting webPort); [ -n "$p" ] || p="$DEFAULT_PANEL_PORT"; printf '%s\n' "$p"; }
sub_port()   { local p; p=$(get_setting subPort); [ -n "$p" ] || p="$DEFAULT_SUB_PORT"; printf '%s\n' "$p"; }

norm_path() {
    local v="${1:-}"
    v="${v%/}"
    [ -n "$v" ] && [ "${v#/}" = "$v" ] && v="/$v"
    printf '%s\n' "$v"
}

panel_path() { norm_path "$(get_setting webBasePath)"; }
sub_path()   { norm_path "$(get_setting subPath)"; }
panel_scheme() { [ -n "$(get_setting webCertFile)" ] && printf 'https\n' || printf 'http\n'; }
sub_scheme()   { [ -n "$(get_setting subCertFile)" ] && printf 'https\n' || printf 'http\n'; }
sub_json_path() { norm_path "$(get_setting subJsonPath)"; }

sub_enabled() {
    local v
    v=$(printf '%s' "$(get_setting subEnable)" | tr '[:upper:]' '[:lower:]')
    case "$v" in true|1|yes|on) return 0 ;; esac
    return 1
}

sub_is_separate() {
    [ -n "$SUB_DOMAIN" ] || return 1
    [ "$SUB_DOMAIN" != "$DOMAIN" ] || return 1
    [ -n "$SUB_CERT" ] || return 1
    [ -n "$SUB_BIND_PORT" ] || return 1
    return 0
}

pick_sub_port() {
    local p limit
    p=$((SITE_PORT + 1))
    limit=$((p + 300))
    refresh_taken_ports 2>/dev/null || true
    while [ "$p" -le "$limit" ]; do
        [ "$p" = "$SITE_PORT" ] && { p=$((p + 1)); continue; }
        if [ "$p" = "${SUB_BIND_PORT:-}" ] && ! port_busy "$p"; then SUB_BIND_PORT="$p"; return 0; fi
        if [ -z "${TAKEN_PORTS[$p]:-}" ] && ! port_busy "$p"; then SUB_BIND_PORT="$p"; return 0; fi
        p=$((p + 1))
    done
    err "No free loopback port for the subscription vhost"
    return 1
}

configure_subscription() {
    local spath jpath
    spath=$(sub_path)
    if ! sub_enabled; then
        SUB_ON_SITE="no"
        warn "Subscription is disabled in the panel - not published on the domain"
        warn "Enable it in the panel, then run option 2 to republish"
        return 0
    fi
    if [ -z "$spath" ]; then
        spath="/sub"
        set_setting subPath "${spath}/"
        warn "Subscription had no path - set to ${spath}/"
    fi
    if [ "$spath" = "$(panel_path)" ]; then
        SUB_ON_SITE="no"
        err "Subscription path equals the panel path - cannot publish both"
        return 0
    fi
    [ -n "$SUB_DOMAIN" ] || SUB_DOMAIN="$DOMAIN"
    if [ "$SUB_DOMAIN" != "$DOMAIN" ]; then
        SUB_CERT=""; SUB_KEY=""
        if resolve_cert "$SUB_DOMAIN" SUB_CERT SUB_KEY; then
            cert_expired "$SUB_CERT" && warn "Certificate for ${SUB_DOMAIN} is EXPIRED - renew it"
            pick_sub_port || { SUB_DOMAIN="$DOMAIN"; SUB_CERT=""; SUB_KEY=""; }
        else
            warn "No certificate for ${SUB_DOMAIN} - subscription falls back to ${DOMAIN}"
            SUB_DOMAIN="$DOMAIN"; SUB_CERT=""; SUB_KEY=""; SUB_BIND_PORT=""
        fi
    fi
    SUB_ON_SITE="yes"
    set_setting subURI "https://${SUB_DOMAIN}${spath}/"
    jpath=$(sub_json_path)
    if [ -n "$jpath" ] && [ "$jpath" != "$spath" ]; then
        set_setting subJsonURI "https://${SUB_DOMAIN}${jpath}/"
    fi
    ok "Subscription URL: https://${SUB_DOMAIN}${spath}/"
    return 0
}

ensure_panel_path() {
    local p; p=$(panel_path)
    if [ -z "$p" ]; then
        p="/panel$(rand_str 6)"
        set_setting webBasePath "${p}/"
        warn "Panel had no base path. It is now: ${p}/"
    fi
    printf '%s\n' "$p"
}

load_inbounds() {
    RI_ID=(); RI_REMARK=(); RI_LISTEN=(); RI_PORT=(); RI_PROTO=(); RI_SNI=(); RI_SNIS=(); RI_NET=()
    local json n i row sec
    json=$(q "SELECT id, remark, listen, port, protocol, stream_settings FROM inbounds WHERE enable=1 OR enable IS NULL ORDER BY id;")
    n=$(printf '%s' "$json" | jq 'length')
    for ((i = 0; i < n; i++)); do
        row=$(printf '%s' "$json" | jq -c ".[$i]")
        sec=$(printf '%s' "$row" | jq -r '(.stream_settings // "{}") | fromjson? | .security // ""')
        [ "$sec" = "reality" ] || continue
        RI_ID+=("$(printf '%s' "$row" | jq -r '.id')")
        RI_REMARK+=("$(printf '%s' "$row" | jq -r '.remark // ""')")
        RI_LISTEN+=("$(printf '%s' "$row" | jq -r '.listen // ""')")
        RI_PORT+=("$(printf '%s' "$row" | jq -r '.port')")
        RI_PROTO+=("$(printf '%s' "$row" | jq -r '.protocol')")
        RI_SNI+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | .realitySettings.serverNames[0] // ""')")
        RI_SNIS+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | (.realitySettings.serverNames // []) | join(" ")')")
        RI_NET+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | .network // "tcp"')")
    done
}

port_busy() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }
port_owner() { ss -Hltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -n1 | sed 's/.*"//'; }

refresh_taken_ports() {
    TAKEN_PORTS=()
    local p
    while IFS= read -r p; do [ -n "$p" ] && TAKEN_PORTS["$p"]=db; done < <(xval "SELECT port FROM inbounds;")
    TAKEN_PORTS["$(panel_port)"]=panel
    TAKEN_PORTS["$(sub_port)"]=sub
}

alloc_port() {
    local keep="${1:-}" p="$MIN_PORT"
    ALLOC_PORT=""
    while [ "$p" -le "$MAX_PORT" ]; do
        if [ -z "${TAKEN_PORTS[$p]:-}" ] || [ "$p" = "$keep" ]; then
            if ! port_busy "$p" || [ "$p" = "$keep" ]; then
                TAKEN_PORTS["$p"]=new
                ALLOC_PORT="$p"
                return 0
            fi
        fi
        p=$((p + 1))
    done
    err "No free internal port between ${MIN_PORT} and ${MAX_PORT}."
    return 1
}

load_state() {
    [ -f "$STATE_FILE" ] || return 0
    DOMAIN=$(jq -r '.domain // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SITE_MODE=$(jq -r '.site_mode // "none"' "$STATE_FILE" 2>/dev/null || echo none)
    SITE_TARGET=$(jq -r '.site_target // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SITE_CERT=$(jq -r '.site_cert // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SITE_KEY=$(jq -r '.site_key // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SITE_BIND_PORT=$(jq -r '.site_bind_port // ""' "$STATE_FILE" 2>/dev/null || echo "")
    PANEL_ON_SITE=$(jq -r '.panel_on_site // "no"' "$STATE_FILE" 2>/dev/null || echo no)
    SUB_ON_SITE=$(jq -r '.sub_on_site // "no"' "$STATE_FILE" 2>/dev/null || echo no)
    SUB_DOMAIN=$(jq -r '.sub_domain // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SUB_CERT=$(jq -r '.sub_cert // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SUB_KEY=$(jq -r '.sub_key // ""' "$STATE_FILE" 2>/dev/null || echo "")
    SUB_BIND_PORT=$(jq -r '.sub_bind_port // ""' "$STATE_FILE" 2>/dev/null || echo "")
    [ -n "$SUB_DOMAIN" ] || SUB_DOMAIN="$DOMAIN"
    [ -n "$SITE_BIND_PORT" ] && SITE_PORT="$SITE_BIND_PORT"
    return 0
}

save_state() {
    mkdir -p "$STATE_DIR"
    jq -n --arg d "$DOMAIN" --arg sm "$SITE_MODE" --arg st "$SITE_TARGET" \
          --arg sc "$SITE_CERT" --arg sk "$SITE_KEY" --arg sbp "$SITE_PORT" \
          --arg pos "$PANEL_ON_SITE" --arg sos "$SUB_ON_SITE" \
          --arg sd2 "$SUB_DOMAIN" --arg sc2 "$SUB_CERT" --arg sk2 "$SUB_KEY" --arg sbp2 "$SUB_BIND_PORT" \
        '{domain:$d, site_mode:$sm, site_target:$st, site_cert:$sc, site_key:$sk,
          site_bind_port:$sbp, panel_on_site:$pos, sub_on_site:$sos,
          sub_domain:$sd2, sub_cert:$sc2, sub_key:$sk2, sub_bind_port:$sbp2}' > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

save_original_ports() {
    mkdir -p "$STATE_DIR"
    if [ -f "$PORTS_FILE" ] && [ -s "$PORTS_FILE" ]; then
        return 0
    fi
    q "SELECT id, listen, port FROM inbounds;" > "$PORTS_FILE"
    if [ ! -s "$PORTS_FILE" ]; then
        err "Could not record original inbound ports - uninstall will not be able to restore them"
        rm -f "$PORTS_FILE"
        return 1
    fi
    chmod 600 "$PORTS_FILE" 2>/dev/null || true
    ok "Original inbound state recorded ($(jq 'length' "$PORTS_FILE") inbound(s))"
    return 0
}

track_created_host() {
    local hid="$1"
    [ -n "$hid" ] || return 0
    mkdir -p "$STATE_DIR"
    [ -f "$HOSTS_FILE" ] || printf '[]' > "$HOSTS_FILE"
    local tmp
    tmp=$(mktemp)
    jq --argjson h "$hid" '. + [$h] | unique' "$HOSTS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$HOSTS_FILE" || rm -f "$tmp"
    return 0
}

save_routed_ports() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$@" | jq -R . | jq -s . > "$ROUTED_FILE" 2>/dev/null || printf '[]' > "$ROUTED_FILE"
}

ask() {
    local label="$1" fn="$2" def="${3:-}" ans out c
    c=$(next_c)
    while true; do
        if [ -n "$def" ]; then
            printf '%s  %s %s[%s]%s: ' "$c" "$label" "$C_GOLD" "$def" "$R" >&2
        else
            printf '%s  %s%s: ' "$c" "$label" "$R" >&2
        fi
        IFS= read -r ans || ans=""
        [ -z "$ans" ] && [ -n "$def" ] && ans="$def"
        if out=$("$fn" "$ans"); then printf '%s\n' "$out"; return 0; fi
    done
}

v_domain() {
    local x="${1:-}"
    x="${x#http://}"; x="${x#https://}"; x="${x%%/*}"; x="${x%%:*}"
    if [[ "$x" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
        printf '%s\n' "$x"; return 0
    fi
    err "Enter a valid domain, e.g. cdn.example.com"
    return 1
}

v_yn() {
    local x; x=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$x" in y|yes) echo yes; return 0 ;; n|no|"") echo no; return 0 ;; esac
    err "Answer y or n."
    return 1
}




v_path() {
    local x="${1:-}"
    [ -f "$x" ] && { printf '%s\n' "$x"; return 0; }
    err "File not found: ${x:-<empty>}"
    return 1
}

show_table() {
    printf '%s  %-4s %-24s %-8s %-7s %-6s %s%s\n' "$C_TURQ" "#" "REMARK" "PORT" "NET" "ON443" "SNI" "$R"
    printf '%s  %s%s\n' "$C_SLATE" "-------------------------------------------------------------------------" "$R"
    local i on col
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        if is_routable_listen "${RI_LISTEN[$i]}" && [ "${RI_PORT[$i]}" -ge "$MIN_PORT" ] && [ "${RI_PORT[$i]}" -le "$MAX_PORT" ]; then
            on="yes"
        else
            on="no"
        fi
        col="${PAL[$((i % ${#PAL[@]}))]}"
        printf '%s  %-4s %-24s %-8s %-7s %-6s %s%s\n' "$col" \
            "$((i + 1))" "${RI_REMARK[$i]:0:24}" "${RI_PORT[$i]}" "${RI_NET[$i]}" "$on" "${RI_SNI[$i]:0:28}" "$R"
    done
    echo
}

parse_selection() {
    local total="${#RI_ID[@]}" raw tok bad
    local -a toks=()
    local -A seen=()
    SEL_IDX=()
    local c; c=$(next_c)
    while true; do
        printf '%s  Inbounds to route (e.g. 1,2,3 or all)%s: ' "$c" "$R" >&2
        IFS= read -r raw || raw=""
        raw="${raw//,/ }"
        if [ "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
            local i
            for ((i = 1; i <= total; i++)); do SEL_IDX+=("$i"); done
            return 0
        fi
        toks=()
        read -ra toks <<< "$raw" || true
        if [ "${#toks[@]}" -eq 0 ]; then err "Enter at least one number, or 'all'."; continue; fi
        bad=""; SEL_IDX=(); seen=()
        for tok in "${toks[@]}"; do
            if ! [[ "$tok" =~ ^[0-9]+$ ]] || [ "$tok" -lt 1 ] || [ "$tok" -gt "$total" ]; then bad="$tok"; break; fi
            [ -n "${seen[$tok]:-}" ] && continue
            seen[$tok]=1
            SEL_IDX+=("$tok")
        done
        if [ -n "$bad" ]; then err "'${bad}' is out of range (1-${total})."; continue; fi
        return 0
    done
}

validate_selection() {
    local -A owner=()
    local idx s rem
    local -a keep=()
    for idx in "${SEL_IDX[@]}"; do
        s="${RI_SNI[$((idx - 1))]}"
        rem="${RI_REMARK[$((idx - 1))]}"
        if [ -z "$s" ]; then
            warn "Skipping '${rem}': no Reality serverName, cannot be routed by SNI."
            continue
        fi
        if [ -n "${owner[$s]:-}" ]; then
            err "SNI '${s}' is shared by '${owner[$s]}' and '${rem}'. Give each inbound a unique serverName."
            return 1
        fi
        owner[$s]="$rem"
        keep+=("$idx")
    done
    if [ "${#keep[@]}" -eq 0 ]; then
        err "None of the selected inbounds have a serverName."
        return 1
    fi
    SEL_IDX=("${keep[@]}")
    return 0
}

sync_nginx_paths() {
    have nginx || return 0
    local cp dir
    cp=$(nginx -V 2>&1 | grep -oE -- '--conf-path=[^ ]+' | head -n1 | cut -d= -f2 || true)
    [ -n "$cp" ] || cp="$NGINX_CONF"
    dir=$(dirname "$cp")
    if [ "$cp" != "$NGINX_CONF" ] || [ ! -d "$dir" ]; then
        NGINX_CONF="$cp"
        NGINX_DIR="$dir"
        STREAM_FILE="${NGINX_DIR}/stream-reality443.conf"
        SITE_CONF="${NGINX_DIR}/conf.d/reality443-site.conf"
        NGINX_TUNE="${NGINX_DIR}/conf.d/00-reality443-tune.conf"
    fi
    mkdir -p "$NGINX_DIR" "${NGINX_DIR}/conf.d" 2>/dev/null || true
    return 0
}

stream_state() {
    local v
    v=$(nginx -V 2>&1 || true)
    if printf '%s' "$v" | grep -q -- '--with-stream=dynamic'; then echo dynamic
    elif printf '%s' "$v" | grep -q -- '--with-stream'; then echo static
    else echo missing; fi
}

modules_path() {
    local p
    p=$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | head -n1 | cut -d= -f2 || true)
    [ -n "$p" ] || p=/usr/lib/nginx/modules
    printf '%s\n' "$p"
}

find_stream_so() {
    local cand
    if [ -n "$STREAM_SO_CACHE" ] && [ -f "$STREAM_SO_CACHE" ]; then
        printf '%s\n' "$STREAM_SO_CACHE"; return 0
    fi
    for cand in "$(modules_path)/ngx_stream_module.so" \
                /usr/lib/nginx/modules/ngx_stream_module.so \
                /usr/lib64/nginx/modules/ngx_stream_module.so \
                /usr/share/nginx/modules/ngx_stream_module.so \
                /etc/nginx/modules/ngx_stream_module.so; do
        [ -f "$cand" ] && { STREAM_SO_CACHE="$cand"; printf '%s\n' "$cand"; return 0; }
    done
    cand=$(find /usr /etc /opt -name 'ngx_stream_module.so' -type f 2>/dev/null | head -n1)
    [ -n "$cand" ] && { STREAM_SO_CACHE="$cand"; printf '%s\n' "$cand"; return 0; }
    return 1
}

stream_module_loaded() {
    local d
    grep -qE 'load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" 2>/dev/null && return 0
    for d in "$NGINX_DIR/modules-enabled" "$NGINX_DIR/conf.d"; do
        [ -d "$d" ] || continue
        grep -RqE 'load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$d" 2>/dev/null && return 0
    done
    return 1
}

drop_duplicate_load_module() {
    grep -qE '^load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" 2>/dev/null || return 1
    local tmp; tmp=$(mktemp)
    grep -vE '^load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" > "$tmp"
    mv "$tmp" "$NGINX_CONF"
    return 0
}

write_minimal_nginx_conf() {
    mkdir -p "$NGINX_DIR" "${NGINX_DIR}/conf.d" /var/log/nginx
    local nuser="www-data"
    id -u www-data >/dev/null 2>&1 || nuser="nginx"
    cat > "$NGINX_CONF" <<NGCONF
user ${nuser};
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    server_names_hash_bucket_size 128;
    include ${NGINX_DIR}/mime.types;
    default_type application/octet-stream;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    include ${NGINX_DIR}/conf.d/*.conf;
}
NGCONF
    [ -f "${NGINX_DIR}/mime.types" ] || printf 'types {\n    text/html html htm;\n    text/css css;\n    application/javascript js;\n    image/png png;\n    image/jpeg jpg jpeg;\n    image/svg+xml svg;\n    application/json json;\n}\n' > "${NGINX_DIR}/mime.types"
}

install_nginx() {
    if ! have nginx; then
        info "Installing nginx..."
        if [ "$(pkg_mgr)" = "apt" ]; then
            install_pkgs nginx libnginx-mod-stream || true
        else
            install_pkgs nginx nginx-mod-stream || install_pkgs nginx || true
        fi
        have nginx || { err "nginx installation failed."; return 1; }
    fi
    sync_nginx_paths
    if [ ! -f "$NGINX_CONF" ]; then
        warn "${NGINX_CONF} missing - creating a clean configuration."
        write_minimal_nginx_conf
    fi
    [ -f "$NGINX_CONF" ] || { err "Cannot create ${NGINX_CONF}."; return 1; }

    local st so
    st=$(stream_state)
    if [ "$st" = "static" ]; then
        systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
        return 0
    fi
    so=$(find_stream_so || true)
    if [ -z "$so" ]; then
        case "$(pkg_mgr)" in
            apt) install_pkgs libnginx-mod-stream || true ;;
            dnf|yum) install_pkgs nginx-mod-stream || true ;;
        esac
        so=$(find_stream_so || true)
    fi
    if [ -z "$so" ]; then
        [ "$(stream_state)" = "static" ] && { systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true; return 0; }
        err "ngx_stream_module.so not found. Install your distribution's nginx stream module."
        return 1
    fi
    if ! stream_module_loaded; then
        local tmp; tmp=$(mktemp)
        { printf 'load_module %s;\n' "$so"; cat "$NGINX_CONF"; } > "$tmp"
        mv "$tmp" "$NGINX_CONF"
    fi
    systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
    return 0
}

ensure_confd_included() {
    mkdir -p "${NGINX_DIR}/conf.d"
    [ -f "$NGINX_CONF" ] || return 0
    grep -qE "^[[:space:]]*include[[:space:]]+[^;]*conf\.d/\*\.conf[[:space:]]*;" "$NGINX_CONF" 2>/dev/null && return 0
    local tmp; tmp=$(mktemp)
    awk -v inc="    include ${NGINX_DIR}/conf.d/*.conf;" '
        BEGIN { done_i = 0 }
        { print }
        !done_i && $0 ~ /^[[:space:]]*http[[:space:]]*\{/ { print inc; done_i = 1 }
    ' "$NGINX_CONF" > "$tmp"
    mv "$tmp" "$NGINX_CONF"
}

nginx_ver() {
    nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

nginx_ver_ge() {
    local want="$1" cur
    cur=$(nginx_ver)
    [ -n "$cur" ] || return 1
    [ "$(printf '%s\n%s\n' "$want" "$cur" | sort -V | head -n1)" = "$want" ]
}

OWNED_DIRECTIVES="gzip sendfile tcp_nopush tcp_nodelay keepalive_timeout keepalive_requests reset_timedout_connection client_body_timeout client_header_timeout send_timeout types_hash_max_size server_names_hash_bucket_size server_tokens access_log"

strip_owned_directives() {
    [ -f "$NGINX_CONF" ] || return 0
    local d tmp
    tmp=$(mktemp)
    cp -f "$NGINX_CONF" "$tmp"
    for d in $OWNED_DIRECTIVES; do
        sed -i "/^[[:space:]]*${d}[[:space:]][^;]*;[[:space:]]*$/d" "$tmp"
        sed -i "/^[[:space:]]*${d};[[:space:]]*$/d" "$tmp"
    done
    mv "$tmp" "$NGINX_CONF"
    return 0
}

R443_WCONN=""
normalize_events_block() {
    [ -f "$NGINX_CONF" ] || return 0
    local tmp
    tmp=$(mktemp)
    R443_EVENTS="events {
    worker_connections ${R443_WCONN:-16384};
    multi_accept on;
    use epoll;
}"
    export R443_EVENTS
    awk '
        BEGIN { st = 0; depth = 0; done_e = 0 }
        function emit() { printf "%s\n", ENVIRON["R443_EVENTS"] }
        {
            plain = $0; sub(/#.*/, "", plain)
            if (st == 0 && !done_e && plain ~ /(^|[ \t;}])events[ \t]*\{/) {
                depth = 0
                for (i = 1; i <= length(plain); i++) {
                    c = substr(plain, i, 1)
                    if (c == "{") depth++; else if (c == "}") depth--
                }
                if (depth <= 0) { emit(); done_e = 1 } else { st = 1 }
                next
            }
            if (st == 1) {
                for (i = 1; i <= length(plain); i++) {
                    c = substr(plain, i, 1)
                    if (c == "{") depth++; else if (c == "}") depth--
                }
                if (depth <= 0) { emit(); st = 0; done_e = 1 }
                next
            }
            print
        }
        END { if (!done_e) emit() }
    ' "$NGINX_CONF" > "$tmp"
    mv "$tmp" "$NGINX_CONF"
    unset R443_EVENTS
    return 0
}

tune_nginx_main() {
    local tmp
    tmp=$(mktemp)
    local mem wconn wfile
    mem=$(ram_mb)
    if [ "$mem" -lt 2048 ]; then
        wconn=16384; wfile=200000
    elif [ "$mem" -lt 8192 ]; then
        wconn=32768; wfile=500000
    else
        wconn=65535; wfile=1000000
    fi
    if ! grep -qE '^[[:space:]]*worker_rlimit_nofile' "$NGINX_CONF"; then
        { printf 'worker_rlimit_nofile %s;\n' "$wfile"; cat "$NGINX_CONF"; } > "$tmp"
        mv "$tmp" "$NGINX_CONF"
    else
        sed -i "s/^[[:space:]]*worker_rlimit_nofile.*/worker_rlimit_nofile ${wfile};/" "$NGINX_CONF"
    fi
    sed -i 's/^[[:space:]]*worker_processes[[:space:]].*/worker_processes auto;/' "$NGINX_CONF"
    grep -qE '^worker_processes' "$NGINX_CONF" || sed -i "1a worker_processes auto;" "$NGINX_CONF"
    sed -i '/^worker_cpu_affinity[[:space:]]\+auto;$/d' "$NGINX_CONF"
    if [ "$(nproc 2>/dev/null || echo 1)" -ge 2 ]; then
        sed -i '/^worker_processes auto;/a worker_cpu_affinity auto;' "$NGINX_CONF"
    fi
    R443_WCONN="$wconn"
    normalize_events_block
    R443_WCONN=""
    strip_owned_directives
    ensure_confd_included
    cat > "$NGINX_TUNE" <<'TUNE'
# reality443-managed
sendfile on;
tcp_nopush on;
tcp_nodelay on;
gzip off;
keepalive_timeout 65;
keepalive_requests 100000;
reset_timedout_connection on;
client_body_timeout 15s;
client_header_timeout 15s;
send_timeout 30s;
types_hash_max_size 4096;
server_names_hash_bucket_size 128;
server_tokens off;
access_log off;
TUNE
    ok "nginx core tuned for high connection count"
}

ram_mb() {
    local m
    m=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    [ -n "$m" ] && [ "$m" -gt 0 ] 2>/dev/null || m=1024
    printf '%s' "$m"
}

apply_sysctl() {
    local mem sockmax rmem_hi ct fmax nl_backlog
    mem=$(ram_mb)
    if [ "$mem" -lt 2048 ]; then
        sockmax=16777216;  rmem_hi=16777216;  ct=131072;  fmax=200000;  nl_backlog=16384
    elif [ "$mem" -lt 8192 ]; then
        sockmax=33554432;  rmem_hi=33554432;  ct=262144;  fmax=500000;  nl_backlog=65536
    else
        sockmax=67108864;  rmem_hi=67108864;  ct=1048576; fmax=1000000; nl_backlog=250000
    fi
    cat > "$SYSCTL_FILE" <<SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${sockmax}
net.core.wmem_max = ${sockmax}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 262144 ${rmem_hi}
net.ipv4.tcp_wmem = 4096 262144 ${rmem_hi}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.somaxconn = 32768
net.core.netdev_max_backlog = ${nl_backlog}
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_no_metrics_save = 1
net.netfilter.nf_conntrack_max = ${ct}
fs.file-max = ${fmax}
vm.swappiness = 10
SYSCTL
    modprobe tcp_bbr >/dev/null 2>&1 || true
    printf 'tcp_bbr\n' > /etc/modules-load.d/reality443.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    if [ "$cc" = "bbr" ]; then
        ok "Kernel tuned for ${mem}MB RAM (BBR + fq + sized buffers)"
    else
        warn "Kernel tuned for ${mem}MB RAM, but congestion control is '${cc}'"
    fi
}

apply_limits() {
    local lim mem
    mem=$(ram_mb)
    if [ "$mem" -lt 2048 ]; then lim=200000
    elif [ "$mem" -lt 8192 ]; then lim=500000
    else lim=1000000; fi
    cat > "$LIMITS_FILE" <<LIM
* soft nofile ${lim}
* hard nofile ${lim}
* soft nproc ${lim}
* hard nproc ${lim}
root soft nofile ${lim}
root hard nofile ${lim}
LIM
    local d
    for d in "$NGINX_SERVICE" "$XUI_SERVICE"; do
        systemctl list-unit-files "${d}.service" >/dev/null 2>&1 || continue
        mkdir -p "/etc/systemd/system/${d}.service.d"
        cat > "/etc/systemd/system/${d}.service.d/reality443-limits.conf" <<DROPIN
[Service]
LimitNOFILE=${lim}
LimitNPROC=${lim}
DROPIN
    done
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/reality443-limits.conf <<SYSD
[Manager]
DefaultLimitNOFILE=${lim}
DefaultLimitNPROC=${lim}
SYSD
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "File descriptor limits set to ${lim} (${mem}MB RAM)"
}

write_stream_conf() {
    local default_backend="" tmp i bip site_be="" sn dupes=""
    local -A sni_seen=()
    local -a map_lines=()
    tmp=$(mktemp)

    if [ -f "$SITE_CONF" ] && [ -n "$DOMAIN" ] && [ -n "$SITE_CERT" ]; then
        site_be="127.0.0.1:${SITE_PORT}"
        default_backend="$site_be"
    fi
    if [ -z "$default_backend" ]; then
        for ((i = 0; i < ${#RI_ID[@]}; i++)); do
            if is_routable_listen "${RI_LISTEN[$i]}" && [ -n "${RI_SNI[$i]}" ]; then
                default_backend="$(backend_ip "${RI_LISTEN[$i]}"):${RI_PORT[$i]}"
                break
            fi
        done
    fi
    if [ -z "$default_backend" ]; then
        err "No routed inbound and no site - nothing to serve on 443."
        rm -f "$tmp"; return 1
    fi

    add_map_entry() {
        local name="$1" backend="$2" holder="$3"
        [ -n "$name" ] || return 0
        if [ -n "${sni_seen[$name]:-}" ]; then
            [ "${sni_seen[$name]}" = "$holder" ] || dupes="${dupes}${name}\n"
            return 0
        fi
        sni_seen[$name]="$holder"
        map_lines+=("    \"${name}\" ${backend};")
    }

    [ -n "$site_be" ] && add_map_entry "$DOMAIN" "$site_be" "site"
    if [ -f "$SITE_CONF" ] && [ "$SUB_ON_SITE" = "yes" ] && sub_is_separate; then
        add_map_entry "$SUB_DOMAIN" "127.0.0.1:${SUB_BIND_PORT}" "subscription"
    fi
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        if is_routable_listen "${RI_LISTEN[$i]}" && [ -n "${RI_SNI[$i]}" ]; then
            bip=$(backend_ip "${RI_LISTEN[$i]}")
            for sn in ${RI_SNIS[$i]}; do
                add_map_entry "$sn" "${bip}:${RI_PORT[$i]}" "${RI_REMARK[$i]:-inbound}"
            done
        fi
    done
    [ -n "$dupes" ] && warn "Duplicate SNI names skipped to keep nginx valid."

    {
        echo "# reality443-managed v${SCRIPT_VERSION}"
        echo "map \$ssl_preread_server_name \$reality443_upstream {"
        echo "    default ${default_backend};"
        [ "${#map_lines[@]}" -gt 0 ] && printf '%s\n' "${map_lines[@]}"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen 443 reuseport backlog=65535 rcvbuf=4m sndbuf=4m;"
        has_ipv6 && echo "    listen [::]:443 reuseport backlog=65535 rcvbuf=4m sndbuf=4m;"
        echo "    proxy_pass \$reality443_upstream;"
        echo "    ssl_preread on;"
        echo "    proxy_protocol off;"
        echo "    proxy_connect_timeout 3s;"
        echo "    proxy_timeout 900s;"
        echo "    proxy_buffer_size 32k;"
        echo "    proxy_socket_keepalive on;"
        echo "    tcp_nodelay on;"
        echo "}"
    } > "$tmp"

    mkdir -p "$(dirname "$STREAM_FILE")" 2>/dev/null || true
    if ! mv "$tmp" "$STREAM_FILE" 2>/dev/null; then
        err "Could not write ${STREAM_FILE}"
        rm -f "$tmp"; return 1
    fi
    unset -f add_map_entry
    return 0
}

find_toplevel_stream() {
    local f="$1"
    [ -f "$f" ] || return 1
    awk '
        { l = $0; sub(/#.*/, "", l) }
        depth == 0 && l ~ /(^|[ \t;}])stream[ \t]*\{/ { print NR; exit }
        { for (i = 1; i <= length(l); i++) { c = substr(l, i, 1); if (c == "{") depth++; else if (c == "}") depth-- } }
    ' "$f"
}

insert_include_into_stream() {
    local file="$1" startline="$2" tmp
    tmp=$(mktemp)
    awk -v startline="$startline" -v inc="    include ${STREAM_FILE};" '
        BEGIN { depth = 0; inserted = 0; started = 0 }
        {
            line = $0; plain = $0; sub(/#.*/, "", plain)
            if (NR == startline) started = 1
            if (started && !inserted) {
                n = length(plain)
                for (i = 1; i <= n; i++) {
                    c = substr(plain, i, 1)
                    if (c == "{") depth++
                    else if (c == "}") { depth--; if (depth == 0) { print inc; inserted = 1 } }
                }
            }
            print line
        }
        END { if (!inserted) exit 1 }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    grep -qF "$STREAM_FILE" "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file"
    return 0
}

hook_stream_include() {
    grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null && return 0
    local hit; hit=$(find_toplevel_stream "$NGINX_CONF" || true)
    if [ -n "$hit" ]; then
        if insert_include_into_stream "$NGINX_CONF" "$hit"; then return 0; fi
        err "Could not extend the existing stream block. Add manually: include ${STREAM_FILE};"
        return 1
    fi
    {
        echo ""
        echo "$MARK_BEGIN"
        echo "stream {"
        echo "    preread_timeout 5s;"
        echo "    preread_buffer_size 16k;"
        echo "    tcp_nodelay on;"
        echo "    proxy_socket_keepalive on;"
        echo "    include ${STREAM_FILE};"
        echo "}"
        echo "$MARK_END"
    } >> "$NGINX_CONF" 2>/dev/null || { err "Could not write to ${NGINX_CONF}"; return 1; }
    grep -qF "$MARK_BEGIN" "$NGINX_CONF" || { err "Stream block did not persist."; return 1; }
    return 0
}

unhook_stream_include() {
    [ -f "$NGINX_CONF" ] || return 0
    local tmp; tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        index($0, b) { skip = 1 }
        !skip { print }
        index($0, e) { skip = 0 }
    ' "$NGINX_CONF" > "$tmp"
    mv "$tmp" "$NGINX_CONF"
    sed -i "\|include ${STREAM_FILE};|d" "$NGINX_CONF" 2>/dev/null || true
    rm -f "$STREAM_FILE"
}

backup_now() {
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${BACKUP_ROOT}/${ts}"
    mkdir -p "$dir"
    [ -f "$DB_PATH" ] && cp -a "$DB_PATH" "${dir}/x-ui.db"
    [ -f "$NGINX_CONF" ] && cp -a "$NGINX_CONF" "${dir}/nginx.conf"
    [ -f "$STREAM_FILE" ] && cp -a "$STREAM_FILE" "${dir}/stream-reality443.conf"
    [ -f "$SITE_CONF" ] && cp -a "$SITE_CONF" "${dir}/reality443-site.conf"
    ln -sfn "$dir" "${BACKUP_ROOT}/latest"
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name '20*' | sort | head -n -10 | xargs -r rm -rf
    printf '%s\n' "$dir"
}

restore_nginx_from() {
    local dir="$1"
    [ -f "${dir}/nginx.conf" ] && cp -a "${dir}/nginx.conf" "$NGINX_CONF"
    if [ -f "${dir}/stream-reality443.conf" ]; then
        cp -a "${dir}/stream-reality443.conf" "$STREAM_FILE"
    else
        rm -f "$STREAM_FILE"
    fi
    if [ -f "${dir}/reality443-site.conf" ]; then
        cp -a "${dir}/reality443-site.conf" "$SITE_CONF"
    fi
}

apply_nginx() {
    local backup_dir="${1:-}"
    if ! nginx -t 2>/tmp/r443.nginx.err; then
        if grep -q 'is already loaded' /tmp/r443.nginx.err && drop_duplicate_load_module; then
            :
        fi
    fi
    if nginx -t 2>/tmp/r443.nginx.err; then
        if systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null; then
            return 0
        fi
        err "nginx config is valid but the service failed to start."
        systemctl status "$NGINX_SERVICE" --no-pager 2>&1 | tail -n 12 >&2
        return 1
    fi
    err "nginx config test failed."
    sed -n '1,25p' /tmp/r443.nginx.err >&2
    [ -n "$backup_dir" ] && restore_nginx_from "$backup_dir"
    return 1
}

wait_for_ports() {
    local -a want=("$@")
    local p all i restarted=0
    [ "${#want[@]}" -eq 0 ] && return 0
    for ((i = 0; i < 40; i++)); do
        all=1
        for p in "${want[@]}"; do
            port_busy "$p" || { all=0; break; }
        done
        [ "$all" -eq 1 ] && return 0
        if [ "$i" -eq 15 ] && [ "$restarted" -eq 0 ]; then
            restarted=1
            systemctl restart "$XUI_SERVICE" >/dev/null 2>&1 || true
        fi
        sleep 1
    done
    return 1
}

start_xui_and_wait() {
    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
    if [ "$#" -gt 0 ] && wait_for_ports "$@"; then return 0; fi
    if systemctl is-active --quiet "$XUI_SERVICE"; then
        [ "$#" -gt 0 ] && warn "x-ui is running but has not bound every port yet."
        return 0
    fi
    err "x-ui failed to start - check: systemctl status ${XUI_SERVICE}"
    return 1
}

set_inbound_host() {
    local id="$1" addr="$2" remark="$3" hport="${4:-443}"
    local ea er existing sj new
    ea=$(esc "$addr"); er=$(esc "$remark")
    if [ "$HOST_MECHANISM" = "hosts_table" ]; then
        existing=$(xval "SELECT id FROM hosts WHERE inbound_id=${id} LIMIT 1;")
        if [ -n "$existing" ]; then
            xsql "UPDATE hosts SET address='${ea}', port=${hport}, remark='${er}' WHERE id=${existing};" || true
            track_created_host "$existing"
        else
            xsql "INSERT INTO hosts (inbound_id, remark, address, port, security) VALUES (${id}, '${er}', '${ea}', ${hport}, 'same');" \
                || xsql "INSERT INTO hosts (inbound_id, remark, address, port) VALUES (${id}, '${er}', '${ea}', ${hport});" || true
            track_created_host "$(xval "SELECT id FROM hosts WHERE inbound_id=${id} ORDER BY id DESC LIMIT 1;")"
        fi
    else
        sj=$(q "SELECT stream_settings FROM inbounds WHERE id=${id};" | jq -r '.[0].stream_settings')
        new=$(printf '%s' "$sj" | jq -c --arg d "$addr" --arg r "$remark" --argjson p "$hport" \
            '.externalProxy = [{forceTls:"same", dest:$d, port:$p, remark:$r}]')
        xsql "UPDATE inbounds SET stream_settings='$(esc "$new")' WHERE id=${id};" || true
    fi
}

is_cert_file() {
    openssl x509 -in "$1" -noout -subject >/dev/null 2>&1
}

is_key_file() {
    openssl pkey -in "$1" -noout >/dev/null 2>&1
}

key_matches_cert() {
    local c="$1" k="$2" cp kp
    cp=$(openssl x509 -in "$c" -pubkey -noout 2>/dev/null)
    [ -n "$cp" ] || return 1
    kp=$(openssl pkey -in "$k" -pubout 2>/dev/null)
    [ -n "$kp" ] || return 1
    [ "$cp" = "$kp" ]
}

cert_primary_name() {
    local c="$1" n
    n=$(openssl x509 -in "$c" -noout -text 2>/dev/null | grep -oE 'DNS:[^,]+' | head -n1 | sed 's/DNS://; s/ //g')
    [ -n "$n" ] || n=$(openssl x509 -in "$c" -noout -subject 2>/dev/null | grep -oE 'CN[[:space:]]*=[[:space:]]*[^,/]+' | sed 's/.*=[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s' "$n"
}

cert_expired() {
    openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1 && return 1
    return 0
}

search_depth_for() {
    case "$1" in
        /root|/home|/etc/ssl/certs) printf '1' ;;
        /etc/letsencrypt/live) printf '2' ;;
        *) printf '3' ;;
    esac
}

find_key_for_cert() {
    local c="$1" d k base
    d=$(dirname "$c")
    base=$(basename "$c")
    base="${base%.*}"
    for k in "${d}/${base}.key" "${d}/${base}.pem" "${d}/privkey.pem" "${d}/private.key" \
             "${d}/key.key" "${d}/key.pem" "${d}/privkey.key" "${d}/$(basename "$d").key" \
             "${d}/server.key" "${d}/ssl.key"; do
        [ -f "$k" ] || continue
        is_key_file "$k" || continue
        key_matches_cert "$c" "$k" && { printf '%s' "$k"; return 0; }
    done
    while IFS= read -r k; do
        [ -f "$k" ] || continue
        [ "$k" = "$c" ] && continue
        is_key_file "$k" || continue
        key_matches_cert "$c" "$k" && { printf '%s' "$k"; return 0; }
    done < <(find "$d" -maxdepth 1 -type f \( -name '*.key' -o -name '*.pem' -o -name '*.txt' \) 2>/dev/null | head -40)
    return 1
}

find_cert_pairs() {
    local base depth f key dom
    for base in $CERT_SEARCH_DIRS; do
        [ -d "$base" ] || continue
        depth=$(search_depth_for "$base")
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            [ -s "$f" ] || continue
            is_cert_file "$f" || continue
            key=$(find_key_for_cert "$f") || continue
            [ -n "$key" ] || continue
            dom=$(cert_primary_name "$f")
            [ -n "$dom" ] || dom=$(basename "$(dirname "$f")")
            printf '%s|%s|%s\n' "$dom" "$f" "$key"
        done < <(find "$base" -maxdepth "$depth" -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.fullchain' \) 2>/dev/null | head -80)
    done | awk -F'|' '!seen[$2]++'
}

cert_covers_domain() {
    local crt="$1" dom="$2" names n cn
    names=$(openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -oE 'DNS:[^,]+' | sed 's/DNS://g' | tr -d ' ' || true)
    cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -oE 'CN[[:space:]]*=[[:space:]]*[^,/]+' | sed 's/.*=[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$cn" ] && names="${names}
${cn}"
    [ -n "$names" ] || return 1
    for n in $names; do
        [ "$n" = "$dom" ] && return 0
        case "$n" in
            \*.*) [ "${dom#*.}" = "${n#\*.}" ] && return 0 ;;
        esac
    done
    return 1
}

auto_select_cert_into() {
    local dom="$1" cvar="$2" kvar="$3" p pd pc pk
    local -a pairs=()
    mapfile -t pairs < <(find_cert_pairs)
    [ "${#pairs[@]}" -eq 0 ] && return 1
    for p in "${pairs[@]}"; do
        IFS='|' read -r pd pc pk <<< "$p"
        if [ "$pd" = "$dom" ]; then
            printf -v "$cvar" '%s' "$pc"
            printf -v "$kvar" '%s' "$pk"
            return 0
        fi
    done
    for p in "${pairs[@]}"; do
        IFS='|' read -r pd pc pk <<< "$p"
        if cert_covers_domain "$pc" "$dom"; then
            printf -v "$cvar" '%s' "$pc"
            printf -v "$kvar" '%s' "$pk"
            return 0
        fi
    done
    return 1
}

auto_select_cert() {
    auto_select_cert_into "$1" SITE_CERT SITE_KEY
}

list_found_certs() {
    local -a pairs=()
    mapfile -t pairs < <(find_cert_pairs)
    if [ "${#pairs[@]}" -eq 0 ]; then
        warn "No usable certificate/key pair found under: ${CERT_SEARCH_DIRS}"
        return 1
    fi
    local k pd pc
    step "Certificates found on this server"
    for k in "${!pairs[@]}"; do
        pd=$(printf '%s' "${pairs[$k]}" | cut -d'|' -f1)
        pc=$(printf '%s' "${pairs[$k]}" | cut -d'|' -f2)
        line_c "$k" "  $((k + 1))) ${pd}"
        printf '%s        %s%s\n' "$C_SLATE" "$pc" "$R"
    done
    return 0
}

resolve_cert() {
    local dom="$1" cvar="$2" kvar="$3" pick c1 c2
    local -a pairs=()
    if auto_select_cert_into "$dom" "$cvar" "$kvar"; then
        ok "Certificate matched for ${dom}"
        return 0
    fi
    err "No certificate covering ${dom} was auto-detected"
    mapfile -t pairs < <(find_cert_pairs)
    if [ "${#pairs[@]}" -gt 0 ]; then
        list_found_certs
        line_c "${#pairs[@]}" "  0) enter certificate paths manually"
        line_c 3 "  s) skip (do not serve ${dom} over TLS)"
        while true; do
            printf '%s  Select certificate for %s%s: ' "$(next_c)" "$dom" "$R"
            IFS= read -r pick || pick="s"
            case "$pick" in
                s|S|"") return 1 ;;
                0) break ;;
            esac
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#pairs[@]}" ]; then
                c1=$(printf '%s' "${pairs[$((pick - 1))]}" | cut -d'|' -f2)
                c2=$(printf '%s' "${pairs[$((pick - 1))]}" | cut -d'|' -f3)
                printf -v "$cvar" '%s' "$c1"
                printf -v "$kvar" '%s' "$c2"
                cert_covers_domain "$c1" "$dom" || warn "That certificate does not list ${dom} - browsers will warn"
                ok "Using ${c1}"
                return 0
            fi
            err "Pick a number, 0 for manual paths, or s to skip."
        done
    fi
    while true; do
        printf '%s  Full path to certificate for %s (Enter to skip)%s: ' "$(next_c)" "$dom" "$R"
        IFS= read -r c1 || c1=""
        [ -z "$c1" ] && return 1
        if [ ! -f "$c1" ] || ! is_cert_file "$c1"; then
            err "Not a valid certificate: ${c1}"
            continue
        fi
        printf '%s  Full path to private key%s: ' "$(next_c)" "$R"
        IFS= read -r c2 || c2=""
        if [ ! -f "$c2" ] || ! is_key_file "$c2"; then
            err "Not a valid private key: ${c2}"
            continue
        fi
        if ! key_matches_cert "$c1" "$c2"; then
            err "This key does not belong to that certificate"
            continue
        fi
        printf -v "$cvar" '%s' "$c1"
        printf -v "$kvar" '%s' "$c2"
        ok "Using ${c1}"
        return 0
    done
}


pick_site_port() {
    local p="${SITE_PORT:-8081}" limit=$((SITE_PORT + 300))
    refresh_taken_ports 2>/dev/null || true
    while [ "$p" -le "$limit" ]; do
        if [ "$p" = "${SITE_BIND_PORT:-}" ] && ! port_busy "$p"; then SITE_PORT="$p"; return 0; fi
        if [ -z "${TAKEN_PORTS[$p]:-}" ] && ! port_busy "$p"; then SITE_PORT="$p"; return 0; fi
        p=$((p + 1))
    done
    err "No free loopback port for the camouflage site."
    return 1
}

copy_site_files() {
    local src="$1" srcdir n sz
    [ -f "$src" ] || return 1
    mkdir -p "$SITE_ROOT"
    srcdir=$(dirname "$src")
    if [ "$srcdir" = "$SITE_ROOT" ]; then
        ok "Site files already in place"
        return 0
    fi
    case "$srcdir" in
        /|/root|/home|/etc|/usr|/var|/opt|/tmp|/srv|/boot)
            warn "Source sits in a system directory - copying only index.html"
            cp -f "$src" "${SITE_ROOT}/index.html" || return 1
            return 0 ;;
    esac
    n=$(find "$srcdir" -type f 2>/dev/null | head -20001 | wc -l)
    sz=$(du -sm "$srcdir" 2>/dev/null | awk '{print $1}')
    [ -n "$sz" ] || sz=0
    if [ "$n" -gt 20000 ] || [ "$sz" -gt 500 ]; then
        warn "Source folder is large (${n} files, ${sz}MB) - copying only index.html"
        cp -f "$src" "${SITE_ROOT}/index.html" || return 1
        return 0
    fi
    info "Copying ${n} file(s) from ${srcdir}"
    if ! timeout 120 cp -a "${srcdir}/." "$SITE_ROOT"/ 2>/dev/null; then
        warn "Bulk copy failed or timed out - falling back to index.html only"
        cp -f "$src" "${SITE_ROOT}/index.html" || return 1
    fi
    [ -f "${SITE_ROOT}/index.html" ] || cp -f "$src" "${SITE_ROOT}/index.html"
    ok "Copied site files to ${SITE_ROOT}"
    return 0
}

find_user_index() {
    local c
    for c in "${SITE_ROOT}/index.html" /var/www/html/index.html /usr/share/nginx/html/index.html; do
        [ -f "$c" ] || continue
        grep -qi 'Welcome to nginx' "$c" 2>/dev/null && continue
        printf '%s\n' "$c"
        return 0
    done
    return 1
}

setup_site_content() {
    local src=""
    if [ -n "${SITE_SRC_ARG:-}" ]; then
        if [ -f "$SITE_SRC_ARG" ]; then
            src="$SITE_SRC_ARG"
            info "Using site file supplied on the command line"
        else
            warn "Supplied site file not found: ${SITE_SRC_ARG}"
        fi
    fi
    [ -n "$src" ] || src=$(find_user_index || true)
    if [ -n "$src" ]; then
        copy_site_files "$src" || { warn "Falling back to built-in page"; generate_default_site; }
    else
        generate_default_site
        ok "Built-in camouflage page generated"
    fi
    chown -R www-data:www-data "$SITE_ROOT" 2>/dev/null || chown -R nginx:nginx "$SITE_ROOT" 2>/dev/null || true
    chmod -R a+rX "$SITE_ROOT" 2>/dev/null || true
    return 0
}

generate_default_site() {
    mkdir -p "$SITE_ROOT"
    cat > "${SITE_ROOT}/index.html" <<'HTMLDOC'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cloud Delivery Network</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#0f1115;color:#e6e8ec;min-height:100vh;display:flex;align-items:center;justify-content:center}
.wrap{max-width:720px;padding:48px 32px;text-align:center}
h1{font-size:34px;font-weight:600;letter-spacing:-.5px;margin-bottom:14px}
p{color:#9aa3b2;line-height:1.7;font-size:16px;margin-bottom:28px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:16px;margin-top:32px}
.card{background:#171a21;border:1px solid #232833;border-radius:10px;padding:20px}
.card h3{font-size:15px;font-weight:600;margin-bottom:6px}
.card span{font-size:13px;color:#7d879c}
footer{margin-top:40px;font-size:13px;color:#5b6478}
</style></head><body>
<div class="wrap">
<h1>Content Delivery Platform</h1>
<p>Distributed edge infrastructure for static assets, media streaming and API acceleration.</p>
<div class="grid">
<div class="card"><h3>Edge Cache</h3><span>Global PoP network</span></div>
<div class="card"><h3>TLS 1.3</h3><span>Modern encryption</span></div>
<div class="card"><h3>HTTP/2</h3><span>Multiplexed delivery</span></div>
</div>
<footer>&copy; 2026 &middot; All rights reserved</footer>
</div></body></html>
HTMLDOC
    chown -R www-data:www-data "$SITE_ROOT" 2>/dev/null || chown -R nginx:nginx "$SITE_ROOT" 2>/dev/null || true
    chmod -R a+rX "$SITE_ROOT" 2>/dev/null || true
}

disable_stock_default_site() {
    mkdir -p "$DISABLED_DIR"
    local f base
    for f in "${NGINX_DIR}"/sites-enabled/* "${NGINX_DIR}"/conf.d/default.conf; do
        [ -e "$f" ] || continue
        case "$f" in *reality443*) continue ;; esac
        grep -qE 'listen[^;]*default_server' "$f" 2>/dev/null || continue
        base=$(basename "$f")
        mv -f "$f" "${DISABLED_DIR}/${base}"
        info "Moved conflicting default site: ${f}"
    done
    for f in "${NGINX_DIR}"/sites-enabled/*.reality443-disabled "${NGINX_DIR}"/conf.d/*.reality443-disabled; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .reality443-disabled)
        mv -f "$f" "${DISABLED_DIR}/${base}"
    done
}

emit_sub_locations() {
    local spath sport2 sscheme jpath lpath ppath
    spath=$(sub_path); sport2=$(sub_port); sscheme=$(sub_scheme)
    jpath=$(sub_json_path); ppath=$(panel_path)
    for lpath in "$spath" "$jpath"; do
        [ -n "$lpath" ] || continue
        [ "$lpath" = "$ppath" ] && continue
        [ "$lpath" = "$jpath" ] && [ "$jpath" = "$spath" ] && continue
        echo "    location ${lpath}/ {"
        echo "        proxy_pass ${sscheme}://127.0.0.1:${sport2};"
        if [ "$sscheme" = "https" ]; then
            echo "        proxy_ssl_verify off;"
            echo "        proxy_ssl_server_name on;"
        fi
        echo "        proxy_http_version 1.1;"
        echo "        proxy_buffering off;"
        echo "        proxy_set_header Host \$host;"
        echo "        proxy_set_header X-Real-IP \$remote_addr;"
        echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
        echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
        echo "        proxy_connect_timeout 5s;"
        echo "        proxy_read_timeout 120s;"
        echo "    }"
        echo "    location = ${lpath} { return 301 ${lpath}/; }"
    done
}

emit_tls_common() {
    local crt="$1" key="$2"
    echo "    ssl_certificate ${crt};"
    echo "    ssl_certificate_key ${key};"
    echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    echo "    ssl_prefer_server_ciphers off;"
    echo "    ssl_session_cache shared:R443SSL:50m;"
    echo "    ssl_session_timeout 1d;"
    echo "    ssl_session_tickets off;"
    echo "    port_in_redirect off;"
    echo "    absolute_redirect off;"
    echo "    client_max_body_size 64m;"
}

emit_listen_ssl() {
    local port="$1"
    if nginx_ver_ge 1.25.1; then
        echo "    listen 127.0.0.1:${port} ssl backlog=65535;"
        echo "    http2 on;"
    else
        echo "    listen 127.0.0.1:${port} ssl http2 backlog=65535;"
    fi
}

emit_site_root() {
    if [ "$SITE_MODE" = "redirect" ] && [ -n "$SITE_TARGET" ]; then
        echo "    location / { return 301 https://${SITE_TARGET}\$request_uri; }"
    else
        echo "    root ${SITE_ROOT};"
        echo "    index index.html index.htm;"
        echo "    location / { try_files \$uri \$uri/ /index.html; }"
    fi
}

write_site_conf() {
    ensure_confd_included
    local tmp ppath pport pscheme
    tmp=$(mktemp)
    {
        echo "# reality443-managed v${SCRIPT_VERSION}"
        echo "server {"
        echo "    listen 80 default_server backlog=65535;"
        has_ipv6 && echo "    listen [::]:80 default_server backlog=65535;"
        echo "    server_name _;"
        if [ -n "$SITE_CERT" ] && [ -n "$DOMAIN" ]; then
            echo "    return 301 https://\$host\$request_uri;"
        elif [ "$SITE_MODE" = "redirect" ] && [ -n "$SITE_TARGET" ]; then
            echo "    return 301 https://${SITE_TARGET}\$request_uri;"
        else
            echo "    root ${SITE_ROOT};"
            echo "    index index.html index.htm;"
            echo "    location / { try_files \$uri \$uri/ /index.html; }"
        fi
        echo "}"
        if [ -n "$DOMAIN" ] && [ -n "$SITE_CERT" ] && [ -n "$SITE_KEY" ]; then
            echo ""
            echo "server {"
            emit_listen_ssl "$SITE_PORT"
            echo "    server_name ${DOMAIN};"
            emit_tls_common "$SITE_CERT" "$SITE_KEY"
            if [ "$PANEL_ON_SITE" = "yes" ]; then
                ppath=$(panel_path); pport=$(panel_port); pscheme=$(panel_scheme)
                if [ -n "$ppath" ]; then
                    echo "    location ${ppath}/ {"
                    echo "        proxy_pass ${pscheme}://127.0.0.1:${pport};"
                    if [ "$pscheme" = "https" ]; then
                        echo "        proxy_ssl_verify off;"
                        echo "        proxy_ssl_server_name on;"
                    fi
                    echo "        proxy_http_version 1.1;"
                    echo "        proxy_buffering off;"
                    echo "        proxy_request_buffering off;"
                    echo "        proxy_set_header Host \$host;"
                    echo "        proxy_set_header X-Real-IP \$remote_addr;"
                    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
                    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
                    echo "        proxy_set_header Upgrade \$http_upgrade;"
                    echo "        proxy_set_header Connection \"upgrade\";"
                    echo "        proxy_read_timeout 600s;"
                    echo "        proxy_send_timeout 600s;"
                    echo "        proxy_connect_timeout 5s;"
                    echo "        proxy_socket_keepalive on;"
                    echo "        proxy_redirect ~^http://[^/]+(/.*)\$ https://\$host\$1;"
                    echo "    }"
                    echo "    location = ${ppath} { return 301 ${ppath}/; }"
                fi
            fi
            if [ "$SUB_ON_SITE" = "yes" ] && ! sub_is_separate; then
                emit_sub_locations
            fi
            emit_site_root
            echo "}"
        fi
        if [ "$SUB_ON_SITE" = "yes" ] && sub_is_separate; then
            echo ""
            echo "server {"
            emit_listen_ssl "$SUB_BIND_PORT"
            echo "    server_name ${SUB_DOMAIN};"
            emit_tls_common "$SUB_CERT" "$SUB_KEY"
            emit_sub_locations
            emit_site_root
            echo "}"
        fi
    } > "$tmp"
    mkdir -p "$(dirname "$SITE_CONF")"
    if ! mv "$tmp" "$SITE_CONF" 2>/dev/null; then
        err "Could not write ${SITE_CONF}"
        rm -f "$tmp"; return 1
    fi
    return 0
}

apply_site() {
    disable_stock_default_site
    if [ -n "$SITE_CERT" ]; then
        pick_site_port || return 1
        SITE_BIND_PORT="$SITE_PORT"
    fi
    save_state
    write_site_conf || return 1
    load_inbounds
    write_stream_conf || return 1
    local bdir; bdir=$(backup_now)
    if apply_nginx "$bdir"; then return 0; fi
    err "Site configuration rolled back."
    rm -f "$SITE_CONF"
    SITE_MODE="none"; save_state
    load_inbounds; write_stream_conf >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 && { systemctl reload "$NGINX_SERVICE" 2>/dev/null || true; }
    return 1
}

install_self() {
    [ -f "$SELF_SRC" ] || return 0
    [ "$SELF_SRC" = "$INSTALL_PATH" ] && return 0
    cp -f "$SELF_SRC" "$INSTALL_PATH" 2>/dev/null || return 0
    chmod 755 "$INSTALL_PATH" 2>/dev/null || true
    ln -sf "$INSTALL_PATH" /usr/local/bin/reality443 2>/dev/null || true
    return 0
}

write_watchdog() {
    mkdir -p "$LOG_DIR" "$(dirname "$WATCHDOG_PATH")"
    cat > "$WATCHDOG_PATH" <<WDCONF
#!/usr/bin/env bash
set -uo pipefail
ROUTED_FILE="${ROUTED_FILE}"
STREAM_FILE="${STREAM_FILE}"
NGINX_CONF="${NGINX_CONF}"
LOG_FILE="${LOG_DIR}/watchdog.log"
NGINX_SERVICE="${NGINX_SERVICE}"
XUI_SERVICE="${XUI_SERVICE}"
INTERVAL=${GUARD_INTERVAL}
WDCONF
    cat >> "$WATCHDOG_PATH" <<'WDBODY'
LOCK_PATH=/run/reality443-watchdog.lock
LOG_MAX=5242880

exec 9>"$LOCK_PATH" 2>/dev/null || true
flock -n 9 2>/dev/null || exit 0

log() {
    local sz
    if [ -f "$LOG_FILE" ]; then
        sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
    fi
    { printf '%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; } 2>/dev/null || true
}

port_busy() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

trap 'log INFO "watchdog stopping"; exit 0' TERM INT
log INFO "watchdog started pid $$"

cooldown=0
while true; do
    if ! systemctl is-active --quiet "$NGINX_SERVICE"; then
        log WARN "nginx inactive - starting"
        systemctl start "$NGINX_SERVICE" >/dev/null 2>&1
    fi
    if ! systemctl is-active --quiet "$XUI_SERVICE"; then
        log WARN "x-ui inactive - starting"
        systemctl start "$XUI_SERVICE" >/dev/null 2>&1
    fi
    if [ -f "$STREAM_FILE" ] && ! grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null; then
        log ERROR "stream include missing from nginx.conf"
    fi
    if [ -f "$STREAM_FILE" ] && ! port_busy 443; then
        log ERROR "port 443 not bound - restarting nginx"
        systemctl restart "$NGINX_SERVICE" >/dev/null 2>&1
    fi
    if [ "$cooldown" -gt 0 ]; then
        cooldown=$((cooldown - 1))
    elif [ -f "$ROUTED_FILE" ] && command -v jq >/dev/null 2>&1; then
        miss=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            port_busy "$p" || miss=$((miss + 1))
        done < <(jq -r '.[]' "$ROUTED_FILE" 2>/dev/null)
        if [ "$miss" -gt 0 ]; then
            log ERROR "$miss backend port(s) down - restarting x-ui"
            systemctl restart "$XUI_SERVICE" >/dev/null 2>&1
            cooldown=10
        fi
    fi
    sleep "$INTERVAL"
done
WDBODY
    chmod 755 "$WATCHDOG_PATH"
    if ! bash -n "$WATCHDOG_PATH" 2>/dev/null; then
        err "Generated watchdog has a syntax error"
        return 1
    fi
    return 0
}

install_guard_service() {
    install_self
    write_watchdog || return 1
    cat > "$GUARD_UNIT" <<UNIT
[Unit]
Description=Reality 443 SNI Router Watchdog
After=network-online.target nginx.service ${XUI_SERVICE}.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${WATCHDOG_PATH}
Restart=always
RestartSec=10
TimeoutStopSec=15
KillMode=mixed
LimitNOFILE=1000000
LimitNPROC=1000000
Nice=-5
OOMScoreAdjust=-500
StandardOutput=journal
StandardError=journal
SyslogIdentifier=reality443

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "${GUARD_NAME}.service" >/dev/null 2>&1 || true
    systemctl restart "${GUARD_NAME}.service" >/dev/null 2>&1 || true
    systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
    systemctl enable "$XUI_SERVICE" >/dev/null 2>&1 || true
    local i
    for ((i = 0; i < 15; i++)); do
        systemctl is-active --quiet "${GUARD_NAME}.service" && return 0
        sleep 1
    done
    err "Watchdog failed to start:"
    systemctl status "${GUARD_NAME}.service" --no-pager 2>&1 | tail -n 10 >&2
    journalctl -u "${GUARD_NAME}.service" -n 12 --no-pager 2>&1 | tail -n 12 >&2
    return 1
}

collect_open_ports() {
    local p lst
    {
        xval "SELECT DISTINCT port FROM inbounds WHERE port IS NOT NULL;" 2>/dev/null
        panel_port
        sub_port
        printf '80\n443\n'
    } | grep -E '^[0-9]+$' | sort -un
}

setup_firewall_auto() {
    local -a sports=()
    mapfile -t sports < <(ssh_ports)
    if [ "${#sports[@]}" -eq 0 ]; then
        sports=(22)
        [ -n "${SSH_CONNECTION:-}" ] && sports+=("${SSH_CONNECTION##* }")
    fi
    if ! have ufw; then
        install_pkgs ufw || true
    fi
    if ! have ufw; then
        warn "ufw not available - firewall step skipped"
        return 1
    fi

    local sp failed=0
    for sp in "${sports[@]}"; do
        fw_allow "$sp" "SSH" || failed=$((failed + 1))
    done
    if [ "$failed" -gt 0 ]; then
        err "SSH rule failed - firewall left untouched to avoid lockout"
        return 1
    fi
    if ! ufw show added 2>/dev/null | grep -qE "allow[[:space:]]+${sports[0]}"; then
        err "SSH rule did not register - firewall left untouched"
        return 1
    fi

    local -a plist=()
    mapfile -t plist < <(collect_open_ports)
    local n=0
    for sp in "${plist[@]}"; do
        [ -n "$sp" ] || continue
        [ "$sp" -ge 1 ] 2>/dev/null || continue
        [ "$sp" -le 65535 ] || continue
        ufw allow "${sp}/tcp" >/dev/null 2>&1 || true
        ufw allow "${sp}/udp" >/dev/null 2>&1 || true
        n=$((n + 1))
    done
    ok "Opened ${n} port(s) from the x-ui database plus 80 and 443 (tcp+udp)"

    if ! ufw --force enable >/dev/null 2>&1; then
        err "Could not enable ufw"
        return 1
    fi
    local okssh=0
    for sp in "${sports[@]}"; do
        ufw status 2>/dev/null | grep -qE "^${sp}(/tcp)?[[:space:]]" && okssh=1
    done
    if [ "$okssh" -eq 0 ]; then
        ufw disable >/dev/null 2>&1 || true
        err "SSH port not open after enabling - firewall disabled again for safety"
        return 1
    fi
    if ! ufw status 2>/dev/null | grep -qE '^443/tcp'; then
        ufw disable >/dev/null 2>&1 || true
        err "Port 443 not open after enabling - firewall disabled again for safety"
        return 1
    fi
    ok "Firewall active - SSH ${sports[*]}, 443, and every inbound port are open"
    return 0
}


verify_live() {
    local fails=0 eff i p
    eff=$(nginx -T 2>/dev/null || true)
    printf '%s' "$eff" | grep -q 'ssl_preread_server_name' || { err "stream map missing from effective nginx config"; fails=$((fails + 1)); }
    if port_busy 443; then
        local o; o=$(port_owner 443)
        [ "$o" = "nginx" ] || [ -z "$o" ] || { err "port 443 is held by '${o}', not nginx"; fails=$((fails + 1)); }
    else
        err "nothing is listening on port 443"; fails=$((fails + 1))
    fi
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        is_routable_listen "${RI_LISTEN[$i]}" || continue
        p="${RI_PORT[$i]}"
        port_busy "$p" || { err "${RI_REMARK[$i]} not listening on ${p}"; fails=$((fails + 1)); }
    done
    [ "$fails" -eq 0 ] && return 0
    return 1
}

success_report() {
    local ppath issues="${1:-0}"
    echo
    if [ "$issues" -eq 0 ]; then
        printf '%s ✓ Installation completed successfully %s\n' "$BG_OK" "$R"
        printf '%s ✓ Configuration applied successfully %s\n' "$BG_OK" "$R"
        printf '%s ✓ Kernel and socket tuning applied %s\n' "$BG_OK" "$R"
        printf '%s ✓ 443 routing started successfully %s\n' "$BG_OK" "$R"
        printf '%s ✓ Service enabled successfully %s\n' "$BG_OK" "$R"
        printf '%s ✓ Auto-start enabled %s\n' "$BG_OK" "$R"
        printf '%s ✓ Automatic reconnect configured %s\n' "$BG_OK" "$R"
    else
        printf '%s ✗ INSTALLATION INCOMPLETE - %s check(s) failed %s\n' "$BG_ERR" "$issues" "$R"
        printf '%s ! The server is NOT serving traffic correctly yet %s\n' "$BG_WARN" "$R"
        printf '%s ! Fix the lines marked with a cross above, then run option 1 again %s\n' "$BG_WARN" "$R"
        echo
        printf '%s  Useful commands:%s\n' "$C_SLATE" "$R"
        printf '%s    nginx -t%s\n' "$C_STEEL" "$R"
        printf '%s    systemctl status nginx %s --no-pager%s\n' "$C_STEEL" "$XUI_SERVICE" "$R"
        printf '%s    journalctl -u %s -n 40 --no-pager%s\n' "$C_STEEL" "$XUI_SERVICE" "$R"
        printf '%s    ss -ltnp | grep -E ":443|:80"%s\n' "$C_STEEL" "$R"
    fi
    echo
    printf '%s  Domain      %s%s\n' "$C_TURQ" "$DOMAIN" "$R"
    if [ "$PANEL_ON_SITE" = "yes" ]; then
        ppath=$(panel_path)
        printf '%s  Panel URL   https://%s%s/%s\n' "$C_GOLD" "$DOMAIN" "$ppath" "$R"
    fi
    if [ "$SUB_ON_SITE" = "yes" ]; then
        printf '%s  Sub URL     https://%s%s/%s\n' "$C_SAND" "$SUB_DOMAIN" "$(sub_path)" "$R"
    fi
    printf '%s  Routed      %s inbound(s) on port 443%s\n' "$C_MINT" "${#SEL_IDX[@]}" "$R"
    printf '%s  Watchdog    %s%s\n' "$C_LILAC" "$(systemctl is-active "${GUARD_NAME}.service" 2>/dev/null || echo inactive)" "$R"
    printf '%s  Firewall    %s%s\n' "$C_ROSE" "$(ufw status 2>/dev/null | head -1 | sed 's/Status: //' || echo 'not installed')" "$R"
    echo
    if [ "$SUB_DOMAIN" != "$DOMAIN" ]; then
        printf '%s  Point %s, %s and every Reality SNI at this server IP.%s\n' "$C_SLATE" "$DOMAIN" "$SUB_DOMAIN" "$R"
    else
        printf '%s  Point %s and every Reality SNI at this server IP.%s\n' "$C_SLATE" "$DOMAIN" "$R"
    fi
    echo
}

do_setup() {
    header
    db_ready || { pause; return 0; }
    detect_host_mechanism
    load_state
    load_inbounds
    refresh_taken_ports

    if [ "${#RI_ID[@]}" -eq 0 ]; then
        err "No Reality inbounds found in ${DB_PATH}"
        pause; return 0
    fi

    step "Reality inbounds"
    show_table
    parse_selection
    validate_selection || { pause; return 0; }

    step "Domains"
    DOMAIN=$(ask "Main domain (site, panel, links)" v_domain "$DOMAIN")
    [ -n "$SUB_DOMAIN" ] || SUB_DOMAIN="$DOMAIN"
    SUB_DOMAIN=$(ask "Subscription domain (Enter = same)" v_domain "$SUB_DOMAIN")

    clear
    header
    step "FULL AUTOMATIC INSTALLATION"
    line_c 0 "  1/10  nginx and stream module"
    line_c 1 "  2/10  kernel and socket tuning"
    line_c 2 "  3/10  file descriptor limits"
    line_c 3 "  4/10  nginx core tuning"
    line_c 4 "  5/10  inbound consolidation"
    line_c 5 "  6/10  TLS certificate"
    line_c 6 "  7/10  camouflage site + panel"
    line_c 7 "  8/10  443 SNI routing"
    line_c 8 "  9/10  firewall"
    line_c 9 " 10/10  watchdog and auto-start"
    echo

    local bdir failed_steps=0

    step "[1/10] nginx"
    if ! install_nginx; then
        err "nginx could not be installed - cannot continue"
        pause; return 0
    fi
    sync_nginx_paths
    ok "nginx ready with stream support"
    if ! preflight_443; then
        err "Port 443 is not available - fix the conflict above and run again"
        pause; return 0
    fi

    bdir=$(backup_now)
    save_original_ports
    save_state

    step "[2/10] kernel tuning"
    apply_sysctl

    step "[3/10] limits"
    apply_limits

    step "[4/10] nginx core"
    tune_nginx_main

    step "[5/10] inbound consolidation"
    local idx i cur
    PLAN_PORT=()
    for idx in "${SEL_IDX[@]}"; do
        i=$((idx - 1)); cur="${RI_PORT[$i]}"
        if is_routable_listen "${RI_LISTEN[$i]}" && [ "$cur" -ge "$MIN_PORT" ] && [ "$cur" -le "$MAX_PORT" ]; then
            TAKEN_PORTS["$cur"]=keep
            PLAN_PORT[$i]="$cur"
        else
            if ! alloc_port "$cur"; then
                err "Could not allocate an internal port"
                pause; return 0
            fi
            PLAN_PORT[$i]="$ALLOC_PORT"
        fi
    done
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    local -a wait_ports=()
    for idx in "${SEL_IDX[@]}"; do
        i=$((idx - 1))
        if is_private_ip "${RI_LISTEN[$i]}"; then
            xsql "UPDATE inbounds SET port=${PLAN_PORT[$i]} WHERE id=${RI_ID[$i]};" || true
        else
            xsql "UPDATE inbounds SET listen='127.0.0.1', port=${PLAN_PORT[$i]} WHERE id=${RI_ID[$i]};" || true
        fi
        set_inbound_host "${RI_ID[$i]}" "$DOMAIN" "${RI_REMARK[$i]:-reality}" 443
        wait_ports+=("${PLAN_PORT[$i]}")
        ok "${RI_REMARK[$i]:-inbound} -> $(backend_ip "${RI_LISTEN[$i]}"):${PLAN_PORT[$i]}"
    done
    save_routed_ports "${wait_ports[@]}"

    step "[6/10] certificate"
    SITE_CERT=""; SITE_KEY=""
    if resolve_cert "$DOMAIN" SITE_CERT SITE_KEY; then
        cert_expired "$SITE_CERT" && warn "Certificate for ${DOMAIN} is EXPIRED - renew it"
        SITE_MODE="local"; PANEL_ON_SITE="yes"; SUB_ON_SITE="yes"
    else
        warn "No certificate for ${DOMAIN} - site will be HTTP only"
        SITE_MODE="local"; PANEL_ON_SITE="no"; SUB_ON_SITE="no"
        failed_steps=$((failed_steps + 1))
    fi
    if [ "$PANEL_ON_SITE" = "yes" ]; then
        ensure_panel_path >/dev/null
        configure_subscription
    fi
    save_state
    start_xui_and_wait "${wait_ports[@]}" || true

    step "[7/10] camouflage site"
    setup_site_content
    if [ -n "$SITE_CERT" ]; then
        pick_site_port || true
        SITE_BIND_PORT="$SITE_PORT"
    fi
    save_state
    disable_stock_default_site
    if write_site_conf; then
        ok "Site configuration written"
    else
        warn "Site configuration failed"
        failed_steps=$((failed_steps + 1))
    fi

    step "[8/10] 443 routing"
    load_inbounds
    if ! write_stream_conf || ! hook_stream_include; then
        err "nginx routing could not be built"
        pause; return 0
    fi
    if ! apply_nginx "$bdir"; then
        err "nginx rolled back - database is consolidated, fix nginx then run Sync"
        pause; return 0
    fi
    ok "nginx reloaded - SNI routing live on 443"

    step "[9/10] firewall"
    setup_firewall_auto || failed_steps=$((failed_steps + 1))

    step "[10/10] watchdog"
    if install_guard_service; then
        ok "Watchdog running, auto-start enabled"
    else
        warn "Watchdog not active - use: Services and Watchdog > Install / Repair Watchdog"
        failed_steps=$((failed_steps + 1))
    fi

    post_install_test || failed_steps=$((failed_steps + TEST_FAILS))
    success_report "$failed_steps"
    pause
}

do_sync() {
    header
    db_ready || { pause; return 0; }
    if [ ! -f "$STREAM_FILE" ]; then
        err "Nothing installed yet. Run Setup first."
        pause; return 0
    fi
    detect_host_mechanism
    load_state
    load_inbounds
    refresh_taken_ports
    sync_nginx_paths

    local -a pending=()
    local i
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        if is_routable_listen "${RI_LISTEN[$i]}" && [ "${RI_PORT[$i]}" -ge "$MIN_PORT" ] && [ "${RI_PORT[$i]}" -le "$MAX_PORT" ]; then
            continue
        fi
        pending+=("$((i + 1))")
    done

    local -a wait_ports=()
    if [ -f "$ROUTED_FILE" ]; then
        mapfile -t wait_ports < <(jq -r '.[]' "$ROUTED_FILE" 2>/dev/null || true)
    fi

    if [ "${#pending[@]}" -gt 0 ]; then
        step "Unrouted inbounds"
        show_table
        parse_selection
        if validate_selection; then
            backup_now >/dev/null
            systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
            local idx p
            for idx in "${SEL_IDX[@]}"; do
                i=$((idx - 1))
                alloc_port "" || break
                p="$ALLOC_PORT"
                if is_private_ip "${RI_LISTEN[$i]}"; then
                    xsql "UPDATE inbounds SET port=${p} WHERE id=${RI_ID[$i]};" || true
                else
                    xsql "UPDATE inbounds SET listen='127.0.0.1', port=${p} WHERE id=${RI_ID[$i]};" || true
                fi
                [ -n "$DOMAIN" ] && set_inbound_host "${RI_ID[$i]}" "$DOMAIN" "${RI_REMARK[$i]:-reality}" 443
                ok "${RI_REMARK[$i]} -> $(backend_ip "${RI_LISTEN[$i]}"):${p}"
                wait_ports+=("$p")
            done
            save_routed_ports "${wait_ports[@]}"
            start_xui_and_wait "${wait_ports[@]}" || true
            load_inbounds
        fi
    else
        ok "All Reality inbounds are already routed - regenerating the map"
    fi

    local bdir; bdir=$(backup_now)
    if ! write_stream_conf || ! hook_stream_include; then
        err "Could not rebuild the nginx map."
        pause; return 0
    fi
    apply_nginx "$bdir" && ok "Routing map rebuilt and reloaded"
    verify_live || warn "Verification reported issues - see Diagnose."
    pause
}


ssh_ports() {
    {
        ss -Hltnp 2>/dev/null | grep -i 'sshd' 2>/dev/null | grep -oE ':[0-9]+ ' 2>/dev/null | tr -d ': ' || true
        grep -hoE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | grep -oE '[0-9]+' 2>/dev/null || true
        local sc="${SSH_CONNECTION:-}"
        [ -n "$sc" ] && printf '%s\n' "${sc##* }"
        true
    } 2>/dev/null | grep -E '^[0-9]+$' 2>/dev/null | sort -un || true
}

fw_allow() {
    local port="$1" label="$2" proto="${3:-tcp}" out
    if out=$(ufw allow "${port}/${proto}" 2>&1); then
        log_write OK "ufw allow ${port}/${proto} (${label})"
        return 0
    fi
    err "Failed to allow ${port}/${proto} (${label}): ${out}"
    return 1
}





colorize_log() {
    local ln ts lvl msg
    while IFS= read -r ln; do
        ts="${ln%%|*}"
        lvl="${ln#*|}"; lvl="${lvl%%|*}"
        msg="${ln#*|*|}"
        case "$lvl" in
            OK)    printf '%s%s%s %s ✓ %s %s\n' "$C_SLATE" "$ts" "$R" "$BG_OK" "$msg" "$R" ;;
            ERROR) printf '%s%s%s %s ✗ %s %s\n' "$C_SLATE" "$ts" "$R" "$BG_ERR" "$msg" "$R" ;;
            WARN)  printf '%s%s%s %s ! %s %s\n' "$C_SLATE" "$ts" "$R" "$BG_WARN" "$msg" "$R" ;;
            *)     printf '%s%s%s %s  %s%s\n' "$C_SLATE" "$ts" "$R" "$C_STEEL" "$msg" "$R" ;;
        esac
    done
}


diagnose() {
    header
    db_ready || { pause; return 0; }
    load_state
    load_inbounds
    sync_nginx_paths

    step "Configuration"
    printf '%s  Domain            %s%s\n' "$C_TURQ" "${DOMAIN:-<unset>}" "$R"
    printf '%s  Sub domain        %s%s\n' "$C_LILAC" "${SUB_DOMAIN:-<same>}" "$R"
    printf '%s  Panel             %s://127.0.0.1:%s%s%s\n' "$C_GOLD" "$(panel_scheme)" "$(panel_port)" "$(panel_path)" "$R"
    printf '%s  Subscription      %s://127.0.0.1:%s%s%s\n' "$C_MINT" "$(sub_scheme)" "$(sub_port)" "$(sub_path)" "$R"
    printf '%s  Sub enabled       %s%s\n' "$C_SAND" "$(sub_enabled && echo yes || echo NO)" "$R"
    printf '%s  Sub URI setting   %s%s\n' "$C_ROSE" "$(get_setting subURI)" "$R"
    printf '%s  Stream file       %s%s\n' "$C_LILAC" "$([ -f "$STREAM_FILE" ] && echo present || echo MISSING)" "$R"
    printf '%s  Hooked in conf    %s%s\n' "$C_ROSE" "$(grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null && echo yes || echo NO)" "$R"
    printf '%s  SNI routes        %s%s\n' "$C_STEEL" "$(count_routed)" "$R"

    step "Kernel"
    printf '%s  congestion        %s%s\n' "$C_TURQ" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)" "$R"
    printf '%s  qdisc             %s%s\n' "$C_MINT" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?)" "$R"
    printf '%s  somaxconn         %s%s\n' "$C_GOLD" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo ?)" "$R"
    printf '%s  nginx nofile      %s%s\n' "$C_LILAC" "$(grep -i 'open files' /proc/"$(pgrep -o nginx 2>/dev/null || echo 1)"/limits 2>/dev/null | awk '{print $4}' || echo ?)" "$R"

    step "Services"
    printf '%s  x-ui              %s%s\n' "$C_TURQ" "$(systemctl is-active "$XUI_SERVICE" 2>/dev/null || echo inactive)" "$R"
    printf '%s  nginx             %s%s\n' "$C_MINT" "$(systemctl is-active "$NGINX_SERVICE" 2>/dev/null || echo inactive)" "$R"
    printf '%s  watchdog          %s%s\n' "$C_LILAC" "$(systemctl is-active "${GUARD_NAME}.service" 2>/dev/null || echo inactive)" "$R"

    step "Live checks"
    if ! nginx -t 2>/tmp/r443.diag.err; then
        err "nginx config test FAILED"
        sed -n '1,10p' /tmp/r443.diag.err >&2
    else
        ok "nginx config test passed"
    fi
    if port_busy 443; then ok "port 443 bound by $(port_owner 443)"; else err "port 443 is not bound"; fi
    local i
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
        is_routable_listen "${RI_LISTEN[$i]}" || continue
        if port_busy "${RI_PORT[$i]}"; then
            ok "${RI_REMARK[$i]} listening on ${RI_PORT[$i]}"
        else
            err "${RI_REMARK[$i]} NOT listening on ${RI_PORT[$i]}"
        fi
    done
    if [ -n "$DOMAIN" ] && [ -n "$SITE_CERT" ] && port_busy "$SITE_PORT"; then
        ok "camouflage site listening on 127.0.0.1:${SITE_PORT}"
    fi
    pause
}


clear_external_proxy() {
    local json n i id sj new cleaned=0
    json=$(q "SELECT id, stream_settings FROM inbounds;")
    n=$(printf '%s' "$json" | jq 'length')
    for ((i = 0; i < n; i++)); do
        id=$(printf '%s' "$json" | jq -r ".[$i].id")
        sj=$(printf '%s' "$json" | jq -r ".[$i].stream_settings // \"\"")
        [ -n "$sj" ] || continue
        printf '%s' "$sj" | jq -e '.externalProxy' >/dev/null 2>&1 || continue
        new=$(printf '%s' "$sj" | jq -c 'del(.externalProxy)' 2>/dev/null) || continue
        [ -n "$new" ] || continue
        xsql "UPDATE inbounds SET stream_settings='$(esc "$new")' WHERE id=${id};" || true
        cleaned=$((cleaned + 1))
    done
    [ "$cleaned" -gt 0 ] && ok "Cleared external proxy from ${cleaned} inbound(s)"
    return 0
}

unbind_loopback_inbounds() {
    local json n i id rem lst prt fixed=0
    refresh_taken_ports
    json=$(q "SELECT id, remark, listen, port FROM inbounds;")
    n=$(printf '%s' "$json" | jq 'length')
    for ((i = 0; i < n; i++)); do
        id=$(printf '%s' "$json" | jq -r ".[$i].id")
        rem=$(printf '%s' "$json" | jq -r ".[$i].remark // \"\"")
        lst=$(printf '%s' "$json" | jq -r ".[$i].listen // \"\"")
        prt=$(printf '%s' "$json" | jq -r ".[$i].port")
        [ "$lst" = "127.0.0.1" ] || continue
        if [ "$prt" -ge "$MIN_PORT" ] && [ "$prt" -le "$MAX_PORT" ] 2>/dev/null; then
            xsql "UPDATE inbounds SET listen='' WHERE id=${id};" || true
            ok "'${rem}' unbound from loopback - now reachable on port ${prt}"
            fixed=$((fixed + 1))
        fi
    done
    [ "$fixed" -eq 0 ] && return 0
    warn "${fixed} inbound(s) kept their internal port but now listen on all interfaces"
    return 0
}

reopen_all_inbound_ports() {
    have ufw || return 0
    ufw status 2>/dev/null | grep -qi '^Status: active' || return 0
    local -a plist=()
    mapfile -t plist < <(collect_open_ports)
    local sp n=0
    for sp in "${plist[@]}"; do
        [ -n "$sp" ] || continue
        [ "$sp" -ge 1 ] 2>/dev/null || continue
        [ "$sp" -le 65535 ] || continue
        ufw allow "${sp}/tcp" >/dev/null 2>&1 || true
        ufw allow "${sp}/udp" >/dev/null 2>&1 || true
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && ok "Firewall reopened for ${n} restored port(s)"
    return 0
}

restore_inbounds() {
    db_ready || { warn "Database unreachable - inbounds not restored"; return 1; }
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true

    if [ -f "$PORTS_FILE" ]; then
        local n i id lst prt
        n=$(jq 'length' "$PORTS_FILE" 2>/dev/null || echo 0)
        for ((i = 0; i < n; i++)); do
            id=$(jq -r ".[$i].id" "$PORTS_FILE")
            lst=$(jq -r ".[$i].listen // \"\"" "$PORTS_FILE")
            prt=$(jq -r ".[$i].port" "$PORTS_FILE")
            [ -n "$id" ] || continue
            xsql "UPDATE inbounds SET listen='$(esc "$lst")', port=${prt} WHERE id=${id};" || true
        done
        ok "Restored original listen address and port for ${n} inbound(s)"
    else
        warn "No original-ports record found"
    fi

    clear_external_proxy

    local hn=0 hid d c
    if [ -f "$HOSTS_FILE" ]; then
        while IFS= read -r hid; do
            [ -n "$hid" ] || continue
            [[ "$hid" =~ ^[0-9]+$ ]] || continue
            xsql "DELETE FROM hosts WHERE id=${hid};" || true
            hn=$((hn + 1))
        done < <(jq -r '.[]' "$HOSTS_FILE" 2>/dev/null)
    fi
    for d in "$DOMAIN" "$SUB_DOMAIN"; do
        [ -n "$d" ] || continue
        c=$(xval "SELECT COUNT(*) FROM hosts WHERE address='$(esc "$d")';" 2>/dev/null || echo 0)
        [ -n "$c" ] || c=0
        if [ "$c" -gt 0 ]; then
            xsql "DELETE FROM hosts WHERE address='$(esc "$d")';" || true
            hn=$((hn + c))
        fi
    done
    if [ "$hn" -gt 0 ]; then
        ok "Removed ${hn} host row(s) created by this script"
    else
        info "No host rows to remove"
    fi

    unbind_loopback_inbounds
    reopen_all_inbound_ports

    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
    sleep 3
    if systemctl is-active --quiet "$XUI_SERVICE"; then
        ok "x-ui restarted - inbounds are live again"
    else
        err "x-ui did not start - run: systemctl status ${XUI_SERVICE}"
    fi

    local json n2 i2 rem2 lst2 prt2
    json=$(q "SELECT remark, listen, port FROM inbounds WHERE enable=1 OR enable IS NULL;")
    n2=$(printf '%s' "$json" | jq 'length')
    echo
    step "Inbound state after restore"
    for ((i2 = 0; i2 < n2; i2++)); do
        rem2=$(printf '%s' "$json" | jq -r ".[$i2].remark // \"\"")
        lst2=$(printf '%s' "$json" | jq -r ".[$i2].listen // \"\"")
        prt2=$(printf '%s' "$json" | jq -r ".[$i2].port")
        if port_busy "$prt2"; then
            ok "${rem2}  ${lst2:-0.0.0.0}:${prt2}  listening"
        else
            err "${rem2}  ${lst2:-0.0.0.0}:${prt2}  NOT listening"
        fi
    done
    return 0
}

do_uninstall() {
    header
    step "Full uninstall"
    line_c 0 "  - stop and disable the watchdog service"
    line_c 1 "  - remove systemd units and drop-ins"
    line_c 2 "  - remove all nginx files created by this script"
    line_c 3 "  - restore original inbound ports"
    line_c 4 "  - remove host rows created by this script"
    line_c 5 "  - remove sysctl, limits and cron entries"
    line_c 6 "  - remove state, logs and backups"
    echo
    local c; c=$(ask "Proceed with full uninstall? [y/N]" v_yn "no")
    [ "$c" = "yes" ] || { warn "Cancelled."; pause; return 0; }
    local wipe; wipe=$(ask "Also delete website files in ${SITE_ROOT}? [y/N]" v_yn "no")

    load_state
    sync_nginx_paths
    backup_now >/dev/null

    systemctl stop "${GUARD_NAME}.service" >/dev/null 2>&1 || true
    systemctl disable "${GUARD_NAME}.service" >/dev/null 2>&1 || true
    rm -f "$GUARD_UNIT"
    rm -f /etc/systemd/system/"${NGINX_SERVICE}".service.d/reality443-limits.conf
    rm -f /etc/systemd/system/"${XUI_SERVICE}".service.d/reality443-limits.conf
    rmdir /etc/systemd/system/"${NGINX_SERVICE}".service.d 2>/dev/null || true
    rmdir /etc/systemd/system/"${XUI_SERVICE}".service.d 2>/dev/null || true
    rm -f /etc/systemd/system.conf.d/reality443-limits.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "Systemd units removed"

    if crontab -l >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v 'reality443\|reality-443' | crontab - 2>/dev/null || true
    fi
    rm -f /etc/cron.d/reality443 2>/dev/null || true
    ok "Cron entries removed"

    step "Restoring inbounds"
    restore_inbounds || true

    unhook_stream_include
    rm -f "$STREAM_FILE" "$SITE_CONF" "$NGINX_TUNE"
    local f base
    if [ -d "$DISABLED_DIR" ]; then
        for f in "$DISABLED_DIR"/*; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            if [ "$base" = "default.conf" ]; then
                mv -f "$f" "${NGINX_DIR}/conf.d/${base}"
            else
                mkdir -p "${NGINX_DIR}/sites-enabled"
                mv -f "$f" "${NGINX_DIR}/sites-enabled/${base}"
            fi
        done
        rmdir "$DISABLED_DIR" 2>/dev/null || true
        ok "Original nginx sites restored"
    fi
    ok "nginx files removed"

    rm -f "$SYSCTL_FILE" "$LIMITS_FILE" /etc/modules-load.d/reality443.conf
    sysctl --system >/dev/null 2>&1 || true
    ok "Kernel tuning reverted"

    [ "$wipe" = "yes" ] && [ -d "$SITE_ROOT" ] && { rm -rf "${SITE_ROOT:?}"; ok "Website files deleted"; }

    if have nginx; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null || true
            ok "nginx reloaded"
        else
            err "nginx config invalid after removal - check manually"
        fi
    fi

    rm -f "$STATE_FILE" "$PORTS_FILE" "$ROUTED_FILE" "$HOSTS_FILE" "$LOCK_FILE" "$WATCHDOG_PATH"
    rm -f /run/reality443-watchdog.lock
    rm -rf "$LOG_DIR"
    rm -f /usr/local/bin/reality443
    DOMAIN=""; SITE_MODE="none"; SITE_CERT=""; SITE_KEY=""
    PANEL_ON_SITE="no"; SUB_ON_SITE="no"
    SUB_DOMAIN=""; SUB_CERT=""; SUB_KEY=""; SUB_BIND_PORT=""

    echo
    printf '%s ✓ Uninstall completed successfully %s\n' "$BG_OK" "$R"
    printf '%s ✓ System restored to pre-install state %s\n' "$BG_OK" "$R"
    echo
    printf '%s  Backups kept at %s%s\n' "$C_SLATE" "$BACKUP_ROOT" "$R"
    printf '%s  Script binary kept at %s%s\n' "$C_SLATE" "$INSTALL_PATH" "$R"
    echo
    pause
}


restart_services() {
    header
    step "Restarting services"
    systemctl restart "$XUI_SERVICE" >/dev/null 2>&1 && ok "x-ui restarted" || err "x-ui restart failed"
    systemctl restart "$NGINX_SERVICE" >/dev/null 2>&1 && ok "nginx restarted" || err "nginx restart failed"
    if systemctl list-unit-files "${GUARD_NAME}.service" >/dev/null 2>&1; then
        systemctl restart "${GUARD_NAME}.service" >/dev/null 2>&1 && ok "watchdog restarted" || warn "watchdog not installed"
    fi
    echo
    printf '%s  x-ui      %s%s\n' "$C_TURQ" "$(systemctl is-active "$XUI_SERVICE" 2>/dev/null || echo inactive)" "$R"
    printf '%s  nginx     %s%s\n' "$C_MINT" "$(systemctl is-active "$NGINX_SERVICE" 2>/dev/null || echo inactive)" "$R"
    printf '%s  watchdog  %s%s\n' "$C_LILAC" "$(systemctl is-active "${GUARD_NAME}.service" 2>/dev/null || echo inactive)" "$R"
    pause
}

do_rollback() {
    header
    if [ ! -e "${BACKUP_ROOT}/latest" ]; then
        err "No backup found."
        pause; return 0
    fi
    local dir c
    dir=$(readlink -f "${BACKUP_ROOT}/latest")
    step "Rollback"
    info "Restoring from ${dir}"
    c=$(ask "Restore database and nginx config? [y/N]" v_yn "no")
    [ "$c" = "yes" ] || { warn "Cancelled."; pause; return 0; }
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    [ -f "${dir}/x-ui.db" ] && cp -a "${dir}/x-ui.db" "$DB_PATH"
    restore_nginx_from "$dir"
    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
    apply_nginx "" && ok "Rollback completed"
    pause
}

main_menu() {
    while true; do
        header
        line_c 0 "  1) Install  -  full automatic setup"
        line_c 1 "  2) Add New Inbounds to 443"
        line_c 2 "  3) Status and Diagnostics"
        line_c 3 "  4) Restart Services"
        line_c 4 "  5) Rollback Last Change"
        line_c 5 "  6) Uninstall Everything"
        line_c 6 "  0) Exit"
        local ch
        printf '%s  Choice%s: ' "$(next_c)" "$R"
        IFS= read -r ch || ch=0
        case "$ch" in
            1) do_setup ;;
            2) do_sync ;;
            3) diagnose ;;
            4) restart_services ;;
            5) do_rollback ;;
            6) do_uninstall ;;
            0) clear; exit 0 ;;
            *) err "Pick a number from the list."; pause ;;
        esac
    done
}

main() {
    require_root
    mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$LOG_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    acquire_lock || exit 1

    ensure_deps
    sync_nginx_paths
    load_state

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --site) SITE_SRC_ARG="${2:-}"; shift 2 || shift ;;
            *) break ;;
        esac
    done

    case "${1:-}" in
        --setup)     do_setup; exit 0 ;;
        --install)   do_setup; exit 0 ;;
        --sync)      do_sync; exit 0 ;;
        --uninstall) do_uninstall; exit 0 ;;
        --rollback)  do_rollback; exit 0 ;;
        --diagnose)  diagnose; exit 0 ;;
        --version)   printf 'reality-443 v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    esac

    if ! is_installed; then
        clear
        header
        printf '%s ! No installation detected %s\n\n' "$BG_WARN" "$R"
        line_c 0 "  Full automatic setup starts in 6 seconds."
        line_c 1 "  Press any key to open the menu instead."
        echo
        local _k=""
        if [ -t 0 ] && read -r -n 1 -t 6 _k 2>/dev/null; then
            echo
            info "Opening menu"
        else
            echo
            do_setup
        fi
    fi

    main_menu
}

main "$@"
# END_OF_SCRIPT
