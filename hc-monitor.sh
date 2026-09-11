#!/usr/bin/env bash
# hc-monitor.sh: checks an Ubuntu server and reports to healthchecks.io.
#
# Install on the server (asks for the ping URL, services and thresholds):
#     sudo bash hc-monitor.sh install
# Afterwards:
#     sudo hc-monitor.sh --dry-run     show the report without sending it
#     sudo hc-monitor.sh install       reconfigure
#     sudo hc-monitor.sh uninstall     remove
#     journalctl -u hc-monitor         logs
#
# Every 5 minutes a systemd timer runs the script without arguments: it checks disk,
# RAM, CPU load and the configured services, then sends the report to healthchecks.io,
# to the check's ping URL or, when something is wrong, to URL/fail.

# This block must stay POSIX-compatible: it catches runs via sh.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Run with bash: sudo bash $0 install" >&2
    exit 2
fi

set -uo pipefail
export LC_ALL=C

readonly INSTALLED_PATH="/usr/local/bin/hc-monitor.sh"

# HC_MONITOR_ROOT is for tests only: a prefix for every system path.
readonly ROOT="${HC_MONITOR_ROOT:-}"
readonly CONF_FILE="$ROOT/etc/hc-monitor.conf"
readonly BIN_FILE="$ROOT$INSTALLED_PATH"
readonly UNIT_DIR="$ROOT/etc/systemd/system"
readonly MEMINFO="$ROOT/proc/meminfo"
readonly LOADAVG="$ROOT/proc/loadavg"

readonly IGNORED_FS=" tmpfs devtmpfs squashfs overlay iso9660 "
readonly DF_TIMEOUT=10

# Defaults; /etc/hc-monitor.conf overrides them.
HC_PING_URL=""
SERVICES=""
DISK_MAX_PCT=90
MEM_MAX_PCT=90
LOAD_MAX_PER_CPU=2

PROBLEMS=()
SUMMARY=()

die() {
    local code="$1"
    shift
    echo "Error: $*" >&2
    exit "$code"
}

join_by() {
    local sep="$1" out="" item
    shift
    for item in "$@"; do
        out+="${out:+$sep}$item"
    done
    printf '%s' "$out"
}

valid_url() {
    [[ $1 =~ ^https?://[^[:space:]]+$ ]] || return 1
    case $1 in *[\"\'\$\`\\]*) return 1 ;; esac
}

valid_pct() {
    [[ $1 =~ ^([1-9][0-9]?|100)$ ]]
}

valid_load() {
    [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v x="$1" 'BEGIN { exit !(x + 0 > 0) }'
}

valid_service() {
    [[ $1 =~ ^[A-Za-z0-9@._:-]+$ ]]
}

load_config() {
    [[ -e $CONF_FILE ]] || return 0
    [[ -r $CONF_FILE ]] || die 2 "cannot read $CONF_FILE, run with sudo"
    # shellcheck source=/dev/null
    source "$CONF_FILE" || die 2 "cannot load $CONF_FILE"
    while [[ $HC_PING_URL == */ ]]; do
        HC_PING_URL="${HC_PING_URL%/}"
    done
}

validate_config() {
    local -a list
    local svc
    [[ -n $HC_PING_URL ]] || die 2 "HC_PING_URL is not set, run install"
    valid_url "$HC_PING_URL" || die 2 "invalid HC_PING_URL in $CONF_FILE"
    valid_pct "$DISK_MAX_PCT" || die 2 "invalid DISK_MAX_PCT in $CONF_FILE: $DISK_MAX_PCT"
    valid_pct "$MEM_MAX_PCT" || die 2 "invalid MEM_MAX_PCT in $CONF_FILE: $MEM_MAX_PCT"
    valid_load "$LOAD_MAX_PER_CPU" || die 2 "invalid LOAD_MAX_PER_CPU in $CONF_FILE: $LOAD_MAX_PER_CPU"
    read -ra list <<< "$SERVICES"
    for svc in "${list[@]}"; do
        valid_service "$svc" || die 2 "invalid service name in $CONF_FILE: $svc"
    done
}

problem() {
    PROBLEMS+=("$1")
}

summary() {
    SUMMARY+=("$1")
}

check_disk() {
    local out rc=0 pcent ipcent fstype target found=0
    out=$(timeout "$DF_TIMEOUT" df -l --output=pcent,ipcent,fstype,target 2> /dev/null) || rc=$?
    if (( rc == 124 )); then
        problem "Disk: df did not respond within $DF_TIMEOUT s"
        return
    fi
    if (( rc != 0 )); then
        problem "Disk: df failed (exit code $rc)"
    fi
    while read -r pcent ipcent fstype target; do
        [[ $pcent =~ ^[0-9]+%$ ]] || continue   # the header and lines without data
        [[ $IGNORED_FS == *" $fstype "* ]] && continue
        found=1
        pcent=${pcent%\%}
        if [[ $ipcent =~ ^[0-9]+%$ ]]; then
            ipcent=${ipcent%\%}
            summary "Disk $target: $pcent% (inodes $ipcent%)"
        else
            ipcent=""
            summary "Disk $target: $pcent%"
        fi
        if (( pcent >= DISK_MAX_PCT )); then
            problem "Disk $target: $pcent% used (threshold $DISK_MAX_PCT%)"
        fi
        if [[ -n $ipcent ]] && (( ipcent >= DISK_MAX_PCT )); then
            problem "Inodes $target: $ipcent% used (threshold $DISK_MAX_PCT%)"
        fi
    done <<< "$out"
    if (( ! found )); then
        problem "Disk: df returned no data"
    fi
}

check_memory() {
    local total="" avail="" used
    if [[ -r $MEMINFO ]]; then
        total=$(awk '$1 == "MemTotal:" { print $2; exit }' "$MEMINFO")
        avail=$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO")
    fi
    if [[ ! $total =~ ^[0-9]+$ || ! $avail =~ ^[0-9]+$ ]] || (( total == 0 )); then
        problem "RAM: cannot determine (no MemAvailable/MemTotal in /proc/meminfo)"
        return
    fi
    used=$(( (total - avail) * 100 / total ))
    summary "RAM: $used% used of $(( total / 1024 )) MiB"
    if (( used >= MEM_MAX_PCT )); then
        problem "RAM: $used% used (threshold $MEM_MAX_PCT%)"
    fi
}

check_load() {
    local l1="" l5="" l15="" cpus limit
    if [[ -r $LOADAVG ]]; then
        read -r l1 l5 l15 _ < "$LOADAVG"
    fi
    cpus=$(nproc 2> /dev/null)
    if [[ ! $l15 =~ ^[0-9]+(\.[0-9]+)?$ || ! $cpus =~ ^[0-9]+$ ]]; then
        problem "Load: cannot determine"
        return
    fi
    limit=$(awk -v c="$cpus" -v k="$LOAD_MAX_PER_CPU" 'BEGIN { printf "%g", c * k }')
    summary "Load (1/5/15 min): $l1 $l5 $l15, CPUs: $cpus"
    if awk -v l="$l15" -v m="$limit" 'BEGIN { exit !(l + 0 >= m + 0) }'; then
        problem "Load: load15 $l15 on $cpus CPUs (threshold $limit)"
    fi
}

check_services() {
    local -a list items=()
    local svc state
    read -ra list <<< "$SERVICES"
    if (( ${#list[@]} == 0 )); then
        summary "Services: none"
        return
    fi
    for svc in "${list[@]}"; do
        state=$(systemctl is-active "$svc" 2> /dev/null)
        state=${state:-unknown}
        if [[ $state != active && $state != reloading ]]; then
            if [[ $(systemctl show -p LoadState --value "$svc" 2> /dev/null) == not-found ]]; then
                state="not-found"
                problem "Service $svc: not found (check the name)"
            else
                problem "Service $svc: $state"
            fi
        fi
        items+=("$svc=$state")
    done
    summary "Services: $(join_by ', ' "${items[@]}")"
}

run_checks() {
    PROBLEMS=()
    SUMMARY=()
    check_disk
    check_memory
    check_load
    check_services
}

build_report() {
    if (( ${#PROBLEMS[@]} > 0 )); then
        printf 'PROBLEMS (%d):\n' "${#PROBLEMS[@]}"
        printf -- '- %s\n' "${PROBLEMS[@]}"
    else
        printf 'All good\n'
    fi
    printf '\nHost: %s\n' "$(uname -n)"
    if (( ${#SUMMARY[@]} > 0 )); then
        printf '%s\n' "${SUMMARY[@]}"
    fi
}

ping_url() {
    if (( ${#PROBLEMS[@]} > 0 )); then
        printf '%s/fail' "$HC_PING_URL"
    else
        printf '%s' "$HC_PING_URL"
    fi
}

print_preview() {
    run_checks
    printf 'Ping URL: %s\n\n' "$(ping_url)"
    build_report
}

cmd_run() {
    local body url rc=0
    load_config
    validate_config
    run_checks
    body=$(build_report)
    url=$(ping_url)
    curl -fsS -m 10 --retry 5 -o /dev/null --data-raw "$body" "$url" || rc=$?
    if (( rc != 0 )); then
        echo "Error: failed to send the report (curl exit code $rc)" >&2
        return 1
    fi
    if (( ${#PROBLEMS[@]} > 0 )); then
        echo "PROBLEMS: $(join_by '; ' "${PROBLEMS[@]}") (report sent to /fail)"
    else
        echo "OK: report sent"
    fi
}

cmd_dry_run() {
    load_config
    validate_config
    print_preview
}

require_root() {
    [[ -n $ROOT || $EUID -eq 0 ]] || die 1 "root privileges required, run with sudo"
}

# ask <prompt>: reads a line into ANSWER (surrounding whitespace is dropped); exits on end of input.
ask() {
    ANSWER=""
    if ! read -r -p "$1" ANSWER && [[ -z $ANSWER ]]; then
        echo >&2
        die 1 "input aborted"
    fi
}

# ask_valid <prompt> <current value> <validator> <hint on invalid input>
ask_valid() {
    while true; do
        if [[ -n $2 ]]; then ask "$1 [$2]: "; else ask "$1: "; fi
        ANSWER="${ANSWER:-$2}"
        "$3" "$ANSWER" && return 0
        echo "$4" >&2
    done
}

# confirm <prompt> <y|n: the answer on Enter>
confirm() {
    while true; do
        ask "$1"
        case ${ANSWER,,} in
            "") [[ $2 == y ]]; return ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "Please answer y or n." >&2
    done
}

ensure_curl() {
    command -v curl > /dev/null && return 0
    confirm "curl is not installed. Install it with apt? [Y/n] " y || die 1 "curl is required to send reports"
    { apt-get update && apt-get install -y curl; } || die 1 "failed to install curl"
    command -v curl > /dev/null || die 1 "curl is still missing after installation"
}

ask_services() {
    local -a list
    local svc ok load_state
    while true; do
        ask "Systemd services to watch, space-separated (Enter keeps the list, - for none) [${SERVICES:-none}]: "
        case $ANSWER in
            -) SERVICES=""; return 0 ;;
            "") read -ra list <<< "$SERVICES" ;;
            *) read -ra list <<< "$ANSWER" ;;
        esac
        ok=1
        for svc in "${list[@]}"; do
            if ! valid_service "$svc"; then
                echo "Invalid service name: $svc" >&2
                ok=0
                continue
            fi
            load_state=$(systemctl show -p LoadState --value "$svc" 2> /dev/null)
            if [[ -z $load_state || $load_state == not-found ]]; then
                echo "Service $svc not found." >&2
                ok=0
            fi
        done
        if (( ok )); then
            SERVICES="${list[*]}"
            return 0
        fi
    done
}

ask_settings() {
    echo "One ping URL per server: create a separate healthchecks.io check for each server." >&2
    ask_valid "healthchecks.io ping URL" "$HC_PING_URL" valid_url \
        "Expected a URL like https://hc-ping.com/<uuid> without spaces, quotes, \$, \` or \\."
    HC_PING_URL="$ANSWER"
    while [[ $HC_PING_URL == */ ]]; do
        HC_PING_URL="${HC_PING_URL%/}"
    done
    ask_services
    if confirm "Thresholds: disk $DISK_MAX_PCT%, RAM $MEM_MAX_PCT%, load $LOAD_MAX_PER_CPU per CPU. Change them? [y/N] " n; then
        ask_valid "Disk and inode threshold, %" "$DISK_MAX_PCT" valid_pct "Expected a whole number from 1 to 100."
        DISK_MAX_PCT="$ANSWER"
        ask_valid "RAM threshold, %" "$MEM_MAX_PCT" valid_pct "Expected a whole number from 1 to 100."
        MEM_MAX_PCT="$ANSWER"
        ask_valid "Load threshold per CPU" "$LOAD_MAX_PER_CPU" valid_load \
            "Expected a positive number, e.g. 2 or 1.5."
        LOAD_MAX_PER_CPU="$ANSWER"
    fi
}

write_config() {
    local tmp
    mkdir -p "${CONF_FILE%/*}" || die 1 "cannot create the directory for $CONF_FILE"
    tmp=$(mktemp "$CONF_FILE.XXXXXX") || die 1 "cannot create a temporary file next to $CONF_FILE"
    if ! cat > "$tmp" <<EOF
# hc-monitor settings. Change them with: sudo $INSTALLED_PATH install (or edit this file).
HC_PING_URL="$HC_PING_URL"
SERVICES="$SERVICES"
DISK_MAX_PCT="$DISK_MAX_PCT"
MEM_MAX_PCT="$MEM_MAX_PCT"
LOAD_MAX_PER_CPU="$LOAD_MAX_PER_CPU"
EOF
    then
        rm -f "$tmp"
        die 1 "cannot write $tmp"
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$CONF_FILE" || { rm -f "$tmp"; die 1 "cannot write $CONF_FILE"; }
}

# write_unit <file>: content from stdin, mode 644.
write_unit() {
    { cat > "$1" && chmod 644 "$1"; } || die 1 "cannot write $1"
}

install_files() {
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ $self != "$(readlink -f "$BIN_FILE")" ]]; then
        install -D -m 700 "$self" "$BIN_FILE" || die 1 "cannot copy the script to $BIN_FILE"
    fi
    mkdir -p "$UNIT_DIR" || die 1 "cannot create $UNIT_DIR"
    write_unit "$UNIT_DIR/hc-monitor.service" <<EOF
[Unit]
Description=Server health report to healthchecks.io
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_PATH
TimeoutStartSec=2min
EOF
    write_unit "$UNIT_DIR/hc-monitor.timer" <<'EOF'
[Unit]
Description=Run hc-monitor every 5 minutes

[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || die 1 "systemctl daemon-reload failed"
}

first_report() {
    echo
    echo "The report will look like this:"
    echo
    print_preview
    echo
    if (( ${#PROBLEMS[@]} > 0 )); then
        echo "Warning: the report lists problems, so the first ping goes to /fail and healthchecks.io will send an alert."
    fi
    echo "Sending the first report via hc-monitor.service..."
    if ! systemctl start hc-monitor.service; then
        systemctl status hc-monitor.service --no-pager >&2
        die 1 "the first report was not sent and the timer is not enabled. Fix the cause and run install again."
    fi
    echo "First report sent."
}

enable_timer() {
    systemctl enable --now hc-monitor.timer || die 1 "cannot enable hc-monitor.timer"
    echo
    systemctl list-timers hc-monitor.timer --no-pager
}

print_done() {
    cat <<EOF

Done: a report goes to healthchecks.io every 5 minutes.

In healthchecks.io, set the check's schedule to:
    Period: 5 minutes, Grace Time: 10 minutes.

Logs:          journalctl -u hc-monitor
Check now:     sudo $INSTALLED_PATH --dry-run
Reconfigure:   sudo $INSTALLED_PATH install
Uninstall:     sudo $INSTALLED_PATH uninstall
EOF
}

cmd_install() {
    local cmd
    require_root
    [[ -d $ROOT/run/systemd/system ]] || die 1 "systemd is required (no /run/systemd/system directory)"
    for cmd in systemctl df timeout awk nproc; do
        command -v "$cmd" > /dev/null || die 1 "required command not found: $cmd"
    done
    ensure_curl
    load_config
    ask_settings
    write_config
    install_files
    first_report
    enable_timer
    print_done
}

cmd_uninstall() {
    require_root
    if ! confirm "Remove hc-monitor (timer, service, script and settings)? [y/N] " n; then
        echo "Cancelled."
        return 0
    fi
    systemctl disable --now hc-monitor.timer 2> /dev/null
    rm -f "$UNIT_DIR/hc-monitor.service" "$UNIT_DIR/hc-monitor.timer"
    systemctl daemon-reload 2> /dev/null
    systemctl reset-failed hc-monitor.service 2> /dev/null
    rm -f "$CONF_FILE" "$BIN_FILE"
    echo "hc-monitor removed."
    echo "Pings have stopped: pause or delete the check in healthchecks.io, otherwise it will report the server as down."
}

usage() {
    cat >&2 <<EOF
Usage:
  sudo bash hc-monitor.sh install    install or reconfigure
  $INSTALLED_PATH                    check the server and send the report
  $INSTALLED_PATH --dry-run          check and print the report without sending it
  sudo $INSTALLED_PATH uninstall     remove
EOF
}

main() {
    if (( $# > 1 )); then
        usage
        exit 2
    fi
    case "${1:-}" in
        "") cmd_run ;;
        --dry-run) cmd_dry_run ;;
        install) cmd_install ;;
        uninstall) cmd_uninstall ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
