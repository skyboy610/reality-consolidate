#!/usr/bin/env bash
# reality-443.sh - Consolidate 3x-ui Reality inbounds behind a single public
# port 443 using nginx stream + ssl_preread (SNI routing, no TLS termination).
set -euo pipefail

SCRIPT_VERSION="2.9.2"

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

# True if the address is a private/RFC1918 IP (a GRE/WireGuard tunnel address).
# Such inbounds keep their listen IP - we still reassign the port and route to
# "<that IP>:<newport>" instead of 127.0.0.1, because the inbound is reachable
# on a tunnel interface, not loopback.
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
xsql() { sqlite3 "$DB_PATH" "$1"; }

db_ready() {
  [ -f "$DB_PATH" ] || { err "Database not found at ${DB_PATH}"; return 1; }
  sqlite3 "$DB_PATH" "SELECT 1 FROM inbounds LIMIT 1;" >/dev/null 2>&1 || {
    err "Cannot read the inbounds table in ${DB_PATH}"; return 1; }
  return 0
}

detect_host_mechanism() {
  if xsql "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts';" | grep -q '^hosts$'; then
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
  exists=$(xsql "SELECT COUNT(*) FROM settings WHERE key='${ek}';")
  if [ "$exists" -gt 0 ]; then
    xsql "UPDATE settings SET value='${ev}' WHERE key='${ek}';"
  else
    xsql "INSERT INTO settings (key, value) VALUES ('${ek}', '${ev}');"
  fi
}

panel_port() { local p; p=$(get_setting webPort); [ -n "$p" ] || p="$DEFAULT_PANEL_PORT"; printf '%s\n' "$p"; }
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
  local json n i row sec __lst
  json=$(q "SELECT id, remark, listen, port, protocol, stream_settings FROM inbounds WHERE enable=1 OR enable IS NULL;")
  n=$(printf '%s' "$json" | jq 'length')
  for ((i = 0; i < n; i++)); do
    row=$(printf '%s' "$json" | jq -c ".[$i]")
    sec=$(printf '%s' "$row" | jq -r '(.stream_settings // "{}") | fromjson? | .security // ""')
    [ "$sec" = "reality" ] || continue
    __lst=$(printf '%s' "$row" | jq -r '.listen // ""')
    if is_private_ip "$__lst"; then
      # tunnel inbound (private IP) - track separately, never route or rewrite
      TUN_ID+=("$(printf '%s' "$row" | jq -r '.id')")
      TUN_REMARK+=("$(printf '%s' "$row" | jq -r '.remark // ""')")
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
  while IFS= read -r p; do [ -n "$p" ] && TAKEN_PORTS["$p"]=db; done < <(xsql "SELECT port FROM inbounds;")
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
}

save_state() {
  mkdir -p "$STATE_DIR"
  jq -n --arg ph "$PUBLIC_HOST" --arg pa "$PANEL_HOST" --arg su "$SUB_HOST" \
        --arg pr "$PANEL_ROUTE" --arg sr "$SUB_ROUTE" \
    '{public_host:$ph, panel_host:$pa, sub_host:$su, panel_route:$pr, sub_route:$sr}' > "$STATE_FILE"
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
  local default_backend="" tmp i pport sport bip
  tmp=$(mktemp)
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    if is_routable_listen "${RI_LISTEN[$i]}" && [ -n "${RI_SNI[$i]}" ]; then
      default_backend="$(backend_ip "${RI_LISTEN[$i]}"):${RI_PORT[$i]}"
      break
    fi
  done
  if [ -z "$default_backend" ]; then
    err "No consolidated inbound found - nothing to route."
    rm -f "$tmp"; return 1
  fi

  {
    echo "# Generated by reality-443.sh v${SCRIPT_VERSION} - do not edit by hand."
    echo "map \$ssl_preread_server_name \$reality443 {"
    echo "    default ${default_backend};"
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
      if is_routable_listen "${RI_LISTEN[$i]}" && [ -n "${RI_SNI[$i]}" ]; then
        bip=$(backend_ip "${RI_LISTEN[$i]}")
        # A Reality inbound can serve many serverNames, and a client link may
        # use ANY of them - map every one to this inbound's backend, or the
        # unlisted ones fall through to "default" and hit the wrong inbound.
        local sn
        for sn in ${RI_SNIS[$i]}; do
          printf '    "%s" %s:%s;\n' "$sn" "$bip" "${RI_PORT[$i]}"
        done
      fi
    done
    if [ "$PANEL_ROUTE" = "yes" ] && [ -n "$PANEL_HOST" ]; then
      pport=$(panel_port)
      printf '    "%s" 127.0.0.1:%s;\n' "$PANEL_HOST" "$pport"
    fi
    if [ "$SUB_ROUTE" = "yes" ] && [ -n "$SUB_HOST" ]; then
      sport=$(sub_port)
      printf '    "%s" 127.0.0.1:%s;\n' "$SUB_HOST" "$sport"
    fi
    echo "}"
    echo ""
    echo "server {"
    echo "    listen 443 reuseport;"
    echo "    listen [::]:443 reuseport;"
    echo "    proxy_pass \$reality443;"
    echo "    ssl_preread on;"
    echo "    proxy_timeout 1h;"
    echo "    proxy_connect_timeout 5s;"
    echo "}"
  } > "$tmp"
  mv "$tmp" "$STREAM_FILE"
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

hook_stream_include() {
  if grep -qF "$STREAM_FILE" "$NGINX_CONF" 2>/dev/null; then return 0; fi

  local hit; hit=$(find_toplevel_stream "$NGINX_CONF" || true)
  if [ -n "$hit" ]; then
    warn "An existing top-level stream {} block was found in nginx.conf (line ${hit})."
    warn "Add this line inside it manually, then re-run:"
    warn "    include ${STREAM_FILE};"
    return 1
  fi

  {
    echo ""
    echo "$MARK_BEGIN"
    echo "stream {"
    echo "    include ${STREAM_FILE};"
    echo "}"
    echo "$MARK_END"
  } >> "$NGINX_CONF"
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
    existing=$(xsql "SELECT id FROM hosts WHERE inbound_id=${id} LIMIT 1;")
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

check_sni_unique() {
  local -A owner=()
  local idx s
  for idx in "$@"; do
    s="${RI_SNI[$((idx - 1))]}"
    if [ -z "$s" ]; then
      err "'${RI_REMARK[$((idx - 1))]}' has no Reality serverName - it cannot be routed by SNI."
      return 1
    fi
    if [ -n "${owner[$s]:-}" ]; then
      err "SNI '${s}' is used by both '${owner[$s]}' and '${RI_REMARK[$((idx - 1))]}'."
      err "Give each inbound a unique serverName in the panel, then re-run."
      return 1
    fi
    owner[$s]="${RI_REMARK[$((idx - 1))]}"
  done
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
  warn "This removes the nginx 443 routing and puts inbounds back on public ports."
  local go; go=$(ask "Proceed? [y/N]" v_yn "no")
  [ "$go" = "yes" ] || { warn "Cancelled."; pause; return 0; }

  backup_now >/dev/null

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
    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || true
    ok "Inbound ports restored from ${orig}."
  else
    warn "No original-ports record found - inbound ports left as they are."
  fi

  unhook_stream_include
  if have nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE" 2>/dev/null || true
      ok "nginx routing removed."
    else
      err "nginx config is invalid after removal - check it manually."
    fi
  fi
  pause
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
  while true; do
    header
    line_c 0 "1) Setup 443 Routing"
    line_c 1 "2) Sync New Inbounds"
    line_c 2 "3) Panel and Ports"
    line_c 3 "4) Services"
    line_c 4 "5) Diagnose"
    line_c 5 "6) Rollback Last Change"
    line_c 6 "7) Remove 443 Routing"
    line_c 7 "0) Exit"
    local ch
    printf '%sChoice%s: ' "$(next_c)" "$R"
    IFS= read -r ch || ch=0
    case "$ch" in
      1) do_setup ;;
      2) do_sync ;;
      3) panel_menu ;;
      4) services_menu ;;
      5) diagnose ;;
      6) do_rollback ;;
      7) do_remove ;;
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
