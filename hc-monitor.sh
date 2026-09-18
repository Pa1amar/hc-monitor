#!/usr/bin/env bash
# hc-monitor.sh: checks an Ubuntu server and reports to healthchecks.io.
#
# Install on the server (asks for the ping URL, services, ports and thresholds):
#     sudo bash hc-monitor.sh install
# Afterwards:
#     sudo hc-monitor.sh --dry-run         show the reports without sending them
#     sudo hc-monitor.sh add <name>        add or change a service: ~/.healthchecks/<name>/.env
#     sudo hc-monitor.sh remove <name>     remove a service
#     sudo hc-monitor.sh install           reconfigure
#     sudo hc-monitor.sh uninstall         remove hc-monitor
#     journalctl -u hc-monitor             logs
#
# Every 5 minutes a systemd timer runs the script without arguments: it checks disk, RAM,
# CPU load and usage, the configured services and local ports, then sends the report to
# healthchecks.io, to the check's ping URL or, when something is wrong, to URL/fail.
# A service file adds a service's units, ports and health endpoint, reported with the server
# or to the service's own check.

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
readonly STATE_DIR="$ROOT/var/lib/hc-monitor"
readonly CPU_STATE="$STATE_DIR/cpu.stat"
readonly RESTARTS_STATE="$STATE_DIR/restarts.state"
readonly OOM_STATE="$STATE_DIR/oom.state"
readonly VMSTAT="$ROOT/proc/vmstat"
readonly CPU_MAX_AGE=900   # seconds; an older saved sample is not used for the average

# Service files live in root's home: the timer runs as root, and systemd doesn't set $HOME.
root_home=$(getent passwd 0 2> /dev/null)
root_home=${root_home#*:*:*:*:*:}
root_home=${root_home%%:*}
readonly SERVICES_DIR="$ROOT${root_home:-/root}/.healthchecks"
unset root_home

readonly IGNORED_FS=" tmpfs devtmpfs squashfs overlay iso9660 "
readonly DF_TIMEOUT=10
readonly HTTP_TIMEOUT=10

# Defaults; /etc/hc-monitor.conf overrides them.
HC_PING_URL=""
SERVICES=""
PORTS=""
DISK_MAX_PCT=90
MEM_MAX_PCT=90
LOAD_MAX_PER_CPU=2
CPU_MAX_PCT=90

# Settings that only service files use (see load_service).
HTTP_URL=""
HTTP_EXPECT=""

PROBLEMS=()
SUMMARY=()
WORDS=()
CPU_SAMPLE=""
OOM_SAMPLE=""
SERVICE_ERROR=""

# Reports to send: index 0 is the server, then services with their own check.
REPORT_NAMES=()
REPORT_URLS=()
REPORT_BODIES=()
REPORT_PROBLEMS=()

# Automatic restart counts keyed "<context>/<unit>", where the context is "." for the server
# and the service name for a service file: saved by the previous run and seen in this one.
RESTART_CONTEXT="."
declare -A RESTARTS_SAVED=()
declare -A RESTARTS_SEEN=()

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

# trim_slashes <variable name>: drops trailing slashes from the URL in that variable.
trim_slashes() {
    local -n trimmed_url=$1
    while [[ $trimmed_url == */ ]]; do
        trimmed_url=${trimmed_url%/}
    done
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

valid_service_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# valid_regex <pattern>: a single-line extended regular expression that bash accepts.
valid_regex() {
    [[ $1 != *$'\n'* ]] || return 1
    [[ x =~ $1 ]]
    (( $? != 2 ))
}

load_config() {
    [[ -e $CONF_FILE ]] || return 0
    [[ -r $CONF_FILE ]] || die 2 "cannot read $CONF_FILE, run with sudo"
    # shellcheck source=/dev/null
    source "$CONF_FILE" || die 2 "cannot load $CONF_FILE"
    trim_slashes HC_PING_URL
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

# check_oom: processes the kernel's OOM killer killed since the previous run (the oom_kill
# counter in /proc/vmstat), named from the kernel log when possible; leaves this run's count in
# OOM_SAMPLE for save_state.
check_oom() {
    local count saved="" now n names word=processes
    OOM_SAMPLE=""
    count=$(awk '$1 == "oom_kill" { print $2; exit }' "$VMSTAT" 2> /dev/null)
    if [[ ! $count =~ ^[0-9]+$ ]]; then
        problem "OOM: cannot determine (no oom_kill in /proc/vmstat)"
        return
    fi
    printf -v now '%(%s)T' -1
    OOM_SAMPLE="$now $count"
    { read -r saved < "$OOM_STATE"; } 2> /dev/null
    [[ $saved =~ ^[0-9]+\ [0-9]+$ ]] || return 0   # the first run only records a baseline
    (( count > ${saved#* } )) || return 0            # no kills, or the counter restarted at boot
    n=$(( count - ${saved#* } ))
    (( n == 1 )) && word=process
    names=$(oom_victims "${saved% *}")
    problem "OOM killer: killed $n $word since the last check${names:+: $names}"
}

# oom_victims <epoch>: "name (pid), ..." for the processes the OOM killer killed since then,
# as the kernel log names them; empty when the log can't be read.
oom_victims() {
    journalctl -k -q --no-pager -o cat --since "@$1" 2> /dev/null | awk '
        match($0, /Killed process [0-9]+ \([^)]*\)/) {
            victim = substr($0, RSTART + 15, RLENGTH - 15)
            pid = victim
            sub(/ .*/, "", pid)
            name = victim
            sub(/^[0-9]+ \(/, "", name)
            sub(/\)$/, "", name)
            list = list (list == "" ? "" : ", ") name " (" pid ")"
        }
        END { printf "%s", list }'
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
# saved sample); leaves this run's counters in CPU_SAMPLE for save_state.
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

# save_state: keeps this run's CPU counters, restart counts and OOM kill count for the next run
# (real runs only; failures are ignored).
save_state() {
    local key
    {
        mkdir -p "$STATE_DIR" || return 0
        [[ -z $CPU_SAMPLE ]] || echo "$CPU_SAMPLE" > "$CPU_STATE"
        [[ -z $OOM_SAMPLE ]] || echo "$OOM_SAMPLE" > "$OOM_STATE"
        for key in "${!RESTARTS_SEEN[@]}"; do
            printf '%s\t%s\t%s\n' "${key%%/*}" "${key#*/}" "${RESTARTS_SEEN[$key]}"
        done > "$RESTARTS_STATE.tmp" && mv -f "$RESTARTS_STATE.tmp" "$RESTARTS_STATE"
    } 2> /dev/null
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
        check_restarts "$svc"
        items+=("$svc=$state")
    done
    summary "Services: $(join_by ', ' "${items[@]}")"
}

# load_restarts_state: reads the restart counts saved by the previous run into RESTARTS_SAVED.
load_restarts_state() {
    local context unit count
    RESTARTS_SAVED=()
    RESTARTS_SEEN=()
    [[ -r $RESTARTS_STATE ]] || return 0
    while IFS=$'\t' read -r context unit count; do
        [[ $count =~ ^[0-9]+$ ]] && RESTARTS_SAVED["$context/$unit"]=$count
    done < "$RESTARTS_STATE"
}

# check_restarts <unit>: compares the unit's automatic restart count with the one the previous
# run saved for this check (RESTART_CONTEXT) and remembers the current count.
check_restarts() {
    local key="$RESTART_CONTEXT/$1" count saved n word=times
    count=$(systemctl show -p NRestarts --value "$1" 2> /dev/null)
    [[ $count =~ ^[0-9]+$ ]] || return 0
    RESTARTS_SEEN[$key]=$count
    saved=${RESTARTS_SAVED[$key]:-}
    if [[ -n $saved ]] && (( count > saved )); then
        n=$(( count - saved ))
        (( n == 1 )) && word="time"
        problem "Service $1: restarted $n $word since the last check"
    fi
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

# check_http: requests HTTP_URL (a service's health endpoint) and expects a 2xx status and, when
# HTTP_EXPECT is set, a response body that matches it.
check_http() {
    local out rc=0 code result
    [[ -n $HTTP_URL ]] || return 0
    out=$(curl -s -L --max-redirs 5 -m "$HTTP_TIMEOUT" -w '\n%{http_code}' "$HTTP_URL" 2> /dev/null) || rc=$?
    code=${out##*$'\n'}
    if (( rc != 0 )); then
        case $rc in
            6) result="cannot resolve host" ;;
            7) result="connection failed" ;;
            28) result="no response within $HTTP_TIMEOUT s" ;;
            *) result="request failed (curl exit code $rc)" ;;
        esac
        problem "HTTP $HTTP_URL: $result"
    elif [[ ! $code =~ ^2[0-9][0-9]$ ]]; then
        result="status $code"
        problem "HTTP $HTTP_URL: $result"
    elif [[ -z $HTTP_EXPECT ]]; then
        result=$code
    elif [[ ${out%$'\n'*} =~ $HTTP_EXPECT ]]; then
        result="$code, expected text found"
    else
        result="$code, expected text not found"
        problem "HTTP $HTTP_URL: expected text not found"
    fi
    summary "HTTP $HTTP_URL: $result"
}

run_checks() {
    PROBLEMS=()
    SUMMARY=()
    check_disk
    check_memory
    check_oom
    check_load
    check_cpu
    check_services
    check_ports
}

# safe_path <path>: exists, belongs to root (to the current user in tests) and isn't writable by
# group or others.
safe_path() {
    local info owner=0
    [[ -z $ROOT ]] || owner=$EUID
    info=$(stat -L -c '%u %a' -- "$1" 2> /dev/null) || return 1
    [[ ${info% *} == "$owner" ]] && (( (8#${info#* } & 8#022) == 0 ))
}

# list_services: sets WORDS to the names of the directories in SERVICES_DIR that have a .env.
list_services() {
    local path
    WORDS=()
    for path in "$SERVICES_DIR"/*/.env; do
        [[ -e $path ]] || continue
        path=${path%/.env}
        WORDS+=("${path##*/}")
    done
}

# load_service <name>: sources SERVICES_DIR/<name>/.env into HC_PING_URL, SERVICES, PORTS,
# HTTP_URL and HTTP_EXPECT after checking the permissions; on failure sets SERVICE_ERROR.
# The file may set anything, so call it in a subshell.
load_service() {
    local file="$SERVICES_DIR/$1/.env" path
    HC_PING_URL="" SERVICES="" PORTS="" HTTP_URL="" HTTP_EXPECT=""
    for path in "$SERVICES_DIR" "$SERVICES_DIR/$1" "$file"; do
        if ! safe_path "$path"; then
            SERVICE_ERROR="unsafe permissions on ${path#"$ROOT"} (it must be owned by root and not writable by group or others)"
            return 1
        fi
    done
    # shellcheck source=/dev/null
    if ! source "$file" > /dev/null; then
        SERVICE_ERROR="cannot load ${file#"$ROOT"}"
        return 1
    fi
    IFS=$' \t\n'
    trim_slashes HC_PING_URL
}

# validate_service: checks the settings loaded by load_service; on failure sets SERVICE_ERROR.
validate_service() {
    local entry
    if [[ -n $HC_PING_URL ]] && ! valid_url "$HC_PING_URL"; then
        SERVICE_ERROR="invalid HC_PING_URL"
        return 1
    fi
    split_words "$SERVICES"
    for entry in "${WORDS[@]}"; do
        if ! valid_service "$entry"; then
            SERVICE_ERROR="invalid service name: $entry"
            return 1
        fi
    done
    split_words "$PORTS"
    for entry in "${WORDS[@]}"; do
        if ! valid_port "$entry"; then
            SERVICE_ERROR="invalid port: $entry"
            return 1
        fi
    done
    if [[ -n $HTTP_URL ]] && ! valid_url "$HTTP_URL"; then
        SERVICE_ERROR="invalid HTTP_URL"
        return 1
    fi
    if [[ -n $HTTP_EXPECT && -z $HTTP_URL ]]; then
        SERVICE_ERROR="HTTP_EXPECT is set without HTTP_URL"
        return 1
    fi
    if [[ -n $HTTP_EXPECT ]] && ! valid_regex "$HTTP_EXPECT"; then
        SERVICE_ERROR="invalid HTTP_EXPECT (not a regular expression)"
        return 1
    fi
    if [[ -z $SERVICES && -z $PORTS && -z $HTTP_URL ]]; then
        SERVICE_ERROR="nothing to check (set SERVICES, PORTS or HTTP_URL)"
        return 1
    fi
}

# service_lines <name> [check]: loads a service and prints tab-separated lines: "V <key> <value>"
# for each setting, "E <error>" when the service can't be used and, with "check", "P <problem>"
# and "S <summary>" from its checks; "END" comes last. Run it in a subshell.
service_lines() {
    local key
    if load_service "$1"; then
        split_words "$SERVICES"
        SERVICES="${WORDS[*]}"
        split_words "$PORTS"
        PORTS="${WORDS[*]}"
        for key in HC_PING_URL SERVICES PORTS HTTP_URL HTTP_EXPECT; do
            printf 'V\t%s\t%s\n' "$key" "${!key}"
        done
        if ! validate_service; then
            printf 'E\t%s\n' "$SERVICE_ERROR"
        elif [[ ${2:-} == check ]]; then
            PROBLEMS=()
            SUMMARY=()
            RESTART_CONTEXT=$1
            RESTARTS_SEEN=()
            [[ -z $SERVICES ]] || check_services
            [[ -z $PORTS ]] || check_ports
            check_http
            (( ${#PROBLEMS[@]} == 0 )) || printf 'P\t%s\n' "${PROBLEMS[@]}"
            (( ${#SUMMARY[@]} == 0 )) || printf 'S\t%s\n' "${SUMMARY[@]}"
            for key in "${!RESTARTS_SEEN[@]}"; do
                printf 'R\t%s\t%s\n' "${key#*/}" "${RESTARTS_SEEN[$key]}"
            done
        fi
    else
        printf 'E\t%s\n' "$SERVICE_ERROR"
    fi
    echo END
}

# add_service_report <name>: runs a service's checks in a subshell. A service with its own
# HC_PING_URL gets its own report in REPORT_*; otherwise its problems and summary go into
# PROBLEMS and SUMMARY with a "[name] " prefix. A service that can't be used is a server problem.
add_service_report() {
    local name="$1" line kind value url="" error="" complete=0 item
    local -a lines problems=() summaries=() restarts=()
    mapfile -t lines < <(service_lines "$name" check)
    for line in "${lines[@]}"; do
        kind=${line%%$'\t'*}
        value=${line#*$'\t'}
        case $kind in
            V) [[ $value == HC_PING_URL$'\t'* ]] && url=${value#*$'\t'} ;;
            E) error=$value ;;
            P) problems+=("$value") ;;
            S) summaries+=("$value") ;;
            R) restarts+=("$value") ;;
            END) complete=1 ;;
        esac
    done
    if [[ -z $error ]] && (( ! complete )); then
        error="cannot load ${SERVICES_DIR#"$ROOT"}/$name/.env"
    elif [[ -z $error && -n $url && $url == "$HC_PING_URL" ]]; then
        error="HC_PING_URL is the server's ping URL (create a separate check)"
    fi
    if [[ -n $error ]]; then
        problem "Service $name: $error"
        return
    fi
    for item in "${restarts[@]}"; do
        RESTARTS_SEEN["$name/${item%%$'\t'*}"]=${item#*$'\t'}
    done
    if [[ -n $url ]]; then
        add_report "$name" "$url" "${#problems[@]}" "${problems[@]}" "${summaries[@]}"
    else
        for item in "${problems[@]}"; do
            problem "[$name] $item"
        done
        for item in "${summaries[@]}"; do
            summary "[$name] $item"
        done
    fi
}

# add_report <name> <ping URL> <problem count> <problem>... <summary line>...: appends a
# service's report to REPORT_*.
add_report() {
    local -a PROBLEMS=("${@:4:$3}") SUMMARY=("${@:$((4 + $3))}")
    REPORT_NAMES+=("$1")
    REPORT_URLS+=("$(report_url "$2")")
    REPORT_BODIES+=("$(build_report "$1")")
    REPORT_PROBLEMS+=("$(join_by '; ' "${PROBLEMS[@]}")")
}

# collect_reports: runs the server checks and the checks of every service. Fills REPORT_NAMES,
# REPORT_URLS, REPORT_BODIES and REPORT_PROBLEMS; index 0 is the server report.
collect_reports() {
    local name
    local -a names
    REPORT_NAMES=("")
    REPORT_URLS=("")
    REPORT_BODIES=("")
    REPORT_PROBLEMS=("")
    load_restarts_state
    RESTART_CONTEXT="."
    run_checks
    list_services
    names=("${WORDS[@]}")
    for name in "${names[@]}"; do
        if valid_service_name "$name"; then
            add_service_report "$name"
        else
            problem "Service \"$name\": invalid name (use letters, digits, '.', '_' and '-')"
        fi
    done
    REPORT_URLS[0]=$(report_url "$HC_PING_URL")
    REPORT_BODIES[0]=$(build_report)
    REPORT_PROBLEMS[0]=$(join_by '; ' "${PROBLEMS[@]}")
}

# build_report [service name]: the report text from PROBLEMS and SUMMARY.
build_report() {
    if (( ${#PROBLEMS[@]} > 0 )); then
        printf 'PROBLEMS (%d):\n' "${#PROBLEMS[@]}"
        printf -- '- %s\n' "${PROBLEMS[@]}"
    else
        printf 'All good\n'
    fi
    printf '\nHost: %s\n' "$(uname -n)"
    if [[ -n ${1:-} ]]; then
        printf 'Service: %s\n' "$1"
    fi
    if (( ${#SUMMARY[@]} > 0 )); then
        printf '%s\n' "${SUMMARY[@]}"
    fi
}

# report_url <ping URL>: where the report built from PROBLEMS goes (URL/fail when it lists any).
report_url() {
    if (( ${#PROBLEMS[@]} > 0 )); then
        printf '%s/fail' "$1"
    else
        printf '%s' "$1"
    fi
}

# send_reports: sends all collected reports at once, then logs a line per report; returns 1 if
# any of them couldn't be sent.
send_reports() {
    local i prefix rc failed=0
    local -a pids=()
    for i in "${!REPORT_URLS[@]}"; do
        curl -fsS -m 10 --retry 5 -o /dev/null --data-raw "${REPORT_BODIES[i]}" "${REPORT_URLS[i]}" &
        pids[i]=$!
    done
    for i in "${!pids[@]}"; do
        prefix=""
        [[ -z ${REPORT_NAMES[i]} ]] || prefix="[${REPORT_NAMES[i]}] "
        rc=0
        wait "${pids[i]}" || rc=$?
        if (( rc != 0 )); then
            echo "Error: ${prefix}failed to send the report (curl exit code $rc)" >&2
            failed=1
        elif [[ -n ${REPORT_PROBLEMS[i]} ]]; then
            echo "${prefix}PROBLEMS: ${REPORT_PROBLEMS[i]} (report sent to /fail)"
        else
            echo "${prefix}OK: report sent"
        fi
    done
    return "$failed"
}

print_preview() {
    local i
    collect_reports
    for i in "${!REPORT_URLS[@]}"; do
        (( i == 0 )) || echo
        printf 'Ping URL: %s\n\n%s\n' "${REPORT_URLS[i]}" "${REPORT_BODIES[i]}"
    done
}

cmd_run() {
    load_config
    validate_config
    collect_reports
    save_state
    send_reports
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

# ask_optional <prompt> <current value> <validator> <hint>: Enter keeps the current value, "-"
# clears it; a value the validator rejects is asked again. The answer is left in ANSWER.
ask_optional() {
    while true; do
        ask "$1 (Enter keeps, - for none) [${2:-none}]: "
        case $ANSWER in
            -) ANSWER=""; return 0 ;;
            "") ANSWER=$2 ;;
        esac
        [[ -n $ANSWER ]] || return 0
        "$3" "$ANSWER" && return 0
        echo "$4" >&2
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
    trim_slashes HC_PING_URL
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
TimeoutStartSec=4min
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
    if [[ -n $(join_by '' "${REPORT_PROBLEMS[@]}") ]]; then
        echo "Warning: a report lists problems, so its first ping goes to /fail and healthchecks.io will send an alert."
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
Add a service: sudo $INSTALLED_PATH add <name>
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
    rm -f "$CONF_FILE" "$BIN_FILE" "$CPU_STATE" "$RESTARTS_STATE" "$OOM_STATE"
    rmdir "$STATE_DIR" 2> /dev/null
    echo "hc-monitor removed."
    echo "Pings have stopped: pause or delete the check in healthchecks.io, otherwise it will report the server as down."
    list_services
    if (( ${#WORDS[@]} > 0 )); then
        echo "Service files in ${SERVICES_DIR#"$ROOT"} were kept ($(join_by ', ' "${WORDS[@]}")): delete them if you don't need them, and pause or delete their checks too."
    fi
}

# valid_service_url <url>: a valid ping URL that isn't the server's.
valid_service_url() {
    local url=$1
    valid_url "$url" || return 1
    trim_slashes url
    [[ $url != "$HC_PING_URL" ]]
}

# shell_quote <value>: the value in single quotes, safe to source.
shell_quote() {
    local s=$1 out="'"
    while [[ $s == *"'"* ]]; do
        out+="${s%%"'"*}'\\''"
        s=${s#*"'"}
    done
    printf "%s%s'" "$out" "$s"
}

# write_service_file <name> <ping URL> <services> <ports> <HTTP URL> <HTTP expect>: saves
# SERVICES_DIR/<name>/.env (directories 700, file 600).
write_service_file() {
    local dir="$SERVICES_DIR/$1" tmp
    { mkdir -p "$dir" && chmod 700 "$SERVICES_DIR" "$dir"; } || die 1 "cannot create ${dir#"$ROOT"}"
    tmp=$(mktemp "$dir/.env.XXXXXX") || die 1 "cannot create a temporary file in ${dir#"$ROOT"}"
    if ! {
        echo "# hc-monitor service \"$1\". Change it with: sudo $INSTALLED_PATH add $1 (or edit this file)."
        echo "HC_PING_URL=$(shell_quote "$2")"
        echo "SERVICES=$(shell_quote "$3")"
        echo "PORTS=$(shell_quote "$4")"
        echo "HTTP_URL=$(shell_quote "$5")"
        echo "HTTP_EXPECT=$(shell_quote "$6")"
    } > "$tmp"; then
        rm -f "$tmp"
        die 1 "cannot write ${tmp#"$ROOT"}"
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$dir/.env" || { rm -f "$tmp"; die 1 "cannot write ${dir#"$ROOT"}/.env"; }
}

# preview_service <name>: prints what the service adds: its own report or its lines in the
# server report.
preview_service() {
    REPORT_NAMES=("")
    REPORT_URLS=("")
    REPORT_BODIES=("")
    REPORT_PROBLEMS=("")
    PROBLEMS=()
    SUMMARY=()
    load_restarts_state
    add_service_report "$1"
    if (( ${#REPORT_URLS[@]} > 1 )); then
        printf 'Ping URL: %s\n\n%s\n' "${REPORT_URLS[1]}" "${REPORT_BODIES[1]}"
    else
        echo "Added to the server report:"
        (( ${#PROBLEMS[@]} == 0 )) || printf -- '- %s\n' "${PROBLEMS[@]}"
        (( ${#SUMMARY[@]} == 0 )) || printf '%s\n' "${SUMMARY[@]}"
    fi
}

cmd_add() {
    local name="$1" line key value error="" loaded=0
    local url="" services="" ports="" http_url="" http_expect=""
    local -a lines
    require_root
    valid_service_name "$name" || die 2 "invalid service name: $name (use letters, digits, '.', '_' and '-')"
    load_config
    if [[ -e $SERVICES_DIR/$name/.env ]]; then
        mapfile -t lines < <(service_lines "$name")
        for line in "${lines[@]}"; do
            case $line in
                V$'\t'*)
                    line=${line#V$'\t'}
                    key=${line%%$'\t'*}
                    value=${line#*$'\t'}
                    loaded=1
                    case $key in
                        HC_PING_URL) url=$value ;;
                        SERVICES) services=$value ;;
                        PORTS) ports=$value ;;
                        HTTP_URL) http_url=$value ;;
                        HTTP_EXPECT) http_expect=$value ;;
                    esac
                    ;;
                E$'\t'*) error=${line#E$'\t'} ;;
            esac
        done
        (( loaded )) || die 1 "service $name: ${error:-cannot load ${SERVICES_DIR#"$ROOT"}/$name/.env}"
    fi
    echo "Service $name: ${SERVICES_DIR#"$ROOT"}/$name/.env" >&2
    ask_optional "Ping URL of a separate healthchecks.io check for this service" "$url" valid_service_url \
        "Expected a URL like https://hc-ping.com/<uuid> of a separate check (not the server's), without spaces, quotes, \$, \` or \\."
    url=$ANSWER
    trim_slashes url
    while true; do
        ask_list "Systemd services to watch, space-separated" "$services" check_service_entry
        services=$ANSWER
        ask_list "Local ports to watch, space-separated: 443 or 443/tcp for TCP, 53/udp for UDP" \
            "$ports" check_port_entry
        ports=$ANSWER
        ask_optional "Health check URL" "$http_url" valid_url \
            "Expected a URL like http://localhost:8080/health without spaces, quotes, \$, \` or \\."
        http_url=$ANSWER
        http_expect=${http_url:+$http_expect}
        if [[ -n $http_url ]]; then
            ask_optional "Text the response must contain, as a regular expression" "$http_expect" valid_regex \
                "Expected a single-line regular expression, e.g. \"status\" *: *\"up\"."
            http_expect=$ANSWER
        fi
        [[ -z $services && -z $ports && -z $http_url ]] || break
        echo "Nothing to check: set at least one service, port or health check URL." >&2
    done
    write_service_file "$name" "$url" "$services" "$ports" "$http_url" "$http_expect"
    echo
    echo "The report for $name will look like this:"
    echo
    preview_service "$name"
    echo
    echo "Saved ${SERVICES_DIR#"$ROOT"}/$name/.env; the next run (within 5 minutes) checks it."
    if [[ -n $url ]]; then
        echo "In healthchecks.io, set the schedule of its check to: Period 5 minutes, Grace Time 10 minutes."
    fi
    if [[ ! -e $UNIT_DIR/hc-monitor.timer ]]; then
        echo "hc-monitor isn't installed yet: run sudo bash hc-monitor.sh install."
    fi
}

cmd_remove() {
    local name="$1" file line url=""
    local -a lines
    require_root
    valid_service_name "$name" || die 2 "invalid service name: $name (use letters, digits, '.', '_' and '-')"
    file="$SERVICES_DIR/$name/.env"
    [[ -e $file ]] || die 1 "no such service: $name (${file#"$ROOT"} does not exist)"
    mapfile -t lines < <(service_lines "$name")
    for line in "${lines[@]}"; do
        if [[ $line == V$'\t'HC_PING_URL$'\t'* ]]; then
            url=${line#V$'\t'HC_PING_URL$'\t'}
        fi
    done
    if ! confirm "Remove service $name (${file#"$ROOT"})? [y/N] " n; then
        echo "Cancelled."
        return 0
    fi
    rm -f "$file" || die 1 "cannot remove ${file#"$ROOT"}"
    rmdir "$SERVICES_DIR/$name" 2> /dev/null
    echo "Service $name removed."
    if [[ -n $url ]]; then
        echo "Its check gets no more pings: pause or delete it in healthchecks.io, otherwise it will report the service as down."
    fi
}

usage() {
    cat >&2 <<EOF
Usage:
  sudo bash hc-monitor.sh install          install or reconfigure
  sudo $INSTALLED_PATH add <name>     add or change a service (${SERVICES_DIR#"$ROOT"}/<name>/.env)
  sudo $INSTALLED_PATH remove <name>  remove a service
  $INSTALLED_PATH                     check and send the reports
  $INSTALLED_PATH --dry-run           check and print the reports without sending them
  sudo $INSTALLED_PATH uninstall      remove hc-monitor
EOF
}

main() {
    case "$#:${1:-}" in
        0: | 1:--dry-run | 1:install | 1:uninstall | 2:add | 2:remove) ;;
        *) usage; exit 2 ;;
    esac
    case "${1:-}" in
        "") cmd_run ;;
        --dry-run) cmd_dry_run ;;
        install) cmd_install ;;
        uninstall) cmd_uninstall ;;
        add) cmd_add "$2" ;;
        remove) cmd_remove "$2" ;;
    esac
}

main "$@"
