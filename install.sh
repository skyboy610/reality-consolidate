#!/usr/bin/env bash
# reality-443.sh - Consolidate 3x-ui Reality inbounds behind a single public
# port 443 using nginx stream + ssl_preread (SNI routing, no TLS termination).
set -euo pipefail

SCRIPT_VERSION="4.0.0"

# ---------------------------------------------------------------------------
# Paths / services
# ---------------------------------------------------------------------------
DB_PATH="${DB_PATH:-/etc/x-ui/x-ui.db}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
BACKUP_ROOT="${BACKUP_ROOT:-/etc/reality443/backups}"
STATE_DIR="${STATE_DIR:-/etc/reality443}"
STATE_FILE="${STATE_DIR}/state.json"
STREAM_FILE="${NGINX_DIR}/stream-reality443.conf"
SITE_CONF="${SITE_CONF:-${NGINX_DIR}/conf.d/reality443-site.conf}"
SITE_ROOT="${SITE_ROOT:-/var/www/reality443}"
SITE_PORT="${SITE_PORT:-8081}"          # internal HTTPS port the site listens on
CERT_SEARCH_DIRS="/root/cert /etc/letsencrypt/live /root/.acme.sh /etc/ssl/private /opt/cert"
XUI_SERVICE="${XUI_SERVICE:-x-ui}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"

MARK_BEGIN="# BEGIN reality443"
MARK_END="# END reality443"

MIN_PORT=10001
MAX_PORT=19999

DEFAULT_PANEL_PORT=2053
DEFAULT_SUB_PORT=2096

# ---------------------------------------------------------------------------
# State (persisted in STATE_FILE)
# ---------------------------------------------------------------------------
PUBLIC_HOST=""
PANEL_HOST=""
SUB_HOST=""
PANEL_ROUTE="no"
SUB_ROUTE="no"
SITE_MODE="none"     # none | local | redirect
SITE_TARGET=""       # redirect destination domain (no scheme)
SITE_DOMAIN=""       # domain the TLS cert belongs to (site's SNI on 443)
SITE_BIND_PORT=""    # actual free loopback port the site listens on
PANEL_ON_SITE="no"   # serve the panel under the site domain at its base path
SITE_CERT=""         # fullchain path
SITE_KEY=""          # private key path

# ---------------------------------------------------------------------------
# Runtime tables
# ---------------------------------------------------------------------------
declare -a RI_ID=() RI_REMARK=() RI_LISTEN=() RI_PORT=() RI_PROTO=() RI_SNI=() RI_SNIS=() RI_NET=() RI_STREAM=()
declare -A TAKEN_PORTS=()
HOST_MECHANISM=""
PROMPT_IDX=0

# ---------------------------------------------------------------------------
# Palette - unusual 256-colour tones, one per line.
# Green / red / orange are reserved for success / error / warning only.
# ---------------------------------------------------------------------------
R=$'\033[0m'
C_OLIVE=$'\033[38;5;107m'
C_PINK=$'\033[38;5;218m'
C_CHERRY=$'\033[38;5;132m'
C_CHOC=$'\033[38;5;137m'
C_PURPLE=$'\033[38;5;146m'
C_TURQ=$'\033[38;5;80m'
C_BLUE=$'\033[38;5;152m'
C_GOLD=$'\033[38;5;180m'
C_SLATE=$'\033[38;5;110m'
C_WHITE=$'\033[38;5;255m'
C_GRAY=$'\033[38;5;245m'

C_OK=$'\033[38;5;40m'
C_ERR=$'\033[38;5;196m'
C_WARN=$'\033[38;5;208m'
BG_OK=$'\033[48;5;40m'$'\033[38;5;232m'
BG_ERR=$'\033[48;5;196m'$'\033[38;5;255m'
BG_WARN=$'\033[48;5;208m'$'\033[38;5;232m'

PAL=("$C_OLIVE" "$C_PINK" "$C_CHERRY" "$C_CHOC" "$C_PURPLE" "$C_TURQ" "$C_BLUE" "$C_GOLD" "$C_SLATE")

line_c() { local i="$1"; shift; printf '%s%s%s\n' "${PAL[$((i % ${#PAL[@]}))]}" "$*" "$R"; }
next_c() { printf '%s' "${PAL[$((PROMPT_IDX % ${#PAL[@]}))]}"; PROMPT_IDX=$((PROMPT_IDX + 1)); }

ok()   { printf '%s OK %s %s%s%s\n'   "$BG_OK"   "$R" "$C_OK"   "$*" "$R" >&2; }
err()  { printf '%s FAIL %s %s%s%s\n' "$BG_ERR"  "$R" "$C_ERR"  "$*" "$R" >&2; }
warn() { printf '%s WARN %s %s%s%s\n' "$BG_WARN" "$R" "$C_WARN" "$*" "$R" >&2; }
info() { printf '%s%s%s\n' "$C_GRAY" "$*" "$R" >&2; }
pause() { local _x; printf '%s\nPress Enter to continue...%s' "$C_WHITE" "$R"; read -r _x || true; }

# ---------------------------------------------------------------------------
# Header + status banner
# ---------------------------------------------------------------------------
header() {
  clear
  local -a art=(
'████  █████  ███  █     █████ █████ █   █'
'█  █  █     █   █ █       █     █    █ █ '
'████  ████  █████ █       █     █     █  '
'█ █   █     █   █ █       █     █     █  '
'█  █  █████ █   █ █████ █████   █     █  '
  )
  local i=0 l
  for l in "${art[@]}"; do line_c "$i" "$l"; i=$((i + 1)); done
  printf '%sReality on 443  -  SNI router for 3x-ui   v%s%s\n\n' "$C_WHITE" "$SCRIPT_VERSION" "$R"
  banner
}

banner_row() {
  local label="$1" state="$2" note="${3:-}"
  local bg text
  case "$state" in
    ok)   bg="$BG_OK";   text="INSTALLED" ;;
    warn) bg="$BG_WARN"; text="PARTIAL" ;;
    *)    bg="$BG_ERR";  text="NOT INSTALLED" ;;
  esac
  printf '%s %-14s %-14s%s' "$bg" "$label" "$text" "$R"
  [ -n "$note" ] && printf ' %s%s%s' "$C_GRAY" "$note" "$R"
  printf '\n'
}

banner() {
  load_state 2>/dev/null || true
  local n_state="bad" s_state="bad" n_note="" s_note=""
  if have nginx; then
    case "$(stream_state)" in
      static) n_state="ok"; n_note="stream built in" ;;
      dynamic)
        if find_stream_so >/dev/null 2>&1; then n_state="ok"; n_note="stream module found"
        else n_state="warn"; n_note="stream .so not installed"; fi ;;
      *) n_state="warn"; n_note="no stream module" ;;
    esac
  fi
  if [ -f "$STREAM_FILE" ] && grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null; then
    s_state="ok"
    s_note="$(count_routed) route(s) on 443"
  fi
  banner_row "NGINX" "$n_state" "$n_note"
  banner_row "443 ROUTING" "$s_state" "$s_note"
  local site_state="bad" site_note="no site"
  if [ -f "$SITE_CONF" ]; then
    site_state="ok"
    if [ -n "$SITE_DOMAIN" ]; then
      site_note="https://${SITE_DOMAIN}"
    else
      site_note="http only (no cert)"
    fi
  fi
  banner_row "SITE" "$site_state" "$site_note"
  local fw_state="bad" fw_note="not active"
  if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    fw_state="ok"; fw_note="ufw active"
  fi
  banner_row "FIREWALL" "$fw_state" "$fw_note"
  echo
}

count_routed() {
  local n
  [ -f "$STREAM_FILE" ] || { echo 0; return; }
  # grep -c prints 0 AND exits 1 on no match, so "|| echo 0" would emit "0\n0".
  n=$(grep -cE '^[[:space:]]+"' "$STREAM_FILE" 2>/dev/null) || true
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Emitting "listen [::]:..." on a host without IPv6 makes nginx -t fail with
# "Address family not supported by protocol", so every IPv6 listen line is
# gated on this.
has_ipv6() {
  [ -f /proc/net/if_inet6 ] || return 1
  [ -s /proc/net/if_inet6 ] || return 1
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' || return 1
  return 0
}

# True if the address is a private/RFC1918 IP (a GRE/WireGuard tunnel address).
# Such inbounds keep their listen IP - we still reassign the port and route to
# "<that IP>:<newport>" instead of 127.0.0.1, because the inbound is reachable
# on a tunnel interface, not loopback.
# True if an inbound's remark marks it as a tunnel (contains "tunnel", any case).
is_tunnel_remark() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *tunnel*) return 0 ;;
    *) return 1 ;;
  esac
}

is_private_ip() {
  local ip="$1"
  case "$ip" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

# The backend address nginx should proxy an inbound to: its own tunnel IP if it
# has one, otherwise loopback.
backend_ip() {
  local listen="$1"
  if is_private_ip "$listen"; then printf '%s\n' "$listen"; else printf '127.0.0.1\n'; fi
}

# An inbound is routable once it listens on loopback OR a tunnel IP.
is_routable_listen() {
  [ "$1" = "127.0.0.1" ] && return 0
  is_private_ip "$1" && return 0
  return 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root. Try: sudo bash $0"
    exit 1
  fi
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
         DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    *)   err "No supported package manager found. Install manually: $*"; return 1 ;;
  esac
}

ensure_deps() {
  local missing=()
  have sqlite3 || missing+=(sqlite3)
  have jq || missing+=(jq)
  have ss || missing+=(iproute2)
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Installing missing dependencies: ${missing[*]}"
    install_pkgs "${missing[@]}" >/dev/null 2>&1 || install_pkgs "${missing[@]}" || true
  fi
  local fatal=0
  have sqlite3 || { err "sqlite3 is required but could not be installed."; fatal=1; }
  have jq || { err "jq is required but could not be installed."; fatal=1; }
  [ "$fatal" -eq 0 ] || exit 1
}

# ---------------------------------------------------------------------------
# nginx install / stream module
# ---------------------------------------------------------------------------
# nginx may be built with a prefix other than /etc/nginx (or the package may be
# installed while its config tree is missing). Ask the binary where its config
# actually lives and re-point every derived path at it.
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
    info "Using nginx config path: ${NGINX_CONF}"
  fi
  mkdir -p "$NGINX_DIR" "${NGINX_DIR}/conf.d"
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

# Locates ngx_stream_module.so. Distributions disagree on where it lands, so
# check the compiled-in modules-path, then the usual suspects, then fall back
# to an actual filesystem search. Prints the path, or nothing if absent.
STREAM_SO_CACHE=""
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

stream_module_already_loaded() {
  local d
  grep -qE 'load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" 2>/dev/null && return 0
  for d in "$NGINX_DIR/modules-enabled" "$NGINX_DIR/conf.d"; do
    [ -d "$d" ] || continue
    grep -RqE 'load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$d" 2>/dev/null && return 0
  done
  return 1
}

# nginx refuses to start if the same module is loaded twice. If our injected
# line is the duplicate, drop it from nginx.conf (the distribution's own
# modules-enabled entry stays).
drop_our_load_module() {
  grep -qE '^load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" 2>/dev/null || return 1
  local tmp; tmp=$(mktemp)
  grep -vE '^load_module[[:space:]]+[^;]*ngx_stream_module\.so' "$NGINX_CONF" > "$tmp"
  mv "$tmp" "$NGINX_CONF"
  warn "Removed a duplicate load_module line that nginx rejected."
  return 0
}

install_nginx() {
  if ! have nginx; then
    info "Installing nginx..."
    if [ "$(pkg_mgr)" = "apt" ]; then
      install_pkgs nginx libnginx-mod-stream || return 1
    else
      install_pkgs nginx || return 1
    fi
    have nginx || { err "nginx installation failed."; return 1; }
    ok "nginx installed."
  else
    ok "nginx already present."
  fi

  sync_nginx_paths
  if [ ! -f "$NGINX_CONF" ]; then
    warn "${NGINX_CONF} is missing - reinstalling nginx to restore its config."
    case "$(pkg_mgr)" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall nginx-common nginx >/dev/null 2>&1 || true ;;
      dnf|yum) install_pkgs nginx >/dev/null 2>&1 || true ;;
    esac
    sync_nginx_paths
  fi
  if [ ! -f "$NGINX_CONF" ]; then
    # Last resort: write a minimal but valid nginx.conf so we have something to
    # hook the stream block into.
    warn "Still no nginx.conf - creating a minimal one at ${NGINX_CONF}."
    mkdir -p "$NGINX_DIR" "${NGINX_DIR}/conf.d"
    cat > "$NGINX_CONF" <<'NGCONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    include /etc/nginx/conf.d/*.conf;
}
NGCONF
    [ -f "${NGINX_DIR}/mime.types" ] || printf 'types {\n    text/html html htm;\n    text/css css;\n    application/javascript js;\n    image/png png;\n    image/jpeg jpg jpeg;\n    image/svg+xml svg;\n}\n' > "${NGINX_DIR}/mime.types"
    mkdir -p /var/log/nginx
  fi
  [ -f "$NGINX_CONF" ] || { err "Cannot create ${NGINX_CONF}."; return 1; }

  local st so
  st=$(stream_state)

  # "static" means it is baked into the binary and always available.
  if [ "$st" = "static" ]; then
    ok "nginx stream module: built in"
    systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
    return 0
  fi

  # Either declared dynamic, or not declared at all. Both cases can be solved
  # by the distribution's separate stream-module package, so try that first
  # before giving up.
  so=$(find_stream_so || true)
  if [ -z "$so" ]; then
    case "$(pkg_mgr)" in
      apt) info "stream module file not present - installing libnginx-mod-stream..."
           install_pkgs libnginx-mod-stream || true ;;
      dnf|yum) info "stream module file not present - installing nginx-mod-stream..."
           install_pkgs nginx-mod-stream || true ;;
    esac
    so=$(find_stream_so || true)
  fi

  if [ -z "$so" ]; then
    st=$(stream_state)
    if [ "$st" = "static" ]; then
      ok "nginx stream module: built in"
      systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
      return 0
    fi
    err "Could not find or install ngx_stream_module.so on this system."
    err "nginx -V says: $(nginx -V 2>&1 | tr ' ' '\n' | grep -E 'with-stream|modules-path' | tr '\n' ' ')"
    err "Install your distribution's nginx stream module package, then re-run."
    return 1
  fi

  # -R (not -r): on Debian/Ubuntu modules-enabled/*.conf are symlinks into
  # /usr/share/nginx/modules-available, and -r silently skips symlinks - which
  # made an earlier version inject a duplicate load_module and break nginx -t.
  if stream_module_already_loaded; then
    info "stream module already loaded by an existing load_module directive."
  else
    info "Adding load_module directive for ${so}"
    local tmp; tmp=$(mktemp)
    { printf 'load_module %s;\n' "$so"; cat "$NGINX_CONF"; } > "$tmp"
    mv "$tmp" "$NGINX_CONF"
  fi

  systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || true
  ok "nginx stream module: dynamic (${so})"
  return 0
}

http_binds_443() {
  grep -rhE '^[[:space:]]*listen[[:space:]]+.*\b443\b' \
    "$NGINX_DIR/sites-enabled" "$NGINX_DIR/conf.d" "$NGINX_CONF" 2>/dev/null \
    | grep -v 'reality443' | grep -q . || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
esc() { printf '%s' "$1" | sed "s/'/''/g"; }
q()   { sqlite3 -json "$DB_PATH" "$1"; }
# All writes go through xsql: a 5s busy-timeout waits out x-ui's lock instead of
# silently racing it, and a WAL checkpoint flushes the change into the main DB
# file so the panel/xray actually see it.
# .timeout is passed as a -cmd DOT-COMMAND (not inline SQL): inline ".timeout"
# swallows the following statement, and inline "PRAGMA busy_timeout" echoes its
# value into the output. As a -cmd flag it does neither - it just waits out
# x-ui's lock silently.
#
# Write helper: runs a write statement then flushes WAL into the main DB file
# so the panel/xray actually see the change. Use xsql ONLY for writes.
xsql() {
  sqlite3 -cmd ".timeout 5000" "$DB_PATH" "$1" >/dev/null 2>&1
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  return 0
}

# Read helper: returns a clean scalar/plain value (no PRAGMA noise). Use for
# SELECTs whose result is captured into a variable.
xval() {
  sqlite3 -cmd ".timeout 5000" "$DB_PATH" "$1"
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
  if [ "$exists" -gt 0 ]; then
    xsql "UPDATE settings SET value='${ev}' WHERE key='${ek}';"
  else
    xsql "INSERT INTO settings (key, value) VALUES ('${ek}', '${ev}');"
  fi
}

panel_port() { local p; p=$(get_setting webPort); [ -n "$p" ] || p="$DEFAULT_PANEL_PORT"; printf '%s\n' "$p"; }
# x-ui's base path, e.g. "/xpanel/". Normalised to /xxx (no trailing slash);
# empty when the panel sits at the web root.
panel_path() {
  local v; v=$(get_setting webBasePath)
  v="${v%/}"
  [ -n "$v" ] && [ "${v#/}" = "$v" ] && v="/$v"
  printf '%s\n' "$v"
}
sub_path() {
  local v; v=$(get_setting subPath)
  v="${v%/}"
  [ -n "$v" ] && [ "${v#/}" = "$v" ] && v="/$v"
  printf '%s\n' "$v"
}
sub_port()   { local p; p=$(get_setting subPort); [ -n "$p" ] || p="$DEFAULT_SUB_PORT"; printf '%s\n' "$p"; }
panel_tls()  { [ -n "$(get_setting webCertFile)" ] && return 0 || return 1; }
sub_tls()    { [ -n "$(get_setting subCertFile)" ] && return 0 || return 1; }

# Tunnel inbounds (Reality on a private IP): infrastructure for reverse/GRE.
# Their listen/port are NEVER rewritten, and they are NEVER routed on 443.
# They DO get a host row (private IP + their own real port) so the panel's
# subscription Listen Domain does not overwrite the address shown in configs.
declare -a TUN_ID=() TUN_REMARK=() TUN_LISTEN=() TUN_PORT=()

load_inbounds() {
  RI_ID=(); RI_REMARK=(); RI_LISTEN=(); RI_PORT=(); RI_PROTO=(); RI_SNI=(); RI_SNIS=(); RI_NET=(); RI_STREAM=()
  TUN_ID=(); TUN_REMARK=(); TUN_LISTEN=(); TUN_PORT=()
  SKIPPED_TUNNELS=0
  local json n i row sec __lst __rem
  json=$(q "SELECT id, remark, listen, port, protocol, stream_settings FROM inbounds WHERE enable=1 OR enable IS NULL;")
  n=$(printf '%s' "$json" | jq 'length')
  for ((i = 0; i < n; i++)); do
    row=$(printf '%s' "$json" | jq -c ".[$i]")
    sec=$(printf '%s' "$row" | jq -r '(.stream_settings // "{}") | fromjson? | .security // ""')
    [ "$sec" = "reality" ] || continue
    __lst=$(printf '%s' "$row" | jq -r '.listen // ""')
    __rem=$(printf '%s' "$row" | jq -r '.remark // ""')
    # A tunnel inbound is one whose remark contains "tunnel" (any case), or that
    # listens on a private/RFC1918 IP (a GRE/WireGuard tunnel address). These
    # carry the reverse tunnel and must NEVER be routed on 443 or rewritten.
    if is_tunnel_remark "$__rem" || is_private_ip "$__lst"; then
      TUN_ID+=("$(printf '%s' "$row" | jq -r '.id')")
      TUN_REMARK+=("$__rem")
      TUN_LISTEN+=("$__lst")
      TUN_PORT+=("$(printf '%s' "$row" | jq -r '.port')")
      SKIPPED_TUNNELS=$((SKIPPED_TUNNELS + 1))
      continue
    fi
    RI_ID+=("$(printf '%s' "$row" | jq -r '.id')")
    RI_REMARK+=("$(printf '%s' "$row" | jq -r '.remark // ""')")
    RI_LISTEN+=("$(printf '%s' "$row" | jq -r '.listen // ""')")
    RI_PORT+=("$(printf '%s' "$row" | jq -r '.port')")
    RI_PROTO+=("$(printf '%s' "$row" | jq -r '.protocol')")
    RI_SNI+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | .realitySettings.serverNames[0] // ""')")
    RI_SNIS+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | (.realitySettings.serverNames // []) | join(" ")')")
    RI_NET+=("$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | .network // "tcp"')")
    RI_STREAM+=("$(printf '%s' "$row" | jq -c '.stream_settings | fromjson')")
  done
}

# Give every tunnel inbound a host of "<its private IP>:<its real port>", so the
# subscription Listen Domain does not bleed into its config address. Never
# touches listen or port.
apply_tunnel_hosts() {
  local i done_n=0
  for ((i = 0; i < ${#TUN_ID[@]}; i++)); do
    # Only private-IP tunnels get a host (IP:realport) to fend off the sub
    # domain. Excluded loopback/public inbounds are left entirely alone.
    if is_private_ip "${TUN_LISTEN[$i]}"; then
      set_inbound_host "${TUN_ID[$i]}" "${TUN_LISTEN[$i]}" "${TUN_REMARK[$i]:-tunnel}" "${TUN_PORT[$i]}"
      done_n=$((done_n + 1))
    fi
  done
  if [ "$done_n" -gt 0 ]; then
    ok "Set host on ${done_n} tunnel inbound(s) so the subscription domain won't override them."
  fi
  return 0
}

refresh_taken_ports() {
  TAKEN_PORTS=()
  local p
  while IFS= read -r p; do [ -n "$p" ] && TAKEN_PORTS["$p"]=db; done < <(xval "SELECT port FROM inbounds;")
  TAKEN_PORTS["$(panel_port)"]=panel
  TAKEN_PORTS["$(sub_port)"]=sub
}

port_busy() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

port_owner() {
  ss -Hltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -n1 | sed 's/.*"//'
}

# Sets the global ALLOC_PORT. Must NOT be called inside $( ) - the assoc-array
# bookkeeping would be lost in the subshell and hand out duplicate ports.
ALLOC_PORT=""
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

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
load_state() {
  [ -f "$STATE_FILE" ] || return 0
  PUBLIC_HOST=$(jq -r '.public_host // ""' "$STATE_FILE")
  PANEL_HOST=$(jq -r '.panel_host // ""' "$STATE_FILE")
  SUB_HOST=$(jq -r '.sub_host // ""' "$STATE_FILE")
  PANEL_ROUTE=$(jq -r '.panel_route // "no"' "$STATE_FILE")
  SUB_ROUTE=$(jq -r '.sub_route // "no"' "$STATE_FILE")
  SITE_MODE=$(jq -r '.site_mode // "none"' "$STATE_FILE")
  SITE_TARGET=$(jq -r '.site_target // ""' "$STATE_FILE")
  SITE_DOMAIN=$(jq -r '.site_domain // ""' "$STATE_FILE")
  SITE_CERT=$(jq -r '.site_cert // ""' "$STATE_FILE")
  SITE_KEY=$(jq -r '.site_key // ""' "$STATE_FILE")
  SITE_BIND_PORT=$(jq -r '.site_bind_port // ""' "$STATE_FILE")
  PANEL_ON_SITE=$(jq -r '.panel_on_site // "no"' "$STATE_FILE")
  [ -n "$SITE_BIND_PORT" ] && SITE_PORT="$SITE_BIND_PORT"
}

save_state() {
  mkdir -p "$STATE_DIR"
  jq -n --arg ph "$PUBLIC_HOST" --arg pa "$PANEL_HOST" --arg su "$SUB_HOST" \
        --arg pr "$PANEL_ROUTE" --arg sr "$SUB_ROUTE" \
        --arg sm "$SITE_MODE" --arg st "$SITE_TARGET" \
        --arg sd "$SITE_DOMAIN" --arg sc "$SITE_CERT" --arg sk "$SITE_KEY" \
        --arg sbp "$SITE_PORT" --arg pos "$PANEL_ON_SITE" \
    '{public_host:$ph, panel_host:$pa, sub_host:$su, panel_route:$pr, sub_route:$sr,
      site_mode:$sm, site_target:$st, site_domain:$sd, site_cert:$sc, site_key:$sk,
      site_bind_port:$sbp, panel_on_site:$pos}' > "$STATE_FILE"
}

save_original_ports() {
  mkdir -p "$STATE_DIR"
  local out="${STATE_DIR}/original-ports.json"
  [ -f "$out" ] && return 0
  q "SELECT id, listen, port FROM inbounds;" > "$out"
  info "Original inbound ports saved to ${out}"
}

# ---------------------------------------------------------------------------
# Prompts - always loop, never abort the flow
# ---------------------------------------------------------------------------
ask() {
  # ask "Label" validator_fn "default"
  local label="$1" fn="$2" def="${3:-}" ans out c
  c=$(next_c)
  while true; do
    if [ -n "$def" ]; then
      printf '%s%s %s(%s)%s: ' "$c" "$label" "$C_WHITE" "$def" "$R" >&2
    else
      printf '%s%s%s: ' "$c" "$label" "$R" >&2
    fi
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && [ -n "$def" ] && ans="$def"
    if out=$("$fn" "$ans"); then printf '%s\n' "$out"; return 0; fi
  done
}

v_host() {
  local x="$1"
  if [[ "$x" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then printf '%s\n' "$x"; return 0; fi
  if [[ "$x" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local o; for o in ${x//./ }; do [ "$o" -le 255 ] || { err "Invalid IPv4 address."; return 1; }; done
    printf '%s\n' "$x"; return 0
  fi
  err "Enter a domain (sub.example.com) or an IPv4 address."
  return 1
}

v_domain() {
  local x="$1"
  if [[ "$x" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then printf '%s\n' "$x"; return 0; fi
  err "Enter a domain name, e.g. panel.example.com"
  return 1
}

# Like v_port_list but refuses an empty answer - used where leaving the field
# blank would mean "no SSH rule at all".
v_port_list_ne() {
  local x="$1" t
  if [ -z "$x" ]; then
    err "Enter at least one port."
    return 1
  fi
  for t in $x; do
    if ! [[ "$t" =~ ^[0-9]+$ ]] || [ "$t" -lt 1 ] || [ "$t" -gt 65535 ]; then
      err "'${t}' is not a valid port."
      return 1
    fi
  done
  printf '%s\n' "$x"
}

v_port_list() {
  local x="$1" t
  [ -z "$x" ] && { printf '\n'; return 0; }
  for t in $x; do
    if ! [[ "$t" =~ ^[0-9]+$ ]] || [ "$t" -lt 1 ] || [ "$t" -gt 65535 ]; then
      err "'${t}' is not a valid port."
      return 1
    fi
  done
  printf '%s\n' "$x"
}

v_site_choice() {
  case "$1" in
    1|2|3) printf '%s\n' "$1"; return 0 ;;
  esac
  err "Enter 1, 2 or 3."
  return 1
}

# Same as v_yn but a bare Enter means YES.
v_yn_default_yes() {
  local x; x=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$x" in y|yes|"") echo yes; return 0 ;; n|no) echo no; return 0 ;; esac
  err "Answer y or n."
  return 1
}

v_yn() {
  local x; x=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$x" in y|yes) echo yes; return 0 ;; n|no|"") echo no; return 0 ;; esac
  err "Answer y or n."
  return 1
}

# Port currently owned by whatever we are editing - accepted even though it
# shows up as "taken", so pressing Enter on the default never dead-ends.
PORT_ALLOW=""
v_port() {
  local x="$1" own
  if ! [[ "$x" =~ ^[0-9]+$ ]] || [ "$x" -lt 1 ] || [ "$x" -gt 65535 ]; then
    err "Port must be a number between 1 and 65535."; return 1
  fi
  if [ "$x" -eq 443 ]; then err "Port 443 is reserved for nginx here. Pick another."; return 1; fi
  if [ -n "$PORT_ALLOW" ] && [ "$x" = "$PORT_ALLOW" ]; then printf '%s\n' "$x"; return 0; fi
  if [ -n "${TAKEN_PORTS[$x]:-}" ]; then
    err "Port ${x} is already used by an inbound or another service in the panel."; return 1
  fi
  if port_busy "$x"; then
    own=$(port_owner "$x"); [ -n "$own" ] || own="an unknown process"
    err "Port ${x} is currently in use by ${own}."; return 1
  fi
  printf '%s\n' "$x"
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
show_table() {
  printf '%s %-3s %-20s %-7s %-6s %-6s %s%s\n' "$C_TURQ" \
    "#" "REMARK" "PORT" "NET" "ON443" "SNI" "$R"
  printf '%s%s%s\n' "$C_GRAY" "---------------------------------------------------------------" "$R"
  local i on
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    if is_routable_listen "${RI_LISTEN[$i]}" \
       && [ "${RI_PORT[$i]}" -ge "$MIN_PORT" ] && [ "${RI_PORT[$i]}" -le "$MAX_PORT" ]; then
      on="yes"
    else
      on="no"
    fi
    printf ' %-3s %-20s %-7s %-6s %-6s %s\n' \
      "$((i + 1))" "${RI_REMARK[$i]:0:20}" "${RI_PORT[$i]}" \
      "${RI_NET[$i]}" "$on" "${RI_SNI[$i]}"
  done
  if [ "${#TUN_ID[@]}" -gt 0 ]; then
    printf '%sExcluded as tunnels (never routed or rewritten):%s\n' "$C_GRAY" "$R"
    local j
    for ((j = 0; j < ${#TUN_ID[@]}; j++)); do
      printf '%s   id %-4s %-20s %s:%s%s\n' "$C_GRAY" \
        "${TUN_ID[$j]}" "${TUN_REMARK[$j]:0:20}" \
        "${TUN_LISTEN[$j]:-0.0.0.0}" "${TUN_PORT[$j]}" "$R"
    done
  fi
  echo
}

# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------
backup_now() {
  local ts dir
  ts=$(date +%Y%m%d-%H%M%S)
  dir="${BACKUP_ROOT}/${ts}"
  mkdir -p "$dir"
  cp -a "$DB_PATH" "${dir}/x-ui.db"
  [ -f "$NGINX_CONF" ] && cp -a "$NGINX_CONF" "${dir}/nginx.conf"
  [ -f "$STREAM_FILE" ] && cp -a "$STREAM_FILE" "${dir}/stream-reality443.conf"
  ln -sfn "$dir" "${BACKUP_ROOT}/latest"
  ok "Backup created: ${dir}"
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
}

do_rollback() {
  header
  local dir
  if [ ! -e "${BACKUP_ROOT}/latest" ]; then
    err "No backup found under ${BACKUP_ROOT}."
    pause; return 0
  fi
  dir=$(readlink -f "${BACKUP_ROOT}/latest")
  info "Restoring from: ${dir}"
  local c; c=$(ask "Restore database and nginx config from this backup? [y/N]" v_yn "no")
  [ "$c" = "yes" ] || { warn "Cancelled."; pause; return 0; }

  systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
  cp -a "${dir}/x-ui.db" "$DB_PATH"
  restore_nginx_from "$dir"
  systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
  ok "Database and nginx config restored."

  if have nginx && nginx -t >/dev/null 2>&1; then
    systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null || true
    ok "nginx reloaded."
  else
    warn "nginx config test failed after restore - check it manually."
  fi
  pause
}

# ---------------------------------------------------------------------------
# nginx stream config
# ---------------------------------------------------------------------------
write_stream_conf() {
  local default_backend="" tmp i pport sport bip site_be=""
  tmp=$(mktemp)
  # A configured camouflage site becomes the default backend: any TLS hello
  # whose SNI we do not recognise then lands on a real website instead of a
  # proxy inbound, which is exactly what a prober should see.
  if [ -f "$SITE_CONF" ] && [ -n "$SITE_DOMAIN" ]; then
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
    err "No consolidated inbound and no site - nothing to route."
    rm -f "$tmp"; return 1
  fi

  # Build the SNI -> backend list first and drop duplicates: nginx aborts with
  # 'conflicting parameter "<name>"' if the same SNI is listed twice, which
  # happens as soon as a Reality serverName equals the site/panel/sub hostname.
  local -A sni_seen=()
  local -a map_lines=()
  local sn dupes=""
  add_map_entry() {
    local name="$1" backend="$2" owner="$3"
    [ -n "$name" ] || return 0
    if [ -n "${sni_seen[$name]:-}" ]; then
      [ "${sni_seen[$name]}" = "$owner" ] || dupes="${dupes}${name} (kept ${sni_seen[$name]}, skipped ${owner})\n"
      return 0
    fi
    sni_seen[$name]="$owner"
    map_lines+=("    \"${name}\" ${backend};")
  }

  # The site is registered first so its own domain always wins the collision.
  if [ -n "$site_be" ]; then
    add_map_entry "$SITE_DOMAIN" "$site_be" "site"
  fi
  if [ "$PANEL_ROUTE" = "yes" ] && [ -n "$PANEL_HOST" ]; then
    pport=$(panel_port)
    add_map_entry "$PANEL_HOST" "127.0.0.1:${pport}" "panel"
  fi
  if [ "$SUB_ROUTE" = "yes" ] && [ -n "$SUB_HOST" ]; then
    sport=$(sub_port)
    add_map_entry "$SUB_HOST" "127.0.0.1:${sport}" "subscription"
  fi
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    if is_routable_listen "${RI_LISTEN[$i]}" && [ -n "${RI_SNI[$i]}" ]; then
      bip=$(backend_ip "${RI_LISTEN[$i]}")
      # A Reality inbound can serve many serverNames and a client link may use
      # ANY of them, so every name is mapped to that inbound's backend.
      for sn in ${RI_SNIS[$i]}; do
        add_map_entry "$sn" "${bip}:${RI_PORT[$i]}" "${RI_REMARK[$i]:-inbound}"
      done
    fi
  done
  if [ -n "$dupes" ]; then
    warn "Duplicate SNI names were skipped so nginx stays valid:"
    printf '%b' "$dupes" | sed '/^$/d' | while IFS= read -r l; do warn "  $l"; done
  fi

  {
    echo "# Generated by reality-443.sh v${SCRIPT_VERSION} - do not edit by hand."
    echo "map \$ssl_preread_server_name \$reality443 {"
    echo "    default ${default_backend};"
    printf '%s\n' "${map_lines[@]}"
    echo "}"
    echo ""
    echo "server {"
    echo "    listen 443 reuseport backlog=4096;"
    has_ipv6 && echo "    listen [::]:443 reuseport backlog=4096;"
    echo "    proxy_pass \$reality443;"
    echo "    ssl_preread on;"
    echo "    proxy_timeout 1h;"
    echo "    proxy_connect_timeout 5s;"
    # Default stream proxy_buffer_size is 16k, which throttles bulk transfers
    # through the router. 64k is the sweet spot for proxied TLS streams.
    echo "    proxy_buffer_size 64k;"
    # Keep the connection to the backend alive on half-closes so a client that
    # stops sending does not tear down an active download.
    echo "    proxy_socket_keepalive on;"
    echo "    tcp_nodelay on;"
    echo "}"
  } > "$tmp"
  mkdir -p "$(dirname "$STREAM_FILE")" 2>/dev/null || true
  if ! mv "$tmp" "$STREAM_FILE" 2>/tmp/r443.mv.err; then
    err "Could not write ${STREAM_FILE}:"
    sed -n '1,5p' /tmp/r443.mv.err >&2
    rm -f "$tmp"
    return 1
  fi
  ok "Wrote ${STREAM_FILE}"
}

find_toplevel_stream() {
  local f="$1"
  [ -f "$f" ] || return 1
  awk '
    { l=$0; sub(/#.*/,"",l) }
    depth==0 && l ~ /(^|[ \t;}])stream[ \t]*\{/ { print NR; exit }
    { for (i=1;i<=length(l);i++) { c=substr(l,i,1); if (c=="{") depth++; else if (c=="}") depth-- } }
  ' "$f"
}

# Adds our include just before the closing brace of the stream {} block that
# starts on line $2. nginx allows only ONE top-level stream block, so when the
# user already has one we must extend it rather than append a second.
insert_include_into_stream() {
  local file="$1" startline="$2" tmp
  tmp=$(mktemp)
  awk -v startline="$startline" -v inc="    include ${STREAM_FILE};" '
    BEGIN { depth = 0; inserted = 0; started = 0 }
    {
      line = $0
      plain = $0
      sub(/#.*/, "", plain)
      if (NR == startline) { started = 1 }
      if (started && !inserted) {
        n = length(plain)
        for (i = 1; i <= n; i++) {
          c = substr(plain, i, 1)
          if (c == "{") depth++
          else if (c == "}") {
            depth--
            if (depth == 0) { print inc; inserted = 1 }
          }
        }
      }
      print line
    }
    END { if (!inserted) exit 1 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  # sanity: the include must now be present exactly once
  if ! grep -qF "$STREAM_FILE" "$tmp"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$file"
  return 0
}

hook_stream_include() {
  if grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null; then return 0; fi

  local hit; hit=$(find_toplevel_stream "$NGINX_CONF" || true)
  if [ -n "$hit" ]; then
    warn "An existing top-level stream {} block was found at ${NGINX_CONF}:${hit}"
    info "Inserting our include into it instead of adding a second block."
    if insert_include_into_stream "$NGINX_CONF" "$hit"; then
      ok "Added the include to the existing stream {} block."
      return 0
    fi
    err "Could not modify the existing stream block. Add this line inside it by hand:"
    err "    include ${STREAM_FILE};"
    return 1
  fi

  if [ ! -f "$NGINX_CONF" ]; then
    err "${NGINX_CONF} does not exist - cannot add the stream block."
    return 1
  fi
  if ! {
    echo ""
    echo "$MARK_BEGIN"
    echo "stream {"
    echo "    include ${STREAM_FILE};"
    echo "}"
    echo "$MARK_END"
  } >> "$NGINX_CONF" 2>/tmp/r443.hook.err; then
    err "Could not write to ${NGINX_CONF}:"
    sed -n '1,5p' /tmp/r443.hook.err >&2
    return 1
  fi
  if ! grep -qF "$MARK_BEGIN" "$NGINX_CONF"; then
    err "Stream block did not persist in ${NGINX_CONF}."
    return 1
  fi
  ok "Added a top-level stream {} block to nginx.conf"
}

unhook_stream_include() {
  local tmp; tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0,b) { skip=1 }
    !skip { print }
    index($0,e) { skip=0 }
  ' "$NGINX_CONF" > "$tmp"
  mv "$tmp" "$NGINX_CONF"
  rm -f "$STREAM_FILE"
}

apply_nginx() {
  local backup_dir="$1"
  if ! nginx -t 2>/tmp/r443.nginx.err; then
    if grep -q 'is already loaded' /tmp/r443.nginx.err && drop_our_load_module; then
      info "Retrying nginx config test..."
    fi
  fi
  if nginx -t 2>/tmp/r443.nginx.err; then
    ok "nginx config test passed."
    if systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null; then
      ok "nginx reloaded - port 443 is now routing by SNI."
      return 0
    fi
    err "nginx config is valid but the service failed to start."
    systemctl status "$NGINX_SERVICE" --no-pager 2>&1 | tail -n 15 >&2
    return 1
  fi
  err "nginx config test failed. Restoring the previous nginx config."
  sed -n '1,40p' /tmp/r443.nginx.err >&2
  restore_nginx_from "$backup_dir"
  return 1
}

# Wait until x-ui/xray binds every expected internal port, restarting x-ui once
# if it stalls. $@ = list of ports that must become LISTEN. Returns 0 if all up.
wait_for_ports() {
  local -a want=("$@")
  local p all i restarted=0
  for ((i = 0; i < 30; i++)); do
    all=1
    for p in "${want[@]}"; do
      port_busy "$p" || { all=0; break; }
    done
    if [ "$all" -eq 1 ]; then return 0; fi
    # Halfway through, give x-ui a real restart - a plain start sometimes does
    # not reload a DB whose ports changed underneath a lingering xray process.
    if [ "$i" -eq 12 ] && [ "$restarted" -eq 0 ]; then
      restarted=1
      systemctl restart "$XUI_SERVICE" >/dev/null 2>&1 || true
    fi
    sleep 1
  done
  return 1
}

start_xui_and_wait() {
  # start_xui_and_wait PORT...  -> starts x-ui, waits for xray to bind PORTs
  systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
  if [ "$#" -gt 0 ] && wait_for_ports "$@"; then
    ok "${XUI_SERVICE} is up and xray is listening on the new port(s)."
    return 0
  fi
  # No ports given, or they never came up: fall back to a status check.
  if systemctl is-active --quiet "$XUI_SERVICE"; then
    if [ "$#" -gt 0 ]; then
      warn "${XUI_SERVICE} is running but xray has not bound all expected ports yet."
      warn "If configs do not connect, run: systemctl restart ${XUI_SERVICE}"
    else
      ok "${XUI_SERVICE} restarted."
    fi
    return 0
  fi
  err "${XUI_SERVICE} failed to start - check 'systemctl status ${XUI_SERVICE}'."
  return 1
}

# ---------------------------------------------------------------------------
# Verification - prove 443 is really routing before claiming success
# ---------------------------------------------------------------------------
verify_live() {
  local fails=0 eff i p

  printf '\n%sVerification%s\n' "$C_PURPLE" "$R"

  # 1. Is our stream block actually part of the effective configuration?
  eff=$(nginx -T 2>/dev/null || true)
  if printf '%s' "$eff" | grep -q 'ssl_preread_server_name'; then
    ok "stream map is present in the effective nginx config."
  else
    err "nginx -T does not contain our stream map."
    err "The stream {} block is missing from ${NGINX_CONF} - nothing is listening on 443."
    fails=$((fails + 1))
  fi

  # 2. Is anything actually bound to :443?
  if port_busy 443; then
    local o; o=$(port_owner 443)
    if [ "$o" = "nginx" ] || [ -z "$o" ]; then
      ok "port 443 is bound${o:+ by ${o}}."
    else
      err "port 443 is bound by '${o}', not nginx."
      fails=$((fails + 1))
    fi
  else
    err "nothing is listening on port 443."
    fails=$((fails + 1))
  fi

  # 3. Is xray actually listening on every internal port we assigned?
  #    Tunnel-IP inbounds bind their tunnel address, so a plain :port check on
  #    loopback would miss them - match on the port alone via "ss".
  local bip
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    is_routable_listen "${RI_LISTEN[$i]}" || continue
    p="${RI_PORT[$i]}"
    bip=$(backend_ip "${RI_LISTEN[$i]}")
    if port_busy "$p"; then
      ok "${RI_REMARK[$i]} is listening on ${bip}:${p}"
    else
      err "${RI_REMARK[$i]} is NOT listening on ${bip}:${p} - check 'journalctl -u ${XUI_SERVICE}'."
      fails=$((fails + 1))
    fi
  done

  if [ "$fails" -eq 0 ]; then
    ok "All checks passed - 443 routing is live."
    return 0
  fi
  err "${fails} check(s) failed. Reality configs will not work until these are fixed."
  return 1
}

diagnose() {
  header
  db_ready || { pause; return 0; }
  load_state
  load_inbounds

  printf '%sConfiguration%s\n' "$C_PURPLE" "$R"
  printf '  Public host      %s\n' "${PUBLIC_HOST:-<not set>}"
  printf '  Panel port       %s (via 443: %s %s)\n' "$(panel_port)" "$PANEL_ROUTE" "$PANEL_HOST"
  printf '  Sub port         %s (via 443: %s %s)\n' "$(sub_port)" "$SUB_ROUTE" "$SUB_HOST"
  printf '  Stream file      %s\n' "$([ -f "$STREAM_FILE" ] && echo present || echo MISSING)"
  if [ -n "$SITE_DOMAIN" ]; then
    local dp; dp=$(panel_path)
    printf '  Site domain      https://%s\n' "$SITE_DOMAIN"
    if [ -n "$dp" ]; then
      if grep -qF "location ${dp}/" "$SITE_CONF" 2>/dev/null; then
        printf '  Panel URL        https://%s%s/  (routed)\n' "$SITE_DOMAIN" "$dp"
      else
        printf '  Panel URL        %sNOT routed - https://%s%s shows the SITE%s\n' "$C_ERR" "$SITE_DOMAIN" "$dp" "$R"
        printf '                   %sFix: Camouflage Site > Panel on Site Domain%s\n' "$C_GRAY" "$R"
      fi
    fi
  fi
  printf '  Hooked into conf %s\n' "$(grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null && echo yes || echo NO)"
  echo

  printf '%sServices%s\n' "$C_PURPLE" "$R"
  printf '  %-8s %s\n' "$XUI_SERVICE" "$(systemctl is-active "$XUI_SERVICE" 2>/dev/null || echo inactive)"
  printf '  %-8s %s\n' "$NGINX_SERVICE" "$(systemctl is-active "$NGINX_SERVICE" 2>/dev/null || echo inactive)"
  echo

  if ! nginx -t 2>/tmp/r443.diag.err; then
    err "nginx config test FAILED:"
    sed -n '1,10p' /tmp/r443.diag.err >&2
    echo
  fi

  verify_live || true

  # SNI reachability probe against the local listener
  if have openssl && port_busy 443; then
    echo
    printf '%sTLS probe on 127.0.0.1:443%s\n' "$C_PURPLE" "$R"
    local i sni out
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
      is_routable_listen "${RI_LISTEN[$i]}" || continue
      sni="${RI_SNI[$i]}"
      [ -n "$sni" ] || continue
      out=$(timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$sni" </dev/null 2>&1 || true)
      if printf '%s' "$out" | grep -q 'Connection refused'; then
        err "${sni} -> connection refused on 127.0.0.1:443"
      elif printf '%s' "$out" | grep -q 'subject='; then
        ok "${sni} -> $(printf '%s' "$out" | grep -m1 'subject=')"
      else
        warn "${sni} -> handshake did not complete (normal for some Reality setups; test from outside)."
      fi
    done
  fi
  pause
}

# ---------------------------------------------------------------------------
# Host / external address for generated links
# ---------------------------------------------------------------------------
set_inbound_host() {
  local id="$1" addr="$2" remark="$3" hport="${4:-443}"
  local ea er existing sj new
  ea=$(esc "$addr"); er=$(esc "$remark")

  if [ "$HOST_MECHANISM" = "hosts_table" ]; then
    existing=$(xval "SELECT id FROM hosts WHERE inbound_id=${id} LIMIT 1;")
    if [ -n "$existing" ]; then
      xsql "UPDATE hosts SET address='${ea}', port=${hport}, remark='${er}' WHERE id=${existing};"
    else
      xsql "INSERT INTO hosts (inbound_id, remark, address, port, security) VALUES (${id}, '${er}', '${ea}', ${hport}, 'same');" 2>/dev/null \
      || xsql "INSERT INTO hosts (inbound_id, remark, address, port) VALUES (${id}, '${er}', '${ea}', ${hport});"
    fi
  else
    sj=$(q "SELECT stream_settings FROM inbounds WHERE id=${id};" | jq -r '.[0].stream_settings')
    new=$(printf '%s' "$sj" | jq -c --arg d "$addr" --arg r "$remark" --argjson p "$hport" \
      '.externalProxy = [{forceTls:"same", dest:$d, port:$p, remark:$r}]')
    xsql "UPDATE inbounds SET stream_settings='$(esc "$new")' WHERE id=${id};"
  fi
}

# ---------------------------------------------------------------------------
# Sample link
# ---------------------------------------------------------------------------
urlenc() {
  local s="$1" o="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in [a-zA-Z0-9.~_-]) o+="$c" ;; *) o+=$(printf '%%%02X' "'$c") ;; esac
  done
  printf '%s\n' "$o"
}

sample_link() {
  local id="$1" host="$2" remark="$3" stream="$4"
  local st uid flow pbk fp sni sid spx net extra=""
  st=$(q "SELECT settings FROM inbounds WHERE id=${id};" | jq -r '.[0].settings')
  uid=$(printf '%s' "$st" | jq -r '.clients[0].id // ""')
  [ -n "$uid" ] || { warn "Inbound '${remark}' has no clients - no sample link."; return 0; }
  flow=$(printf '%s' "$st" | jq -r '.clients[0].flow // ""')
  pbk=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.publicKey // ""')
  fp=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.fingerprint // "chrome"')
  sni=$(printf '%s' "$stream" | jq -r '.realitySettings.serverNames[0] // ""')
  sid=$(printf '%s' "$stream" | jq -r '.realitySettings.shortIds[0] // ""')
  spx=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.spiderX // "/"')
  net=$(printf '%s' "$stream" | jq -r '.network // "tcp"')
  case "$net" in
    xhttp) extra="&path=$(urlenc "$(printf '%s' "$stream" | jq -r '.xhttpSettings.path // "/"')")&mode=auto" ;;
    grpc)  extra="&serviceName=$(urlenc "$(printf '%s' "$stream" | jq -r '.grpcSettings.serviceName // ""')")" ;;
  esac
  [ -n "$flow" ] && extra="${extra}&flow=${flow}"
  printf '%svless://%s@%s:443?type=%s&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&spx=%s%s#%s%s\n' \
    "$C_GOLD" "$uid" "$host" "$net" "$pbk" "$fp" "$sni" "$sid" "$(urlenc "$spx")" "$extra" "$(urlenc "$remark")" "$R"
}

# ---------------------------------------------------------------------------
# 1) Setup / consolidate
# ---------------------------------------------------------------------------
pick_inbounds() {
  local total="${#RI_ID[@]}" raw tok bad
  local -a toks=() out=()
  local -A seen=()
  local c; c=$(next_c)
  while true; do
    printf '%sInbounds to route (e.g. 1 3 4, or "all")%s: ' "$c" "$R" >&2
    IFS= read -r raw || raw=""
    if [ "$raw" = "all" ] || [ "$raw" = "ALL" ]; then
      local i; for ((i = 1; i <= total; i++)); do out+=("$i"); done
      printf '%s\n' "${out[@]}"; return 0
    fi
    read -ra toks <<< "${raw//,/ }"
    if [ "${#toks[@]}" -eq 0 ]; then err "Enter at least one number, or 'all'."; continue; fi
    bad=""; out=(); seen=()
    for tok in "${toks[@]}"; do
      if ! [[ "$tok" =~ ^[0-9]+$ ]] || [ "$tok" -lt 1 ] || [ "$tok" -gt "$total" ]; then bad="$tok"; break; fi
      [ -n "${seen[$tok]:-}" ] && continue
      seen[$tok]=1; out+=("$tok")
    done
    if [ -n "$bad" ]; then err "'${bad}' is out of range (1-${total})."; continue; fi
    printf '%s\n' "${out[@]}"; return 0
  done
}

# Validates the selection and prints the usable subset on stdout.
# - inbounds with no serverName are skipped with a warning (they simply cannot
#   be routed by SNI) instead of aborting the whole run
# - two selected inbounds sharing an SNI IS fatal: one of them would silently
#   never receive traffic, and only the operator can decide which is right
SNI_OK=()
check_sni_unique() {
  local -A owner=()
  local idx s rem
  SNI_OK=()
  for idx in "$@"; do
    s="${RI_SNI[$((idx - 1))]}"
    rem="${RI_REMARK[$((idx - 1))]}"
    if [ -z "$s" ]; then
      warn "Skipping '${rem}': it has no Reality serverName, so it cannot be routed by SNI."
      continue
    fi
    if [ -n "${owner[$s]:-}" ]; then
      err "SNI '${s}' is used by both '${owner[$s]}' and '${rem}'."
      err "Give each inbound a unique serverName in the panel, then re-run."
      return 1
    fi
    owner[$s]="$rem"
    SNI_OK+=("$idx")
  done
  if [ "${#SNI_OK[@]}" -eq 0 ]; then
    err "None of the selected inbounds have a serverName - nothing can be routed."
    return 1
  fi
  return 0
}

sni_taken() {
  local x="$1" i
  for ((i = 0; i < ${#RI_SNI[@]}; i++)); do [ "${RI_SNI[$i]}" = "$x" ] && return 0; done
  return 1
}

ask_extra_host() {
  # ask_extra_host "Panel" existing_value  -> echoes chosen hostname
  local label="$1" def="$2" h
  while true; do
    h=$(ask "${label} hostname" v_domain "$def")
    if sni_taken "$h"; then err "'${h}' is already a Reality SNI. Choose another."; continue; fi
    if [ "$label" = "Subscription" ] && [ "$PANEL_ROUTE" = "yes" ] && [ "$h" = "$PANEL_HOST" ]; then
      err "Subscription hostname must differ from the panel hostname."; continue
    fi
    printf '%s\n' "$h"; return 0
  done
}

do_setup() {
  header
  db_ready || { pause; return 0; }
  detect_host_mechanism
  load_inbounds
  refresh_taken_ports

  if [ "${#RI_ID[@]}" -eq 0 ]; then
    warn "No Reality inbounds found in ${DB_PATH}."
    pause; return 0
  fi
  show_table

  local -a sel=()
  mapfile -t sel < <(pick_inbounds)
  if [ "${#sel[@]}" -eq 0 ]; then warn "Nothing selected."; pause; return 0; fi
  check_sni_unique "${sel[@]}" || { pause; return 0; }
  sel=("${SNI_OK[@]}")

  install_nginx || { pause; return 0; }
  if http_binds_443; then
    warn "Another nginx site already listens on 443 in the http block."
    warn "That will conflict with the stream listener. Disable it first."
    local go; go=$(ask "Continue anyway? [y/N]" v_yn "no")
    [ "$go" = "yes" ] || { pause; return 0; }
  fi
  local own443
  if port_busy 443; then
    own443=$(port_owner 443)
    [ "$own443" = "nginx" ] || warn "Port 443 is currently held by '${own443:-unknown}', not nginx."
  fi

  load_state
  PUBLIC_HOST=$(ask "Public domain or IP for client links" v_host "$PUBLIC_HOST")

  warn "Exposing the panel on public 443 increases attack surface."
  PANEL_ROUTE=$(ask "Route the panel through 443 as well? [y/N]" v_yn "$PANEL_ROUTE")
  if [ "$PANEL_ROUTE" = "yes" ]; then
    panel_tls || warn "The panel has no TLS certificate set - SNI routing will not work until you set one in the panel."
    PANEL_HOST=$(ask_extra_host "Panel" "$PANEL_HOST")
  else
    PANEL_HOST=""
  fi

  SUB_ROUTE=$(ask "Route the subscription service through 443? [y/N]" v_yn "$SUB_ROUTE")
  if [ "$SUB_ROUTE" = "yes" ]; then
    sub_tls || warn "The subscription service has no TLS certificate set - SNI routing will not work until you set one."
    SUB_HOST=$(ask_extra_host "Subscription" "$SUB_HOST")
  else
    SUB_HOST=""
  fi

  # Camouflage site - all questions asked here so a fresh install is one
  # uninterrupted pass; the site itself is applied after 443 is live.
  echo
  printf '%sCamouflage site%s\n' "$C_PURPLE" "$R"
  line_c 0 "  1) Serve Local Files"
  line_c 1 "  2) Redirect to Another Site"
  line_c 2 "  3) Skip"
  local site_choice
  site_choice=$(ask "Choice" v_site_choice "3")
  case "$site_choice" in
    1) site_pick_local || site_choice=3 ;;
    2) site_ask_redirect || site_choice=3 ;;
  esac

  # Offer to publish the panel under the site's domain at its own base path,
  # e.g. https://site.example.com/xpanel - one domain for both.
  PANEL_ON_SITE="no"
  if [ "$site_choice" != "3" ] && [ -n "$SITE_DOMAIN" ]; then
    local ppath; ppath=$(panel_path)
    if [ -n "$ppath" ]; then
      warn "The site will occupy ${SITE_DOMAIN}. Without this, ${SITE_DOMAIN}${ppath} shows the site, not the panel."
      # Default yes: putting a site on the panel's domain and NOT publishing the
      # panel is how the panel silently disappears behind index.html.
      PANEL_ON_SITE=$(ask "Serve the panel at https://${SITE_DOMAIN}${ppath} ? [Y/n]" v_yn_default_yes "yes")
    else
      warn "The panel has no base path set (webBasePath)."
      warn "Set one in the panel (e.g. /xpanel) so it can be published under the site domain."
    fi
  fi

  local fw_choice
  fw_choice=$(ask "Install and enable the firewall (ufw)? [y/N]" v_yn "no")

  # Plan internal ports
  local -a plan_port=()
  local idx i cur
  for idx in "${sel[@]}"; do
    i=$((idx - 1)); cur="${RI_PORT[$i]}"
    if is_routable_listen "${RI_LISTEN[$i]}" && [ "$cur" -ge "$MIN_PORT" ] && [ "$cur" -le "$MAX_PORT" ]; then
      # already consolidated (loopback or tunnel IP) on an internal port - keep it
      TAKEN_PORTS["$cur"]=keep
      plan_port[$i]="$cur"
    else
      alloc_port "$cur" || { pause; return 0; }
      plan_port[$i]="$ALLOC_PORT"
    fi
  done

  echo
  printf '%sPlanned changes%s\n' "$C_PURPLE" "$R"
  for idx in "${sel[@]}"; do
    i=$((idx - 1))
    printf '  %-20s :%-6s ->  %s:%-6s [%s]\n' \
      "${RI_REMARK[$i]:0:20}" "${RI_PORT[$i]}" "$(backend_ip "${RI_LISTEN[$i]}")" "${plan_port[$i]}" "${RI_SNI[$i]}"
  done
  printf '  Link host                %s:443\n' "$PUBLIC_HOST"
  printf '  Panel via 443            %s%s\n' "$PANEL_ROUTE" "$([ "$PANEL_ROUTE" = yes ] && printf ' (%s -> :%s)' "$PANEL_HOST" "$(panel_port)")"
  printf '  Subscription via 443     %s%s\n' "$SUB_ROUTE" "$([ "$SUB_ROUTE" = yes ] && printf ' (%s -> :%s)' "$SUB_HOST" "$(sub_port)")"
  case "$site_choice" in
    1) printf '  Site                     local files from %s\n' "$SITE_SRC" ;;
    2) printf '  Site                     redirect to https://%s\n' "$SITE_TARGET" ;;
    *) printf '  Site                     none\n' ;;
  esac
  [ -n "$SITE_DOMAIN" ] && printf '  Site certificate         %s\n' "$SITE_DOMAIN"
  if [ "$PANEL_ON_SITE" = "yes" ]; then
    printf '  Panel URL                https://%s%s/\n' "$SITE_DOMAIN" "$(panel_path)"
  fi
  printf '  Firewall (ufw)           %s\n' "$fw_choice"
  echo
  warn "Existing users will be disconnected until they get updated links."
  local go; go=$(ask "Apply now? [y/N]" v_yn "no")
  [ "$go" = "yes" ] || { warn "Cancelled - nothing was written."; pause; return 0; }

  local bdir; bdir=$(backup_now)
  save_original_ports
  save_state

  info "Stopping ${XUI_SERVICE} before writing the database..."
  systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true

  for idx in "${sel[@]}"; do
    i=$((idx - 1))
    if is_private_ip "${RI_LISTEN[$i]}"; then
      # tunnel inbound: keep its listen IP, only change the port
      xsql "UPDATE inbounds SET port=${plan_port[$i]} WHERE id=${RI_ID[$i]};"
    else
      xsql "UPDATE inbounds SET listen='127.0.0.1', port=${plan_port[$i]} WHERE id=${RI_ID[$i]};"
    fi
    set_inbound_host "${RI_ID[$i]}" "$PUBLIC_HOST" "${RI_REMARK[$i]:-reality}"
  done
  ok "Database updated for ${#sel[@]} inbound(s) (mechanism: ${HOST_MECHANISM})."

  apply_tunnel_hosts

  # Collect the internal ports xray must now bind, and wait for them before
  # writing the nginx map - otherwise nginx proxies to ports nothing is on yet.
  local -a wait_ports=()
  for idx in "${sel[@]}"; do wait_ports+=("${plan_port[$((idx - 1))]}"); done
  start_xui_and_wait "${wait_ports[@]}"

  load_inbounds
  if ! write_stream_conf || ! hook_stream_include; then
    err "The database is already consolidated but nginx routing is incomplete."
    err "Fix the issue above, then run 'Sync New Inbounds' to finish - or use Rollback."
    pause; return 0
  fi
  if ! apply_nginx "$bdir"; then
    err "nginx was rolled back, but the database is already consolidated."
    err "Fix the nginx error above, then run 'Sync New Inbounds' to finish."
    pause; return 0
  fi
  verify_live || true

  case "$site_choice" in
    1) echo; site_apply_local || warn "Camouflage site was not set up." ;;
    2) echo; site_apply_redirect || warn "Camouflage site was not set up." ;;
  esac

  if [ "$fw_choice" = "yes" ]; then
    echo
    setup_firewall || warn "Firewall was not configured."
  fi

  echo
  printf '%sSample links%s\n' "$C_PURPLE" "$R"
  for idx in "${sel[@]}"; do
    i=$((idx - 1))
    sample_link "${RI_ID[$i]}" "$PUBLIC_HOST" "${RI_REMARK[$i]:-reality}" "${RI_STREAM[$i]}"
  done
  echo
  info "Point ${PUBLIC_HOST} and every SNI above at this server's IP."
  pause
}

# ---------------------------------------------------------------------------
# 2) Sync (pick up new inbounds, rewrite nginx map)
# ---------------------------------------------------------------------------
do_sync() {
  header
  db_ready || { pause; return 0; }
  if [ ! -f "$STREAM_FILE" ]; then
    err "Nothing set up yet. Run 'Setup' first."
    pause; return 0
  fi
  detect_host_mechanism
  load_state
  load_inbounds
  refresh_taken_ports

  local -a pending=()
  local i
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    # Already done = routable listen AND already on an internal port.
    if is_routable_listen "${RI_LISTEN[$i]}" \
       && [ "${RI_PORT[$i]}" -ge "$MIN_PORT" ] && [ "${RI_PORT[$i]}" -le "$MAX_PORT" ]; then
      continue
    fi
    pending+=("$((i + 1))")
  done

  if [ "${#pending[@]}" -eq 0 ]; then
    ok "All Reality inbounds are already routed. Regenerating nginx map only."
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    apply_tunnel_hosts
    start_xui_and_wait
  else
    show_table
    info "Not yet routed: ${#pending[@]} inbound(s)."
    local go; go=$(ask "Route them now? [y/N]" v_yn "yes")
    if [ "$go" = "yes" ]; then
      check_sni_unique "${pending[@]}" || { pause; return 0; }
      pending=("${SNI_OK[@]}")
      backup_now >/dev/null
      systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
      local idx p
      local -a wait_ports=()
      for idx in "${pending[@]}"; do
        i=$((idx - 1))
        alloc_port "" || break
        p="$ALLOC_PORT"
        if is_private_ip "${RI_LISTEN[$i]}"; then
          xsql "UPDATE inbounds SET port=${p} WHERE id=${RI_ID[$i]};"
        else
          xsql "UPDATE inbounds SET listen='127.0.0.1', port=${p} WHERE id=${RI_ID[$i]};"
        fi
        [ -n "$PUBLIC_HOST" ] && set_inbound_host "${RI_ID[$i]}" "$PUBLIC_HOST" "${RI_REMARK[$i]:-reality}"
        ok "${RI_REMARK[$i]} -> $(backend_ip "${RI_LISTEN[$i]}"):${p}"
        wait_ports+=("$p")
      done
      apply_tunnel_hosts
      start_xui_and_wait "${wait_ports[@]}"
      load_inbounds
    fi
  fi

  local bdir2; bdir2=$(backup_now)
  if ! write_stream_conf || ! hook_stream_include; then
    err "Could not complete nginx routing - see the message above."
    pause; return 0
  fi
  apply_nginx "$bdir2" || { pause; return 0; }
  verify_live || true
  pause
}

# ---------------------------------------------------------------------------
# 3) Panel settings
# ---------------------------------------------------------------------------
panel_menu() {
  while true; do
    header
    db_ready || { pause; return 0; }
    load_state
    refresh_taken_ports
    printf '%sPanel port         %s%s%s\n' "$C_GRAY" "$C_WHITE" "$(panel_port)" "$R"
    printf '%sSubscription port  %s%s%s\n' "$C_GRAY" "$C_WHITE" "$(sub_port)" "$R"
    printf '%sPanel via 443      %s%s %s%s\n\n' "$C_GRAY" "$C_WHITE" "$PANEL_ROUTE" "${PANEL_HOST}" "$R"

    line_c 0 "1) Change Panel Port"
    line_c 1 "2) Change Subscription Port"
    line_c 2 "3) Panel Hostname on 443"
    line_c 3 "4) Subscription Hostname on 443"
    line_c 4 "0) Back"
    local ch np
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1)
        PORT_ALLOW=$(panel_port)
        np=$(ask "New panel port" v_port "$(panel_port)")
        PORT_ALLOW=""
        systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
        set_setting webPort "$np"
        systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
        ok "Panel port set to ${np}."
        [ -f "$STREAM_FILE" ] && { load_inbounds; write_stream_conf && apply_nginx "$(backup_now)"; }
        pause ;;
      2)
        PORT_ALLOW=$(sub_port)
        np=$(ask "New subscription port" v_port "$(sub_port)")
        PORT_ALLOW=""
        systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
        set_setting subPort "$np"
        systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
        ok "Subscription port set to ${np}."
        [ -f "$STREAM_FILE" ] && { load_inbounds; write_stream_conf && apply_nginx "$(backup_now)"; }
        pause ;;
      3)
        load_inbounds
        PANEL_ROUTE=$(ask "Route the panel through 443? [y/N]" v_yn "$PANEL_ROUTE")
        if [ "$PANEL_ROUTE" = "yes" ]; then
          panel_tls || warn "The panel has no TLS certificate - SNI routing will not work until you set one."
          PANEL_HOST=$(ask_extra_host "Panel" "$PANEL_HOST")
        else
          PANEL_HOST=""
        fi
        save_state
        [ -f "$STREAM_FILE" ] && { write_stream_conf && apply_nginx "$(backup_now)"; }
        pause ;;
      4)
        load_inbounds
        SUB_ROUTE=$(ask "Route the subscription service through 443? [y/N]" v_yn "$SUB_ROUTE")
        if [ "$SUB_ROUTE" = "yes" ]; then
          sub_tls || warn "The subscription service has no TLS certificate - SNI routing will not work until you set one."
          SUB_HOST=$(ask_extra_host "Subscription" "$SUB_HOST")
        else
          SUB_HOST=""
        fi
        save_state
        [ -f "$STREAM_FILE" ] && { write_stream_conf && apply_nginx "$(backup_now)"; }
        pause ;;
      0) return 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4) Services
# ---------------------------------------------------------------------------
svc() {
  local s="$1" a="$2"
  case "$a" in
    status) systemctl status "$s" --no-pager 2>&1 | head -n 20 ;;
    logs)   journalctl -u "$s" -n 40 --no-pager 2>&1 | tail -n 40 ;;
    *)      if systemctl "$a" "$s" 2>/tmp/r443.svc.err; then ok "${s}: ${a}"; else err "${s}: ${a} failed"; cat /tmp/r443.svc.err >&2; fi ;;
  esac
}

services_menu() {
  while true; do
    header
    line_c 0 "1) Restart x-ui"
    line_c 1 "2) Restart nginx"
    line_c 2 "3) Reload nginx"
    line_c 3 "4) Stop / Start x-ui"
    line_c 4 "5) Stop / Start nginx"
    line_c 5 "6) Status"
    line_c 6 "7) Logs"
    line_c 7 "8) Test nginx Config"
    line_c 8 "0) Back"
    local ch sub
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1) svc "$XUI_SERVICE" restart; pause ;;
      2) svc "$NGINX_SERVICE" restart; pause ;;
      3) svc "$NGINX_SERVICE" reload; pause ;;
      4) sub=$(ask "stop or start" v_startstop "start"); svc "$XUI_SERVICE" "$sub"; pause ;;
      5) sub=$(ask "stop or start" v_startstop "start"); svc "$NGINX_SERVICE" "$sub"; pause ;;
      6) svc "$XUI_SERVICE" status; echo; svc "$NGINX_SERVICE" status; pause ;;
      7) svc "$XUI_SERVICE" logs; echo; svc "$NGINX_SERVICE" logs; pause ;;
      8) if nginx -t 2>&1 | sed 's/^/  /'; then ok "Config OK"; else err "Config has errors"; fi; pause ;;
      0) return 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

v_startstop() {
  local x; x=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$x" in start|stop) printf '%s\n' "$x"; return 0 ;; esac
  err "Type 'start' or 'stop'."
  return 1
}

# ---------------------------------------------------------------------------
# 5) Remove
# ---------------------------------------------------------------------------
do_remove() {
  header
  warn "This removes ALL changes made by this script:"
  warn "  - nginx stream block, stream config and site config"
  warn "  - inbound listen/port restored to their original values"
  warn "  - host rows created for those inbounds"
  warn "  - saved state under ${STATE_DIR}"
  local go; go=$(ask "Proceed? [y/N]" v_yn "no")
  [ "$go" = "yes" ] || { warn "Cancelled."; pause; return 0; }

  local wipe_site; wipe_site=$(ask "Also delete the copied website files in ${SITE_ROOT}? [y/N]" v_yn "no")

  backup_now >/dev/null

  # ---- 1. inbound ports -----------------------------------------------------
  local orig="${STATE_DIR}/original-ports.json"
  if [ -f "$orig" ] && db_ready; then
    local n i id lst prt
    n=$(jq 'length' "$orig")
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    for ((i = 0; i < n; i++)); do
      id=$(jq -r ".[$i].id" "$orig")
      lst=$(jq -r ".[$i].listen // \"\"" "$orig")
      prt=$(jq -r ".[$i].port" "$orig")
      xsql "UPDATE inbounds SET listen='$(esc "$lst")', port=${prt} WHERE id=${id};"
    done
    ok "Inbound ports restored from ${orig}."
  else
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    warn "No original-ports record found - inbound ports left as they are."
  fi

  # ---- 2. host rows this script created ------------------------------------
  if db_ready && [ -n "$PUBLIC_HOST" ]; then
    local hn
    hn=$(xval "SELECT COUNT(*) FROM hosts WHERE address='$(esc "$PUBLIC_HOST")';" 2>/dev/null || echo 0)
    [ -n "$hn" ] || hn=0
    if [ "$hn" -gt 0 ]; then
      xsql "DELETE FROM hosts WHERE address='$(esc "$PUBLIC_HOST")';"
      ok "Removed ${hn} host row(s) pointing at ${PUBLIC_HOST}."
    fi
  fi
  systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true

  # ---- 3. nginx: stream block, stream file, site file ----------------------
  unhook_stream_include
  rm -f "$STREAM_FILE" "$SITE_CONF"
  # put back any distro site files we moved aside
  local f base
  if [ -d "$DISABLED_DIR" ]; then
    for f in "$DISABLED_DIR"/*; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      if [ "$base" = "default.conf" ]; then
        mv -f "$f" "${NGINX_DIR}/conf.d/${base}"
        ok "Restored ${NGINX_DIR}/conf.d/${base}"
      else
        mkdir -p "${NGINX_DIR}/sites-enabled"
        mv -f "$f" "${NGINX_DIR}/sites-enabled/${base}"
        ok "Restored ${NGINX_DIR}/sites-enabled/${base}"
      fi
    done
    rmdir "$DISABLED_DIR" 2>/dev/null || true
  fi
  # also undo any in-place renames left by older versions
  for f in "${NGINX_DIR}"/sites-enabled/*.reality443-disabled \
           "${NGINX_DIR}"/conf.d/*.reality443-disabled; do
    [ -e "$f" ] || continue
    mv -f "$f" "${f%.reality443-disabled}"
    ok "Restored ${f%.reality443-disabled}"
  done

  # ---- 4. website files (optional) -----------------------------------------
  if [ "$wipe_site" = "yes" ] && [ -d "$SITE_ROOT" ]; then
    rm -rf "${SITE_ROOT:?}"
    ok "Deleted ${SITE_ROOT}"
  fi

  # ---- 5. saved state -------------------------------------------------------
  rm -f "$STATE_FILE" "${STATE_DIR}/original-ports.json"
  PUBLIC_HOST=""; PANEL_HOST=""; SUB_HOST=""
  PANEL_ROUTE="no"; SUB_ROUTE="no"
  SITE_MODE="none"; SITE_TARGET=""; SITE_DOMAIN=""; SITE_CERT=""; SITE_KEY=""
  ok "Cleared saved state."

  # ---- 6. reload ------------------------------------------------------------
  if have nginx; then
    if nginx -t 2>/tmp/r443.rm.err; then
      systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null || true
      ok "nginx reloaded - all routing removed."
    else
      err "nginx config is invalid after removal:"
      sed -n '1,10p' /tmp/r443.rm.err >&2
    fi
  fi
  pause
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
manage_hosts() {
  while true; do
    header
    db_ready || { pause; return 0; }
    local json n i id iid addr prt rem
    json=$(q "SELECT h.id, h.inbound_id, h.address, h.port, h.remark, i.remark AS ib FROM hosts h LEFT JOIN inbounds i ON i.id=h.inbound_id ORDER BY h.id;")
    n=$(printf '%s' "$json" | jq 'length')
    printf '%s %-5s %-8s %-22s %-7s %s%s\n' "$C_TURQ" "HOSTID" "INBOUND" "ADDRESS" "PORT" "INBOUND REMARK" "$R"
    printf '%s%s%s\n' "$C_GRAY" "----------------------------------------------------------------" "$R"
    if [ "$n" -eq 0 ]; then
      info "No host rows in the database."
    else
      for ((i = 0; i < n; i++)); do
        id=$(printf '%s' "$json" | jq -r ".[$i].id")
        iid=$(printf '%s' "$json" | jq -r ".[$i].inbound_id")
        addr=$(printf '%s' "$json" | jq -r ".[$i].address // \"\"")
        prt=$(printf '%s' "$json" | jq -r ".[$i].port")
        rem=$(printf '%s' "$json" | jq -r ".[$i].ib // \"\"")
        printf ' %-5s %-8s %-22s %-7s %s\n' "$id" "$iid" "${addr:0:22}" "$prt" "${rem:0:20}"
      done
    fi
    echo
    line_c 0 "1) Delete host(s) by HOSTID"
    line_c 1 "2) Delete ALL hosts"
    line_c 2 "0) Back"
    local ch
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1)
        [ "$n" -eq 0 ] && { warn "Nothing to delete."; pause; continue; }
        local raw; printf '%sHOSTIDs to delete (space-separated)%s: ' "$(next_c)" "$R"; IFS= read -r raw || raw=""
        [ -z "$raw" ] && { warn "No change."; pause; continue; }
        backup_now >/dev/null
        local tok deleted=0
        for tok in $raw; do
          if [[ "$tok" =~ ^[0-9]+$ ]]; then
            xsql "DELETE FROM hosts WHERE id=${tok};"
            deleted=$((deleted + 1))
          else
            err "'$tok' is not a HOSTID."
          fi
        done
        systemctl restart "$XUI_SERVICE" >/dev/null 2>&1 || true
        ok "Deleted ${deleted} host row(s) and restarted ${XUI_SERVICE}."
        pause ;;
      2)
        [ "$n" -eq 0 ] && { warn "Nothing to delete."; pause; continue; }
        local c; c=$(ask "Delete ALL ${n} host row(s)? [y/N]" v_yn "no")
        [ "$c" = "yes" ] || { warn "Cancelled."; pause; continue; }
        backup_now >/dev/null
        xsql "DELETE FROM hosts;"
        systemctl restart "$XUI_SERVICE" >/dev/null 2>&1 || true
        ok "All host rows deleted and ${XUI_SERVICE} restarted."
        pause ;;
      0) return 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

# Strips any scheme/path the user pastes and validates a bare domain, so both
# "example.com" and "https://example.com/x" are accepted and normalised.
v_bare_domain() {
  local x="$1"
  x="${x#http://}"; x="${x#https://}"
  x="${x%%/*}"
  x="${x%%:*}"
  if [[ "$x" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
    printf '%s\n' "$x"; return 0
  fi
  err "Enter a domain like example.com (no https://)."
  return 1
}

# ---------------------------------------------------------------------------
# TLS certificate discovery
# ---------------------------------------------------------------------------
# Prints "<domain>|<fullchain>|<privkey>" for every usable cert pair found.
find_cert_pairs() {
  local base d chain key dom
  for base in $CERT_SEARCH_DIRS; do
    [ -d "$base" ] || continue
    while IFS= read -r chain; do
      [ -f "$chain" ] || continue
      d=$(dirname "$chain")
      key=""
      for k in privkey.pem private.key key.pem privkey.key "$(basename "$d").key"; do
        [ -f "${d}/${k}" ] && { key="${d}/${k}"; break; }
      done
      if [ -z "$key" ]; then
        key=$(find "$d" -maxdepth 1 -name '*.key' -type f 2>/dev/null | head -n1)
      fi
      [ -n "$key" ] || continue
      dom=$(basename "$d")
      printf '%s|%s|%s\n' "$dom" "$chain" "$key"
    done < <(find "$base" -maxdepth 3 \( -name 'fullchain.pem' -o -name 'fullchain.cer' -o -name 'cert.pem' \) -type f 2>/dev/null)
  done | awk -F'|' '!seen[$1]++'
}

# Picks a cert: single match is used automatically, several are offered as a list.
choose_cert() {
  local -a pairs=()
  mapfile -t pairs < <(find_cert_pairs)
  if [ "${#pairs[@]}" -eq 0 ]; then
    warn "No TLS certificate found under: ${CERT_SEARCH_DIRS}"
    return 1
  fi
  if [ "${#pairs[@]}" -eq 1 ]; then
    IFS='|' read -r SITE_DOMAIN SITE_CERT SITE_KEY <<< "${pairs[0]}"
    ok "Using certificate for ${SITE_DOMAIN}"
    return 0
  fi
  printf '%sCertificates found on this server:%s\n' "$C_PURPLE" "$R"
  local k dom
  for k in "${!pairs[@]}"; do
    dom="${pairs[$k]%%|*}"
    printf '  %-3s %s\n' "$((k + 1))" "$dom"
  done
  local pick
  while true; do
    printf '%sPick a certificate%s: ' "$(next_c)" "$R"
    IFS= read -r pick || pick=""
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#pairs[@]}" ]; then
      IFS='|' read -r SITE_DOMAIN SITE_CERT SITE_KEY <<< "${pairs[$((pick - 1))]}"
      ok "Using certificate for ${SITE_DOMAIN}"
      return 0
    fi
    err "Pick a number from the list."
  done
}

# ---------------------------------------------------------------------------
# Camouflage site
# ---------------------------------------------------------------------------
find_index_candidates() {
  local d
  for d in /var/www/html /usr/share/nginx/html /var/www /usr/share/nginx \
           /root /home /opt /srv; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 3 -name 'index.html' -type f 2>/dev/null
  done | grep -v "^${SITE_ROOT}/" | awk '!seen[$0]++' | head -n 10
}

# nginx must actually include conf.d/*.conf from http{}, or our site file is
# written but never loaded.
ensure_confd_included() {
  mkdir -p "${NGINX_DIR}/conf.d"
  grep -qE "^[[:space:]]*include[[:space:]]+[^;]*conf\.d/\*\.conf[[:space:]]*;" "$NGINX_CONF" 2>/dev/null && return 0
  local tmp; tmp=$(mktemp)
  awk -v inc="    include ${NGINX_DIR}/conf.d/*.conf;" '
    BEGIN { done=0 }
    { print }
    !done && $0 ~ /^[[:space:]]*http[[:space:]]*\{/ { print inc; done=1 }
  ' "$NGINX_CONF" > "$tmp"
  mv "$tmp" "$NGINX_CONF"
  info "Added conf.d include to ${NGINX_CONF}"
}

# Writes the site server blocks:
#   :80                    -> permanent redirect to https (plus the site itself
#                             if no cert is available)
#   127.0.0.1:SITE_PORT    -> TLS site, reached from the 443 stream map by SNI
# The site's loopback port must be genuinely free: a hardcoded 8081 collides
# with whatever else the box happens to run and nginx then fails to bind.
pick_site_port() {
  local p="${SITE_PORT:-8081}" limit=$((${SITE_PORT:-8081} + 200))
  refresh_taken_ports 2>/dev/null || true
  while [ "$p" -le "$limit" ]; do
    if [ -z "${TAKEN_PORTS[$p]:-}" ] && ! port_busy "$p"; then
      if [ "$p" != "${SITE_PORT:-}" ]; then
        info "Site port ${SITE_PORT} was busy - using ${p} instead."
      fi
      SITE_PORT="$p"
      return 0
    fi
    # a port we ourselves already assigned to the site is fine to reuse
    if [ "$p" = "${SITE_BIND_PORT:-}" ] && ! port_busy "$p"; then
      SITE_PORT="$p"; return 0
    fi
    p=$((p + 1))
  done
  err "No free loopback port for the site between ${SITE_PORT} and ${limit}."
  return 1
}

write_site_conf() {
  ensure_confd_included
  local tmp; tmp=$(mktemp)
  {
    echo "# Managed by reality-443.sh v${SCRIPT_VERSION} - do not edit by hand."
    echo "server {"
    echo "    listen 80 default_server;"
    has_ipv6 && echo "    listen [::]:80 default_server;"
    echo "    server_name _;"
    if [ -n "$SITE_DOMAIN" ]; then
      echo "    return 301 https://\$host\$request_uri;"
    elif [ "$SITE_MODE" = "redirect" ]; then
      echo "    return 301 https://${SITE_TARGET}\$request_uri;"
    else
      echo "    root ${SITE_ROOT};"
      echo "    index index.html index.htm;"
      echo "    location / { try_files \$uri \$uri/ /index.html; }"
    fi
    echo "}"
    if [ -n "$SITE_DOMAIN" ] && [ -n "$SITE_CERT" ] && [ -n "$SITE_KEY" ]; then
      echo ""
      echo "server {"
      echo "    listen 127.0.0.1:${SITE_PORT} ssl;"
      echo "    server_name ${SITE_DOMAIN};"
      echo "    ssl_certificate ${SITE_CERT};"
      echo "    ssl_certificate_key ${SITE_KEY};"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_cache shared:R443SSL:10m;"
      # This server listens on a private loopback port behind the 443 stream
      # router. Without these, nginx builds redirects and proxied Location
      # headers from its own port and leaks e.g. https://host:8081/ to clients.
      echo "    port_in_redirect off;"
      echo "    absolute_redirect off;"
      # Panel / subscription served on the SAME domain under their own base
      # paths. These must come before the catch-all "location /" so that
      # https://<site>/xpanel reaches x-ui instead of the static site.
      if [ "$PANEL_ON_SITE" = "yes" ]; then
        local ppath pport spath sport2
        ppath=$(panel_path); pport=$(panel_port)
        if [ -n "$ppath" ]; then
          local pscheme; pscheme=$(panel_backend_scheme)
          echo "    location ${ppath}/ {"
          echo "        proxy_pass ${pscheme}://127.0.0.1:${pport};"
          if [ "$pscheme" = "https" ]; then
            # the panel presents its own certificate on loopback; we are not
            # validating a name we control, so skip verification
            echo "        proxy_ssl_verify off;"
            echo "        proxy_ssl_server_name on;"
          fi
          echo "        proxy_http_version 1.1;"
          echo "        proxy_set_header Host \$host;"
          echo "        proxy_set_header X-Real-IP \$remote_addr;"
          echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
          echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
          echo "        proxy_set_header Upgrade \$http_upgrade;"
          echo "        proxy_set_header Connection \"upgrade\";"
          echo "        proxy_read_timeout 300s;"
          echo "        proxy_redirect ~^http://[^/]+(/.*)\$ https://\$host\$1;"
          echo "    }"
          # /xpanel with no trailing slash must not fall through to the site
          echo "    location = ${ppath} { return 301 ${ppath}/; }"
        fi
        spath=$(sub_path); sport2=$(sub_port)
        if [ -n "$spath" ] && [ "$spath" != "$ppath" ]; then
          local sscheme="http"
          [ -n "$(get_setting subCertFile)" ] && sscheme="https"
          echo "    location ${spath}/ {"
          echo "        proxy_pass ${sscheme}://127.0.0.1:${sport2};"
          if [ "$sscheme" = "https" ]; then
            echo "        proxy_ssl_verify off;"
            echo "        proxy_ssl_server_name on;"
          fi
          echo "        proxy_http_version 1.1;"
          echo "        proxy_set_header Host \$host;"
          echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
          echo "    }"
          echo "    location = ${spath} { return 301 ${spath}/; }"
        fi
      fi
      if [ "$SITE_MODE" = "redirect" ]; then
        echo "    location / { return 301 https://${SITE_TARGET}\$request_uri; }"
      else
        echo "    root ${SITE_ROOT};"
        echo "    index index.html index.htm;"
        echo "    location / { try_files \$uri \$uri/ /index.html; }"
      fi
      echo "}"
    fi
  } > "$tmp"
  mkdir -p "$(dirname "$SITE_CONF")"
  if ! mv "$tmp" "$SITE_CONF" 2>/tmp/r443.sitemv.err; then
    err "Could not write ${SITE_CONF}:"
    sed -n '1,5p' /tmp/r443.sitemv.err >&2
    rm -f "$tmp"; return 1
  fi
  ok "Wrote ${SITE_CONF}"
}

# A second default_server on :80 makes nginx -t fail with a duplicate error.
# The file has to be MOVED OUT of nginx's tree, not just renamed: Debian's
# nginx.conf includes "sites-enabled/*" (no .conf suffix), so a renamed file in
# that directory is still loaded and still collides.
DISABLED_DIR="${STATE_DIR}/disabled-sites"
disable_stock_default_site() {
  mkdir -p "$DISABLED_DIR"
  local f base
  for f in "${NGINX_DIR}"/sites-enabled/* "${NGINX_DIR}"/conf.d/default.conf; do
    [ -e "$f" ] || continue
    # never touch our own file
    case "$f" in *reality443*) continue ;; esac
    # only files that actually declare a default_server on :80 or :443
    grep -qE 'listen[^;]*default_server' "$f" 2>/dev/null || continue
    base=$(basename "$f")
    mv -f "$f" "${DISABLED_DIR}/${base}"
    warn "Moved conflicting default site out of nginx: ${f}"
    info "  (kept at ${DISABLED_DIR}/${base}, restored by Remove)"
  done
  # clean up files an older version renamed in place - those are still loaded
  # by a "sites-enabled/*" glob and would keep breaking nginx -t.
  for f in "${NGINX_DIR}"/sites-enabled/*.reality443-disabled \
           "${NGINX_DIR}"/conf.d/*.reality443-disabled; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .reality443-disabled)
    mv -f "$f" "${DISABLED_DIR}/${base}"
    warn "Cleaned up previously renamed site: $(basename "$f")"
  done
}

# When the panel is proxied by nginx, nginx terminates TLS - x-ui itself must
# then answer plain HTTP on its loopback port, or the proxy_pass gets a TLS
# handshake it cannot parse and the panel 502s.
# Whether the panel serves HTTPS on its own port. When it does, nginx must
# proxy with https:// upstream; when it does not, http://. Detected instead of
# asked, and x-ui's own settings are never modified.
panel_backend_scheme() {
  local cert; cert=$(get_setting webCertFile)
  if [ -n "$cert" ]; then printf 'https\n'; else printf 'http\n'; fi
}

apply_site() {
  disable_stock_default_site
  if [ -n "$SITE_DOMAIN" ]; then
    pick_site_port || return 1
    SITE_BIND_PORT="$SITE_PORT"
    save_state
  fi
  write_site_conf || return 1
  # The site's SNI has to be in the 443 stream map, otherwise nothing on 443
  # ever reaches it.
  load_inbounds
  write_stream_conf || return 1
  if nginx -t 2>/tmp/r443.site.err; then
    systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null || true
    if [ -n "$SITE_DOMAIN" ]; then
      ok "Site is live on https://${SITE_DOMAIN} (and http:// redirects to it)."
      if [ "$PANEL_ON_SITE" = "yes" ]; then
        local ppath2; ppath2=$(panel_path)
        if grep -qF "location ${ppath2}/" "$SITE_CONF" 2>/dev/null; then
          ok "Panel is live on https://${SITE_DOMAIN}${ppath2}/"
        else
          err "The panel location block is MISSING from ${SITE_CONF}."
          err "https://${SITE_DOMAIN}${ppath2} will show the site instead of the panel."
        fi
      else
        local ppath3; ppath3=$(panel_path)
        [ -n "$ppath3" ] && warn "The panel is NOT published on this domain - https://${SITE_DOMAIN}${ppath3} shows the site. Enable it from: Camouflage Site > Panel on Site Domain."
      fi
    else
      ok "Site is live on port 80."
    fi
    return 0
  fi
  err "nginx config test failed - rolling the site config back."
  sed -n '1,20p' /tmp/r443.site.err >&2
  rm -f "$SITE_CONF"
  SITE_MODE="none"; save_state
  load_inbounds; write_stream_conf >/dev/null 2>&1 || true
  nginx -t >/dev/null 2>&1 && { systemctl reload "$NGINX_SERVICE" 2>/dev/null || true; }
  return 1
}

# ---- phase 1: questions (asked up front) ----------------------------------
SITE_SRC=""
site_pick_local() {
  local -a cands=()
  mapfile -t cands < <(find_index_candidates)
  local src=""
  if [ "${#cands[@]}" -gt 0 ]; then
    printf '%sindex.html files found on this server:%s\n' "$C_PURPLE" "$R"
    local k
    for k in "${!cands[@]}"; do
      printf '  %-3s %s\n' "$((k + 1))" "${cands[$k]}"
    done
    printf '  %-3s %s\n' "0" "enter a path manually"
    local pick
    while true; do
      printf '%sPick a file%s: ' "$(next_c)" "$R"
      IFS= read -r pick || pick=""
      if [ "$pick" = "0" ]; then src=""; break; fi
      if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#cands[@]}" ]; then
        src="${cands[$((pick - 1))]}"; break
      fi
      err "Pick a number from the list."
    done
  else
    warn "No index.html found in the usual web roots."
  fi
  if [ -z "$src" ]; then
    while true; do
      printf '%sFull path to an index.html%s: ' "$(next_c)" "$R"
      IFS= read -r src || src=""
      [ -f "$src" ] && break
      err "File not found: ${src:-<empty>}"
    done
  fi
  SITE_SRC="$src"
  choose_cert || warn "The site will only be reachable over http:// until a certificate exists."
  return 0
}

site_ask_redirect() {
  local dom
  dom=$(ask "Site to redirect to (no https://)" v_bare_domain "$SITE_TARGET")
  SITE_TARGET="$dom"
  choose_cert || warn "The redirect will only work over http:// until a certificate exists."
  return 0
}

# ---- phase 2: apply --------------------------------------------------------
# shellcheck disable=SC2120  # optional arg, normally uses SITE_SRC
site_apply_local() {
  local src="${1:-$SITE_SRC}"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    err "No source index.html selected."
    return 1
  fi
  mkdir -p "$SITE_ROOT"
  local srcdir; srcdir=$(dirname "$src")
  if [ "$srcdir" = "$SITE_ROOT" ]; then
    info "Source is already the site root - nothing to copy."
  else
    cp -a "${srcdir}/." "$SITE_ROOT"/ 2>/dev/null || cp -a "$src" "${SITE_ROOT}/index.html"
    ok "Copied site files from ${srcdir} to ${SITE_ROOT}"
  fi
  [ -f "${SITE_ROOT}/index.html" ] || cp -a "$src" "${SITE_ROOT}/index.html"
  chown -R www-data:www-data "$SITE_ROOT" 2>/dev/null || true
  chmod -R a+rX "$SITE_ROOT" 2>/dev/null || true
  SITE_MODE="local"; SITE_TARGET=""
  save_state
  apply_site
}

site_apply_redirect() {
  [ -n "$SITE_TARGET" ] || { err "No redirect target set."; return 1; }
  SITE_MODE="redirect"
  save_state
  apply_site
}

site_disable() {
  local c; c=$(ask "Disable the site? [y/N]" v_yn "no")
  [ "$c" = "yes" ] || { warn "Cancelled."; return 0; }
  rm -f "$SITE_CONF"
  SITE_MODE="none"; SITE_TARGET=""; SITE_DOMAIN=""; SITE_CERT=""; SITE_KEY=""
  save_state
  load_inbounds; write_stream_conf >/dev/null 2>&1 || true
  if nginx -t >/dev/null 2>&1; then
    systemctl reload "$NGINX_SERVICE" 2>/dev/null || true
    ok "Site disabled."
  else
    err "nginx config test failed after removing the site."
  fi
}

toggle_panel_on_site() {
  if [ "$SITE_MODE" = "none" ] || [ -z "$SITE_DOMAIN" ]; then
    err "Set up the site with a certificate first."
    return 1
  fi
  local ppath; ppath=$(panel_path)
  if [ -z "$ppath" ]; then
    err "The panel has no base path (webBasePath) set."
    err "Set one in the panel (e.g. /xpanel), then come back."
    return 1
  fi
  PANEL_ON_SITE=$(ask "Serve the panel at https://${SITE_DOMAIN}${ppath} ? [y/N]" v_yn "$PANEL_ON_SITE")
  save_state
  apply_site || return 1
  if [ "$PANEL_ON_SITE" = "yes" ]; then
    ok "Panel URL: https://${SITE_DOMAIN}${ppath}/"
  else
    ok "Panel is no longer served under the site domain."
  fi
}

site_menu() {
  while true; do
    header
    load_state
    printf '%sMode        %s%s%s\n' "$C_GRAY" "$C_WHITE" "$SITE_MODE" "$R"
    [ -n "$SITE_DOMAIN" ] && printf '%sDomain      %s%s%s\n' "$C_GRAY" "$C_WHITE" "$SITE_DOMAIN" "$R"
    [ "$SITE_MODE" = "redirect" ] && printf '%sRedirects   %s%s%s\n' "$C_GRAY" "$C_WHITE" "$SITE_TARGET" "$R"
    [ "$SITE_MODE" = "local" ] && printf '%sFiles       %s%s%s\n' "$C_GRAY" "$C_WHITE" "$SITE_ROOT" "$R"
    if [ "$PANEL_ON_SITE" = "yes" ] && [ -n "$SITE_DOMAIN" ]; then
      printf '%sPanel URL   %shttps://%s%s/%s\n' "$C_GRAY" "$C_WHITE" "$SITE_DOMAIN" "$(panel_path)" "$R"
    fi
    echo
    line_c 0 "1) Serve Local Files"
    line_c 1 "2) Redirect to Another Site"
    line_c 2 "3) Change Certificate"
    line_c 3 "4) Panel on Site Domain"
    line_c 4 "5) Disable Site"
    line_c 5 "0) Back"
    local ch
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1) site_pick_local && site_apply_local; pause ;;
      2) site_ask_redirect && site_apply_redirect; pause ;;
      3) if choose_cert; then
           save_state
           if [ "$SITE_MODE" = "none" ]; then
             warn "No site configured yet - set one up first."
           else
             apply_site
           fi
         fi
         pause ;;
      4) toggle_panel_on_site; pause ;;
      5) site_disable; pause ;;
      0) return 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
# Every port sshd is actually listening on. Checked in three ways because
# locking yourself out of the box is the one unrecoverable mistake here:
# the live listeners, sshd_config, and finally the port of THIS session.
ssh_ports() {
  # Every sub-check is "|| true": under set -e/pipefail a grep that simply finds
  # nothing would otherwise abort the whole function and we would fall back to
  # 22, which is exactly how you lock yourself out of a box on a custom port.
  {
    ss -Hltnp 2>/dev/null | grep -i 'sshd' 2>/dev/null | grep -oE ':[0-9]+ ' 2>/dev/null | tr -d ': ' || true
    grep -hoE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
         /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      | grep -oE '[0-9]+' 2>/dev/null || true
    # port of the current SSH session, if any
    local sc="${SSH_CONNECTION:-}"
    [ -n "$sc" ] && printf '%s\n' "${sc##* }"
    true
  } 2>/dev/null | grep -E '^[0-9]+$' 2>/dev/null | sort -un || true
}

# Adds one ufw rule and REPORTS THE TRUTH. Every rule used to be wrapped in
# ">/dev/null 2>&1 || true", so a rule that silently failed still printed OK -
# which is how you end up locked out of a panel the script claims it opened.
fw_allow() {
  local port="$1" label="$2" proto="${3:-tcp}" out
  if out=$(ufw allow "${port}/${proto}" 2>&1); then
    ok "Allowed ${port}/${proto}${label:+  (${label})}"
    return 0
  fi
  err "Failed to allow ${port}/${proto}${label:+ (${label})}: ${out}"
  return 1
}

setup_firewall() {
  local -a detected=()
  mapfile -t detected < <(ssh_ports)

  local sp default_ssh answer
  if [ "${#detected[@]}" -gt 0 ]; then
    printf '%sSSH ports detected on this server%s\n' "$C_PURPLE" "$R"
    for sp in "${detected[@]}"; do
      printf '  %s%s%s\n' "$C_WHITE" "$sp" "$R"
    done
    default_ssh="${detected[*]}"
  else
    warn "Could not detect the SSH port automatically."
    default_ssh="22"
  fi
  echo
  # Always confirmable by hand: detection can miss a non-standard port, and
  # getting this wrong locks you out of the server the moment ufw comes up.
  answer=$(ask "SSH port(s) to keep open" v_port_list_ne "$default_ssh")
  local -a sports=()
  read -ra sports <<< "$answer"

  # Show exactly what will be opened BEFORE touching anything.
  local pp sbp
  pp=$(panel_port); sbp=$(sub_port)
  echo
  printf '%sPorts that will be opened%s\n' "$C_PURPLE" "$R"
  for sp in "${sports[@]}"; do printf '  %-7s %s\n' "$sp" "SSH"; done
  printf '  %-7s %s\n' "80" "http"
  printf '  %-7s %s\n' "443/tcp" "https / proxy"
  printf '  %-7s %s\n' "443/udp" "QUIC / Hysteria2 / TUIC"
  printf '  %-7s %s\n' "$pp" "x-ui panel"
  printf '  %-7s %s\n' "$sbp" "subscription"
  echo
  local extra
  extra=$(ask "Extra ports to open (space separated, blank for none)" v_port_list "")
  local go; go=$(ask "Enable the firewall with these rules? [y/N]" v_yn "no")
  if [ "$go" != "yes" ]; then
    warn "Firewall not changed."
    return 0
  fi

  if ! have ufw; then
    info "Installing ufw..."
    install_pkgs ufw >/dev/null 2>&1 || install_pkgs ufw || true
  fi
  if ! have ufw; then
    err "Could not install ufw on this system."
    return 1
  fi

  local failed=0
  # SSH first, always - enabling ufw without it would lock this session out.
  for sp in "${sports[@]}"; do
    fw_allow "$sp" "SSH" || failed=$((failed + 1))
  done
  if [ "$failed" -gt 0 ]; then
    err "Could not open the SSH port(s). Refusing to enable the firewall."
    return 1
  fi

  fw_allow 80  "http"  || failed=$((failed + 1))
  fw_allow 443 "https / proxy" || failed=$((failed + 1))
  # UDP 443 carries QUIC, Hysteria2 and TUIC. Leaving it closed silently kills
  # those protocols while TCP-based ones keep working, which is hard to spot.
  fw_allow 443 "QUIC / Hysteria2 / TUIC" udp || failed=$((failed + 1))
  # The panel and subscription ports stay open even when they are also reachable
  # through 443: closing them is what makes the panel vanish from the browser
  # for anyone who opens it by IP:port.
  fw_allow "$pp"  "x-ui panel"   || failed=$((failed + 1))
  fw_allow "$sbp" "subscription" || failed=$((failed + 1))

  local e
  for e in $extra; do
    fw_allow "$e" "extra" || failed=$((failed + 1))
    fw_allow "$e" "extra" udp || failed=$((failed + 1))
  done

  if [ "$failed" -gt 0 ]; then
    err "${failed} rule(s) failed - not enabling the firewall to avoid locking you out."
    return 1
  fi

  if ! ufw --force enable >/tmp/r443.ufw.err 2>&1; then
    err "Could not enable ufw:"
    sed -n '1,10p' /tmp/r443.ufw.err >&2
    return 1
  fi

  echo
  if ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
    warn "ufw did not report active - check 'ufw status'."
    return 1
  fi
  ok "Firewall is active."

  # Verify the rules that matter actually landed, rather than trusting the
  # earlier output.
  local not_open="" check
  for check in "${sports[@]}" 80 443 "$pp" "$sbp"; do
    ufw status 2>/dev/null | grep -qE "^${check}/tcp" || not_open="${not_open} ${check}/tcp"
  done
  ufw status 2>/dev/null | grep -qE '^443/udp' || not_open="${not_open} 443/udp"
  if [ -n "$not_open" ]; then
    err "These ports are NOT open despite the rules:${not_open}"
    err "Run 'ufw disable' if you lose access, then re-run this step."
  else
    ok "Verified: SSH, 80, 443/tcp, 443/udp, panel (${pp}) and subscription (${sbp}) are open."
  fi
  echo
  ufw status 2>/dev/null | sed -n '1,25p'
  return 0
}

# Turns the firewall off - the escape hatch when a rule locks something out.
disable_firewall() {
  if ! have ufw; then
    warn "ufw is not installed."
    return 0
  fi
  local c; c=$(ask "Disable the firewall? [y/N]" v_yn "no")
  [ "$c" = "yes" ] || { warn "Cancelled."; return 0; }
  if ufw disable >/dev/null 2>&1; then
    ok "Firewall disabled."
  else
    err "Could not disable ufw."
  fi
}

firewall_menu() {
  while true; do
    header
    if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
      printf '%sStatus  %sactive%s\n\n' "$C_GRAY" "$C_WHITE" "$R"
    else
      printf '%sStatus  %sinactive%s\n\n' "$C_GRAY" "$C_WHITE" "$R"
    fi
    line_c 0 "1) Enable Firewall"
    line_c 1 "2) Disable Firewall"
    line_c 2 "3) Show Rules"
    line_c 3 "0) Back"
    local ch
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1) setup_firewall; pause ;;
      2) disable_firewall; pause ;;
      3) if have ufw; then ufw status verbose 2>/dev/null | sed -n '1,30p'; else warn "ufw is not installed."; fi; pause ;;
      0) return 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    header
    line_c 0 "1) Setup 443 Routing"
    line_c 1 "2) Sync New Inbounds"
    line_c 2 "3) Camouflage Site"
    line_c 3 "4) Firewall"
    line_c 4 "5) Manage Hosts"
    line_c 5 "6) Panel and Ports"
    line_c 6 "7) Services"
    line_c 7 "8) Diagnose"
    line_c 8 "9) Rollback Last Change"
    line_c 1 "10) Remove 443 Routing"
    line_c 0 "0) Exit"
    local ch
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1) do_setup ;;
      2) do_sync ;;
      3) site_menu ;;
      4) firewall_menu ;;
      5) manage_hosts ;;
      6) panel_menu ;;
      7) services_menu ;;
      8) diagnose ;;
      9) do_rollback ;;
      10) do_remove ;;
      0) clear; exit 0 ;;
      *) err "Pick a number from the list."; pause ;;
    esac
  done
}

main() {
  require_root
  ensure_deps
  mkdir -p "$BACKUP_ROOT" "$STATE_DIR"
  load_state
  main_menu
}

main "$@"
