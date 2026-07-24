#!/usr/bin/env bash
# reality-consolidate.sh - consolidate 3x-ui Xray Reality inbounds onto a
# single public port 443 via nginx stream + ssl_preread SNI routing.
set -euo pipefail

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.1.0"

# ---------------------------------------------------------------------------
# Globals (all initialized up front - set -u forbids reading unset vars)
# ---------------------------------------------------------------------------
: "${DB_PATH:=/etc/x-ui/x-ui.db}"
: "${NGINX_CONF:=/etc/nginx/nginx.conf}"
: "${NGINX_DIR:=/etc/nginx}"
: "${BACKUP_ROOT:=/etc/x-ui-reality-backups}"
: "${XUI_SERVICE:=x-ui}"
: "${NGINX_SERVICE:=nginx}"

STREAM_INCLUDE_FILE="${NGINX_DIR}/streams-reality.conf"
STATE_FILE="${BACKUP_ROOT}/state.conf"
MARK_BEGIN="# BEGIN reality-consolidate managed stream block"
MARK_END="# END reality-consolidate managed stream block"
MIN_INTERNAL_PORT=10001
MAX_INTERNAL_PORT=19999

# Persisted-across-runs settings (loaded from STATE_FILE if present)
PUBLIC_HOST=""
PANEL_HOSTNAME=""
SUB_HOSTNAME=""
PANEL_ROUTING_ENABLED="no"

# Working arrays populated by load_reality_inbounds
declare -a RI_ID=()
declare -a RI_REMARK=()
declare -a RI_LISTEN=()
declare -a RI_PORT=()
declare -a RI_PROTOCOL=()
declare -a RI_SNI=()
declare -a RI_STREAM_JSON=()

# Ports assigned/claimed during the current run (bash 4+ assoc array)
declare -A ASSIGNED_PORTS=()
# Cycles through the palette so each distinct prompt line gets its own color.
PROMPT_COLOR_IDX=0
# All ports currently used by any row in the inbounds table (built by
# build_db_ports_set before port assignment), so a freshly assigned port
# never collides with a not-yet-running inbound that "ss" can't see.
declare -A DB_PORTS_SET=()

# ---------------------------------------------------------------------------
# Colors (256-color palette). Green/red/orange reserved for
# success/error/warning only - never decorative.
# ---------------------------------------------------------------------------
C_RESET=$'\033[0m'
C_OLIVE=$'\033[38;5;100m'
C_PALEPINK=$'\033[38;5;217m'
C_CHERRY=$'\033[38;5;131m'
C_CHOC=$'\033[38;5;94m'
C_PALEPURPLE=$'\033[38;5;183m'
C_TURQ=$'\033[38;5;80m'
C_PALEBLUE=$'\033[38;5;153m'
C_GOLD=$'\033[38;5;178m'
C_WHITE=$'\033[38;5;255m'

C_SUCCESS=$'\033[1;38;5;40m'
C_ERROR=$'\033[1;38;5;196m'
C_WARN=$'\033[1;38;5;208m'

BG_GREEN=$'\033[48;5;40m'
BG_RED=$'\033[48;5;196m'
FG_DARK=$'\033[38;5;232m'
FG_WHITE=$'\033[38;5;255m'

PALETTE=("$C_OLIVE" "$C_PALEPINK" "$C_CHERRY" "$C_CHOC" "$C_PALEPURPLE" "$C_TURQ" "$C_PALEBLUE" "$C_GOLD")

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s[OK] %s%s\n' "$C_SUCCESS" "$*" "$C_RESET"; }
err()   { printf '%s[ERROR] %s%s\n' "$C_ERROR" "$*" "$C_RESET" >&2; }
warn()  { printf '%s[WARN] %s%s\n' "$C_WARN" "$*" "$C_RESET"; }
palette_line() { local idx="$1"; shift; printf '%s%s%s\n' "${PALETTE[$((idx % ${#PALETTE[@]}))]}" "$*" "$C_RESET"; }
next_prompt_color() {
  printf '%s' "${PALETTE[$((PROMPT_COLOR_IDX % ${#PALETTE[@]}))]}"
  PROMPT_COLOR_IDX=$((PROMPT_COLOR_IDX + 1))
}

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

pause() { local _dummy; printf '%s\n' "${C_WHITE}Press Enter to continue...${C_RESET}"; read -r _dummy || true; }

# ---------------------------------------------------------------------------
# Dependency / status detection
# ---------------------------------------------------------------------------
ensure_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    return 0
  fi
  warn "sqlite3 is not installed. Attempting to install it."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y sqlite3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sqlite
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sqlite
  else
    err "No supported package manager found. Install sqlite3 manually and re-run."
    exit 1
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    err "sqlite3 installation failed."
    exit 1
  fi
  ok "sqlite3 installed."
}

is_nginx_installed() {
  command -v nginx >/dev/null 2>&1
}

# Prints "static" (module baked into the nginx binary, always available),
# "dynamic" (module built as a loadable .so, needs a load_module directive),
# or "missing" (nginx was not built with the stream module at all - some
# distributions ship it as a separate package instead, e.g. Debian/Ubuntu's
# libnginx-mod-stream).
stream_module_state() {
  local v
  v=$(nginx -V 2>&1)
  if printf '%s' "$v" | grep -q -- '--with-stream=dynamic'; then
    printf 'dynamic\n'
  elif printf '%s' "$v" | grep -q -- '--with-stream'; then
    printf 'static\n'
  else
    printf 'missing\n'
  fi
}

nginx_modules_path() {
  local p
  p=$(nginx -V 2>&1 | grep -oE -- '--modules-path=[^ ]+' | head -n1 | cut -d= -f2)
  [ -n "$p" ] || p="/usr/lib/nginx/modules"
  printf '%s\n' "$p"
}

# For the "dynamic" case: makes sure a load_module directive for
# ngx_stream_module.so is actually reachable from $NGINX_CONF (directly or via
# a depth-0 include, e.g. Debian/Ubuntu's modules-enabled/*.conf), inserting
# one at the very top of $NGINX_CONF if not. nginx requires load_module to
# appear before any other context, so it must go before events{}/http{}.
ensure_stream_module_loaded() {
  local state
  state=$(stream_module_state)
  case "$state" in
    missing)
      err "nginx was not built with the stream module (no --with-stream in 'nginx -V'). On Debian/Ubuntu install the separate 'libnginx-mod-stream' package, or use an nginx build that includes it, then re-run."
      return 1
      ;;
    static)
      return 0
      ;;
  esac

  local mods_path so_file
  mods_path=$(nginx_modules_path)
  so_file="${mods_path}/ngx_stream_module.so"
  if [ ! -f "$so_file" ]; then
    err "nginx reports the stream module as dynamic, but ${so_file} was not found. On Debian/Ubuntu install 'libnginx-mod-stream', then re-run."
    return 1
  fi

  if grep -qE 'load_module[[:space:]]+.*ngx_stream_module\.so' "$NGINX_CONF" 2>/dev/null; then
    return 0
  fi
  local inc f
  while IFS= read -r inc; do
    for f in $inc; do
      [ -f "$f" ] || continue
      if grep -qE 'load_module[[:space:]]+.*ngx_stream_module\.so' "$f" 2>/dev/null; then
        return 0
      fi
    done
  done < <(depth0_includes "$NGINX_CONF")

  warn "nginx's stream module is dynamic and not yet loaded. Adding 'load_module ${so_file};' to the top of ${NGINX_CONF}."
  local tmp
  tmp=$(mktemp)
  { printf 'load_module %s;\n' "$so_file"; cat "$NGINX_CONF"; } > "$tmp"
  mv "$tmp" "$NGINX_CONF"
}

is_stream_configured() {
  [ -f "$STREAM_INCLUDE_FILE" ] || return 1
  grep -qF "$MARK_BEGIN" "$NGINX_CONF" 2>/dev/null && return 0
  grep -qF "$STREAM_INCLUDE_FILE" "$NGINX_CONF" 2>/dev/null
}

print_status_banner() {
  local label="$1" installed="$2" text bg fg
  if [ "$installed" = "yes" ]; then
    bg="$BG_GREEN"; fg="$FG_DARK"; text="${label}: INSTALLED"
  else
    bg="$BG_RED"; fg="$FG_WHITE"; text="${label}: NOT INSTALLED"
  fi
  printf '%s%s %-40s %s\n' "$bg" "$fg" "$text" "$C_RESET"
}

print_status_banners() {
  local nginx_ok="no" stream_ok="no"
  is_nginx_installed && nginx_ok="yes"
  is_stream_configured && stream_ok="yes"
  print_status_banner "NGINX" "$nginx_ok"
  print_status_banner "STREAM CONFIG" "$stream_ok"
  echo
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
print_header() {
  clear
  local -a lines=(
    '######  #######    #    #       ### ####### #     # '
    '#     # #         # #   #        #     #     #   #  '
    '#     # #        #   #  #        #     #      # #   '
    '######  #####   #     # #        #     #       #    '
    '#   #   #       ####### #        #     #       #    '
    '#    #  #       #     # #        #     #       #    '
    '#     # ####### #     # ####### ###    #       #    '
  )
  local i=0
  for line in "${lines[@]}"; do
    palette_line "$i" "$line"
    i=$((i + 1))
  done
  printf '%sReality-on-443 Consolidator  v%s%s\n\n' "$C_WHITE" "$SCRIPT_VERSION" "$C_RESET"
  print_status_banners
}

# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------
load_state() {
  [ -f "$STATE_FILE" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      PUBLIC_HOST) PUBLIC_HOST="$value" ;;
      PANEL_HOSTNAME) PANEL_HOSTNAME="$value" ;;
      SUB_HOSTNAME) SUB_HOSTNAME="$value" ;;
      PANEL_ROUTING_ENABLED) PANEL_ROUTING_ENABLED="$value" ;;
    esac
  done < "$STATE_FILE"
}

save_state() {
  mkdir -p "$BACKUP_ROOT"
  {
    printf 'PUBLIC_HOST=%s\n' "$PUBLIC_HOST"
    printf 'PANEL_HOSTNAME=%s\n' "$PANEL_HOSTNAME"
    printf 'SUB_HOSTNAME=%s\n' "$SUB_HOSTNAME"
    printf 'PANEL_ROUTING_ENABLED=%s\n' "$PANEL_ROUTING_ENABLED"
  } > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Input validation loops
# ---------------------------------------------------------------------------
# ask_loop PROMPT VALIDATOR_FN [DEFAULT]
# Prints PROMPT, reads a line, calls VALIDATOR_FN "$answer" which must echo the
# normalized value and return 0, or print an error and return 1. Loops forever
# on invalid input - never aborts the flow. Echoes the accepted value on stdout.
ask_loop() {
  local prompt="$1" validator="$2" default="${3:-}"
  local ans normalized rc color
  color=$(next_prompt_color)
  while true; do
    if [ -n "$default" ]; then
      printf '%s%s %s(%s)%s: ' "$color" "$prompt" "$C_WHITE" "$default" "$C_RESET" >&2
    else
      printf '%s%s%s: ' "$color" "$prompt" "$C_RESET" >&2
    fi
    IFS= read -r ans || ans=""
    if [ -z "$ans" ] && [ -n "$default" ]; then
      ans="$default"
    fi
    if normalized=$("$validator" "$ans" 2>/tmp/reality_ask_loop_err); then
      printf '%s\n' "$normalized"
      return 0
    fi
    err "$(cat /tmp/reality_ask_loop_err 2>/dev/null)"
    rc=1
    : "$rc"
  done
}

validate_hostname() {
  local v="$1"
  if [[ "$v" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  printf 'Not a valid hostname (expected something like sub.example.com).\n' >&2
  return 1
}

validate_ipv4() {
  local v="$1" IFS='.' octets o
  read -ra octets <<< "$v"
  if [ "${#octets[@]}" -ne 4 ]; then
    printf 'Not a valid IPv4 address.\n' >&2
    return 1
  fi
  for o in "${octets[@]}"; do
    if ! [[ "$o" =~ ^[0-9]{1,3}$ ]] || [ "$o" -gt 255 ]; then
      printf 'Not a valid IPv4 address.\n' >&2
      return 1
    fi
  done
  printf '%s\n' "$v"
  return 0
}

validate_host_or_ip() {
  local v="$1"
  if validate_ipv4 "$v" >/dev/null 2>&1 || validate_hostname "$v" >/dev/null 2>&1; then
    printf '%s\n' "$v"
    return 0
  fi
  printf 'Enter a valid domain name or IPv4 address.\n' >&2
  return 1
}

validate_yes_no() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    y|yes) printf 'yes\n'; return 0 ;;
    n|no|"") printf 'no\n'; return 0 ;;
    *) printf 'Please answer y or n.\n' >&2; return 1 ;;
  esac
}

validate_nonempty_indices() {
  printf '%s\n' "$1"
  return 0
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
is_port_bound() {
  local port="$1"
  ss -Htln "( sport = :${port} )" 2>/dev/null | grep -q .
}

build_db_ports_set() {
  DB_PORTS_SET=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && DB_PORTS_SET[$p]=1
  done < <(all_inbound_ports)
}

find_free_port() {
  local start="$1" exclude="${2:-}" port
  port="$start"
  while [ "$port" -le "$MAX_INTERNAL_PORT" ]; do
    if [ -z "${ASSIGNED_PORTS[$port]:-}" ] && ! is_port_bound "$port" \
      && { [ -z "${DB_PORTS_SET[$port]:-}" ] || [ "$port" = "$exclude" ]; }; then
      ASSIGNED_PORTS[$port]=1
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  err "No free internal port found between $MIN_INTERNAL_PORT and $MAX_INTERNAL_PORT."
  return 1
}

check_port_443_owner() {
  if ! is_port_bound 443; then
    return 0
  fi
  local owner
  owner=$(ss -Htlnp "( sport = :443 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | sed 's/users:(("//')
  if [ "$owner" != "nginx" ] && [ -n "$owner" ]; then
    warn "Port 443 is already bound by '${owner}', not nginx. Consolidation will conflict with it."
  elif [ -z "$owner" ]; then
    warn "Port 443 is already bound, but the owning process could not be identified (run as root to see it)."
  fi
}

# ---------------------------------------------------------------------------
# Database access
# ---------------------------------------------------------------------------
db_query() {
  # db_query SQL  -> executes with sqlite3 -json against DB_PATH
  sqlite3 -json "$DB_PATH" "$1"
}

db_exec_file() {
  # db_exec_file SQLFILE -> executes a script of statements against DB_PATH
  sqlite3 "$DB_PATH" < "$1"
}

load_reality_inbounds() {
  RI_ID=(); RI_REMARK=(); RI_LISTEN=(); RI_PORT=(); RI_PROTOCOL=(); RI_SNI=(); RI_STREAM_JSON=()
  local json
  json=$(db_query "SELECT id, remark, listen, port, protocol, stream_settings FROM inbounds;")
  local count
  count=$(printf '%s' "$json" | jq 'length')
  local i
  for ((i = 0; i < count; i++)); do
    local row security sni
    row=$(printf '%s' "$json" | jq ".[$i]")
    security=$(printf '%s' "$row" | jq -r '.stream_settings | fromjson? | .security // empty' 2>/dev/null || true)
    if [ "$security" != "reality" ]; then
      continue
    fi
    sni=$(printf '%s' "$row" | jq -r '.stream_settings | fromjson | .realitySettings.serverNames[0] // empty')
    RI_ID+=("$(printf '%s' "$row" | jq -r '.id')")
    RI_REMARK+=("$(printf '%s' "$row" | jq -r '.remark // empty')")
    RI_LISTEN+=("$(printf '%s' "$row" | jq -r '.listen // empty')")
    RI_PORT+=("$(printf '%s' "$row" | jq -r '.port')")
    RI_PROTOCOL+=("$(printf '%s' "$row" | jq -r '.protocol')")
    RI_SNI+=("$sni")
    RI_STREAM_JSON+=("$(printf '%s' "$row" | jq -c '.stream_settings | fromjson')")
  done
}

all_inbound_ports() {
  db_query "SELECT port FROM inbounds;" | jq -r '.[].port'
}

get_setting() {
  local key="$1" esc
  esc=$(sql_escape "$key")
  db_query "SELECT value FROM settings WHERE key='${esc}';" | jq -r '.[0].value // empty'
}

# ---------------------------------------------------------------------------
# Table printing
# ---------------------------------------------------------------------------
print_reality_table() {
  printf '%s%-4s %-22s %-8s %-12s %-10s %-30s%s\n' \
    "$C_TURQ" "#" "Remark" "Port" "Listen" "Protocol" "SNI (serverNames[0])" "$C_RESET"
  local i
  for ((i = 0; i < ${#RI_ID[@]}; i++)); do
    local listen_disp="${RI_LISTEN[$i]}"
    [ -z "$listen_disp" ] && listen_disp="0.0.0.0"
    printf '%-4s %-22s %-8s %-12s %-10s %-30s\n' \
      "$((i + 1))" "${RI_REMARK[$i]:-<none>}" "${RI_PORT[$i]}" "$listen_disp" "${RI_PROTOCOL[$i]}" "${RI_SNI[$i]:-<none>}"
  done
  echo
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
backup_all() {
  local ts backup_dir manifest
  ts=$(date +%Y%m%d-%H%M%S)
  backup_dir="${BACKUP_ROOT}/${ts}"
  mkdir -p "$backup_dir"
  manifest="${backup_dir}/manifest.txt"
  : > "$manifest"

  cp -a "$DB_PATH" "${backup_dir}/x-ui.db"
  printf 'DB\t%s\t%s\n' "$DB_PATH" "x-ui.db" >> "$manifest"

  if [ -f "$NGINX_CONF" ]; then
    cp -a "$NGINX_CONF" "${backup_dir}/nginx.conf"
    printf 'FILE\t%s\t%s\n' "$NGINX_CONF" "nginx.conf" >> "$manifest"
  fi
  if [ -f "$STREAM_INCLUDE_FILE" ]; then
    cp -a "$STREAM_INCLUDE_FILE" "${backup_dir}/streams-reality.conf"
    printf 'FILE\t%s\t%s\n' "$STREAM_INCLUDE_FILE" "streams-reality.conf" >> "$manifest"
  fi

  ln -sfn "$ts" "${BACKUP_ROOT}/latest"
  ok "Backed up DB and nginx files to ${backup_dir}"
  printf '%s\n' "$backup_dir"
}

rollback_nginx_only() {
  # restore only nginx-related files from the given backup dir (used on nginx -t failure)
  local backup_dir="$1" manifest line kind orig rel
  manifest="${backup_dir}/manifest.txt"
  [ -f "$manifest" ] || return 1
  while IFS=$'\t' read -r kind orig rel; do
    [ "$kind" = "FILE" ] || continue
    if [ -f "${backup_dir}/${rel}" ]; then
      cp -a "${backup_dir}/${rel}" "$orig"
    fi
  done < "$manifest"
}

rollback_latest() {
  local latest_link="${BACKUP_ROOT}/latest" backup_dir manifest kind orig rel
  if [ ! -L "$latest_link" ] && [ ! -d "$latest_link" ]; then
    err "No backup found under ${BACKUP_ROOT}. Nothing to roll back."
    return 1
  fi
  backup_dir=$(readlink -f "$latest_link")
  manifest="${backup_dir}/manifest.txt"
  if [ ! -f "$manifest" ]; then
    err "Backup manifest missing at ${manifest}."
    return 1
  fi
  say "About to restore from: ${backup_dir}"
  local confirm
  confirm=$(ask_loop "Proceed with rollback? [y/N]" validate_yes_no "no")
  if [ "$confirm" != "yes" ]; then
    warn "Rollback cancelled."
    return 1
  fi
  while IFS=$'\t' read -r kind orig rel; do
    case "$kind" in
      DB) cp -a "${backup_dir}/${rel}" "$orig" ;;
      FILE) cp -a "${backup_dir}/${rel}" "$orig" ;;
    esac
  done < "$manifest"
  ok "Files restored from ${backup_dir}."

  if is_nginx_installed; then
    if nginx -t -c "$NGINX_CONF" 2>/tmp/reality_nginx_test_err; then
      systemctl reload "$NGINX_SERVICE" || systemctl restart "$NGINX_SERVICE"
      ok "nginx reloaded."
    else
      err "nginx -t failed after rollback:"
      cat /tmp/reality_nginx_test_err >&2
    fi
  fi
  if systemctl restart "$XUI_SERVICE"; then
    ok "${XUI_SERVICE} restarted."
  else
    err "Failed to restart ${XUI_SERVICE}."
  fi
}

# ---------------------------------------------------------------------------
# nginx stream block generation
# ---------------------------------------------------------------------------
# Finds a top-level (brace-depth 0) "stream {" block in a file. Prints
# "<file>:<line>" if found (foreign block not created by us), nothing if not.
find_foreign_stream_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -qF "$MARK_BEGIN" "$file" && return 0
  awk '
    { line=$0; gsub(/#.*/,"",line) }
    { for (i=1;i<=length(line);i++) {
        c=substr(line,i,1)
        if (c=="{") { if (depth==0 && line ~ /stream[[:space:]]*\{[[:space:]]*$/ && found==0) { print NR; found=1 } depth++ }
        else if (c=="}") { depth-- }
      }
    }
  ' "$file"
}

insert_include_into_foreign_block() {
  local file="$1" line="$2" tmp
  tmp=$(mktemp)
  awk -v startline="$line" -v inc="    include ${STREAM_INCLUDE_FILE};" '
    BEGIN { depth=0; inserted=0 }
    {
      out=$0
      plain=$0; gsub(/#.*/,"",plain)
      if (NR==startline) { depth=1; print out; next }
      if (depth>0) {
        for (i=1;i<=length(plain);i++) {
          c=substr(plain,i,1)
          if (c=="{") depth++
          else if (c=="}") {
            depth--
            if (depth==0 && inserted==0) { print inc; inserted=1 }
          }
        }
      }
      print out
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Prints the target paths of "include ...;" directives that sit at brace
# depth 0 (i.e. outside http{}/stream{}/etc.) in the given file - so we only
# ever chase includes that could plausibly hold a top-level stream {} block.
depth0_includes() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    { line=$0; sub(/#.*/,"",line) }
    depth==0 && line ~ /include[ \t]+/ { print line }
    {
      n=length(line)
      for (i=1;i<=n;i++) {
        c=substr(line,i,1)
        if (c=="{") depth++
        else if (c=="}") depth--
      }
    }
  ' "$file" | sed -E 's/^[[:space:]]*include[[:space:]]+"?([^"; 	]+)"?[[:space:]]*;.*/\1/'
}

ensure_stream_context() {
  if grep -qF "$MARK_BEGIN" "$NGINX_CONF" 2>/dev/null; then
    return 0
  fi
  if grep -qF "$STREAM_INCLUDE_FILE" "$NGINX_CONF" 2>/dev/null; then
    return 0
  fi

  local hit
  hit=$(find_foreign_stream_block "$NGINX_CONF")
  if [ -n "$hit" ]; then
    warn "Found an existing top-level stream {} block in ${NGINX_CONF} (line ${hit}); inserting our include into it instead of creating a second one."
    insert_include_into_foreign_block "$NGINX_CONF" "$hit"
    return 0
  fi

  # Check one level of top-level includes for a foreign stream block.
  local inc_file f
  while IFS= read -r inc_file; do
    [ -z "$inc_file" ] && continue
    for f in $inc_file; do
      [ -f "$f" ] || continue
      hit=$(find_foreign_stream_block "$f")
      if [ -n "$hit" ]; then
        warn "Found an existing top-level stream {} block in included file ${f} (line ${hit}); inserting our include into it."
        insert_include_into_foreign_block "$f" "$hit"
        return 0
      fi
    done
  done < <(depth0_includes "$NGINX_CONF")

  # No stream context anywhere reachable: append our own top-level block.
  {
    echo ""
    echo "$MARK_BEGIN"
    echo "stream {"
    echo "    include ${STREAM_INCLUDE_FILE};"
    echo "}"
    echo "$MARK_END"
  } >> "$NGINX_CONF"
}

# Regenerates the streams-reality.conf include file from the CURRENT state of
# the database (every already-consolidated Reality inbound, not just the ones
# picked in this run) plus the persisted panel/sub hostnames. Idempotent by
# construction: it is a full rebuild, never an append.
generate_stream_include() {
  local default_port="$1"
  local tmp
  tmp=$(mktemp)
  {
    echo "# Managed by reality-consolidate.sh - regenerated on every run, do not edit by hand."
    echo "map \$ssl_preread_server_name \$reality_backend {"
    echo "    default 127.0.0.1:${default_port};"
    local i
    for ((i = 0; i < ${#RI_ID[@]}; i++)); do
      if [ "${RI_LISTEN[$i]}" = "127.0.0.1" ] && [ "${RI_PORT[$i]}" -ge "$MIN_INTERNAL_PORT" ] && [ -n "${RI_SNI[$i]}" ]; then
        echo "    \"${RI_SNI[$i]}\" 127.0.0.1:${RI_PORT[$i]};"
      fi
    done
    if [ "$PANEL_ROUTING_ENABLED" = "yes" ] && [ -n "$PANEL_HOSTNAME" ]; then
      local panel_port
      panel_port=$(get_setting webPort)
      echo "    \"${PANEL_HOSTNAME}\" 127.0.0.1:${panel_port};"
    fi
    if [ -n "$SUB_HOSTNAME" ]; then
      local sub_port
      sub_port=$(get_setting subPort)
      echo "    \"${SUB_HOSTNAME}\" 127.0.0.1:${sub_port};"
    fi
    echo "}"
    echo ""
    echo "server {"
    echo "    listen 443 reuseport;"
    echo "    listen [::]:443 reuseport;"
    echo "    proxy_pass \$reality_backend;"
    echo "    ssl_preread on;"
    echo "}"
  } > "$tmp"
  mv "$tmp" "$STREAM_INCLUDE_FILE"
}

test_and_reload_nginx() {
  local backup_dir="$1"
  if nginx -t -c "$NGINX_CONF" 2>/tmp/reality_nginx_test_err; then
    ok "nginx -t passed."
    if systemctl reload "$NGINX_SERVICE" 2>/tmp/reality_nginx_reload_err || systemctl restart "$NGINX_SERVICE" 2>>/tmp/reality_nginx_reload_err; then
      ok "nginx reloaded."
      return 0
    fi
    err "nginx config is valid, but reload and restart both failed:"
    cat /tmp/reality_nginx_reload_err >&2
    return 1
  fi
  err "nginx -t failed. Restoring previous nginx config from backup."
  rollback_nginx_only "$backup_dir"
  err "nginx -t error output:"
  cat /tmp/reality_nginx_test_err >&2
  return 1
}

# ---------------------------------------------------------------------------
# hosts table (externalProxy replacement - see decision in project notes)
# ---------------------------------------------------------------------------
upsert_host_row() {
  local inbound_id="$1" address="$2" port="$3" remark="$4"
  local esc_addr esc_remark existing sqlfile
  esc_addr=$(sql_escape "$address")
  esc_remark=$(sql_escape "$remark")
  existing=$(db_query "SELECT id FROM hosts WHERE inbound_id=${inbound_id} AND address='${esc_addr}' AND port=${port};" | jq -r '.[0].id // empty')
  sqlfile=$(mktemp)
  if [ -n "$existing" ]; then
    printf "UPDATE hosts SET remark='%s', security='same', updated_at=strftime('%%s','now')*1000 WHERE id=%s;\n" "$esc_remark" "$existing" > "$sqlfile"
  else
    printf "INSERT INTO hosts (inbound_id, remark, address, port, security, sort_order, created_at, updated_at) VALUES (%s, '%s', '%s', %s, 'same', 0, strftime('%%s','now')*1000, strftime('%%s','now')*1000);\n" \
      "$inbound_id" "$esc_remark" "$esc_addr" "$port" > "$sqlfile"
  fi
  db_exec_file "$sqlfile"
  rm -f "$sqlfile"
}

# ---------------------------------------------------------------------------
# Sample link generation (for confirmation only)
# ---------------------------------------------------------------------------
url_encode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s\n' "$out"
}

print_sample_link() {
  local inbound_id="$1" host="$2" remark="$3" stream_json="$4"
  local settings_json client_id pbk fp sni sid spx
  settings_json=$(db_query "SELECT settings FROM inbounds WHERE id=${inbound_id};" | jq -r '.[0].settings')
  client_id=$(printf '%s' "$settings_json" | jq -r '.clients[0].id // empty')
  if [ -z "$client_id" ]; then
    warn "Inbound '${remark}' (id ${inbound_id}) has no clients configured; skipping sample link."
    return 0
  fi
  pbk=$(printf '%s' "$stream_json" | jq -r '.realitySettings.settings.publicKey // empty')
  fp=$(printf '%s' "$stream_json" | jq -r '.realitySettings.settings.fingerprint // empty')
  sni=$(printf '%s' "$stream_json" | jq -r '.realitySettings.serverNames[0] // empty')
  sid=$(printf '%s' "$stream_json" | jq -r '.realitySettings.shortIds[0] // empty')
  spx=$(printf '%s' "$stream_json" | jq -r '.realitySettings.settings.spiderX // empty')
  local spx_enc
  spx_enc=$(url_encode "$spx")
  printf '%svless://%s@%s:443?type=tcp&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&spx=%s#%s%s\n' \
    "$C_GOLD" "$client_id" "$host" "$pbk" "$fp" "$sni" "$sid" "$spx_enc" "$(url_encode "$remark")" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Consolidation flow
# ---------------------------------------------------------------------------
prompt_select_inbounds() {
  local total="${#RI_ID[@]}"
  local raw color
  color=$(next_prompt_color)
  while true; do
    printf '%sEnter indices to consolidate (e.g. "1 3 4"), "all", or "q" to cancel%s: ' "$color" "$C_RESET" >&2
    IFS= read -r raw || raw=""
    if [ "$raw" = "q" ] || [ "$raw" = "Q" ]; then
      return 1
    fi
    if [ "$raw" = "all" ] || [ "$raw" = "ALL" ]; then
      local seq=()
      local i
      for ((i = 1; i <= total; i++)); do seq+=("$i"); done
      printf '%s\n' "${seq[@]}"
      return 0
    fi
    local -a tokens=()
    read -ra tokens <<< "${raw//,/ }"
    if [ "${#tokens[@]}" -eq 0 ]; then
      err "Enter at least one index."
      continue
    fi
    local -a valid=()
    local bad=""
    local tok
    for tok in "${tokens[@]}"; do
      if ! [[ "$tok" =~ ^[0-9]+$ ]] || [ "$tok" -lt 1 ] || [ "$tok" -gt "$total" ]; then
        bad="$tok"
        break
      fi
      valid+=("$tok")
    done
    if [ -n "$bad" ]; then
      err "'${bad}' is not a valid index (1-${total})."
      continue
    fi
    local -A seen=()
    local -a dedup=()
    for tok in "${valid[@]}"; do
      if [ -z "${seen[$tok]:-}" ]; then
        seen[$tok]=1
        dedup+=("$tok")
      fi
    done
    printf '%s\n' "${dedup[@]}"
    return 0
  done
}

check_sni_uniqueness() {
  # args: selected indices (1-based). Returns 1 and prints the collision if any.
  local -A sni_owner=()
  local idx sni owner
  for idx in "$@"; do
    sni="${RI_SNI[$((idx - 1))]}"
    if [ -z "$sni" ]; then
      err "Inbound '${RI_REMARK[$((idx - 1))]}' has no serverNames[0] set - cannot route by SNI."
      return 1
    fi
    owner="${sni_owner[$sni]:-}"
    if [ -n "$owner" ]; then
      err "SNI collision: '${sni}' is used by both '${owner}' and '${RI_REMARK[$((idx - 1))]}'. Change one of their Reality serverNames in 3x-ui before consolidating."
      return 1
    fi
    sni_owner[$sni]="${RI_REMARK[$((idx - 1))]}"
  done
  return 0
}

hostname_collides_with_sni() {
  local candidate="$1" idx
  for idx in "${!RI_SNI[@]}"; do
    if [ "${RI_SNI[$idx]}" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

do_consolidate() {
  print_header
  load_reality_inbounds
  if [ "${#RI_ID[@]}" -eq 0 ]; then
    warn "No Reality inbounds found in ${DB_PATH}."
    pause
    return 0
  fi
  print_reality_table

  local -a selection
  if ! mapfile -t selection < <(prompt_select_inbounds); then
    warn "Consolidation cancelled."
    pause
    return 0
  fi

  if ! check_sni_uniqueness "${selection[@]}"; then
    pause
    return 1
  fi

  if ! is_nginx_installed; then
    err "nginx is not installed. Install nginx (with the stream module) before consolidating."
    pause
    return 1
  fi
  if [ "$(stream_module_state)" = "missing" ]; then
    err "nginx was not compiled with the stream module (no --with-stream in 'nginx -V'). On Debian/Ubuntu install 'libnginx-mod-stream' or an nginx build that includes it, then re-run."
    pause
    return 1
  fi
  check_port_443_owner

  load_state
  PUBLIC_HOST=$(ask_loop "Public domain or IP for client links" validate_host_or_ip "$PUBLIC_HOST")

  local panel_route_choice
  warn "Routing the panel publicly on 443 is a real exposure risk (auth brute-force, 0-day surface)."
  panel_route_choice=$(ask_loop "Route the panel through public 443 too? [y/N] (n = keep it on SSH tunnel / restricted IP)" validate_yes_no "no")
  PANEL_ROUTING_ENABLED="$panel_route_choice"

  if [ "$PANEL_ROUTING_ENABLED" = "yes" ]; then
    while true; do
      PANEL_HOSTNAME=$(ask_loop "Panel hostname (SNI)" validate_hostname "$PANEL_HOSTNAME")
      if hostname_collides_with_sni "$PANEL_HOSTNAME"; then
        err "'${PANEL_HOSTNAME}' is already used as a Reality SNI. Choose a different hostname."
        continue
      fi
      break
    done
  else
    PANEL_HOSTNAME=""
    ok "Panel will remain on its internal port only (no public 443 route)."
  fi

  while true; do
    SUB_HOSTNAME=$(ask_loop "Subscription service hostname (SNI)" validate_hostname "$SUB_HOSTNAME")
    if hostname_collides_with_sni "$SUB_HOSTNAME"; then
      err "'${SUB_HOSTNAME}' is already used as a Reality SNI. Choose a different hostname."
      continue
    fi
    if [ "$PANEL_ROUTING_ENABLED" = "yes" ] && [ "$SUB_HOSTNAME" = "$PANEL_HOSTNAME" ]; then
      err "Subscription hostname must differ from the panel hostname."
      continue
    fi
    break
  done

  save_state

  # Assign internal ports (skip already-consolidated, unique-per-run).
  build_db_ports_set
  local idx
  local -a new_port=()
  for idx in "${selection[@]}"; do
    local i=$((idx - 1))
    local cur_listen="${RI_LISTEN[$i]}" cur_port="${RI_PORT[$i]}"
    if [ "$cur_listen" = "127.0.0.1" ] && [ "$cur_port" -ge "$MIN_INTERNAL_PORT" ]; then
      ASSIGNED_PORTS[$cur_port]=1
      new_port[i]="$cur_port"
      continue
    fi
    local assigned
    assigned=$(find_free_port "$MIN_INTERNAL_PORT" "$cur_port") || { pause; return 1; }
    new_port[i]="$assigned"
  done

  echo
  say "Planned changes:"
  for idx in "${selection[@]}"; do
    local i=$((idx - 1))
    printf '  %s -> listen 127.0.0.1:%s (was %s:%s), SNI %s\n' \
      "${RI_REMARK[$i]:-<none>}" "${new_port[$i]}" "${RI_LISTEN[$i]:-0.0.0.0}" "${RI_PORT[$i]}" "${RI_SNI[$i]}"
  done
  printf '  Panel routing: %s' "$PANEL_ROUTING_ENABLED"
  [ "$PANEL_ROUTING_ENABLED" = "yes" ] && printf ' (%s)' "$PANEL_HOSTNAME"
  printf '\n  Subscription hostname: %s\n' "$SUB_HOSTNAME"
  echo

  local confirm
  confirm=$(ask_loop "Write these changes and restart ${XUI_SERVICE}? [y/N]" validate_yes_no "no")
  if [ "$confirm" != "yes" ]; then
    warn "Cancelled before any write."
    pause
    return 0
  fi

  local backup_dir
  backup_dir=$(backup_all)

  local sqlfile
  sqlfile=$(mktemp)
  for idx in "${selection[@]}"; do
    local i=$((idx - 1))
    printf "UPDATE inbounds SET listen='127.0.0.1', port=%s WHERE id=%s;\n" "${new_port[$i]}" "${RI_ID[$i]}" >> "$sqlfile"
  done
  db_exec_file "$sqlfile"
  rm -f "$sqlfile"
  ok "Database updated: listen/port for ${#selection[@]} inbound(s)."

  for idx in "${selection[@]}"; do
    local i=$((idx - 1))
    upsert_host_row "${RI_ID[$i]}" "$PUBLIC_HOST" 443 "${RI_REMARK[$i]:-reality}-443"
  done
  ok "hosts table updated so generated links show ${PUBLIC_HOST}:443."

  if systemctl restart "$XUI_SERVICE"; then
    ok "${XUI_SERVICE} restarted."
  else
    err "Failed to restart ${XUI_SERVICE}. Check 'systemctl status ${XUI_SERVICE}'."
  fi

  # Reload the tables from DB so generate_stream_include sees every
  # already-consolidated inbound (old + new), not just this run's selection.
  load_reality_inbounds

  local first_idx=$((selection[0] - 1))
  local default_port="${new_port[$first_idx]}"
  generate_stream_include "$default_port"

  if ! ensure_stream_module_loaded; then
    err "nginx routing was NOT set up. Database and ${XUI_SERVICE} changes above are already applied - use the Rollback menu if you want a full revert."
    pause
    return 1
  fi
  ensure_stream_context

  if test_and_reload_nginx "$backup_dir"; then
    ok "nginx is now routing 443 by SNI."
  else
    err "nginx config was rolled back to the pre-run version. x-ui and the database were NOT rolled back automatically - use the Rollback menu if you want a full revert."
    pause
    return 1
  fi

  echo
  say "Sample links (confirm host/port before distributing):"
  for idx in "${selection[@]}"; do
    local i=$((idx - 1))
    print_sample_link "${RI_ID[$i]}" "$PUBLIC_HOST" "${RI_REMARK[$i]:-reality}" "${RI_STREAM_JSON[$i]}"
  done
  pause
}

# ---------------------------------------------------------------------------
# Services submenu
# ---------------------------------------------------------------------------
svc_action() {
  local service="$1" action="$2"
  case "$action" in
    logs) journalctl -u "$service" -n 50 --no-pager ;;
    status) systemctl status "$service" --no-pager || true ;;
    *)
      if systemctl "$action" "$service"; then
        ok "${service}: ${action} ok."
      else
        err "${service}: ${action} failed."
      fi
      ;;
  esac
}

services_menu() {
  while true; do
    print_header
    palette_line 0 "1) x-ui  - start"
    palette_line 1 "2) x-ui  - stop"
    palette_line 2 "3) x-ui  - restart"
    palette_line 3 "4) x-ui  - status"
    palette_line 4 "5) x-ui  - logs"
    palette_line 5 "6) nginx - start"
    palette_line 6 "7) nginx - stop"
    palette_line 7 "8) nginx - restart"
    palette_line 0 "9) nginx - reload"
    palette_line 1 "10) nginx - status"
    palette_line 2 "11) nginx - logs"
    palette_line 3 "0) Back"
    local choice
    printf '%sChoice%s: ' "$(next_prompt_color)" "$C_RESET"
    IFS= read -r choice || choice="0"
    case "$choice" in
      1) svc_action "$XUI_SERVICE" start ;;
      2) svc_action "$XUI_SERVICE" stop ;;
      3) svc_action "$XUI_SERVICE" restart ;;
      4) svc_action "$XUI_SERVICE" status ;;
      5) svc_action "$XUI_SERVICE" logs ;;
      6) svc_action "$NGINX_SERVICE" start ;;
      7) svc_action "$NGINX_SERVICE" stop ;;
      8) svc_action "$NGINX_SERVICE" restart ;;
      9) svc_action "$NGINX_SERVICE" reload ;;
      10) svc_action "$NGINX_SERVICE" status ;;
      11) svc_action "$NGINX_SERVICE" logs ;;
      0) return 0 ;;
      *) err "Invalid choice." ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
  while true; do
    print_header
    palette_line 0 "1) List Reality Inbounds"
    palette_line 1 "2) Consolidate Reality Inbounds onto 443"
    palette_line 2 "3) Services (x-ui / nginx)"
    palette_line 3 "4) Rollback (restore last backup)"
    palette_line 4 "5) Exit"
    local choice
    printf '%sChoice%s: ' "$(next_prompt_color)" "$C_RESET"
    IFS= read -r choice || choice="5"
    case "$choice" in
      1) print_header; load_reality_inbounds; print_reality_table; pause ;;
      2) do_consolidate ;;
      3) services_menu ;;
      4) print_header; rollback_latest; pause ;;
      5) exit 0 ;;
      *) err "Invalid choice." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (it writes ${DB_PATH}, ${NGINX_CONF}, and restarts services). Re-run with: sudo $0"
    exit 1
  fi
}

main() {
  require_root
  ensure_sqlite3
  mkdir -p "$BACKUP_ROOT"
  load_state
  main_menu
}

main "$@"
