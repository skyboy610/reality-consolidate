#!/usr/bin/env bash
set -o pipefail

PLUGIN_SLUG="site-revenue-calculator"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_FILE="${PLUGIN_DIR}/${PLUGIN_SLUG}.php"
BUILD_DIR="${PLUGIN_DIR}/build"
LOG_FILE="${PLUGIN_DIR}/manage.log"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[38;5;203m"
C_GREEN="\033[38;5;83m"
C_YELLOW="\033[38;5;227m"
C_BLUE="\033[38;5;75m"
C_CYAN="\033[38;5;87m"
C_MAGENTA="\033[38;5;207m"
C_ORANGE="\033[38;5;215m"
C_PURPLE="\033[38;5;141m"
C_TEAL="\033[38;5;80m"
C_PINK="\033[38;5;211m"
C_GREY="\033[38;5;245m"

BG_RED="\033[48;5;160m\033[97m"
BG_GREEN="\033[48;5;28m\033[97m"
BG_YELLOW="\033[48;5;136m\033[97m"
BG_BLUE="\033[48;5;25m\033[97m"

log_write() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

msg_ok() {
    printf "${BG_GREEN} SUCCESS ${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$1"
    log_write "SUCCESS" "$1"
}

msg_warn() {
    printf "${BG_YELLOW} WARNING ${C_RESET} ${C_YELLOW}%s${C_RESET}\n" "$1"
    log_write "WARNING" "$1"
}

msg_err() {
    printf "${BG_RED}  ERROR  ${C_RESET} ${C_RED}%s${C_RESET}\n" "$1"
    log_write "ERROR" "$1"
}

msg_info() {
    printf "${BG_BLUE}  INFO   ${C_RESET} ${C_BLUE}%s${C_RESET}\n" "$1"
    log_write "INFO" "$1"
}

header() {
    clear
    printf "${C_CYAN}"
    cat <<'ART'
 ____  _____ _     _ _____ _   _ _   _ _____
|  _ \| ____| |   | | ____| \ | | | | | ____|
| |_) |  _| | |   | |  _| |  \| | | | |  _|
|  _ <| |___|  \_/  | |___| |\  | |_| | |___
|_| \_\_____|\_____/|_____|_| \_|\___/|_____|
ART
    printf "${C_RESET}"
    printf "${C_MAGENTA}      Site Revenue Calculator${C_RESET} ${C_GREY}|${C_RESET} ${C_ORANGE}Plugin Manager${C_RESET}\n"
    printf "${C_GREY}--------------------------------------------------------${C_RESET}\n"
    printf "${C_TEAL} Version :${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$(current_version)"
    printf "${C_TEAL} Path    :${C_RESET} ${C_BLUE}%s${C_RESET}\n" "$PLUGIN_DIR"
    printf "${C_GREY}--------------------------------------------------------${C_RESET}\n"
}

current_version() {
    grep -m1 '^ \* Version:' "$MAIN_FILE" 2>/dev/null | awk '{print $3}'
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        msg_err "ابزار $1 روی سیستم نصب نیست."
        return 1
    fi
    return 0
}

action_lint() {
    local failed=0
    require_tool php || return 1
    while IFS= read -r file; do
        if php -l "$file" >/dev/null 2>&1; then
            printf "${C_GREEN}  PASS${C_RESET} ${C_GREY}%s${C_RESET}\n" "${file#$PLUGIN_DIR/}"
        else
            printf "${C_RED}  FAIL${C_RESET} ${C_ORANGE}%s${C_RESET}\n" "${file#$PLUGIN_DIR/}"
            php -l "$file"
            failed=1
        fi
    done < <(find "$PLUGIN_DIR" -name '*.php' -not -path '*/build/*')

    if command -v node >/dev/null 2>&1; then
        if node --check "$PLUGIN_DIR/assets/js/admin.js" >/dev/null 2>&1; then
            printf "${C_GREEN}  PASS${C_RESET} ${C_GREY}assets/js/admin.js${C_RESET}\n"
        else
            printf "${C_RED}  FAIL${C_RESET} ${C_ORANGE}assets/js/admin.js${C_RESET}\n"
            failed=1
        fi
    else
        msg_warn "node نصب نیست، بررسی فایل جاوااسکریپت انجام نشد."
    fi

    if [ "$failed" -eq 0 ]; then
        msg_ok "همه فایل‌ها بدون خطای نحوی هستند."
    else
        msg_err "در برخی فایل‌ها خطا وجود دارد."
    fi
    return "$failed"
}

action_build() {
    require_tool zip || return 1
    action_lint || { msg_err "ساخت بسته متوقف شد."; return 1; }

    local version zip_name stage
    version="$(current_version)"
    zip_name="${PLUGIN_SLUG}-${version}.zip"
    stage="$(mktemp -d)"

    mkdir -p "$BUILD_DIR"
    mkdir -p "${stage}/${PLUGIN_SLUG}"

    while IFS= read -r item; do
        cp -R "$item" "${stage}/${PLUGIN_SLUG}/"
    done < <(find "$PLUGIN_DIR" -maxdepth 1 -mindepth 1 \
        ! -name 'build' ! -name 'manage.sh' ! -name 'manage.log' ! -name '.gitignore' ! -name '*.zip')

    rm -f "${BUILD_DIR}/${zip_name}"
    ( cd "$stage" && zip -r -q "${BUILD_DIR}/${zip_name}" "$PLUGIN_SLUG" -x '*.DS_Store' )
    rm -rf "$stage"

    if [ -f "${BUILD_DIR}/${zip_name}" ]; then
        msg_ok "بسته نصب ساخته شد: build/${zip_name}"
    else
        msg_err "ساخت بسته نصب ناموفق بود."
        return 1
    fi
}

action_bump() {
    local old new
    old="$(current_version)"
    printf "${C_YELLOW} نسخه فعلی: ${C_GREEN}%s${C_RESET}\n" "$old"
    printf "${C_CYAN} نسخه جدید را وارد کنید: ${C_RESET}"
    read -r new
    if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        msg_err "قالب نسخه معتبر نیست. نمونه درست: 1.0.1"
        return 1
    fi
    sed -i "s/^ \* Version: .*/ * Version: ${new}/" "$MAIN_FILE"
    sed -i "s/define( 'SREVC_VERSION', '.*' );/define( 'SREVC_VERSION', '${new}' );/" "$MAIN_FILE"
    sed -i "s/^Stable tag: .*/Stable tag: ${new}/" "${PLUGIN_DIR}/readme.txt"
    msg_ok "نسخه از ${old} به ${new} تغییر کرد."
}

action_info() {
    printf "${C_PURPLE} فایل‌های افزونه:${C_RESET}\n"
    find "$PLUGIN_DIR" -type f \( -name '*.php' -o -name '*.css' -o -name '*.js' -o -name '*.txt' \) -not -path '*/build/*' | while IFS= read -r file; do
        printf "${C_TEAL}  %-42s${C_RESET} ${C_GREY}%s bytes${C_RESET}\n" "${file#$PLUGIN_DIR/}" "$(wc -c < "$file" | tr -d ' ')"
    done
    printf "${C_PINK} بسته‌های ساخته شده:${C_RESET}\n"
    if [ -d "$BUILD_DIR" ] && [ -n "$(ls -A "$BUILD_DIR" 2>/dev/null)" ]; then
        ls -1 "$BUILD_DIR" | while IFS= read -r item; do
            printf "${C_ORANGE}  %s${C_RESET}\n" "$item"
        done
    else
        msg_warn "هنوز بسته‌ای ساخته نشده است."
    fi
}

action_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        msg_warn "فایل لاگ هنوز ساخته نشده است."
        return 0
    fi
    printf "${C_PURPLE} آخرین رویدادها:${C_RESET}\n"
    tail -n 40 "$LOG_FILE" | while IFS= read -r line; do
        case "$line" in
            *"[SUCCESS]"*) printf "${BG_GREEN} OK  ${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$line" ;;
            *"[WARNING]"*) printf "${BG_YELLOW} WRN ${C_RESET} ${C_YELLOW}%s${C_RESET}\n" "$line" ;;
            *"[ERROR]"*)   printf "${BG_RED} ERR ${C_RESET} ${C_RED}%s${C_RESET}\n" "$line" ;;
            *)             printf "${BG_BLUE} INF ${C_RESET} ${C_BLUE}%s${C_RESET}\n" "$line" ;;
        esac
    done
}

action_clean() {
    rm -rf "$BUILD_DIR"
    msg_ok "پوشه build پاک شد."
}

action_clear_logs() {
    : > "$LOG_FILE"
    msg_ok "فایل لاگ خالی شد."
}

menu() {
    while true; do
        header
        printf "${C_GREEN}  1)${C_RESET} ${C_GREEN}ساخت بسته نصب (zip)${C_RESET}\n"
        printf "${C_BLUE}  2)${C_RESET} ${C_BLUE}بررسی خطای نحوی فایل‌ها${C_RESET}\n"
        printf "${C_ORANGE}  3)${C_RESET} ${C_ORANGE}تغییر نسخه افزونه${C_RESET}\n"
        printf "${C_PURPLE}  4)${C_RESET} ${C_PURPLE}اطلاعات و فهرست فایل‌ها${C_RESET}\n"
        printf "${C_TEAL}  5)${C_RESET} ${C_TEAL}نمایش لاگ رنگی${C_RESET}\n"
        printf "${C_PINK}  6)${C_RESET} ${C_PINK}پاک کردن لاگ${C_RESET}\n"
        printf "${C_YELLOW}  7)${C_RESET} ${C_YELLOW}پاک کردن پوشه build${C_RESET}\n"
        printf "${C_RED}  0)${C_RESET} ${C_RED}خروج${C_RESET}\n"
        printf "${C_GREY}--------------------------------------------------------${C_RESET}\n"
        printf "${C_CYAN} انتخاب شما: ${C_RESET}"
        read -r choice
        printf "\n"
        case "$choice" in
            1) action_build ;;
            2) action_lint ;;
            3) action_bump ;;
            4) action_info ;;
            5) action_logs ;;
            6) action_clear_logs ;;
            7) action_clean ;;
            0) msg_info "خروج از مدیریت افزونه."; exit 0 ;;
            *) msg_err "گزینه نامعتبر است." ;;
        esac
        printf "\n${C_GREY} برای ادامه کلید Enter را بزنید...${C_RESET}"
        read -r _
    done
}

case "${1:-}" in
    build) action_build ;;
    lint) action_lint ;;
    info) action_info ;;
    logs) action_logs ;;
    clean) action_clean ;;
    "") menu ;;
    *) msg_err "دستور ناشناخته: ${1}"; exit 1 ;;
esac
