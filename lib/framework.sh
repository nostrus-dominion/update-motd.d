# shellcheck shell=bash

## Shared configuration and display functions.

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'ERROR: Nostrus MOTD requires Bash 4.4 or newer.\n' >&2
    return 1
fi

MOTD_LIBRARY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MOTD_ROOT_DIR=${MOTD_LIBRARY_DIR%/*}
MOTD_CONFIG_DIR="$MOTD_ROOT_DIR/config"

motd_defaults() {
    MOTD_ROLE=""
    MOTD_COLOR=true
    MOTD_LABEL_WIDTH=16
    MOTD_BAR_WIDTH=40
    MOTD_BAR_USED="="
    MOTD_BAR_FREE="-"
    MOTD_ACCENT='\033[0;36m'
    MOTD_OK='\033[0;32m'
    MOTD_WARNING='\033[1;33m'
    MOTD_ERROR='\033[0;31m'
    MOTD_DIM='\033[2m'
    MOTD_RESET='\033[0m'
    MOTD_COLORS_FILE="$MOTD_CONFIG_DIR/colors.conf"
    MOTD_SERVICE_PROVIDER=none
    MOTD_USAGE_WARN=75
    MOTD_USAGE_CRIT=90
    MOTD_TEMP_WARN=70
    MOTD_TEMP_CRIT=85
    MOTD_LOAD_WARN=75
    MOTD_LOAD_CRIT=100
    MOTD_UPDATE_WARN=1
    MOTD_UPDATE_CRIT=50
    MOTD_CERT_WARN_DAYS=14
    MOTD_CERT_CRIT_DAYS=3
    MOTD_COMMAND_TIMEOUT=3
    MOTD_MODULE_TIMEOUT=10
    MOTD_HTTP_TIMEOUT=2
    MOTD_CACHE_ENABLED=true
    MOTD_MAX_ITEMS=8
    MOTD_CONTAINER_LIMIT=20
    MOTD_SHOW_STOPPED_CONTAINERS=true
    MOTD_NETWORK_IPV6=false
    MOTD_BANNER=true
    MOTD_FIGLET_FONT=standard
    MOTD_FIGLET_WIDTH=80
    MOTD_DATE_FORMAT='%A, %B %d, %Y %T %Z'
    MOTD_CERT_DIR=/etc/letsencrypt/live
    MOTD_FAIL2BAN_LOG=/var/log/fail2ban.log
    MOTD_LAST_LOGIN_COUNT=3
    MOTD_REBOOT_FILE=/run/reboot-required
    MOTD_NOTES=""
    # Alternate roots also make hardware checks reproducible with fixture data.
    MOTD_PROC_ROOT=/proc
    MOTD_SYS_ROOT=/sys
    MOTD_CACHE_DIR="$MOTD_ROOT_DIR/cache"
    declare -ga MOTD_MODULES=(
        10-hostname 11-time-sync 20-system-info 21-cpu-load 22-memory 26-network
        32-disk-space 80-update
        81-reboot-required 91-other-users
    )
    declare -ga MOTD_DISK_PATHS=("/")
    declare -ga MOTD_REQUIRED_MOUNTS=()
    declare -ga MOTD_SMART_DEVICES=()
    declare -ga MOTD_NETWORK_INTERFACES=()
    declare -ga MOTD_CONTAINER_EXCLUDE=()
    declare -ga MOTD_CERT_DOMAINS=()
    declare -gA MOTD_SERVICES=()
    declare -ga MOTD_DOCKER_CONTAINERS=()
    declare -ga MOTD_PODMAN_CONTAINERS=()
    declare -ga MOTD_LXC_CONTAINERS=()
    declare -ga MOTD_LXD_INSTANCES=()
    declare -gA MOTD_ENDPOINTS=()
    declare -gA MOTD_PROCESSES=()
    declare -gA MOTD_CACHE_TTL=(
        [23-temperatures]=10 [24-gpu]=10 [30-disk-health]=300
        [34-zpool-status]=30 [35-zpool]=30 [50-ssl-cert]=300
        [60-pia-vpn]=15 [70-fail2ban]=600 [80-update]=300
    )
    declare -gA MOTD_TIMEOUTS=([30-disk-health]=30 [70-fail2ban]=10)
}

motd_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

motd_debug() {
    [[ ${MOTD_DEBUG:-false} == true ]] || return 0
    printf 'MOTD: %s\n' "$*" >&2
}

motd_uint() {
    [[ $1 =~ ^(0|[1-9][0-9]*)$ && ${#1} -le 6 ]]
}

motd_validate() {
    local name value
    case $MOTD_SERVICE_PROVIDER in none|systemd|openrc|sysv) ;;
        *) motd_error "Unknown service provider: $MOTD_SERVICE_PROVIDER"; return 1 ;;
    esac
    for name in MOTD_LABEL_WIDTH MOTD_BAR_WIDTH MOTD_USAGE_WARN MOTD_USAGE_CRIT \
        MOTD_TEMP_WARN MOTD_TEMP_CRIT MOTD_LOAD_WARN MOTD_LOAD_CRIT \
        MOTD_UPDATE_WARN MOTD_UPDATE_CRIT MOTD_CERT_WARN_DAYS MOTD_CERT_CRIT_DAYS \
        MOTD_COMMAND_TIMEOUT MOTD_MODULE_TIMEOUT MOTD_HTTP_TIMEOUT \
        MOTD_MAX_ITEMS MOTD_CONTAINER_LIMIT MOTD_LAST_LOGIN_COUNT MOTD_FIGLET_WIDTH; do
        value=${!name}
        motd_uint "$value" || { motd_error "$name must be a nonnegative integer."; return 1; }
    done
    (( MOTD_LABEL_WIDTH >= 8 && MOTD_LABEL_WIDTH <= 40 &&
       MOTD_BAR_WIDTH >= 10 && MOTD_BAR_WIDTH <= 100 &&
       MOTD_COMMAND_TIMEOUT > 0 && MOTD_MODULE_TIMEOUT > 0 &&
       MOTD_HTTP_TIMEOUT > 0 && MOTD_MAX_ITEMS > 0 &&
       MOTD_CONTAINER_LIMIT > 0 && MOTD_LAST_LOGIN_COUNT > 0 &&
       MOTD_FIGLET_WIDTH >= 20 && MOTD_FIGLET_WIDTH <= 200 )) ||
        { motd_error "Widths, limits, or timeouts are outside their allowed range."; return 1; }
    (( MOTD_USAGE_WARN <= MOTD_USAGE_CRIT && MOTD_USAGE_CRIT <= 100 &&
       MOTD_TEMP_WARN <= MOTD_TEMP_CRIT && MOTD_LOAD_WARN <= MOTD_LOAD_CRIT &&
       MOTD_UPDATE_WARN <= MOTD_UPDATE_CRIT &&
       MOTD_CERT_CRIT_DAYS <= MOTD_CERT_WARN_DAYS )) ||
        { motd_error "Warning and critical thresholds are inconsistent."; return 1; }
    for name in MOTD_COLOR MOTD_CACHE_ENABLED MOTD_SHOW_STOPPED_CONTAINERS \
        MOTD_NETWORK_IPV6 MOTD_BANNER; do
        [[ ${!name} == true || ${!name} == false ]] ||
            { motd_error "$name must be true or false."; return 1; }
    done
    [[ ${#MOTD_BAR_USED} == 1 && ${#MOTD_BAR_FREE} == 1 ]] ||
        { motd_error "Bar characters must each be one character."; return 1; }
    for value in "${MOTD_CACHE_TTL[@]}"; do
        motd_uint "$value" || { motd_error "Cache durations must be nonnegative integers."; return 1; }
    done
    for value in "${MOTD_TIMEOUTS[@]}"; do
        motd_uint "$value" && (( value > 0 )) ||
            { motd_error "Module timeouts must be positive integers."; return 1; }
    done
}

motd_load_config() {
    motd_defaults
    MOTD_CONFIG_FILE=${MOTD_CONFIG_FILE:-"$MOTD_CONFIG_DIR/motd.conf"}
    if [[ -r $MOTD_CONFIG_FILE ]]; then
        # Machine configuration is trusted Bash, installed under /etc.
        # shellcheck disable=SC1090
        source "$MOTD_CONFIG_FILE" || return 1
    elif [[ ${MOTD_CONFIG_EXPLICIT:-false} == true ]]; then
        motd_error "Cannot read configuration: $MOTD_CONFIG_FILE"
        return 1
    fi
    if [[ -r $MOTD_COLORS_FILE ]]; then
        # shellcheck disable=SC1090
        source "$MOTD_COLORS_FILE" || return 1
    fi
    MOTD_COLOR=${MOTD_COLOR_OVERRIDE:-$MOTD_COLOR}
    MOTD_CACHE_ENABLED=${MOTD_CACHE_OVERRIDE:-$MOTD_CACHE_ENABLED}
    motd_validate || return 1
    if [[ $MOTD_COLOR == true ]]; then
        printf -v CA '%b' "$MOTD_ACCENT"
        printf -v CO '%b' "$MOTD_OK"
        printf -v CW '%b' "$MOTD_WARNING"
        printf -v CE '%b' "$MOTD_ERROR"
        printf -v CD '%b' "$MOTD_DIM"
        printf -v CN '%b' "$MOTD_RESET"
    else
        CA="" CO="" CW="" CE="" CD="" CN=""
    fi
    WIDTH=$MOTD_BAR_WIDTH
}

motd_contains() {
    local needle=$1 element
    shift
    for element in "$@"; do
        [[ $needle == "$element" ]] && return 0
    done
    return 1
}

motd_init() {
    motd_load_config || return 2
    [[ ${MOTD_FORCE_MODULE:-false} == true ]] ||
        motd_contains "$1" "${MOTD_MODULES[@]}"
}

motd_need() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 ||
            { motd_debug "Skipping ${0##*/}: missing $command."; return 1; }
    done
    return 0
}

motd_run() {
    timeout --foreground "${MOTD_COMMAND_TIMEOUT}s" "$@"
}

motd_systemd() {
    motd_need systemctl || return 1
    local state
    state=$(motd_run systemctl is-system-running 2>/dev/null || :)
    [[ $state == running || $state == degraded || $state == starting ||
       $state == maintenance ]]
}

append_line() {
    local -n motd_lines=$1
    shift
    motd_lines+="${motd_lines:+$'\n'}$*"
}

# Final, padded output: no second renderer or column utility is required.
print_columns() {
    local label="${1}${1:+:}" line
    [[ -n ${2:-} ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        printf '  %s%-*s%s  %s\n' "$CA" "$MOTD_LABEL_WIDTH" "$label" "$CN" "$line"
        label=""
    done <<< "$2"
}

print_color() {
    local color=$CW result
    if [[ $2 =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        result=$(awk -v value="$2" -v warn="$3" -v crit="$4" \
            'BEGIN { print value < warn ? 0 : (value < crit ? 1 : 2) }')
        case $result in 0) color=$CO ;; 1) color=$CW ;; 2) color=$CE ;; esac
    fi
    printf '%s%s%s' "$color" "$1" "$CN"
}

print_status() {
    local color=$CW
    case ${2,,} in
        active|running|healthy|connected|ok|mounted|passed) color=$CO ;;
        failed|inactive|dead|degraded|expired|missing|unhealthy|disconnected|exited|stopped|faulted|offline) color=$CE ;;
    esac
    printf '%s: %s%s%s' "$1" "$color" "$2" "$CN"
}

print_bar() {
    local percentage=$1 inner used free fill empty color
    motd_uint "$percentage" || return 1
    (( percentage > 100 )) && percentage=100
    inner=$((MOTD_BAR_WIDTH - 2))
    used=$((percentage * inner / 100))
    free=$((inner - used))
    printf -v fill '%*s' "$used" ''
    printf -v empty '%*s' "$free" ''
    fill=${fill// /$MOTD_BAR_USED}
    empty=${empty// /$MOTD_BAR_FREE}
    color=$CO
    (( percentage >= MOTD_USAGE_WARN )) && color=$CW
    (( percentage >= MOTD_USAGE_CRIT )) && color=$CE
    printf '[%s%s%s%s%s] %s%%' "$color" "$fill" "$CD" "$empty" "$CN" "$percentage"
}

human_bytes() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf 'N/A'
}

motd_excluded() {
    local pattern
    for pattern in "${MOTD_CONTAINER_EXCLUDE[@]}"; do
        [[ $1 == $pattern ]] && return 0
    done
    return 1
}

motd_containers() {
    local engine=$1 text="" records name state detail count=0 wanted
    local -n selected="MOTD_${1^^}_CONTAINERS"
    local -a seen=()
    motd_need "$engine" || return 0
    if ! records=$(motd_run "$engine" ps -a \
        --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null); then
        print_columns "${engine^}" "${CW}Daemon unavailable or access denied${CN}"
        return 0
    fi
    while IFS=$'\t' read -r name state detail; do
        [[ -n $name ]] || continue
        (( ${#selected[@]} == 0 )) || motd_contains "$name" "${selected[@]}" || continue
        seen+=("$name")
        motd_excluded "$name" && continue
        [[ $MOTD_SHOW_STOPPED_CONTAINERS == true || $state == running ]] || continue
        (( count < MOTD_CONTAINER_LIMIT )) || continue
        [[ $detail != *unhealthy* ]] || state=unhealthy
        append_line text "$(print_status "$name" "$state")${detail:+ ($detail)}"
        count=$((count + 1))

    done <<< "$records"
    for wanted in "${selected[@]}"; do
        motd_contains "$wanted" "${seen[@]}" ||
            append_line text "$(print_status "$wanted" missing)"
    done
    print_columns "${engine^}" "${text:-No matching containers}"
}
