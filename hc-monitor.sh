#!/usr/bin/env bash
# hc-monitor.sh: checks an Ubuntu server and reports to healthchecks.io.
#
# Install on the server (asks for the ping URL, services, ports and thresholds):
#     sudo bash hc-monitor.sh install
# Afterwards:
#     sudo hc-monitor.sh --dry-run     show the report without sending it
#     sudo hc-monitor.sh install       reconfigure
#     sudo hc-monitor.sh uninstall     remove
#     journalctl -u hc-monitor         logs
#
# Every 5 minutes a systemd timer runs the script without arguments: it checks disk, RAM,
# CPU load and usage, the configured services and local ports, then sends the report to
# healthchecks.io, to the check's ping URL or, when something is wrong, to URL/fail.

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
readonly PROC_NET="$ROOT/proc/net"
readonly PROC_STAT="$ROOT/proc/stat"
readonly CPU_STATE_DIR="$ROOT/var/lib/hc-monitor"
readonly CPU_STATE="$CPU_STATE_DIR/cpu.stat"
readonly CPU_MAX_AGE=900   # seconds; an older saved sample is not used for the average

readonly IGNORED_FS=" tmpfs devtmpfs squashfs overlay iso9660 "
readonly DF_TIMEOUT=10

# Defaults; /etc/hc-monitor.conf overrides them.
HC_PING_URL=""
SERVICES=""
PORTS=""
DISK_MAX_PCT=90
MEM_MAX_PCT=90
LOAD_MAX_PER_CPU=2
CPU_MAX_PCT=90

PROBLEMS=()
SUMMARY=()
WORDS=()
CPU_SAMPLE=""

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

# split_words <text>: splits on any whitespace, newlines included, into the WORDS array
# (no globbing, no here-string).
split_words() {
    local -
    set -f
    # shellcheck disable=SC2206
    WORDS=($1)
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

valid_port() {
    [[ $1 =~ ^([1-9][0-9]{0,4})(/(tcp|udp))?$ ]] && (( BASH_REMATCH[1] <= 65535 ))
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
    local entry
    [[ -n $HC_PING_URL ]] || die 2 "HC_PING_URL is not set, run install"
    valid_url "$HC_PING_URL" || die 2 "invalid HC_PING_URL in $CONF_FILE"
    valid_pct "$DISK_MAX_PCT" || die 2 "invalid DISK_MAX_PCT in $CONF_FILE: $DISK_MAX_PCT"
    valid_pct "$MEM_MAX_PCT" || die 2 "invalid MEM_MAX_PCT in $CONF_FILE: $MEM_MAX_PCT"
    valid_load "$LOAD_MAX_PER_CPU" || die 2 "invalid LOAD_MAX_PER_CPU in $CONF_FILE: $LOAD_MAX_PER_CPU"
    valid_pct "$CPU_MAX_PCT" || die 2 "invalid CPU_MAX_PCT in $CONF_FILE: $CPU_MAX_PCT"
    split_words "$SERVICES"
    for entry in "${WORDS[@]}"; do
        valid_service "$entry" || die 2 "invalid service name in $CONF_FILE: $entry"
    done
    split_words "$PORTS"
    for entry in "${WORDS[@]}"; do
        valid_port "$entry" || die 2 "invalid port in $CONF_FILE: $entry"
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

# cpu_counters: prints "total idle iowait steal" in clock ticks from the first line of /proc/stat
# (guest time is already part of user and nice), or returns 1.
cpu_counters() {
    local label="" user="" nice="" system="" idle="" iowait="" irq="" softirq="" steal="" n
    { read -r label user nice system idle iowait irq softirq steal _ < "$PROC_STAT"; } 2> /dev/null
    [[ $label == cpu ]] || return 1
    steal=${steal:-0}
    for n in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal"; do
        [[ $n =~ ^[0-9]+$ ]] || return 1
    done
    echo "$(( user + nice + system + idle + iowait + irq + softirq + steal )) $idle $iowait $steal"
}

# check_cpu: CPU busy share since the previous run (or over one second when there is no usable
# saved sample); leaves this run's counters in CPU_SAMPLE for save_cpu_sample.
check_cpu() {
    local cur saved="" now elapsed span d_total busy total idle iowait steal
    local p_time=0 p_total=0 p_idle=0 p_iowait=0 p_steal=0
    CPU_SAMPLE=""
    if ! cur=$(cpu_counters); then
        problem "CPU: cannot read /proc/stat"
        return
    fi
    # shellcheck disable=SC2086
    set -- $cur
    total=$1 idle=$2 iowait=$3 steal=$4
    printf -v now '%(%s)T' -1
    { read -r saved < "$CPU_STATE"; } 2> /dev/null
    if [[ $saved =~ ^(0|[1-9][0-9]*)( (0|[1-9][0-9]*)){4}$ ]]; then
        # shellcheck disable=SC2086
        set -- $saved
        p_time=$1 p_total=$2 p_idle=$3 p_iowait=$4 p_steal=$5
    fi
    elapsed=$(( now - p_time ))
    if (( p_time == 0 || elapsed < 1 || elapsed > CPU_MAX_AGE || total <= p_total ||
          idle < p_idle || iowait < p_iowait || steal < p_steal )); then
        # No usable sample from the previous run: measure over one second instead.
        p_total=$total p_idle=$idle p_iowait=$iowait p_steal=$steal
        sleep 1
        if ! cur=$(cpu_counters); then
            problem "CPU: cannot read /proc/stat"
            return
        fi
        # shellcheck disable=SC2086
        set -- $cur
        total=$1 idle=$2 iowait=$3 steal=$4
        printf -v now '%(%s)T' -1
        span="1 s"
    elif (( elapsed < 90 )); then
        span="$elapsed s"
    else
        span="$(( (elapsed + 30) / 60 )) min"
    fi
    CPU_SAMPLE="$now $total $idle $iowait $steal"
    d_total=$(( total - p_total ))
    if (( d_total <= 0 )); then
        problem "CPU: cannot determine (no CPU time counted)"
        return
    fi
    busy=$(( (d_total - (idle - p_idle) - (iowait - p_iowait)) * 100 / d_total ))
    summary "CPU: $busy% busy over $span (steal $(( (steal - p_steal) * 100 / d_total ))%, iowait $(( (iowait - p_iowait) * 100 / d_total ))%)"
    if (( busy >= CPU_MAX_PCT )); then
        problem "CPU: $busy% busy (threshold $CPU_MAX_PCT%)"
    fi
}

# save_cpu_sample: keeps this run's CPU counters for the next run's average (real runs only).
save_cpu_sample() {
    [[ -n $CPU_SAMPLE ]] || return 0
    { mkdir -p "$CPU_STATE_DIR" && echo "$CPU_SAMPLE" > "$CPU_STATE"; } 2> /dev/null
    return 0
}

check_services() {
    local -a items=()
    local svc state
    split_words "$SERVICES"
    if (( ${#WORDS[@]} == 0 )); then
        summary "Services: none"
        return
    fi
    for svc in "${WORDS[@]}"; do
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

# listening_ports <tcp|udp>: prints " port port ... " for sockets that listen on this protocol
# (TCP state 0A, UDP state 07) in /proc/net/<proto> and, if present, /proc/net/<proto>6.
# If a table can't be read or lacks the kernel header, prints its path and returns 1.
listening_ports() {
    local proto="$1" name header state=0A
    local -a files=()
    [[ $proto == udp ]] && state=07
    for name in "$proto" "${proto}6"; do
        [[ $name == *6 && ! -e $PROC_NET/$name ]] && continue   # IPv6 is disabled
        header=""
        { read -r header < "$PROC_NET/$name"; } 2> /dev/null
        if [[ $header != *local_address* ]]; then
            printf '/proc/net/%s' "$name"
            return 1
        fi
        files+=("$PROC_NET/$name")
    done
    awk -v state="$state" '
        function hex(s,   i, n) {
            n = 0
            for (i = 1; i <= length(s); i++)
                n = n * 16 + index("0123456789ABCDEF", toupper(substr(s, i, 1))) - 1
            return n
        }
        FNR > 1 && $4 == state { split($2, addr, ":"); printf " %d", hex(addr[2]) }
        END { printf " " }
    ' "${files[@]}"
}

check_ports() {
    local -a items=() unreadable=()
    local -A seen=() socks=()
    local entry key port proto state
    split_words "$PORTS"
    if (( ${#WORDS[@]} == 0 )); then
        summary "Ports: none"
        return
    fi
    for entry in "${WORDS[@]}"; do
        if [[ $entry == */* ]]; then key=$entry; else key=$entry/tcp; fi
        [[ -n ${seen[$key]+set} ]] && continue
        seen[$key]=1
        port=${key%/*}
        proto=${key#*/}
        if [[ -z ${socks[$proto]+set} ]]; then
            socks[$proto]=$(listening_ports "$proto") || {
                unreadable+=("${socks[$proto]}")
                socks[$proto]=unknown
            }
        fi
        if [[ ${socks[$proto]} == unknown ]]; then
            state=unknown
        elif [[ ${socks[$proto]} == *" $port "* ]]; then
            state=listening
        else
            state=not-listening
            problem "Port $key: not listening"
        fi
        items+=("$key=$state")
    done
    if (( ${#unreadable[@]} > 0 )); then
        problem "Ports: cannot read $(join_by ', ' "${unreadable[@]}")"
    fi
    summary "Ports: $(join_by ', ' "${items[@]}")"
}

run_checks() {
    PROBLEMS=()
    SUMMARY=()
    check_disk
    check_memory
    check_load
    check_cpu
    check_services
    check_ports
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
    save_cpu_sample
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

# ask_list <prompt> <current list> <checker>: asks for a space-separated list; Enter keeps the
# current list, "-" clears it. <checker> gets each entry, explains a bad one on stderr and
# returns 1. The accepted list is left in ANSWER.
ask_list() {
    local entry ok
    while true; do
        ask "$1 (Enter keeps the list, - for none) [${2:-none}]: "
        case $ANSWER in
            -) ANSWER=""; return 0 ;;
            "") split_words "$2" ;;
            *) split_words "$ANSWER" ;;
        esac
        ok=1
        for entry in "${WORDS[@]}"; do
            "$3" "$entry" || ok=0
        done
        if (( ok )); then
            ANSWER="${WORDS[*]}"
            return 0
        fi
    done
}

check_service_entry() {
    local load_state
    if ! valid_service "$1"; then
        echo "Invalid service name: $1" >&2
        return 1
    fi
    load_state=$(systemctl show -p LoadState --value "$1" 2> /dev/null)
    if [[ -z $load_state || $load_state == not-found ]]; then
        echo "Service $1 not found." >&2
        return 1
    fi
}

check_port_entry() {
    valid_port "$1" && return 0
    echo "Invalid port: $1 (expected 443, 443/tcp or 53/udp)." >&2
    return 1
}

ask_settings() {
    echo "One ping URL per server: create a separate healthchecks.io check for each server." >&2
    ask_valid "healthchecks.io ping URL" "$HC_PING_URL" valid_url \
        "Expected a URL like https://hc-ping.com/<uuid> without spaces, quotes, \$, \` or \\."
    HC_PING_URL="$ANSWER"
    while [[ $HC_PING_URL == */ ]]; do
        HC_PING_URL="${HC_PING_URL%/}"
    done
    ask_list "Systemd services to watch, space-separated" "$SERVICES" check_service_entry
    SERVICES="$ANSWER"
    ask_list "Local ports to watch, space-separated: 443 or 443/tcp for TCP, 53/udp for UDP" \
        "$PORTS" check_port_entry
    PORTS="$ANSWER"
    if confirm "Thresholds: disk $DISK_MAX_PCT%, RAM $MEM_MAX_PCT%, load $LOAD_MAX_PER_CPU per CPU, CPU busy $CPU_MAX_PCT%. Change them? [y/N] " n; then
        ask_valid "Disk and inode threshold, %" "$DISK_MAX_PCT" valid_pct "Expected a whole number from 1 to 100."
        DISK_MAX_PCT="$ANSWER"
        ask_valid "RAM threshold, %" "$MEM_MAX_PCT" valid_pct "Expected a whole number from 1 to 100."
        MEM_MAX_PCT="$ANSWER"
        ask_valid "Load threshold per CPU" "$LOAD_MAX_PER_CPU" valid_load \
            "Expected a positive number, e.g. 2 or 1.5."
        LOAD_MAX_PER_CPU="$ANSWER"
        ask_valid "CPU busy threshold, %" "$CPU_MAX_PCT" valid_pct "Expected a whole number from 1 to 100."
        CPU_MAX_PCT="$ANSWER"
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
PORTS="$PORTS"
DISK_MAX_PCT="$DISK_MAX_PCT"
MEM_MAX_PCT="$MEM_MAX_PCT"
LOAD_MAX_PER_CPU="$LOAD_MAX_PER_CPU"
CPU_MAX_PCT="$CPU_MAX_PCT"
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
    rm -f "$CONF_FILE" "$BIN_FILE" "$CPU_STATE"
    rmdir "$CPU_STATE_DIR" 2> /dev/null
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
